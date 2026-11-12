import XCTest
@testable import TuttoKit

final class SnapZonesTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func testEdgesAndCorners() {
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 0, y: 500), screen: screen), .leftHalf)
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 1511, y: 500), screen: screen), .rightHalf)
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 700, y: 0), screen: screen), .maximize)
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 0, y: 0), screen: screen), .topLeft)
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 1511, y: 10), screen: screen), .topRight)
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 20, y: 981), screen: screen), .bottomLeft)
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 1511, y: 981), screen: screen), .bottomRight)
        XCTAssertNil(SnapZones.action(at: CGPoint(x: 700, y: 500), screen: screen), "nowhere near an edge")
        XCTAssertNil(SnapZones.action(at: CGPoint(x: 12, y: 500), screen: screen), "close, not at the edge")
    }

    func testTheBottomEdgeMakesThirdsAndTwoThirds() {
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 300, y: 981), screen: screen), .leftThird)
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 756, y: 981), screen: screen), .centerThird)
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 1200, y: 981), screen: screen), .rightThird)
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 756, y: 981), screen: screen, previous: .leftThird), .leftTwoThirds)
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 756, y: 981), screen: screen, previous: .rightThird), .rightTwoThirds)
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 700, y: 981), screen: screen, previous: .leftTwoThirds), .leftTwoThirds, "stays while sliding")
    }

    func testASecondDisplayUsesItsOwnEdges() {
        let second = CGRect(x: 1512, y: -200, width: 1920, height: 1080)
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 1512, y: 300), screen: second), .leftHalf)
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 2400, y: -200), screen: second), .maximize)
    }

    func testDraggingASnappedWindowAwayGivesBackItsSize() {
        // A left half 756 wide, grabbed a quarter of the way along; it was 800 × 600 before.
        let frame = SnapZones.unsnapped(current: CGRect(x: 0, y: 38, width: 756, height: 944), previousSize: CGSize(width: 800, height: 600),
                                        pointer: CGPoint(x: 189, y: 50))
        XCTAssertEqual(frame, CGRect(x: -11, y: 38, width: 800, height: 600))
    }
}
