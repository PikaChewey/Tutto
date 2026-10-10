//
//  EngineCore.swift
//  Tutto (trackpad corner engine)
//
//  The hot path. Two inputs meet here:
//   • raw trackpad frames from MultitouchSupport (background thread, only while a finger is down)
//   • left mouse events from a CGEventTap (main run loop, only when you click)
//  Nothing runs in between: no timers, no polling.
//

import CoreGraphics
import CBridges
import Foundation
import IOKit
import os

/// Contacts handed to the UI while a window is watching the trackpad.
public struct TouchFrame: Equatable, Sendable {
    public var deviceIndex: Int
    public var contacts: [Contact]
}

/// Events the hot path reports back to the main thread.
public enum EngineEvent: Sendable {
    case rightClick(Trigger)
    case frame(TouchFrame)
    /// The trackpad clicked but no touch frames are arriving: restart the listener.
    case touchStreamStale
    /// One line describing a click and the decision (diagnostics mode only).
    case diagnostic(String)
}

public final class EngineCore: @unchecked Sendable {
    /// Marks events Trackpad Corner synthesizes so it never reacts to its own clicks.
    public static let syntheticMarker: Int64 = 0x436F_726E_6572_436C  // "CornerCl"

    private struct Shared {
        var trackers: [TouchTracker] = []
        var rules = RuleSet()
        var converting = false
        var observing = false
        var diagnostics = false
        var lastPublish: UInt64 = 0
        var lastPublishedCount = 0
        var senderCache: [UInt64: SenderKind] = [:]
        var lastFrameAt: UInt64 = 0
        var lastStaleReport: UInt64 = 0
    }

    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    /// The parts of the outside world the engine reads or touches, swappable in tests.
    public struct System: Sendable {
        var tapToClickEnabled: @Sendable (Int) -> Bool = { SystemTrackpad.tapToClickEnabled(deviceIndex: $0) }
        var recentlyTyped: @Sendable () -> Bool = SystemTrackpad.recentlyTyped
        var postRightClick: @Sendable () -> Bool = { EngineCore.postRightClick() }
        var menuUnderPointer: @Sendable (CGPoint) -> Bool = SystemTrackpad.menuContains

        public init() {}
    }

    private let report: @Sendable (EngineEvent) -> Void
    private let system: System

    public init(system: System = System(), report: @escaping @Sendable (EngineEvent) -> Void) {
        self.system = system
        self.report = report
    }

    // MARK: Configuration

    public func setRules(_ rules: RuleSet) {
        shared.withLock { state in
            state.rules = rules
            for i in state.trackers.indices { state.trackers[i].zone = rules.zone }
        }
    }

    /// Troubleshooting only: describe every trackpad click and what Trackpad Corner decided.
    public func setDiagnostics(_ on: Bool) {
        shared.withLock { $0.diagnostics = on }
    }

    public func setObserving(_ observing: Bool) {
        shared.withLock { $0.observing = observing }
    }

    /// One tracker per trackpad, each knowing its physical size.
    public func resetTouches(sizes: [TrackpadSize]) {
        shared.withLock { state in
            state.trackers = sizes.map { size in
                var tracker = TouchTracker()
                tracker.size = size
                tracker.zone = state.rules.zone
                return tracker
            }
            state.converting = false
        }
    }

    // MARK: Multitouch frames (background thread)

    public func handleFrame(deviceIndex: Int, contacts: UnsafePointer<CCContact>?, count: Int) {
        let now = monotonicNanoseconds()
        var touching: [Contact] = []
        touching.reserveCapacity(count)
        if let contacts {
            for i in 0..<count where Contact.isTouching(state: contacts[i].state) {
                let c = contacts[i]
                touching.append(Contact(id: c.identifier, x: Double(c.x), y: Double(c.y), size: Double(c.size)))
            }
        }

        let frame = touching
        let (cornerTap, publish) = shared.withLock { state -> (Bool, Bool) in
            state.lastFrameAt = now
            guard deviceIndex >= 0, deviceIndex < state.trackers.count else { return (false, false) }
            var cornerTap = false
            if let tap = state.trackers[deviceIndex].update(touching: frame, now: now),
               state.rules.tapEnabled,
               ClickDecider.isCornerTap(tap) {
                cornerTap = true
            }
            var publish = false
            if state.observing {
                // ~60 fps for the live preview, plus every change in finger count so it never lags behind.
                if now &- state.lastPublish >= 16_000_000 || frame.count != state.lastPublishedCount {
                    state.lastPublish = now
                    state.lastPublishedCount = frame.count
                    publish = true
                }
            }
            return (cornerTap, publish)
        }

        if publish {
            report(.frame(TouchFrame(deviceIndex: deviceIndex, contacts: frame)))
        }
        // With "Tap to click" on, macOS sends a click for this tap and the event tap converts it.
        // With it off, no click is coming, so Trackpad Corner makes the right-click itself.
        guard cornerTap else { return }
        let tapToClick = system.tapToClickEnabled(deviceIndex)
        let typing = system.recentlyTyped()
        if shared.withLock({ $0.diagnostics }) {
            report(.diagnostic("corner-tap pad\(deviceIndex) tapToClick=\(tapToClick) typing=\(typing) " +
                               (tapToClick ? "-> waiting for macOS's click" : (typing ? "-> ignored (typing)" : "-> making the right-click"))))
        }
        guard !tapToClick, !typing else { return }
        let synthesize = shared.withLock { state -> Bool in
            guard deviceIndex < state.trackers.count, let tap = state.trackers[deviceIndex].lastTap,
                  !tap.consumed else { return false }
            state.trackers[deviceIndex].consumeTap()
            return true
        }
        if synthesize {
            DispatchQueue.main.async { [report, system] in
                if system.postRightClick() {
                    report(.rightClick(.tap))
                }
            }
        }
    }

