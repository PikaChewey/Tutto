//
//  EventTapThread.swift
//  Tutto (trackpad corner engine)
//
//  The event tap sits in front of every left click on the Mac, so it gets its own
//  high-priority thread. Nothing on the main thread (UI, SwiftUI layout, system
//  dialogs) can ever delay a click.
//

@preconcurrency import CoreGraphics
import Foundation

public final class EventTapThread: @unchecked Sendable {
    private let core: EngineCore
    private let lock = NSLock()
    private var port: CFMachPort?
    private var runLoop: CFRunLoop?

    public init(core: EngineCore) {
        self.core = core
    }

    /// Creates the tap and starts its thread. Returns false if macOS refused the tap
    /// (usually because Accessibility access is missing).
    public func start() -> Bool {
        stop()
        let mask = (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)  // only read, for diagnostics

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let tapThread = Unmanaged<EventTapThread>.fromOpaque(context).takeUnretainedValue()
                return Unmanaged.passUnretained(tapThread.handle(type: type, event: event))
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            guard let self else {
                ready.signal()
                return
            }
            let loop = CFRunLoopGetCurrent()
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            self.lock.withLock { self.runLoop = loop }
            ready.signal()
            CFRunLoopRun()
            CFRunLoopRemoveSource(loop, source, .commonModes)
        }
        thread.name = "Trackpad Corner event tap"
        thread.qualityOfService = QualityOfService.userInteractive
        lock.withLock { self.port = port }
        thread.start()
        ready.wait()
        return true
    }

    public func stop() {
        let (port, loop) = lock.withLock { () -> (CFMachPort?, CFRunLoop?) in
            defer {
                self.port = nil
                self.runLoop = nil
            }
            return (self.port, self.runLoop)
        }
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let loop {
            CFRunLoopStop(loop)
        }
    }

    // MARK: Tap thread

    private func handle(type: CGEventType, event: CGEvent) -> CGEvent {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS switched the tap off. Release anything in flight and switch it back on.
            core.recoverFromTapInterruption()
            if let port = lock.withLock({ self.port }) {
                CGEvent.tapEnable(tap: port, enable: true)
            }
            return event
        default:
            return core.handleMouseEvent(type: type, event: event)
        }
    }
}
