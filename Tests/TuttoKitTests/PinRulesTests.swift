import XCTest
@testable import TuttoKit

final class PinRulesTests: XCTestCase {
    let pinned: CGWindowID = 4_210
    let pid: pid_t = 812

    // MARK: Showing the copy

    func testShowsWhileAnotherAppIsInFront() {
        XCTAssertTrue(PinRules.showsCopy(pinned: pinned, pinnedPID: pid, frontmostPID: 99, focusedWindow: 77, windowOnScreen: true))
        XCTAssertTrue(PinRules.showsCopy(pinned: pinned, pinnedPID: pid, frontmostPID: 99, focusedWindow: nil, windowOnScreen: true),
                      "another app's focus doesn't matter")
        XCTAssertTrue(PinRules.showsCopy(pinned: pinned, pinnedPID: pid, frontmostPID: nil, focusedWindow: nil, windowOnScreen: true),
                      "no app in front (the desktop)")
    }

    func testHidesWhileYouAreInTheWindowItself() {
        XCTAssertFalse(PinRules.showsCopy(pinned: pinned, pinnedPID: pid, frontmostPID: pid, focusedWindow: pinned, windowOnScreen: true))
    }

    func testShowsOverAnotherWindowOfTheSameApp() {
        XCTAssertTrue(PinRules.showsCopy(pinned: pinned, pinnedPID: pid, frontmostPID: pid, focusedWindow: 4_211, windowOnScreen: true))
    }

    func testHidesWhenItsAppIsInFrontButTheFocusIsUnknown() {
        XCTAssertFalse(PinRules.showsCopy(pinned: pinned, pinnedPID: pid, frontmostPID: pid, focusedWindow: nil, windowOnScreen: true))
    }

    func testNeverShowsForAWindowThatIsNotOnScreen() {
        // Minimized, its app hidden, or on another Space.
        XCTAssertFalse(PinRules.showsCopy(pinned: pinned, pinnedPID: pid, frontmostPID: 99, focusedWindow: 77, windowOnScreen: false))
        XCTAssertFalse(PinRules.showsCopy(pinned: pinned, pinnedPID: pid, frontmostPID: pid, focusedWindow: 4_211, windowOnScreen: false))
    }

    // MARK: Pinning

    func testToggle() {
        XCTAssertEqual(PinRules.toggle(1, pinned: []), .pin)
        XCTAssertEqual(PinRules.toggle(1, pinned: [1]), .unpin)
        XCTAssertEqual(PinRules.toggle(4, pinned: [1, 2]), .pin)
        XCTAssertEqual(PinRules.toggle(4, pinned: [1, 2, 3]), .full, "three is the most")
        XCTAssertEqual(PinRules.toggle(2, pinned: [1, 2, 3]), .unpin, "a full list still lets one go")
    }

    func testRefusals() {
        let size = CGSize(width: 800, height: 600)
        XCTAssertNil(PinRules.refusal(pid: 10, ownPID: 1, layer: 0, size: size, fullScreen: false))
        XCTAssertEqual(PinRules.refusal(pid: 1, ownPID: 1, layer: 0, size: size, fullScreen: false), .ownWindow)
        XCTAssertEqual(PinRules.refusal(pid: 10, ownPID: 1, layer: 3, size: size, fullScreen: false), .notAWindow)
        XCTAssertEqual(PinRules.refusal(pid: 10, ownPID: 1, layer: 0, size: size, fullScreen: true), .fullScreen)
        XCTAssertEqual(PinRules.refusal(pid: 10, ownPID: 1, layer: 0, size: CGSize(width: 30, height: 600), fullScreen: false), .tooSmall)
    }

    // MARK: Size and place

    func testCaptureSizeIsTheWindowsOwnPixels() {
        let size = PinRules.captureSize(points: CGSize(width: 800, height: 600), scale: 2)
        XCTAssertEqual(size.width, 1_600)
        XCTAssertEqual(size.height, 1_200)
        let odd = PinRules.captureSize(points: CGSize(width: 640.5, height: 401.25), scale: 2)
        XCTAssertEqual(odd.width, 1_281)
        XCTAssertEqual(odd.height, 803)
    }

    func testCaptureSizeIsNeverZeroAndNeverHuge() {
        let empty = PinRules.captureSize(points: .zero, scale: 0)
        XCTAssertEqual(empty.width, 1)
        XCTAssertEqual(empty.height, 1)
        let huge = PinRules.captureSize(points: CGSize(width: 6_000, height: 3_000), scale: 2)
        XCTAssertEqual(huge.width, PinRules.maxCaptureSide)
        XCTAssertEqual(huge.height, PinRules.maxCaptureSide / 2, "scaled evenly")
    }

    func testPanelFrameFlipsToAppKit() {
        // A window 100 pt from the top of a 982 pt main display.
        let frame = PinRules.panelFrame(windowBounds: CGRect(x: 50, y: 100, width: 400, height: 300), primaryHeight: 982)
        XCTAssertEqual(frame, CGRect(x: 50, y: 582, width: 400, height: 300))
        // On a display above the main one (negative y in the window server's space).
        let above = PinRules.panelFrame(windowBounds: CGRect(x: 0, y: -900, width: 400, height: 300), primaryHeight: 982)
        XCTAssertEqual(above.minY, 1_582)
    }

    func testSmallDifferencesDontMoveTheCopy() {
        let frame = CGRect(x: 10, y: 10, width: 400, height: 300)
        XCTAssertFalse(PinRules.needsMove(from: frame, to: frame.offsetBy(dx: 0.2, dy: -0.3)))
        XCTAssertTrue(PinRules.needsMove(from: frame, to: frame.offsetBy(dx: 1, dy: 0)))
        XCTAssertTrue(PinRules.needsMove(from: frame, to: CGRect(x: 10, y: 10, width: 401, height: 300)))
    }

    // MARK: Words

    func testLabels() {
        XCTAssertEqual(PinRules.label(app: "TextEdit", title: "Notes.txt"), "TextEdit — Notes.txt")
        XCTAssertEqual(PinRules.label(app: "Terminal", title: "  "), "Terminal")
        XCTAssertEqual(PinRules.label(app: "Notes", title: "Notes"), "Notes")
        XCTAssertEqual(PinRules.paletteTitle(pinned: false), "Keep on Top")
        XCTAssertEqual(PinRules.paletteTitle(pinned: true), "Stop Keeping on Top")
    }

    func testPaletteMatching() {
        XCTAssertNotNil(PinRules.paletteScore("pin"))
        XCTAssertNotNil(PinRules.paletteScore("keep"))
        XCTAssertNotNil(PinRules.paletteScore("on top"))
        XCTAssertNotNil(PinRules.paletteScore("float"))
        XCTAssertNil(PinRules.paletteScore("left half"))
    }

    func testPalettePlacement() {
        // Nothing typed: last, after every window action.
        XCTAssertEqual(PinRules.paletteIndex(query: "", rankedActionScores: [0, 0, 0]), 3)
        // "pin" matches nothing else: first.
        XCTAssertEqual(PinRules.paletteIndex(query: "pin", rankedActionScores: []), 0)
        // "top": the actions that start with "Top" match better and stay above it.
        let top = PinRules.paletteScore("top")!
        XCTAssertEqual(PinRules.paletteIndex(query: "top", rankedActionScores: [900, 900, 900, 300]), top > 300 ? 3 : 4)
        // Not a match: left out.
        XCTAssertNil(PinRules.paletteIndex(query: "left half", rankedActionScores: [1000]))
    }
}
