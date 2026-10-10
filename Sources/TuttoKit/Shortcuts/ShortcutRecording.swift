//
//  ShortcutRecording.swift
//  Tutto
//
//  What a key press means while a shortcut recorder is listening. Pure, so it's tested
//  without a keyboard: Esc cancels, Delete removes, a bare key needs a modifier, a combo
//  already used by another action is refused, anything else is the new shortcut.
//

import Carbon.HIToolbox

public enum ShortcutRecording {
    public enum Outcome: Equatable {
        case cancel
        case remove
        case needsModifier
        case conflict(with: String)
        case record(KeyShortcut)
    }

    /// `owner` returns the title of another action already using a shortcut, if any.
    public static func interpret(keyCode: UInt16, modifiers: KeyShortcut.Modifiers,
                                 owner: (KeyShortcut) -> String?) -> Outcome {
        if modifiers.isEmpty {
            switch Int(keyCode) {
            case kVK_Escape: return .cancel
            case kVK_Delete, kVK_ForwardDelete: return .remove
            default: break
            }
        }
        let shortcut = KeyShortcut(keyCode: keyCode, modifiers: modifiers)
        guard shortcut.isValidGlobalShortcut else { return .needsModifier }
        if let other = owner(shortcut) { return .conflict(with: other) }
        return .record(shortcut)
    }
}
