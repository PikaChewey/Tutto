import XCTest
@testable import TuttoKit

/// Window pictures are kept in a RecentlyUsed store: it must never hold more than its limit, and
/// what it lets go of must be the oldest, so a day of new windows can't pile up pictures.
final class RecentlyUsedTests: XCTestCase {
    func testStoringPastTheLimitLetsGoOfTheOldest() {
        var store = RecentlyUsed<Int, String>(limit: 3)
        for id in 1...5 { store.set("picture \(id)", for: id) }
        XCTAssertEqual(store.count, 3)
        XCTAssertEqual(store.keys, [3, 4, 5])
        XCTAssertNil(store[1])
        XCTAssertEqual(store[5], "picture 5")
    }

    func testStoringAgainMakesItTheNewest() {
        var store = RecentlyUsed<Int, String>(limit: 3)
        for id in 1...3 { store.set("old \(id)", for: id) }
        store.set("new 1", for: 1)
        store.set("picture 4", for: 4)
        XCTAssertEqual(store.keys, [3, 1, 4], "2 was the oldest once 1 was stored again")
        XCTAssertEqual(store[1], "new 1")
        XCTAssertNil(store[2])
    }

    func testWindowsThatAreGoneAreLetGo() {
        var store = RecentlyUsed<Int, String>(limit: 24)
        for id in 1...6 { store.set("picture \(id)", for: id) }
        store.remove(2)
        store.keep(only: [1, 3, 6, 99])
        XCTAssertEqual(store.keys, [1, 3, 6])
        XCTAssertEqual(store.count, 3)
        store.removeAll()
        XCTAssertTrue(store.isEmpty)
        XCTAssertEqual(store.keys, [])
    }

    func testALimitBelowOneStillKeepsTheNewest() {
        var store = RecentlyUsed<Int, Int>(limit: 0)
        store.set(1, for: 1)
        store.set(2, for: 2)
        XCTAssertEqual(store.keys, [2])
    }
}