    // MARK: Mouse events (event tap thread)

    /// Returns the event to deliver. Never returns nil: Trackpad Corner only ever
    /// rewrites a click, it never swallows one.
    public func handleMouseEvent(type: CGEventType, event: CGEvent) -> CGEvent {
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker {
            return event
        }

        switch type {
        case .leftMouseDown:
            let sender = senderKind(event)
            if sender == .trackpad {
                // A trackpad click always has a finger on it. No recent frames means the
                // touch stream died (it can after sleep), so ask for a restart.
                let now = monotonicNanoseconds()
                let stale = shared.withLock { state -> Bool in
                    guard now &- state.lastFrameAt > 1_500_000_000,
                          now &- state.lastStaleReport > 5_000_000_000 else { return false }
                    state.lastStaleReport = now
                    return true
                }
                if stale { report(.touchStreamStale) }
            }
            let (decision, snapshot): (ClickDecider.Decision, String?) = shared.withLock { state in
                state.converting = false
                let now = monotonicNanoseconds()
                let decision = ClickDecider.decide(trackers: state.trackers, now: now, rules: state.rules)
                let snapshot = state.diagnostics ? Self.describe(state.trackers, now: now) : nil
                if let index = decision.consumesTapOf, index < state.trackers.count {
                    state.trackers[index].consumeTap()
                }
                return (decision, snapshot)
            }
            func log(_ outcome: String) {
                guard let snapshot else { return }
                let trigger = decision.trigger?.rawValue ?? "none"
                report(.diagnostic("sender=\(sender) decided=\(trigger) result=\(outcome) \(snapshot)"))
            }
            // Clicking on an open menu chooses an item. Turning that into another
            // right-click would just reopen a menu.
            // Fingers down during a click were pressing, so their lift isn't a tap.
            func settle(_ right: Bool) {
                shared.withLock { state in
                    for i in state.trackers.indices { state.trackers[i].markPressed(rightClick: right) }
                }
            }
            guard let trigger = decision.trigger, sender != .other else {
                settle(false)
                log("left")
                return event
            }
            if system.menuUnderPointer(event.location) {
                settle(false)
                log("left(menu)")
                return event
            }
            settle(true)
            log("right")
            event.type = .rightMouseDown
            event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(CGMouseButton.right.rawValue))
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            shared.withLock { $0.converting = true }
            report(.rightClick(trigger))
            return event

        case .rightMouseDown:
            // macOS's own secondary click (two fingers). Never changed; logged in diagnostics
            // so a corner press that stayed left and was retried this way shows up as a miss.
            let snapshot = shared.withLock { state in
                state.diagnostics ? Self.describe(state.trackers, now: monotonicNanoseconds()) : nil
            }
            if let snapshot { report(.diagnostic("native-right \(snapshot)")) }
            return event

        case .leftMouseDragged:
            if shared.withLock({ $0.converting }) {
                event.type = .rightMouseDragged
                event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(CGMouseButton.right.rawValue))
            }
            return event

