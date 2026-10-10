import Carbon.HIToolbox
import XCTest
@testable import TuttoKit

final class ShortcutRecordingTests: XCTestCase {
    private func interpret(_ key: Int, _ modifiers: KeyShortcut.Modifiers, taken: [KeyShortcut: String] = [:]) -> ShortcutRecording.Outcome {
        ShortcutRecording.interpret(keyCode: UInt16(key), modifiers: modifiers) { taken[$0] }
    }

    func testEscapeCancelsAndDeleteRemoves() {
        XCTAssertEqual(interpret(kVK_Escape, []), .cancel)
        XCTAssertEqual(interpret(kVK_Delete, []), .remove)
        XCTAssertEqual(interpret(kVK_ForwardDelete, []), .remove)
    }

    func testModifiedEscapeIsAShortcut() {
        XCTAssertEqual(interpret(kVK_Escape, [.command, .option]), .record(KeyShortcut(keyCode: UInt16(kVK_Escape), modifiers: [.command, .option])))
    }

    func testBareKeysNeedAModifier() {
        XCTAssertEqual(interpret(kVK_ANSI_A, []), .needsModifier)
        XCTAssertEqual(interpret(kVK_ANSI_A, [.shift]), .needsModifier)
        XCTAssertEqual(interpret(kVK_F6, []), .record(KeyShortcut(keyCode: UInt16(kVK_F6), modifiers: [])))
    }

    func testConflictsAreRefused() {
        let leftHalf = KeyShortcut(keyCode: UInt16(kVK_ANSI_L), modifiers: [.control, .option, .command])
        XCTAssertEqual(interpret(kVK_ANSI_L, [.control, .option, .command], taken: [leftHalf: "Left Half"]), .conflict(with: "Left Half"))
    }

    func testDefaultsRecord() {
        XCTAssertEqual(interpret(kVK_ANSI_Grave, [.command, .shift]), .record(.cmdShift(kVK_ANSI_Grave)))
        XCTAssertEqual(interpret(kVK_ANSI_V, [.control, .shift]), .record(.ctrlShift(kVK_ANSI_V)))
    }
}
