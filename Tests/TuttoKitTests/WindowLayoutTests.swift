import XCTest
@testable import TuttoKit

final class WindowLayoutTests: XCTestCase {
    // A 1512 × 945 usable area below a 37 pt menu bar, in top-left coordinates.
    let visible = CGRect(x: 0, y: 37, width: 1512, height: 945)
    let window = CGRect(x: 300, y: 200, width: 800, height: 500)

    func testHalves() {
        XCTAssertEqual(WindowLayout.frame(for: .leftHalf, visible: visible, current: window), CGRect(x: 0, y: 37, width: 756, height: 945))
        XCTAssertEqual(WindowLayout.frame(for: .rightHalf, visible: visible, current: window), CGRect(x: 756, y: 37, width: 756, height: 945))
        XCTAssertEqual(WindowLayout.frame(for: .topHalf, visible: visible, current: window).height, 473)
        XCTAssertEqual(WindowLayout.frame(for: .bottomHalf, visible: visible, current: window).minY, 509)
    }

    func testThirdsAndQuarters() {
        XCTAssertEqual(WindowLayout.frame(for: .centerThird, visible: visible, current: window), CGRect(x: 504, y: 37, width: 504, height: 945))
        XCTAssertEqual(WindowLayout.frame(for: .rightTwoThirds, visible: visible, current: window).minX, 504)
        XCTAssertEqual(WindowLayout.frame(for: .bottomRight, visible: visible, current: window).origin, CGPoint(x: 756, y: 509))
    }

    func testMaximizeCenterAndHeight() {
        XCTAssertEqual(WindowLayout.frame(for: .maximize, visible: visible, current: window), visible)
        let centered = WindowLayout.frame(for: .center, visible: visible, current: window)
        XCTAssertEqual(centered.size, window.size)
        XCTAssertEqual(centered.midX, visible.midX, accuracy: 1)
        XCTAssertEqual(centered.midY, visible.midY, accuracy: 1)
        let tall = WindowLayout.frame(for: .maximizeHeight, visible: visible, current: window)
        XCTAssertEqual(tall.height, visible.height)
        XCTAssertEqual(tall.minX, window.minX)
    }

    func testGapsLeaveEqualSpaceBetweenTiles() {
        let left = WindowLayout.frame(for: .leftHalf, visible: visible, current: window, gap: 8)
        let right = WindowLayout.frame(for: .rightHalf, visible: visible, current: window, gap: 8)
        XCTAssertEqual(left.minX, 8)
        XCTAssertEqual(right.minX - left.maxX, 8, accuracy: 1)
        XCTAssertEqual(right.maxX, visible.maxX - 8, accuracy: 1)
    }

    func testMoveBetweenDisplaysKeepsRelativePlacement() {
        let external = CGRect(x: 1512, y: 25, width: 2560, height: 1415)
        let moved = WindowLayout.move(CGRect(x: 0, y: 37, width: 756, height: 945), from: visible, to: external)
        XCTAssertEqual(moved.minX, external.minX)
        XCTAssertEqual(moved.width, 1280, accuracy: 1)
        XCTAssertTrue(external.contains(moved))
    }

    func testFlipToAccessibilityCoordinates() {
        // Cocoa frame of a menu-bar-less area on a 982 pt tall primary screen.
        let cocoa = CGRect(x: 0, y: 0, width: 1512, height: 945)
        XCTAssertEqual(WindowLayout.flip(cocoa, primaryHeight: 982), CGRect(x: 0, y: 37, width: 1512, height: 945))
    }

    func testFuzzyMatching() {
        func best(_ query: String) -> WindowAction? {
            WindowAction.allCases.compactMap { action in
                FuzzyMatcher.score(query, title: action.title, aliases: action.aliases).map { (action, $0) }
            }.max { $0.1 < $1.1 }?.0
        }
        XCTAssertEqual(best("left half"), .leftHalf)
        XCTAssertEqual(best("Left Ha"), .leftHalf)
        XCTAssertEqual(best("right half"), .rightHalf)
        XCTAssertEqual(best("lh"), .leftHalf)
        XCTAssertEqual(best("max"), .maximize)
        XCTAssertEqual(best("next disp"), .nextDisplay)
        XCTAssertEqual(best("top right"), .topRight)
        XCTAssertNil(FuzzyMatcher.score("zzz", title: "Left Half"))
    }
}