        case .leftMouseUp:
            let wasConverting = shared.withLock { state -> Bool in
                defer { state.converting = false }
                return state.converting
            }
            if wasConverting {
                event.type = .rightMouseUp
                event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(CGMouseButton.right.rawValue))
                event.setIntegerValueField(.mouseEventClickState, value: 1)
            }
            return event

        default:
            return event
        }
    }

    /// Called when macOS disabled the tap (it was too slow, or secure input).
    /// If a converted press was in flight, release the right button so nothing sticks.
    public func recoverFromTapInterruption() {
        let wasConverting = shared.withLock { state -> Bool in
            defer { state.converting = false }
            return state.converting
        }
        if wasConverting, let location = CGEvent(source: nil)?.location,
           let up = CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp,
                            mouseCursorPosition: location, mouseButton: .right) {
            up.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
            up.post(tap: .cghidEventTap)
        }
    }

    // MARK: Helpers

    /// Posts a right-click at the pointer. Used only when "Tap to click" is off.
    @discardableResult
    public static func postRightClick() -> Bool {
        guard let location = CGEvent(source: nil)?.location else { return false }
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(mouseEventSource: source, mouseType: .rightMouseDown,
                                 mouseCursorPosition: location, mouseButton: .right),
              let up = CGEvent(mouseEventSource: source, mouseType: .rightMouseUp,
                               mouseCursorPosition: location, mouseButton: .right) else { return false }
        for event in [down, up] {
            event.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.post(tap: .cghidEventTap)
        }
        return true
    }

    public enum SenderKind: Sendable { case unknown, trackpad, other }

    /// Compact text for diagnostics: every finger (x, y, press growth, in zone, mm since its
    /// last click) plus the latest tap and lift. Trackpad positions only.
    public static func describe(_ trackers: [TouchTracker], now: UInt64) -> String {
        func ms(_ t: UInt64) -> Int { now >= t ? Int((now - t) / 1_000_000) : -1 }
        var parts: [String] = []
        for (index, tracker) in trackers.enumerated() {
            let fingers = tracker.active.map { f in
                String(format: "(%.3f,%.3f g=%.2f z=%d age=%d since=%@)", f.x, f.y, f.pressGrowth,
                       f.inZoneNow ? 1 : 0, ms(f.downAt),
                       f.clickX == nil ? "-" : String(format: "%.1f", f.travelSinceClick))
            }.joined(separator: " ")
            var line = "pad\(index)=[\(fingers)]"
            if let tap = tracker.lastTap {
                line += String(format: " tap=(%.3f,%.3f z=%d age=%d used=%d)", tap.x, tap.y,
                               tap.inZone ? 1 : 0, ms(tap.liftedAt), tap.consumed ? 1 : 0)
            }
            if let lift = tracker.lastLift {
                line += String(format: " lift=(%.3f,%.3f z=%d age=%d)", lift.x, lift.y, lift.inZone ? 1 : 0, ms(lift.liftedAt))
            }
            parts.append(line)
        }
        return parts.joined(separator: " ")
    }

    /// Quartz stores the IORegistry ID of the HID service that produced a mouse event
    /// in an undocumented field (87). Multitouch drivers are trackpads; anything else
    /// (a USB/Bluetooth mouse) is never remapped. Unknown senders are trusted, because
    /// the decision already required a finger in the corner.
    private func senderKind(_ event: CGEvent) -> SenderKind {
        guard let field = CGEventField(rawValue: 87) else { return .unknown }
        let sender = UInt64(bitPattern: event.getIntegerValueField(field))
        guard sender != 0 else { return .unknown }
        if let cached = shared.withLock({ $0.senderCache[sender] }) {
            return cached
        }
        var kind = SenderKind.unknown
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(sender))
        if service != IO_OBJECT_NULL {
            var name = [CChar](repeating: 0, count: 128)
            if IOObjectGetClass(service, &name) == KERN_SUCCESS {
                kind = String(cString: name).contains("Multitouch") ? .trackpad : .other
            }
            IOObjectRelease(service)
        }
        let result = kind
        shared.withLock { state in
            if state.senderCache.count > 32 { state.senderCache.removeAll() }
            state.senderCache[sender] = result
        }
        return result
    }
}

// MARK: - System trackpad settings (read-only)

public enum SystemTrackpad {
    /// Whether "Tap to click" is on for this trackpad. Read live from the trackpad's driver,
    /// which holds the settings macOS actually applies (saved preferences can be stale, and
    /// the built-in and Bluetooth trackpads keep separate copies). Trackpad Corner only reads it.
    public static func tapToClickEnabled(deviceIndex: Int) -> Bool {
        let service = CCMultitouchDeviceService(Int32(deviceIndex))
        if service != 0,
           let value = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "MultitouchPreferences" as CFString,
                                                       kCFAllocatorDefault,
                                                       IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)),
           let preferences = value as? [String: Any],
           let clicking = preferences["Clicking"] as? NSNumber {
            return clicking.boolValue
        }
        // Fallback: the built-in trackpad's saved setting.
        let domain = "com.apple.AppleMultitouchTrackpad" as CFString
        CFPreferencesAppSynchronize(domain)
        return (CFPreferencesCopyAppValue("Clicking" as CFString, domain) as? NSNumber)?.boolValue ?? false
    }

    /// "Dragging" (double-tap drag) or drag lock makes macOS deliver tap clicks later.
    public static func tapToDragEnabled() -> Bool {
        for domain in ["com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad"] {
            CFPreferencesAppSynchronize(domain as CFString)
            for key in ["Dragging", "DragLock"] {
                if let value = CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? NSNumber,
                   value.boolValue {
                    return true
                }
            }
        }
        return false
    }

    /// True when the pointer is over an open context menu or menu bar menu
    /// (they live at the pop-up menu window level). Takes about 0.1 ms.
    public static func menuContains(_ point: CGPoint) -> Bool {
        let level = Int(CGWindowLevelForKey(.popUpMenuWindow))
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                        kCGNullWindowID) as? [[String: Any]] else { return false }
        return windows.contains { window in
            guard (window[kCGWindowLayer as String] as? Int) == level,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
            return rect.contains(point)
        }
    }

    /// Ignore taps while typing, so a palm brushing the corner never right-clicks.
    public static func recentlyTyped() -> Bool {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown) < 0.4
    }
}
