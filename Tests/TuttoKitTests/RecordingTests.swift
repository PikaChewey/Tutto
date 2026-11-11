import CoreGraphics
import Foundation
import XCTest
@testable import TuttoKit

final class RecordingTests: XCTestCase {
    func testSourceRectIsInPoints() {
        let rect = RecordingRules.sourceRect(pixels: CGRect(x: 200, y: 100, width: 1001, height: 601), scale: 2)
        XCTAssertEqual(rect, CGRect(x: 100, y: 50, width: 500.5, height: 300.5))
    }

    func testVideoSizeIsEvenAtNativeResolution() {
        let size = RecordingRules.videoSize(points: CGSize(width: 500.5, height: 300.5), scale: 2)
        XCTAssertEqual(size.width, 1000)
        XCTAssertEqual(size.height, 600)
        let odd = RecordingRules.videoSize(points: CGSize(width: 333, height: 211), scale: 1)
        XCTAssertEqual(odd.width, 332)
        XCTAssertEqual(odd.height, 210)
        let tiny = RecordingRules.videoSize(points: CGSize(width: 3, height: 3), scale: 2)
        XCTAssertEqual(tiny.width, RecordingRules.minimumSide)
    }

    func testTinySelectionsAreNotRecorded() {
        XCTAssertFalse(RecordingRules.isRecordable(pixels: CGRect(x: 0, y: 0, width: 10, height: 400)))
        XCTAssertTrue(RecordingRules.isRecordable(pixels: CGRect(x: 0, y: 0, width: 400, height: 300)))
    }

    func testElapsedText() {
        XCTAssertEqual(RecordingRules.elapsed(7.9), "0:07")
        XCTAssertEqual(RecordingRules.elapsed(272), "4:32")
        XCTAssertEqual(RecordingRules.elapsed(3723), "1:02:03")
        XCTAssertEqual(RecordingRules.elapsed(-3), "0:00")
    }

    func testFileName() {
        let date = Date(timeIntervalSince1970: 1_794_373_924)  // 2026-11-11 05:12:04 UTC
        XCTAssertEqual(RecordingRules.baseName(at: date, timeZone: TimeZone(identifier: "UTC")!), "Recording 2026-11-11 at 05.12.04")
    }
}
