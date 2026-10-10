//
//  KeyShortcut.swift
//  Tutto
//
//  A global keyboard shortcut: one key plus modifiers. Stored by virtual key code
//  (layout-independent, like the system's own shortcuts) and shown with the
//  symbols macOS uses in menus.
//

import Carbon.HIToolbox
import Foundation

public struct KeyShortcut: Codable, Hashable, Sendable {
    public struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    public var keyCode: UInt16
    public var modifiers: Modifiers

    public init(keyCode: UInt16, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Carbon modifier mask for RegisterEventHotKey.
    public var carbonModifiers: UInt32 {
        var mask: UInt32 = 0
        if modifiers.contains(.command) { mask |= UInt32(cmdKey) }
        if modifiers.contains(.option) { mask |= UInt32(optionKey) }
        if modifiers.contains(.control) { mask |= UInt32(controlKey) }
        if modifiers.contains(.shift) { mask |= UInt32(shiftKey) }
        return mask
    }

    /// Modifier symbols in Apple's canonical order (⌃⌥⇧⌘), then the key.
    public var symbols: [String] {
        var result: [String] = []
        if modifiers.contains(.control) { result.append("⌃") }
        if modifiers.contains(.option) { result.append("⌥") }
        if modifiers.contains(.shift) { result.append("⇧") }
        if modifiers.contains(.command) { result.append("⌘") }
        result.append(Self.keyName(for: keyCode))
        return result
    }

    public var displayString: String { symbols.joined() }

    public var spokenDescription: String {
        var words: [String] = []
        if modifiers.contains(.control) { words.append("Control") }
        if modifiers.contains(.option) { words.append("Option") }
        if modifiers.contains(.shift) { words.append("Shift") }
        if modifiers.contains(.command) { words.append("Command") }
        words.append(Self.spokenKeyName(for: keyCode))
        return words.joined(separator: " ")
    }

    /// Function keys may stand alone; everything else needs ⌘, ⌃ or ⌥ to be safe as a global shortcut.
    public var isValidGlobalShortcut: Bool {
        if Self.functionKeys.contains(Int(keyCode)) { return true }
        return modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.option)
    }

    // MARK: Key names

    static let functionKeys: Set<Int> = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9,
                                         kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17,
                                         kVK_F18, kVK_F19, kVK_F20]

    private static let special: [Int: (symbol: String, spoken: String)] = [
        kVK_Return: ("↩", "Return"), kVK_Tab: ("⇥", "Tab"), kVK_Space: ("Space", "Space"),
        kVK_Delete: ("⌫", "Delete"), kVK_ForwardDelete: ("⌦", "Forward Delete"), kVK_Escape: ("⎋", "Escape"),
        kVK_LeftArrow: ("←", "Left Arrow"), kVK_RightArrow: ("→", "Right Arrow"),
        kVK_UpArrow: ("↑", "Up Arrow"), kVK_DownArrow: ("↓", "Down Arrow"),
        kVK_Home: ("↖", "Home"), kVK_End: ("↘", "End"), kVK_PageUp: ("⇞", "Page Up"), kVK_PageDown: ("⇟", "Page Down"),
        kVK_F1: ("F1", "F1"), kVK_F2: ("F2", "F2"), kVK_F3: ("F3", "F3"), kVK_F4: ("F4", "F4"), kVK_F5: ("F5", "F5"),
        kVK_F6: ("F6", "F6"), kVK_F7: ("F7", "F7"), kVK_F8: ("F8", "F8"), kVK_F9: ("F9", "F9"), kVK_F10: ("F10", "F10"),
        kVK_F11: ("F11", "F11"), kVK_F12: ("F12", "F12"), kVK_F13: ("F13", "F13"), kVK_F14: ("F14", "F14"),
        kVK_F15: ("F15", "F15"), kVK_F16: ("F16", "F16"), kVK_F17: ("F17", "F17"), kVK_F18: ("F18", "F18"),
        kVK_F19: ("F19", "F19"), kVK_F20: ("F20", "F20"),
        kVK_ANSI_KeypadEnter: ("⌤", "Enter"),
    ]

    /// US-layout names for printable keys, used when the current layout can't be asked.
    private static let ansi: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
        kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R",
        kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z", kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Grave: "`", kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[",
        kVK_ANSI_RightBracket: "]", kVK_ANSI_Backslash: "\\", kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'",
        kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
    ]

    public static func keyName(for keyCode: UInt16) -> String {
        if let special = special[Int(keyCode)] { return special.symbol }
        if let typed = layoutCharacter(for: keyCode) { return typed }
        return ansi[Int(keyCode)] ?? "#\(keyCode)"
    }

    static func spokenKeyName(for keyCode: UInt16) -> String {
        if let special = special[Int(keyCode)] { return special.spoken }
        if Int(keyCode) == kVK_ANSI_Grave { return "Grave Accent" }
        return keyName(for: keyCode)
    }

    /// The character this key types on the current keyboard layout (so AZERTY users see their letters).
    static func layoutCharacter(for keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: characters, count: length).uppercased()
        guard let scalar = text.unicodeScalars.first, !CharacterSet.controlCharacters.contains(scalar),
              !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return text
    }
}

public extension KeyShortcut {
    static func ctrlShift(_ key: Int) -> KeyShortcut { KeyShortcut(keyCode: UInt16(key), modifiers: [.control, .shift]) }
    static func cmdShift(_ key: Int) -> KeyShortcut { KeyShortcut(keyCode: UInt16(key), modifiers: [.command, .shift]) }
    static func cmdOption(_ key: Int) -> KeyShortcut { KeyShortcut(keyCode: UInt16(key), modifiers: [.command, .option]) }
}
