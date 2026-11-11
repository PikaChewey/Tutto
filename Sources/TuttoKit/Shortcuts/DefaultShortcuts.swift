//
//  DefaultShortcuts.swift
//  TuttoKit
//
//  The shortcuts Tutto starts with for its everyday tools (the strip's live with its commands),
//  and the macOS shortcuts none of them may take over: a global shortcut catches the keys
//  before macOS and every app.
//

import Carbon.HIToolbox

public enum DefaultShortcuts {
    public static let clipboardHistory = KeyShortcut.ctrlShift(kVK_ANSI_V)
    public static let windowPalette = KeyShortcut.ctrlShift(kVK_ANSI_B)
    /// ⇧⌘`, Bryan's choice: it takes the keys from macOS's "back through an app's windows" on
    /// purpose (⌘` still goes forward through them). The window switcher's key filter takes it
    /// first, so macOS can't. (Swapped with area and edit's ⇧⌘1 on 2026-11-06, at his request.)
    public static let captureScreen = KeyShortcut.cmdShift(kVK_ANSI_Grave)
    public static let captureArea = KeyShortcut.cmdShift(kVK_ANSI_2)
    public static let captureAreaEdit = KeyShortcut.cmdShift(kVK_ANSI_1)
    public static let wordCounter = KeyShortcut.ctrlShift(kVK_ANSI_C)
    /// The auto clicker on and off (or, in hold mode, clicking while held). "A" for auto, in Tutto's
    /// ⌃⇧ family; F-keys and single keys can be recorded instead, as clickers usually offer.
    public static let toggleClicker = KeyShortcut.ctrlShift(kVK_ANSI_A)

    public static let all = [clipboardHistory, windowPalette, captureScreen, captureArea, captureAreaEdit, wordCounter, toggleClicker]

    /// Defaults that take a macOS shortcut on purpose.
    public static let takenFromMacOS: Set<KeyShortcut> = [captureScreen]
}

/// Well-known macOS shortcuts worth a warning when someone records them.
public enum SystemShortcuts {
    public static func owner(of shortcut: KeyShortcut) -> String? {
        let m = shortcut.modifiers
        switch (Int(shortcut.keyCode), m) {
        case (kVK_ANSI_3, [.command, .shift]): return "screenshots of the screen"
        case (kVK_ANSI_4, [.command, .shift]): return "screenshots of a selection"
        case (kVK_ANSI_5, [.command, .shift]): return "the Screenshot toolbar"
        case (kVK_Space, [.command]): return "Spotlight"
        case (kVK_Space, [.control]): return "switching input sources"
        case (kVK_Tab, [.command]): return "switching apps"
        case (kVK_ANSI_Grave, [.command]): return "cycling windows"
        case (kVK_ANSI_Grave, [.command, .shift]): return "cycling windows backwards"
        case (kVK_ANSI_Q, [.command]), (kVK_ANSI_W, [.command]), (kVK_ANSI_C, [.command]), (kVK_ANSI_V, [.command]),
             (kVK_ANSI_X, [.command]), (kVK_ANSI_Z, [.command]), (kVK_ANSI_A, [.command]), (kVK_ANSI_S, [.command]):
            return "a standard app command"
        default: return nil
        }
    }
}
