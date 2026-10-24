//
//  StripCommands.swift
//  Tutto (scrolling strip)
//
//  Everything you can do to the strip from the keyboard, with the keys it starts with.
//  All on Control-Option (⌃⌥), which nothing in macOS uses; plain ⌥ is left to macOS
//  for jumping by word and typing characters like ç and ®. Every one can be changed.
//

import Carbon.HIToolbox
import Foundation

public enum StripCommand: Hashable, Sendable, Identifiable {
    case focusLeft, focusRight, focusUp, focusDown, focusFirst, focusLast
    case focusNumber(Int)
    case moveLeft, moveRight, moveUp, moveDown, moveToFirst, moveToLast
    case moveToNumber(Int)
    case nextDisplay, toggleRunning, showStrip
    case cycleWidth, fullWidth, centre, wider, narrower
    case taller, shorter, equalizeHeights
    case pinLeft, pinRight
    case stackLeft, stackRight, popOutRight, popOutLeft
    case toggleTabbed, toggleFloat

    public enum Group: String, CaseIterable, Sendable {
        case navigate = "Navigate"
        case move = "Move"
        case size = "Size"
        case stacks = "Stacks"
    }

    /// In the order the Shortcuts page lists them.
    public static let allCases: [StripCommand] =
        [.focusLeft, .focusRight, .focusUp, .focusDown, .focusFirst, .focusLast]
        + (1...9).map { .focusNumber($0) }
        + [.showStrip, .nextDisplay, .toggleRunning]
        + [.moveLeft, .moveRight, .moveUp, .moveDown, .moveToFirst, .moveToLast]
        + (1...9).map { .moveToNumber($0) }
        + [.cycleWidth, .fullWidth, .centre, .wider, .narrower, .taller, .shorter, .equalizeHeights, .pinLeft, .pinRight]
        + [.stackLeft, .stackRight, .popOutRight, .popOutLeft, .toggleTabbed, .toggleFloat]

    public var id: String {
        switch self {
        case .focusNumber(let n): "strip.focus\(n)"
        case .moveToNumber(let n): "strip.moveTo\(n)"
        default: "strip.\(name)"
        }
    }

    private var name: String {
        switch self {
        case .focusLeft: "focusLeft"
        case .focusRight: "focusRight"
        case .focusUp: "focusUp"
        case .focusDown: "focusDown"
        case .focusFirst: "focusFirst"
        case .focusLast: "focusLast"
        case .focusNumber: "focusNumber"
        case .moveLeft: "moveLeft"
        case .moveRight: "moveRight"
        case .moveUp: "moveUp"
        case .moveDown: "moveDown"
        case .moveToFirst: "moveToFirst"
        case .moveToLast: "moveToLast"
        case .moveToNumber: "moveToNumber"
        case .nextDisplay: "nextDisplay"
        case .toggleRunning: "toggleRunning"
        case .showStrip: "showStrip"
        case .cycleWidth: "cycleWidth"
        case .fullWidth: "fullWidth"
        case .centre: "centre"
        case .wider: "wider"
        case .narrower: "narrower"
        case .taller: "taller"
        case .shorter: "shorter"
        case .equalizeHeights: "equalizeHeights"
        case .pinLeft: "pinLeft"
        case .pinRight: "pinRight"
        case .stackLeft: "stackLeft"
        case .stackRight: "stackRight"
        case .popOutRight: "popOutRight"
        case .popOutLeft: "popOutLeft"
        case .toggleTabbed: "toggleTabbed"
        case .toggleFloat: "toggleFloat"
        }
    }

    public var title: String {
        switch self {
        case .focusLeft: "Focus left"
        case .focusRight: "Focus right"
        case .focusUp: "Focus up in the column"
        case .focusDown: "Focus down in the column"
        case .focusFirst: "First window"
        case .focusLast: "Last window"
        case .focusNumber(let n): n == 9 ? "Jump to the last window" : "Jump to window \(n)"
        case .moveLeft: "Move left"
        case .moveRight: "Move right"
        case .moveUp: "Move up in the column"
        case .moveDown: "Move down in the column"
        case .moveToFirst: "Move to the start"
        case .moveToLast: "Move to the end"
        case .moveToNumber(let n): n == 9 ? "Move to the end" : "Move to position \(n)"
        case .nextDisplay: "Send to the next display"
        case .toggleRunning: "Stop or start the strip"
        case .showStrip: "Show the strip"
        case .cycleWidth: "Cycle width"
        case .fullWidth: "Full width"
        case .centre: "Centre the column"
        case .wider: "Wider"
        case .narrower: "Narrower"
        case .taller: "Taller"
        case .shorter: "Shorter"
        case .equalizeHeights: "Equal heights"
        case .pinLeft: "Pin to the left edge"
        case .pinRight: "Pin to the right edge"
        case .stackLeft: "Stack into the left column"
        case .stackRight: "Stack into the right column"
        case .popOutRight: "Pop out to the right"
        case .popOutLeft: "Pop out to the left"
        case .toggleTabbed: "Tabbed column"
        case .toggleFloat: "Float or tile the window"
        }
    }

