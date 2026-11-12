import Carbon.HIToolbox
import Foundation
import XCTest
@testable import TuttoKit

final class KeystrokeTests: XCTestCase {
    /// A fixed US layout, so the tests don't depend on the Mac's keyboard.
    private let us: (UInt16) -> String = { code in
        switch Int(code) {
        case kVK_ANSI_B: "B"
        case kVK_ANSI_4: "4"
        case kVK_ANSI_A: "A"
        case kVK_ANSI_S: "S"
        case kVK_F1: "F1"
        case kVK_F12: "F12"
        default: "#\(code)"
        }
    }

    func testModifiersWriteInTheMacsOrder() {
        XCTAssertEqual(KeystrokeRules.modifierCaps([.command, .shift, .option, .control]), ["⌃", "⌥", "⇧", "⌘"])
        XCTAssertEqual(KeystrokeRules.keycaps(keyCode: UInt16(kVK_ANSI_4), modifiers: [.command, .shift], name: us), ["⇧", "⌘", "4"])
    }

    func testNamedKeys() {
        let names: [(Int, String)] = [(kVK_Return, "Return"), (kVK_Escape, "Esc"), (kVK_Tab, "Tab"), (kVK_Delete, "Delete"),
                                      (kVK_Space, "Space"), (kVK_LeftArrow, "←"), (kVK_RightArrow, "→"),
                                      (kVK_UpArrow, "↑"), (kVK_DownArrow, "↓"), (kVK_F1, "F1"), (kVK_F12, "F12")]
        for (code, expected) in names {
            XCTAssertEqual(KeystrokeRules.keyName(UInt16(code), name: us), expected, "\(code)")
        }
    }

    func testShortcutsFilter() {
        XCTAssertTrue(KeystrokeRules.isShortcut(keyCode: UInt16(kVK_ANSI_B), modifiers: .command))
        XCTAssertTrue(KeystrokeRules.isShortcut(keyCode: UInt16(kVK_ANSI_B), modifiers: [.control, .shift]))
        XCTAssertTrue(KeystrokeRules.isShortcut(keyCode: UInt16(kVK_ANSI_B), modifiers: .option))
        XCTAssertTrue(KeystrokeRules.isShortcut(keyCode: UInt16(kVK_Escape), modifiers: []))
        XCTAssertTrue(KeystrokeRules.isShortcut(keyCode: UInt16(kVK_Return), modifiers: []))
        XCTAssertTrue(KeystrokeRules.isShortcut(keyCode: UInt16(kVK_DownArrow), modifiers: []))
        XCTAssertTrue(KeystrokeRules.isShortcut(keyCode: UInt16(kVK_F5), modifiers: []))
        XCTAssertFalse(KeystrokeRules.isShortcut(keyCode: UInt16(kVK_ANSI_B), modifiers: []))
        XCTAssertFalse(KeystrokeRules.isShortcut(keyCode: UInt16(kVK_ANSI_B), modifiers: .shift))
        XCTAssertFalse(KeystrokeRules.isShortcut(keyCode: UInt16(kVK_Space), modifiers: []))
    }

    func testOffShowsNothing() {
        var feed = KeystrokeFeed(mode: .off)
        XCTAssertNil(feed.press(keyCode: UInt16(kVK_ANSI_B), modifiers: .command, characters: "b", now: 0, name: us))
        XCTAssertNil(feed.modifiersChanged(.command))
    }

    func testShortcutsModeIgnoresTyping() {
        var feed = KeystrokeFeed(mode: .shortcuts)
        XCTAssertNil(feed.press(keyCode: UInt16(kVK_ANSI_A), modifiers: [], characters: "a", now: 0, name: us))
        XCTAssertEqual(feed.press(keyCode: UInt16(kVK_ANSI_B), modifiers: .command, characters: "b", now: 1, name: us),
                       .keys(["⌘", "B"], count: 1))
    }

