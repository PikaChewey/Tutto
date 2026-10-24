//
//  ShortcutTap.swift
//  Tutto
//
//  Global shortcuts that win even when another app has registered the same keys. macOS hands
//  a registered shortcut to whichever app registered it first, without telling the second;
//  an event tap in front of the session sees the key press before that happens. It swallows
//  only exact matches (and their key-up) and lets everything else through untouched.
//
//  While a password field has focus macOS hides keystrokes from taps (Secure Input), so the
//  regular registration stays in place underneath and answers then.
//

@preconcurrency import CoreGraphics
import Foundation

public final class ShortcutTap: @unchecked Sendable {
    private let lock = NSLock()
    private var port: CFMachPort?
    private var runLoop: CFRunLoop?
    private var _bindings: [KeyShortcut: String] = [:]
    private var _suspended = false
    private var swallowed = Set<Int64>()
    private let deliver: @Sendable (String) -> Void

    /// `deliver` gets the id bound to the shortcut, on the tap's thread.
    public init(deliver: @escaping @Sendable (String) -> Void) {
        self.deliver = deliver
    }

    /// Shortcut → id of what it does.
    public var bindings: [KeyShortcut: String] {
        get { lock.withLock { _bindings } }
        set { lock.withLock { _bindings = newValue } }
    }

    /// While a shortcut recorder listens, every key passes through.
    public var isSuspended: Bool {
        get { lock.withLock { _suspended } }
        set { lock.withLock { _suspended = newValue } }
    }

    public var isRunning: Bool { lock.withLock { port != nil } }

    public var isEnabled: Bool {
        guard let port = lock.withLock({ self.port }) else { return false }
        return CGEvent.tapIsEnabled(tap: port)
    }

    /// False if macOS refused the tap (Accessibility not allowed).
    @discardableResult
    public func start(name: String = "Shortcut tap") -> Bool {
        stop()
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let tap = Unmanaged<ShortcutTap>.fromOpaque(context).takeUnretainedValue()
                return tap.handle(type: type, event: event).map { Unmanaged.passUnretained($0) }
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
        thread.name = name
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
                self.swallowed.removeAll()
            }
            return (self.port, self.runLoop)
        }
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let loop { CFRunLoopStop(loop) }
    }

    /// The shortcut a key event is, if its modifiers are only ⌘ ⌥ ⌃ ⇧ (arrow keys also carry
    /// the keypad and fn flags, which don't count).
    static func shortcut(code: Int64, flags: CGEventFlags) -> KeyShortcut {
        var modifiers: KeyShortcut.Modifiers = []
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        return KeyShortcut(keyCode: UInt16(truncatingIfNeeded: code), modifiers: modifiers)
    }

    /// Returns nil to swallow the event.
    func handle(type: CGEventType, event: CGEvent) -> CGEvent? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port = lock.withLock({ self.port }) { CGEvent.tapEnable(tap: port, enable: true) }
            return event
        case .keyDown, .keyUp:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            lock.lock()
            if type == .keyUp {
                let wasSwallowed = swallowed.remove(code) != nil
                lock.unlock()
                return wasSwallowed ? nil : event
            }
            guard !_suspended, let id = _bindings[Self.shortcut(code: code, flags: event.flags)] else {
                lock.unlock()
                return event
            }
            swallowed.insert(code)
            lock.unlock()
            deliver(id)
            return nil
        default:
            return event
        }
    }
}