    public var group: Group {
        switch self {
        case .focusLeft, .focusRight, .focusUp, .focusDown, .focusFirst, .focusLast, .focusNumber,
             .showStrip, .nextDisplay, .toggleRunning: .navigate
        case .moveLeft, .moveRight, .moveUp, .moveDown, .moveToFirst, .moveToLast, .moveToNumber: .move
        case .cycleWidth, .fullWidth, .centre, .wider, .narrower, .taller, .shorter, .equalizeHeights,
             .pinLeft, .pinRight: .size
        case .stackLeft, .stackRight, .popOutRight, .popOutLeft, .toggleTabbed, .toggleFloat: .stacks
        }
    }

    /// Whether it changes the layout (and so needs the strip running).
    public var needsStrip: Bool { self != .toggleRunning }

    public var defaultShortcut: KeyShortcut {
        let co: KeyShortcut.Modifiers = [.control, .option]
        let cos: KeyShortcut.Modifiers = [.control, .option, .shift]
        let coc: KeyShortcut.Modifiers = [.control, .option, .command]
        let cosc: KeyShortcut.Modifiers = [.control, .option, .shift, .command]
        func key(_ code: Int, _ modifiers: KeyShortcut.Modifiers) -> KeyShortcut {
            KeyShortcut(keyCode: UInt16(code), modifiers: modifiers)
        }
        switch self {
        case .focusLeft: return key(kVK_LeftArrow, co)
        case .focusRight: return key(kVK_RightArrow, co)
        case .focusUp: return key(kVK_UpArrow, co)
        case .focusDown: return key(kVK_DownArrow, co)
        case .focusFirst: return key(kVK_LeftArrow, coc)
        case .focusLast: return key(kVK_RightArrow, coc)
        case .focusNumber(let n): return key(Self.digitKeys[min(max(n, 1), 9) - 1], co)
        case .moveLeft: return key(kVK_LeftArrow, cos)
        case .moveRight: return key(kVK_RightArrow, cos)
        case .moveUp: return key(kVK_UpArrow, cos)
        case .moveDown: return key(kVK_DownArrow, cos)
        case .moveToFirst: return key(kVK_LeftArrow, cosc)
        case .moveToLast: return key(kVK_RightArrow, cosc)
        case .moveToNumber(let n): return key(Self.digitKeys[min(max(n, 1), 9) - 1], cos)
        case .nextDisplay: return key(kVK_ANSI_N, co)
        case .toggleRunning: return key(kVK_ANSI_Q, co)
        case .showStrip: return key(kVK_ANSI_S, co)
        case .cycleWidth: return key(kVK_ANSI_R, co)
        case .fullWidth: return key(kVK_ANSI_F, co)
        case .centre: return key(kVK_ANSI_C, co)
        case .wider: return key(kVK_ANSI_Equal, co)
        case .narrower: return key(kVK_ANSI_Minus, co)
        case .taller: return key(kVK_ANSI_Equal, cos)
        case .shorter: return key(kVK_ANSI_Minus, cos)
        case .equalizeHeights: return key(kVK_ANSI_0, co)
        case .pinLeft: return key(kVK_ANSI_P, co)
        case .pinRight: return key(kVK_ANSI_P, cos)
        case .stackLeft: return key(kVK_ANSI_RightBracket, co)
        case .stackRight: return key(kVK_ANSI_LeftBracket, co)
        case .popOutRight: return key(kVK_ANSI_RightBracket, cos)
        case .popOutLeft: return key(kVK_ANSI_LeftBracket, cos)
        case .toggleTabbed: return key(kVK_ANSI_T, cos)
        case .toggleFloat: return key(kVK_ANSI_T, co)
        }
    }

    static let digitKeys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                            kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
}
