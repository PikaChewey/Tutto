import XCTest
@testable import TuttoKit

/// The panel's "Busiest apps": helpers count as their app, Tutto itself is left out, and the
/// numbers are percent of one core like Activity Monitor's.
final class AppActivityTests: XCTestCase {
    // A browser (100) with two helpers (101, 102), an editor (200), Tutto (300) with a helper (301).
    private let owners: [pid_t: pid_t] = [100: 100, 101: 100, 102: 100, 200: 200, 300: 300, 301: 300]
    private func responsible(_ pid: pid_t) -> pid_t { owners[pid] ?? pid }

    func testHelpersCountAsTheirApp() {
        let ranked = AppActivitySampler.rank([(101, 300), (102, 200), (100, 100), (200, 450)], elapsed: 1_000,
                                             responsible: responsible, excluding: [], limit: 3)
        XCTAssertEqual(ranked.map(\.pid), [100, 200])
        XCTAssertEqual(ranked[0].cpu, 60, accuracy: 0.001)   // 600 of 1,000
        XCTAssertEqual(ranked[1].cpu, 45, accuracy: 0.001)
    }

    func testTuttoIsLeftOutHelpersIncluded() {
        let ranked = AppActivitySampler.rank([(300, 500), (301, 500), (200, 100)], elapsed: 1_000,
                                             responsible: responsible, excluding: [300], limit: 3)
        XCTAssertEqual(ranked.map(\.pid), [200])
    }

    func testIdleAppsAreLeftOutAndTheListIsCut() {
        let deltas: [(pid: pid_t, cpuTime: UInt64)] = [(1, 900), (2, 800), (3, 700), (4, 600), (5, 4)]
        let ranked = AppActivitySampler.rank(deltas, elapsed: 1_000, responsible: { $0 }, excluding: [], limit: 3)
        XCTAssertEqual(ranked.map(\.pid), [1, 2, 3])
        let idle = AppActivitySampler.rank([(5, 4)], elapsed: 1_000, responsible: { $0 }, excluding: [], limit: 3)
        XCTAssertTrue(idle.isEmpty, "0.4 % is noise")
    }

    func testSeveralCoresShowOverAHundred() {
        let ranked = AppActivitySampler.rank([(7, 3_500)], elapsed: 1_000, responsible: { $0 }, excluding: [], limit: 3)
        XCTAssertEqual(ranked.first?.cpu ?? 0, 350, accuracy: 0.001)
        XCTAssertTrue(AppActivitySampler.rank([(7, 10)], elapsed: 0, responsible: { $0 }, excluding: [], limit: 3).isEmpty)
    }

    func testTheLiveSamplerReadsThisMac() {
        let sampler = AppActivitySampler()
        XCTAssertTrue(sampler.sample().isEmpty, "the first call only takes the starting reading")
        // Burn a little CPU in this process's own children? No: just check a second reading works.
        _ = (0..<2_000_000).reduce(0, &+)
        let apps = sampler.sample(limit: 5)
        XCTAssertLessThanOrEqual(apps.count, 5)
        XCTAssertTrue(apps.allSatisfy { $0.cpu >= 0.5 && !$0.name.isEmpty })
    }
}
