//
//  StripInput.swift
//  Tutto (scrolling strip)
//
//  The strip's mouse and trackpad input, on its own thread:
//  - ⌃⌥ + scroll moves along the strip (a wheel notch is one window; a trackpad scroll follows
//    the fingers). Only those scroll events are held back from the app under the pointer.
//  - A three- or four-finger horizontal swipe moves the strip with the fingers. Swipes are
//    only watched, never held back, so macOS's own gestures keep working.
//  - Pointer moves, for focus follows mouse.
//  The taps exist only while one of these is switched on.
//

@preconcurrency import CoreGraphics
import AppKit

final class StripInputTap: @unchecked Sendable {
    enum Event: Sendable {
        /// Points along the strip (positive moves the view right), from ⌃⌥ + a trackpad scroll.
        case scroll(points: Double, ended: Bool)
        /// One wheel notch with ⌃⌥ held: +1 is the next window, -1 the one before.
        case notch(Int)
        /// Fingers moved this fraction of the trackpad's width (positive: to the right).
        case swipe(fraction: Double)
        case swipeEnded
        case pointer(CGPoint)
    }

    struct Options: Equatable, Sendable {
        var scroll = false
        var swipeFingers = 0
        var pointer = false
        var isEmpty: Bool { !scroll && swipeFingers == 0 && !pointer }
    }

    private let lock = NSLock()
    private var activePort: CFMachPort?
    private var passivePort: CFMachPort?
    private var runLoop: CFRunLoop?
    private var options = Options()
    private let deliver: @Sendable (Event) -> Void

    // Swipe tracking (tap thread only).
    private enum SwipeState { case idle, deciding, horizontal, rejected }
    private var swipeState = SwipeState.idle
    private var lastX: Double?
    private var travel = CGVector.zero
    private var lastY: Double?
    private var scrolling = false

    init(deliver: @escaping @Sendable (Event) -> Void) {
        self.deliver = deliver
    }

    var isRunning: Bool { lock.withLock { activePort != nil || passivePort != nil } }

