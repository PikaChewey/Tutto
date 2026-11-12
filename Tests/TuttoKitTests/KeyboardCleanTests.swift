import CoreGraphics
import XCTest
@testable import TuttoKit

final class KeyboardCleanTests: XCTestCase {
    func testKeysClicksScrollAndSystemKeysAreBlocked() {
        let blocked: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged,
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel,
        ]
        for type in blocked { XCTAssertTrue(KeyboardCleanLock.blocks(type), "\(type)") }
        XCTAssertTrue(KeyboardCleanLock.blocks(14), "media, volume and brightness keys")
        XCTAssertTrue(KeyboardCleanLock.blocks(29), "gesture")
        XCTAssertTrue(KeyboardCleanLock.blocks(30), "gesture")
    }

    func testPointerMovementIsNotBlocked() {
        XCTAssertFalse(KeyboardCleanLock.blocks(.mouseMoved))
    }

    func testTapMaskCoversEveryBlockedType() {
        let mask = KeyboardCleanLock.eventMask
        for raw in KeyboardCleanLock.blockedTypes { XCTAssertNotEqual(mask & (1 << CGEventMask(raw)), 0) }
        XCTAssertEqual(mask & (1 << CGEventMask(CGEventType.mouseMoved.rawValue)), 0)
    }

    func testCountdownText() {
        XCTAssertEqual(KeyboardCleanLock.countdownText(secondsLeft: 27), "0:27")
        XCTAssertEqual(KeyboardCleanLock.countdownText(secondsLeft: 26.2), "0:27")
        XCTAssertEqual(KeyboardCleanLock.countdownText(secondsLeft: 60), "1:00")
        XCTAssertEqual(KeyboardCleanLock.countdownText(secondsLeft: 9), "0:09")
        XCTAssertEqual(KeyboardCleanLock.countdownText(secondsLeft: -3), "0:00")
    }

    func testLengthsAndProgress() {
        XCTAssertEqual(KeyboardCleanLock.clamped(15), 15)
        XCTAssertEqual(KeyboardCleanLock.clamped(60), 60)
        XCTAssertEqual(KeyboardCleanLock.clamped(7), 30)
        XCTAssertEqual(KeyboardCleanLock.progress(secondsLeft: 15, total: 30), 0.5, accuracy: 1e-9)
        XCTAssertEqual(KeyboardCleanLock.progress(secondsLeft: 40, total: 30), 1)
        XCTAssertEqual(KeyboardCleanLock.progress(secondsLeft: -1, total: 30), 0)
    }
}
