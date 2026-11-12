//
//  KeyboardCleanLock.swift
//  Tutto (keyboard cleaning logic)
//
//  Which events the cleaning lock swallows, the lengths you can choose, and the
//  countdown text. Pure, so it is tested without a tap.
//

@preconcurrency import CoreGraphics
import Foundation

public enum KeyboardCleanLock {
    public static let allowedSeconds = [15, 30, 60]
    public static let defaultSeconds = 30

    /// Anything not in the list falls back to the default.
    public static func clamped(_ seconds: Int) -> Int {
        allowedSeconds.contains(seconds) ? seconds : defaultSeconds
    }

    /// Raw values for events that have no `CGEventType` case: system-defined (media,
    /// brightness and volume keys) and the trackpad gesture family.
    static let systemDefined: UInt32 = 14
    static let gestureTypes: [UInt32] = [18, 19, 20, 29, 30, 31, 32]  // gesture, begin/end, magnify, swipe, rotate, smart zoom

    /// Event types the lock swallows. Pointer movement is left alone.
    public static let blockedTypes: Set<UInt32> = {
        var set: Set<UInt32> = [systemDefined]
        let known: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged,
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
            .scrollWheel, .tabletPointer, .tabletProximity,
        ]
        for type in known { set.insert(type.rawValue) }
        for raw in gestureTypes { set.insert(raw) }
        return set
    }()

    public static func blocks(_ rawType: UInt32) -> Bool { blockedTypes.contains(rawType) }

    public static func blocks(_ type: CGEventType) -> Bool { blocks(type.rawValue) }

    /// The bit mask to hand to `CGEvent.tapCreate`.
    public static var eventMask: CGEventMask {
        blockedTypes.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1)) }
    }

    /// "0:27", rounded up so the display never shows 0:00 while still locked.
    public static func countdownText(secondsLeft: Double) -> String {
        let whole = max(0, Int(secondsLeft.rounded(.up)))
        return "\(whole / 60):" + String(format: "%02d", whole % 60)
    }

    /// 1 at the start, 0 at the end, for the thin ring.
    public static func progress(secondsLeft: Double, total: Int) -> Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, secondsLeft / Double(total)))
    }
}
