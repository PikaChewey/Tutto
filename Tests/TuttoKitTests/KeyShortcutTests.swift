import Carbon.HIToolbox
import XCTest
@testable import TuttoKit

final class KeyShortcutTests: XCTestCase {
    func testSymbolsUseApplesOrder() {
        let shortcut = KeyShortcut(keyCode: UInt16(kVK_ANSI_V), modifiers: [.shift, .control])
        XCTAssertEqual(shortcut.symbols.prefix(2), ["⌃", "⇧"])
        XCTAssertEqual(KeyShortcut.cmdOption(kVK_ANSI_B).symbols.prefix(2), ["⌥", "⌘"])
    }

    func testCarbonModifiers() {
        XCTAssertEqual(KeyShortcut.cmdShift(kVK_ANSI_2).carbonModifiers, UInt32(cmdKey | shiftKey))
        XCTAssertEqual(KeyShortcut.ctrlShift(kVK_ANSI_V).carbonModifiers, UInt32(controlKey | shiftKey))
    }

    func testGraveKeyIsNamed() {
        XCTAssertEqual(KeyShortcut.spokenKeyName(for: UInt16(kVK_ANSI_Grave)), "Grave Accent")
        XCTAssertFalse(KeyShortcut.keyName(for: UInt16(kVK_ANSI_Grave)).isEmpty)
    }

    func testValidity() {
        XCTAssertTrue(KeyShortcut(keyCode: UInt16(kVK_F5), modifiers: []).isValidGlobalShortcut)
        XCTAssertFalse(KeyShortcut(keyCode: UInt16(kVK_ANSI_A), modifiers: [.shift]).isValidGlobalShortcut)
        XCTAssertTrue(KeyShortcut(keyCode: UInt16(kVK_ANSI_A), modifiers: [.option]).isValidGlobalShortcut)
    }

    func testCodableRoundTrip() throws {
        let shortcut = KeyShortcut.cmdShift(kVK_ANSI_Grave)
        let data = try JSONEncoder().encode(shortcut)
        XCTAssertEqual(try JSONDecoder().decode(KeyShortcut.self, from: data), shortcut)
    }

    /// A global shortcut catches its keys before macOS does: no default may be one of macOS's own,
    /// and no two defaults may be the same.
    func testDefaultsLeaveMacOSItsShortcuts() {
        let defaults = DefaultShortcuts.all + StripCommand.allCases.map(\.defaultShortcut)
        for shortcut in defaults {
            XCTAssertNil(SystemShortcuts.owner(of: shortcut), shortcut.displayString)
        }
        XCTAssertEqual(Set(defaults).count, defaults.count)
        // Area to the editor sits beside macOS's screenshot keys, not on ⇧⌘` (back through an app's windows).
        XCTAssertEqual(DefaultShortcuts.captureAreaEdit, .cmdShift(kVK_ANSI_6))
        XCTAssertEqual(SystemShortcuts.owner(of: .cmdShift(kVK_ANSI_Grave)), "cycling windows backwards")
    }
}