    /// Starts (or reconfigures) the taps for `options`. False if macOS refused them.
    @discardableResult
    func start(_ options: Options) -> Bool {
        stop()
        guard !options.isEmpty else { return true }
        lock.withLock { self.options = options }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<StripInputTap>.fromOpaque(context).takeUnretainedValue()
            return tap.handle(type, event).map { Unmanaged.passUnretained($0) }
        }
        var active: CFMachPort?
        if options.scroll {
            active = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                       eventsOfInterest: CGEventMask(1 << CGEventType.scrollWheel.rawValue),
                                       callback: callback, userInfo: context)
            if active == nil { return false }
        }
        var passiveMask: UInt64 = 0
        if options.swipeFingers > 0 { passiveMask |= 1 << 29 }  // NSEventTypeGesture: trackpad touches
        if options.pointer { passiveMask |= 1 << CGEventType.mouseMoved.rawValue }
        var passive: CFMachPort?
        if passiveMask != 0 {
            passive = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                        eventsOfInterest: CGEventMask(passiveMask), callback: callback, userInfo: context)
        }
        guard active != nil || passive != nil else { return false }

        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            guard let self else {
                ready.signal()
                return
            }
            let loop = CFRunLoopGetCurrent()
            var sources: [CFRunLoopSource] = []
            for port in [active, passive].compactMap({ $0 }) {
                if let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) {
                    CFRunLoopAddSource(loop, source, .commonModes)
                    sources.append(source)
                }
                CGEvent.tapEnable(tap: port, enable: true)
            }
            self.lock.withLock { self.runLoop = loop }
            ready.signal()
            CFRunLoopRun()
            for source in sources { CFRunLoopRemoveSource(loop, source, .commonModes) }
        }
        thread.name = "Strip input"
        thread.qualityOfService = .userInteractive
        lock.withLock {
            activePort = active
            passivePort = passive
        }
        thread.start()
        ready.wait()
        return true
    }

    func stop() {
        let (ports, loop) = lock.withLock { () -> ([CFMachPort], CFRunLoop?) in
            defer {
                activePort = nil
                passivePort = nil
                runLoop = nil
            }
            return ([activePort, passivePort].compactMap { $0 }, runLoop)
        }
        for port in ports {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let loop { CFRunLoopStop(loop) }
    }

    /// macOS switches taps off after a timeout or across sleep.
    var isEnabled: Bool {
        let ports = lock.withLock { [activePort, passivePort].compactMap { $0 } }
        return !ports.isEmpty && ports.allSatisfy { CGEvent.tapIsEnabled(tap: $0) }
    }

    // MARK: Tap thread

    private func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            let ports = lock.withLock { [activePort, passivePort].compactMap { $0 } }
            ports.forEach { CGEvent.tapEnable(tap: $0, enable: true) }
            return event
        case .scrollWheel:
            return scroll(event)
        case .mouseMoved:
            deliver(.pointer(event.location))
            return event
        default:
            if type.rawValue == 29 { gesture(event) }
            return event
        }
    }

    private func scroll(_ event: CGEvent) -> CGEvent? {
        let flags = event.flags
        guard flags.contains(.maskControl), flags.contains(.maskAlternate), !flags.contains(.maskCommand) else {
            if scrolling {
                scrolling = false
                deliver(.scroll(points: 0, ended: true))
            }
            return event
        }
        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        if continuous {
            // Momentum after the fingers lift is held back too: the strip settles on its own.
            guard momentum == 0 else { return nil }
            // Sideways or up and down, whichever the fingers moved more. Scrolling "down" (content
            // moving up) means further along the strip.
            let horizontal = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
            let vertical = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
            let points = abs(horizontal) >= abs(vertical) ? -horizontal : -vertical
            let ended = phase == 4 || phase == 8
            scrolling = !ended
            deliver(.scroll(points: points, ended: ended))
        } else {
            let lines = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            let sideways = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
            let step = lines != 0 ? (lines > 0 ? -1 : 1) : (sideways > 0 ? -1 : sideways < 0 ? 1 : 0)
            if step != 0 { deliver(.notch(step)) }
        }
        return nil
    }

    private func gesture(_ event: CGEvent) {
        let fingers = lock.withLock { options.swipeFingers }
        guard fingers > 0, let ns = NSEvent(cgEvent: event) else { return }
        let touching = ns.allTouches().filter { $0.phase != .ended && $0.phase != .cancelled && !$0.isResting }
        guard touching.count == fingers else {
            if swipeState == .horizontal {
                deliver(.swipeEnded)
                swipeState = .rejected
            }
            if touching.count < fingers {
                swipeState = .idle
                lastX = nil
                lastY = nil
            }
            return
        }
        let x = touching.reduce(0) { $0 + Double($1.normalizedPosition.x) } / Double(fingers)
        let y = touching.reduce(0) { $0 + Double($1.normalizedPosition.y) } / Double(fingers)
        defer {
            lastX = x
            lastY = y
        }
        guard let lastX, let lastY else {
            swipeState = .deciding
            travel = .zero
            return
        }
        let dx = x - lastX
        let dy = y - lastY
        switch swipeState {
        case .idle:
            swipeState = .deciding
            travel = .zero
        case .deciding:
            travel.dx += dx
            travel.dy += dy
            // Decide once the fingers have clearly gone one way: sideways moves the strip,
            // up or down is left to macOS (Mission Control, App Exposé).
            if abs(travel.dy) > 0.03, abs(travel.dy) > abs(travel.dx) {
                swipeState = .rejected
            } else if abs(travel.dx) > 0.02, abs(travel.dx) > abs(travel.dy) * 1.2 {
                swipeState = .horizontal
                deliver(.swipe(fraction: travel.dx))
            }
        case .horizontal:
            deliver(.swipe(fraction: dx))
        case .rejected:
            break
        }
    }
}
