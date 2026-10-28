//
//  SwitcherKeyTap.swift
//  Tutto (window switcher)
//
//  Takes ⌘Tab away from macOS's app switcher without switching it off. An event tap in
//  front of the session swallows the ⌘Tab key press before the system sees it; every other
//  key passes through untouched. Nothing in the system is reconfigured, so if Tutto quits or
//  crashes the tap simply disappears and macOS's own ⌘Tab is back the same instant.
//
//  It runs on its own high-priority thread so a busy main thread can never delay typing,
//  and the callback only looks at a key code and modifier flags.
//
//  While a password field has focus macOS hides keystrokes from all taps (Secure Input);
//  ⌘Tab then reaches macOS's own switcher, which is the right fallback.
//

@preconcurrency import CoreGraphics
import Carbon.HIToolbox
import Foundation

public final class SwitcherKeyTap: @unchecked Sendable {
    public enum Event: Sendable, Equatable {
        /// The trigger was pressed: Tab (all windows) or the key above Tab (front app's windows).
        case trigger(backward: Bool, appWindows: Bool, isRepeat: Bool)
        /// A key pressed while the switcher is open (key code, shift held).
        case key(code: Int, shift: Bool, isRepeat: Bool)
        /// The trigger modifier was let go.
        case released
        /// One of Tutto's own shortcuts on the switcher's keys (⇧⌘` for capture and edit): taken
        /// here, before macOS's window cycling can, and run as that shortcut.
        case shortcut(KeyShortcut)
    }

    public enum Mode: Int, Sendable {
        /// Waiting for the trigger.
        case idle
        /// Switcher on screen: keys are routed to it.
        case open
        /// The switcher's text field (search, rename) has the keyboard: keys pass through.
        case typing
    }

    public enum Trigger: String, Sendable, CaseIterable {
        case command, option
        var flag: CGEventFlags { self == .command ? .maskCommand : .maskAlternate }
    }

    private let lock = NSLock()
    private var port: CFMachPort?
    private var runLoop: CFRunLoop?
    private var _mode: Mode = .idle
    private var _trigger: Trigger = .command
    private var _appWindowsKey = true
    private var _claimed: Set<KeyShortcut> = []
    private var swallowed = Set<Int64>()
    /// Whether the trigger modifier is down, as the key events themselves say. Tracked here
    /// because the hardware state misses software-posted keys (remote control, automation),
    /// and macOS still shows modifier changes to taps during Secure Input.
    private var _triggerHeld = false
    /// Last sign of life from the switcher while it's open (system uptime).
    private var lastBeat: TimeInterval = 0
    /// If the switcher stops checking in for this long while open, the tap lets the keyboard
    /// go: a hung or confused switcher must never hold on to every keystroke.
    public static let heartbeatTimeout: TimeInterval = 2
    private let deliver: @Sendable (Event) -> Void

    public init(deliver: @escaping @Sendable (Event) -> Void) {
        self.deliver = deliver
    }

    public var mode: Mode {
        get { lock.withLock { _mode } }
        set { lock.withLock { _mode = newValue } }
    }

    public var trigger: Trigger {
        get { lock.withLock { _trigger } }
        set { lock.withLock { _trigger = newValue } }
    }

    /// Whether the key above Tab opens the front app's windows.
    public var appWindowsKey: Bool {
        get { lock.withLock { _appWindowsKey } }
        set { lock.withLock { _appWindowsKey = newValue } }
    }

    /// Tutto's own shortcuts on Tab or the key above it: they run as those shortcuts instead of
    /// opening the switcher, and neither macOS nor the front app ever sees them.
    public var claimed: Set<KeyShortcut> {
        get { lock.withLock { _claimed } }
        set { lock.withLock { _claimed = newValue } }
    }

    public var isRunning: Bool { lock.withLock { port != nil } }

    /// The trigger modifier is held, per the last keyboard event the tap saw.
    public var isTriggerHeld: Bool { lock.withLock { _triggerHeld } }

    func setLastBeatForTesting(_ value: TimeInterval) { lock.withLock { lastBeat = value } }

    /// The switcher calls this at least twice a second while it's open.
    public func heartbeat() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.withLock { lastBeat = now }
    }

    /// Creates the tap and its thread. False if macOS refused (Accessibility not allowed).
    public func start() -> Bool {
        stop()
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let tap = Unmanaged<SwitcherKeyTap>.fromOpaque(context).takeUnretainedValue()
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
        thread.name = "Window switcher key tap"
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
                self._mode = .idle
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

    /// Whether macOS has switched the tap off (it does after a timeout, or across sleep).
    public var isEnabled: Bool {
        guard let port = lock.withLock({ self.port }) else { return false }
        return CGEvent.tapIsEnabled(tap: port)
    }

    // MARK: Tap thread

    /// Returns nil to swallow the event.
    func handle(type: CGEventType, event: CGEvent) -> CGEvent? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port = lock.withLock({ self.port }) { CGEvent.tapEnable(tap: port, enable: true) }
            return event
        case .flagsChanged:
            let (mode, held) = lock.withLock { () -> (Mode, Bool) in
                _triggerHeld = event.flags.contains(_trigger.flag)
                return (_mode, _triggerHeld)
            }
            if mode == .open, !held { deliver(.released) }
            return event
        case .keyDown, .keyUp:
            return handleKey(type == .keyDown, event)
        default:
            return event
        }
    }

    private func handleKey(_ down: Bool, _ event: CGEvent) -> CGEvent? {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        lock.lock()
        let mode = _mode, trigger = _trigger, appKey = _appWindowsKey
        _triggerHeld = flags.contains(trigger.flag)
        if !down {
            // Swallow the release of every key whose press was swallowed, nothing else.
            let wasSwallowed = swallowed.remove(code) != nil
            lock.unlock()
            return wasSwallowed ? nil : event
        }
        switch mode {
        case .typing:
            lock.unlock()
            return event
        case .idle:
            if code == Int64(kVK_Tab) || code == Int64(kVK_ANSI_Grave), !_claimed.isEmpty {
                let pressed = ShortcutTap.shortcut(code: code, flags: flags)
                if _claimed.contains(pressed) {
                    swallowed.insert(code)
                    lock.unlock()
                    if !isRepeat { deliver(.shortcut(pressed)) }
                    return nil
                }
            }
            let others: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl]
            let extra = flags.intersection(others).subtracting(trigger.flag)
            let isTab = code == Int64(kVK_Tab)
            let isAppKey = code == Int64(kVK_ANSI_Grave) && appKey
            guard flags.contains(trigger.flag), extra.isEmpty, isTab || isAppKey else {
                lock.unlock()
                return event
            }
            // Open right here, on the tap thread, so keys that follow in the next
            // milliseconds are already routed to the switcher.
            _mode = .open
            lastBeat = ProcessInfo.processInfo.systemUptime
            swallowed.insert(code)
            lock.unlock()
            deliver(.trigger(backward: flags.contains(.maskShift), appWindows: isAppKey, isRepeat: isRepeat))
            return nil
        case .open:
            if ProcessInfo.processInfo.systemUptime - lastBeat > Self.heartbeatTimeout {
                _mode = .idle
                lock.unlock()
                return event
            }
            swallowed.insert(code)
            lock.unlock()
            if code == Int64(kVK_Tab) {
                deliver(.trigger(backward: flags.contains(.maskShift), appWindows: false, isRepeat: isRepeat))
            } else {
                deliver(.key(code: Int(code), shift: flags.contains(.maskShift), isRepeat: isRepeat))
            }
            return nil
        }
    }
}
