import XCTest
@testable import TuttoKit

final class ScreenshotNamesTests: XCTestCase {
    func testBaseNameLooksLikeFinders() {
        let date = Date(timeIntervalSince1970: 1_794_337_516)  // 2026-11-10 19:05:16 UTC
        XCTAssertEqual(ScreenshotNames.base(at: date, timeZone: TimeZone(identifier: "UTC")!), "Screenshot 2026-11-10 at 19.05.16")
        XCTAssertEqual(ScreenshotNames.base(at: date, timeZone: TimeZone(identifier: "America/Toronto")!), "Screenshot 2026-11-10 at 14.05.16")
    }

    func testUniqueSkipsTakenNames() {
        let folder = URL(fileURLWithPath: "/tmp/shots", isDirectory: true)
        let taken: Set<String> = ["Shot.png", "Shot 2.png"]
        let url = ScreenshotNames.unique("Shot", ext: "png", in: folder) { taken.contains($0.lastPathComponent) }
        XCTAssertEqual(url.lastPathComponent, "Shot 3.png")
        XCTAssertEqual(ScreenshotNames.unique("Free", ext: "jpg", in: folder) { _ in false }.lastPathComponent, "Free.jpg")
    }

    func testTypedNamesGetTheFormatsExtension() {
        let dir = URL(fileURLWithPath: "/Users/me/Desktop", isDirectory: true)
        func name(_ typed: String, _ ext: String) -> String {
            ScreenshotNames.withExtension(dir.appendingPathComponent(typed), ext: ext).lastPathComponent
        }
        XCTAssertEqual(name("notes", "png"), "notes.png")
        XCTAssertEqual(name("notes.png", "png"), "notes.png")
        XCTAssertEqual(name("notes.PNG", "png"), "notes.PNG")
        XCTAssertEqual(name("notes.jpg", "png"), "notes.png")
        XCTAssertEqual(name("notes.png", "jpg"), "notes.jpg")
        XCTAssertEqual(name("notes.jpeg", "jpg"), "notes.jpeg")
        XCTAssertEqual(name("v1.2", "png"), "v1.2.png")
        XCTAssertEqual(name("Lecture (Nov 10)", "jpg"), "Lecture (Nov 10).jpg")
    }
}
