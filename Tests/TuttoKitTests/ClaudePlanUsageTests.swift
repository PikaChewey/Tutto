import Foundation
import XCTest
@testable import TuttoKit

final class ClaudePlanUsageTests: XCTestCase {
    // Shaped like the real reply (CodexBar's test samples), times made up.
    let reply = #"""
    {"five_hour":{"utilization":5.0,"resets_at":"2026-11-25T00:50:00.282668+00:00"},
     "seven_day":{"utilization":63.0,"resets_at":"2026-11-26T00:00:00Z"},
     "seven_day_opus":null,"seven_day_sonnet":null,"extra_usage":null,"limits":[]}
    """#

    func testReadsBothWindowsAsPercent() throws {
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        let usage = try XCTUnwrap(ClaudePlanUsage(json: Data(reply.utf8), at: now))
        XCTAssertEqual(usage.fiveHour?.percent, 5)
        XCTAssertEqual(usage.week?.percent, 63)
        XCTAssertEqual(usage.week?.resetsAt, ISO8601DateFormatter().date(from: "2026-11-26T00:00:00Z"))
        XCTAssertNotNil(usage.fiveHour?.resetsAt)
        let limits = usage.limits(samples: [], now: now)
        XCTAssertEqual(limits.week?.percent, 63)
        XCTAssertEqual(limits.week?.exact, true)
        XCTAssertEqual(limits.tool, .claude)
    }

    func testNullWindowsAndJunk() {
        XCTAssertNil(ClaudePlanUsage(json: Data(#"{"five_hour":null,"seven_day":null}"#.utf8), at: Date()))
        XCTAssertNil(ClaudePlanUsage(json: Data("not json".utf8), at: Date()))
        let week = ClaudePlanUsage(json: Data(#"{"five_hour":null,"seven_day":{"utilization":12,"resets_at":null}}"#.utf8), at: Date())
        XCTAssertNil(week?.fiveHour)
        XCTAssertEqual(week?.week?.percent, 12)
    }

    func testWindowThatHasResetReadsZero() throws {
        let usage = try XCTUnwrap(ClaudePlanUsage(json: Data(reply.utf8), at: Date()))
        let later = ISO8601DateFormatter().date(from: "2026-11-27T00:00:00Z")!
        XCTAssertEqual(usage.limits(samples: [], now: later).week?.percent, 0)
    }

    func testPaceFromReadingsOfTheSameWindow() {
        let resets = Date(timeIntervalSince1970: 2_000_000)
        let start = Date(timeIntervalSince1970: 1_000_000)
        func reading(_ minutes: Double, _ percent: Double) -> ClaudePlanUsage {
            ClaudePlanUsage(fiveHour: nil, week: .init(percent: percent, resetsAt: resets), at: start.addingTimeInterval(minutes * 60))
        }
        let samples = [reading(0, 50), reading(30, 60)]
        let now = start.addingTimeInterval(30 * 60)
        let limits = reading(30, 60).limits(samples: samples, now: now)
        // 10 % in 30 min: 40 % more in 2 h.
        XCTAssertEqual(limits.week?.limitAt?.timeIntervalSince(now) ?? 0, 7200, accuracy: 1)
    }

    func testSignIn() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":1795000000000,"scopes":["user:inference","user:profile"]},"mcpOAuth":{"x":1}}"#
        let signIn = try XCTUnwrap(ClaudeSignIn(json: Data(json.utf8)))
        XCTAssertEqual(signIn.expiresAt, Date(timeIntervalSince1970: 1_795_000_000))
        XCTAssertTrue(signIn.canReadUsage)
        XCTAssertTrue(signIn.isExpired(now: Date(timeIntervalSince1970: 1_795_000_000)))
        XCTAssertFalse(signIn.isExpired(now: Date(timeIntervalSince1970: 1_794_000_000)))
        // Renewed: the new token and expiry, everything else kept (the MCP sign-ins too).
        let renewed = try XCTUnwrap(signIn.renewed(accessToken: "b", refreshToken: "s", expiresIn: 3600, now: Date(timeIntervalSince1970: 1_800_000_000)))
        let again = try XCTUnwrap(ClaudeSignIn(json: renewed))
        XCTAssertEqual(again.accessToken, "b")
        XCTAssertEqual(again.refreshToken, "s")
        XCTAssertEqual(again.expiresAt, Date(timeIntervalSince1970: 1_800_003_600))
        XCTAssertEqual(again.scopes, signIn.scopes)
        XCTAssertNotNil(again.stored["mcpOAuth"])
        // Inference-only tokens can't read usage; no Claude sign-in at all is nil.
        XCTAssertFalse(ClaudeSignIn(json: Data(#"{"claudeAiOauth":{"accessToken":"a","scopes":["user:inference"]}}"#.utf8))!.canReadUsage)
        XCTAssertNil(ClaudeSignIn(json: Data(#"{"mcpOAuth":{}}"#.utf8)))
    }
}
