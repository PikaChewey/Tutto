//
//  KeyboardCleanTap.swift
//  Tutto (keyboard cleaning)
//
//  An active session event tap that swallows keys, clicks, scrolls and gestures while
//  the cleaning lock is on. It runs on its own thread so a busy main thread can never
//  let a key through, and it exists only between start() and stop().
//

@preconcurrency import CoreGraphics
import Foundation

public final class KeyboardCleanTap: @unchecked Sendable {
    private let lock = NSLock()
    private var port: CFMachPort?
    private var runLoop: CFRunLoop?

    public init() {}

    /// Creates the tap. Returns false if macOS refused it (Accessibility is off).
    public func start() -> Bool {
        stop()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: KeyboardCleanLock.eventMask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let tap = Unmanaged<KeyboardCleanTap>.fromOpaque(context).takeUnretainedValue()
                return tap.handle(type: type, event: event)
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
        thread.name = "Keyboard cleaning tap"
        thread.qualityOfService = .userInteractive
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
        if let loop { CFRunLoopStop(loop) }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS switched the tap off: switch it straight back on so the lock holds.
            if let port = lock.withLock({ self.port }) { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        default:
            return KeyboardCleanLock.blocks(type) ? nil : Unmanaged.passUnretained(event)
        }
    }
}
