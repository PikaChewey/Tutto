import XCTest
@testable import TuttoKit

final class ClickerTests: XCTestCase {
    func testIntervalAndLabels() {
        var settings = ClickerSettings()
        settings.clicksPerSecond = 20
        XCTAssertEqual(settings.interval, 0.05, accuracy: 1e-9)
        XCTAssertEqual(settings.speedLabel, "20 CPS")
        settings.clicksPerSecond = 0.5
        XCTAssertEqual(settings.speedLabel, "0.5 CPS")
        XCTAssertEqual(settings.interval, 2, accuracy: 1e-9)
        settings.button = .right
        settings.double = true
        settings.stop = .afterSeconds(90)
        XCTAssertEqual(settings.summary, "0.5 CPS · double right · for 1 min 30 s")
        settings.target = .point(x: 10, y: 20)
        settings.stop = .afterClicks(1500)
        XCTAssertTrue(settings.summary.contains("at a set spot"))
        XCTAssertTrue(settings.summary.contains("clicks"))
    }

    func testNormalizeKeepsValuesInRange() {
        var settings = ClickerSettings()
        settings.clicksPerSecond = 5000
        settings.jitter = 3
        settings.startDelay = -4
        settings.stop = .afterClicks(0)
        settings.normalize()
        XCTAssertEqual(settings.clicksPerSecond, ClickerSettings.fastest)
        XCTAssertEqual(settings.jitter, 0.5)
        XCTAssertEqual(settings.startDelay, 0)
        XCTAssertEqual(settings.stop, .afterClicks(1))
        settings.clicksPerSecond = .nan
        settings.stop = .afterSeconds(0)
        settings.normalize()
        XCTAssertEqual(settings.clicksPerSecond, 10)
        XCTAssertEqual(settings.stop, .afterSeconds(1))
    }

    func testWaitSpreadsAroundTheInterval() {
        var settings = ClickerSettings()
        settings.clicksPerSecond = 10
        XCTAssertEqual(ClickerRules.wait(settings, random: 0.9), 0.1, accuracy: 1e-12, "no spread: exact")
        settings.jitter = 0.25
        XCTAssertEqual(ClickerRules.wait(settings, random: 0), 0.075, accuracy: 1e-12)
        XCTAssertEqual(ClickerRules.wait(settings, random: 0.5), 0.1, accuracy: 1e-12)
        XCTAssertEqual(ClickerRules.wait(settings, random: 0.999_999), 0.125, accuracy: 1e-6)
        // Over many waits the average stays the set speed.
        var total = 0.0
        for i in 0..<1000 { total += ClickerRules.wait(settings, random: Double(i) / 1000) }
        XCTAssertEqual(total / 1000, 0.1, accuracy: 0.001)
    }

    func testStopConditions() {
        var settings = ClickerSettings()
        XCTAssertFalse(ClickerRules.isDone(settings, clicks: 1_000_000, elapsed: 1e6))
        settings.stop = .afterClicks(50)
        XCTAssertFalse(ClickerRules.isDone(settings, clicks: 49, elapsed: 0))
        XCTAssertTrue(ClickerRules.isDone(settings, clicks: 50, elapsed: 0))
        settings.stop = .afterSeconds(30)
        XCTAssertFalse(ClickerRules.isDone(settings, clicks: 1, elapsed: 29.9))
        XCTAssertTrue(ClickerRules.isDone(settings, clicks: 1, elapsed: 30))
    }

    func testCornersOfEveryScreen() {
        let main = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let right = CGRect(x: 1512, y: -200, width: 1920, height: 1080)
        let screens = [main, right]
        XCTAssertTrue(ClickerRules.inCorner(CGPoint(x: 0, y: 0), screens: screens))
        XCTAssertTrue(ClickerRules.inCorner(CGPoint(x: 1511, y: 981), screens: screens))
        XCTAssertTrue(ClickerRules.inCorner(CGPoint(x: 1513, y: -199), screens: screens))
        XCTAssertTrue(ClickerRules.inCorner(CGPoint(x: 3431, y: 879), screens: screens))
        XCTAssertFalse(ClickerRules.inCorner(CGPoint(x: 756, y: 0), screens: screens), "top edge, not a corner")
        XCTAssertFalse(ClickerRules.inCorner(CGPoint(x: 0, y: 491), screens: screens), "left edge")
        XCTAssertFalse(ClickerRules.inCorner(CGPoint(x: 700, y: 400), screens: screens))
    }

    func testOldSettingsDecodeWithDefaults() throws {
        let old = #"{"clicksPerSecond":25,"button":"right"}"#.data(using: .utf8)!
        let settings = try JSONDecoder().decode(ClickerSettings.self, from: old)
        XCTAssertEqual(settings.clicksPerSecond, 25)
        XCTAssertEqual(settings.button, .right)
        XCTAssertTrue(settings.cornerStops)
        XCTAssertFalse(settings.holdToClick)
        let roundTrip = try JSONDecoder().decode(ClickerSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(roundTrip, settings)
    }

    func testDurations() {
        XCTAssertEqual(ClickerRules.duration(45), "45 s")
        XCTAssertEqual(ClickerRules.duration(60), "1 min")
        XCTAssertEqual(ClickerRules.duration(90), "1 min 30 s")
        XCTAssertEqual(ClickerRules.duration(3600), "1 h")
        XCTAssertEqual(ClickerRules.duration(5400), "1 h 30 min")
    }
}
