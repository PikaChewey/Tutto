//
//  KeystrokeRules.swift
//  Tutto
//
//  What the keycap overlay shows while a recording runs, kept apart from AppKit so it can be
//  tested: the text of each keycap from a key code and modifier flags, which presses count as
//  shortcuts, the "×3" for a key pressed again and again, and the short rolling string for typing.
//

import Carbon.HIToolbox
import Foundation

/// How much of what you press the recording shows.
public enum KeystrokeMode: String, CaseIterable, Sendable {
    case off, shortcuts, everyKey

    public var title: String {
        switch self {
        case .off: "Off"
        case .shortcuts: "Shortcuts"
        case .everyKey: "Every key"
        }
    }
}

public enum KeystrokeRules {
    /// Keys that mean something on their own: Esc, Return, Tab, Delete, the arrows and F-keys.
    static let namedKeys: Set<Int> = {
        var keys = KeyShortcut.functionKeys
        for key in [kVK_Escape, kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab, kVK_Delete, kVK_ForwardDelete,
                    kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow] {
            keys.insert(key)
        }
        return keys
    }()

    /// The modifier keycaps in the order the Mac writes them: ⌃ ⌥ ⇧ ⌘.
    public static func modifierCaps(_ modifiers: KeyShortcut.Modifiers) -> [String] {
        var caps: [String] = []
        if modifiers.contains(.control) { caps.append("⌃") }
        if modifiers.contains(.option) { caps.append("⌥") }
        if modifiers.contains(.shift) { caps.append("⇧") }
        if modifiers.contains(.command) { caps.append("⌘") }
        return caps
    }

    /// The keycaps for a press: modifiers, then the key ("⇧", "⌘", "4").
    public static func keycaps(keyCode: UInt16, modifiers: KeyShortcut.Modifiers,
                               name: (UInt16) -> String = KeyShortcut.keyName(for:)) -> [String] {
        modifierCaps(modifiers) + [keyName(keyCode, name: name)]
    }

    /// The name on a key's cap: words for the keys people look for, the layout's letter otherwise.
    public static func keyName(_ keyCode: UInt16, name: (UInt16) -> String = KeyShortcut.keyName(for:)) -> String {
        switch Int(keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter: return "Return"
        case kVK_Escape: return "Esc"
        case kVK_Tab: return "Tab"
        case kVK_Space: return "Space"
        case kVK_Delete: return "Delete"
        case kVK_ForwardDelete: return "Fwd Delete"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default: return name(keyCode)
        }
    }

    /// The Shortcuts filter: a key pressed with ⌘, ⌃ or ⌥, or one of Esc, Return, Tab, Delete,
    /// the arrows and the F-keys. Plain typing (and ⇧ with a letter) isn't a shortcut.
    public static func isShortcut(keyCode: UInt16, modifiers: KeyShortcut.Modifiers) -> Bool {
        if !modifiers.isDisjoint(with: [.command, .control, .option]) { return true }
        return namedKeys.contains(Int(keyCode))
    }

    /// Whether a modifier held down alone is worth a cap: ⌘, ⌃ or ⌥ (⇧ alone is noise).
    public static func showsModifiersAlone(_ modifiers: KeyShortcut.Modifiers) -> Bool {
        !modifiers.isDisjoint(with: [.command, .control, .option])
    }

    /// Characters that belong in the typing string: printable, not a control character.
    public static func isTypable(_ text: String) -> Bool {
        guard let scalar = text.unicodeScalars.first else { return false }
        return !CharacterSet.controlCharacters.contains(scalar)
            && !(0xF700...0xF8FF).contains(scalar.value)  // arrows, F-keys and the like
    }
}

/// What the overlay shows right now.
public enum KeystrokeShown: Equatable, Sendable {
    /// Keycaps, and how many times in a row ("×3" when more than 1).
    case keys([String], count: Int)
    /// Typing, as a short rolling string.
    case typing(String)
}

/// Turns presses into what's shown: filters by mode, counts repeats, keeps the typing string.
/// Time is passed in, so there's no clock in here.
public struct KeystrokeFeed: Sendable {
    /// A press this soon after the last one continues the run (a repeat count or the typing).
    public static let continuation: TimeInterval = 1.2
    /// The most characters the typing string keeps.
    public static let typingLimit = 14

    public var mode: KeystrokeMode
    /// Secure Input is on: a password field has the keyboard, so nothing is shown.
    public var secureInput = false

    private var lastCaps: [String] = []
    private var lastCount = 0
    private var lastTime: TimeInterval = -.infinity
    private var typed = ""
    private var typedTime: TimeInterval = -.infinity

    public init(mode: KeystrokeMode) { self.mode = mode }

    /// A key went down. Returns what to show, or nil to leave the overlay as it is.
    public mutating func press(keyCode: UInt16, modifiers: KeyShortcut.Modifiers, characters: String?,
                               now: TimeInterval,
                               name: (UInt16) -> String = KeyShortcut.keyName(for:)) -> KeystrokeShown? {
        guard mode != .off, !secureInput else { return nil }
        if KeystrokeRules.isShortcut(keyCode: keyCode, modifiers: modifiers) {
            typed = ""
            return repeated(KeystrokeRules.keycaps(keyCode: keyCode, modifiers: modifiers, name: name), now: now)
        }
        guard mode == .everyKey else { return nil }
        let text = Int(keyCode) == kVK_Space ? " " : (characters ?? "")
        guard KeystrokeRules.isTypable(text) else {
            return repeated(KeystrokeRules.keycaps(keyCode: keyCode, modifiers: modifiers, name: name), now: now)
        }
        lastCaps = []
        lastCount = 0
        if now - typedTime > Self.continuation { typed = "" }
        typed.append(text)
        if typed.count > Self.typingLimit { typed = String(typed.suffix(Self.typingLimit)) }
        typedTime = now
        lastTime = now
        return .typing(typed)
    }

    /// The modifier keys changed. Shows ⌘, ⌃ or ⌥ held down so the cap is up before the key.
    public mutating func modifiersChanged(_ modifiers: KeyShortcut.Modifiers) -> KeystrokeShown? {
        guard mode != .off, !secureInput, KeystrokeRules.showsModifiersAlone(modifiers) else { return nil }
        return .keys(KeystrokeRules.modifierCaps(modifiers), count: 1)
    }

    private mutating func repeated(_ caps: [String], now: TimeInterval) -> KeystrokeShown {
        if caps == lastCaps, now - lastTime <= Self.continuation {
            lastCount += 1
        } else {
            lastCount = 1
        }
        lastCaps = caps
        lastTime = now
        return .keys(caps, count: lastCount)
    }

    /// "×3" for the badge, nil for a first press.
    public static func repeatBadge(_ count: Int) -> String? { count > 1 ? "×\(count)" : nil }
}