    func testRepeatsCountWithinTheWindowAndResetAfter() {
        var feed = KeystrokeFeed(mode: .shortcuts)
        var counts: [Int] = []
        for t in [0.0, 0.5, 1.0, 3.0] {
            if case .keys(_, let count)? = feed.press(keyCode: UInt16(kVK_ANSI_B), modifiers: .command, characters: "b", now: t, name: us) {
                counts.append(count)
            }
        }
        XCTAssertEqual(counts, [1, 2, 3, 1])
        XCTAssertEqual(KeystrokeFeed.repeatBadge(3), "×3")
        XCTAssertNil(KeystrokeFeed.repeatBadge(1))
    }

    func testADifferentKeyRestartsTheCount() {
        var feed = KeystrokeFeed(mode: .shortcuts)
        _ = feed.press(keyCode: UInt16(kVK_ANSI_B), modifiers: .command, characters: "b", now: 0, name: us)
        XCTAssertEqual(feed.press(keyCode: UInt16(kVK_ANSI_A), modifiers: .command, characters: "a", now: 0.2, name: us),
                       .keys(["⌘", "A"], count: 1))
    }

    func testEveryKeyRollsTypingAndResetsAfterAPause() {
        var feed = KeystrokeFeed(mode: .everyKey)
        XCTAssertEqual(feed.press(keyCode: UInt16(kVK_ANSI_A), modifiers: [], characters: "a", now: 0, name: us), .typing("a"))
        XCTAssertEqual(feed.press(keyCode: UInt16(kVK_Space), modifiers: [], characters: " ", now: 0.2, name: us), .typing("a "))
        XCTAssertEqual(feed.press(keyCode: UInt16(kVK_ANSI_S), modifiers: .shift, characters: "S", now: 0.4, name: us), .typing("a S"))
        XCTAssertEqual(feed.press(keyCode: UInt16(kVK_ANSI_A), modifiers: [], characters: "a", now: 5, name: us), .typing("a"))
    }

    func testTypingKeepsOnlyTheLastFewCharacters() {
        var feed = KeystrokeFeed(mode: .everyKey)
        var shown: KeystrokeShown?
        for i in 0..<30 {
            shown = feed.press(keyCode: UInt16(kVK_ANSI_A), modifiers: [], characters: "x", now: Double(i) * 0.1, name: us)
        }
        XCTAssertEqual(shown, .typing(String(repeating: "x", count: KeystrokeFeed.typingLimit)))
    }

    func testEveryKeyStillShowsShortcutsAsKeycapsAndEndsTheRun() {
        var feed = KeystrokeFeed(mode: .everyKey)
        _ = feed.press(keyCode: UInt16(kVK_ANSI_A), modifiers: [], characters: "a", now: 0, name: us)
        XCTAssertEqual(feed.press(keyCode: UInt16(kVK_Return), modifiers: [], characters: "\r", now: 0.1, name: us), .keys(["Return"], count: 1))
        XCTAssertEqual(feed.press(keyCode: UInt16(kVK_ANSI_B), modifiers: [], characters: "b", now: 0.2, name: us), .typing("b"))
    }

    func testSecureInputShowsNothing() {
        var feed = KeystrokeFeed(mode: .everyKey)
        feed.secureInput = true
        XCTAssertNil(feed.press(keyCode: UInt16(kVK_ANSI_A), modifiers: [], characters: "a", now: 0, name: us))
        XCTAssertNil(feed.press(keyCode: UInt16(kVK_ANSI_B), modifiers: .command, characters: "b", now: 0, name: us))
        XCTAssertNil(feed.modifiersChanged(.command))
    }

    func testHeldModifiersShowExceptShiftAlone() {
        var feed = KeystrokeFeed(mode: .shortcuts)
        XCTAssertEqual(feed.modifiersChanged([.command, .shift]), .keys(["⇧", "⌘"], count: 1))
        XCTAssertNil(feed.modifiersChanged(.shift))
        XCTAssertNil(feed.modifiersChanged([]))
    }

    func testTypableText() {
        XCTAssertTrue(KeystrokeRules.isTypable("a"))
        XCTAssertFalse(KeystrokeRules.isTypable("\r"))
        XCTAssertFalse(KeystrokeRules.isTypable("\u{F700}"))
        XCTAssertFalse(KeystrokeRules.isTypable(""))
    }
}
