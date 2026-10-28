import Carbon.HIToolbox
import CoreGraphics
import XCTest
@testable import TuttoKit

/// The strip's rules, checked against how it's described working: "Notes is 66% … 75% … 25% …
/// 33% … 50%", "Full width · back to 50%", "That's the first window on the strip.",
/// "Stack · joined the column on its left", and so on.
final class StripModelTests: XCTestCase {
    private func strip(_ widths: [Double], focus: Int = 0) -> Strip {
        Strip(columns: widths.enumerated().map { StripColumn(windows: [StripWindow($0.offset + 1)], width: $0.element) },
              focusColumn: focus)
    }

    func testCycleWidthGoesUpToFullWidthAndWraps() {
        var s = strip([2.0 / 3.0])
        var seen: [String] = []
        for _ in 0..<6 { seen.append(s.cycleWidth().message) }
        XCTAssertEqual(seen, ["Cycle width · 75%", "Cycle width · Full", "Cycle width · 25%", "Cycle width · 33%",
                              "Cycle width · 50%", "Cycle width · 67%"])
        XCTAssertEqual(s.columns[0].width, 2.0 / 3.0, accuracy: 0.0001)
    }

    func testCyclingOntoFullWidthIsTheSameAsFullWidth() {
        var s = strip([0.75])
        XCTAssertEqual(s.cycleWidth(), .done("Cycle width · Full"))
        XCTAssertEqual(s.columns[0].width, 1)
        // Full width remembers the width before, like the full width key does.
        XCTAssertEqual(s.toggleFullWidth(), .done("Full width · back to 75%"))
        XCTAssertEqual(s.columns[0].width, 0.75)
        // A preset list that already ends at full width doesn't get it twice.
        var t = strip([0.5])
        XCTAssertEqual(t.cycleWidth(presets: [0.5, 1]), .done("Cycle width · Full"))
        XCTAssertEqual(t.cycleWidth(presets: [0.5, 1]), .done("Cycle width · 50%"))
    }

    func testFullWidthTogglesBackToTheWidthBefore() {
        var s = strip([0.5])
        XCTAssertEqual(s.toggleFullWidth(), .done("Full width · fills the screen"))
        XCTAssertEqual(s.columns[0].width, 1)
        XCTAssertEqual(s.toggleFullWidth(), .done("Full width · back to 50%"))
        XCTAssertEqual(s.columns[0].width, 0.5)
    }

    func testFullWindowsMakesEveryColumnFullAndGivesEachItsWidthBack() {
        var s = strip([0.5, 1.0 / 3.0, 1, 0.75])
        XCTAssertFalse(s.isAllFull)
        XCTAssertEqual(s.setAllFull(true), .done("Full windows"))
        XCTAssertTrue(s.isAllFull)
        XCTAssertEqual(s.columns.map(\.width), [1, 1, 1, 1])
        XCTAssertEqual(s.setAllFull(true), .refused("Every window is already full."))
        XCTAssertEqual(s.setAllFull(false, fallback: 0.5), .done("Strip"))
        // Each goes back to the width it had; one that was already full stays full.
        XCTAssertEqual(s.columns.map(\.width), [0.5, 1.0 / 3.0, 1, 0.75])
        XCTAssertFalse(s.columns.contains { $0.widthBeforeFull != nil || $0.widthBeforeAllFull != nil })
        // A column that arrived while full (no width to go back to) takes the fallback.
        var t = strip([0.5])
        _ = t.setAllFull(true)
        t.columns.append(StripColumn(windows: [99], width: 1))
        _ = t.setAllFull(false, fallback: 0.5)
        XCTAssertEqual(t.columns.map(\.width), [0.5, 0.5])
        var empty = Strip()
        XCTAssertEqual(empty.setAllFull(true), .refused("The strip is empty."))
    }

    func testFullWindowsLeavesAStripThatWasAlreadyFullAsItWas() {
        // Every window already full (brought onto the strip at 100 %): Full, then Strip, keeps them full.
        var s = strip([1, 1])
        XCTAssertEqual(s.setAllFull(true), .done("Full windows"))
        XCTAssertEqual(s.setAllFull(true), .refused("Every window is already full."))
        XCTAssertEqual(s.setAllFull(false, fallback: 0.5), .done("Strip"))
        XCTAssertEqual(s.columns.map(\.width), [1, 1])
    }

    func testAWindowAwayWhileFullComesBackToItsOwnWidth() {
        // Hidden or minimized while Full windows is on, a window keeps its strip width in its slot.
        var s = strip([0.75, 0.5])
        _ = s.setAllFull(true)
        let slot = s.slot(of: 1)!
        s.remove(1)
        s.restore(1, to: slot)
        XCTAssertEqual(s.columns.map(\.width), [1, 1])
        _ = s.setAllFull(false, fallback: 0.5)
        XCTAssertEqual(s.columns.map(\.width), [0.75, 0.5])
    }

    func testWindowsJoiningWhileFullComeInFullAndGoBackToTheirStripWidths() {
        var s = strip([0.5])
        _ = s.setAllFull(true)
        // One back from before Full windows (its slot says 0.75), one from full screen (full on the
        // strip too), one brand new (no strip width of its own: it takes the fallback).
        s.restore(7, to: StripSlot(index: 1, row: 0, width: 0.75, leftNeighbour: 1, rightNeighbour: nil, stackedWith: []))
        s.joinFull(7, stripWidth: 0.75)
        s.insert(8, width: 1)
        s.joinFull(8, stripWidth: 1)
        s.insert(9, width: 1)
        s.joinFull(9, stripWidth: nil)
        XCTAssertTrue(s.isAllFull)
        _ = s.setAllFull(false, fallback: 0.5)
        let widths = Dictionary(uniqueKeysWithValues: s.columns.map { ($0.windows[0], $0.width) })
        XCTAssertEqual(widths, [1: 0.5, 7: 0.75, 8: 1, 9: 0.5])
    }

    func testFocusAndMoveStopAtTheEnds() {
        var s = strip([0.5, 0.5, 0.5])
        XCTAssertEqual(s.focusLeft(), .refused("That's the first window on the strip."))
        XCTAssertEqual(s.focusRight(), .done("Focus right"))
        XCTAssertEqual(s.focusLast(), .done("Last window"))
        XCTAssertEqual(s.focusRight(), .refused("That's the last window on the strip."))
        XCTAssertEqual(s.moveRight(), .refused("Already at the end of the strip."))
        XCTAssertEqual(s.moveLeft(), .done("Move left · swapped places"))
        XCTAssertEqual(s.allWindows, [1, 3, 2])
        XCTAssertEqual(s.focusedWindow, 3)
        XCTAssertEqual(s.focusFirst(), .done("First window"))
        XCTAssertEqual(s.focusedWindow, 1)
    }

    func testJumpByNumberAndNineIsTheLast() {
        var s = strip([0.5, 0.5, 0.5, 0.5])
        XCTAssertEqual(s.focusNumber(3), .done("Window 3"))
        XCTAssertEqual(s.focusedWindow, 3)
        XCTAssertEqual(s.focusNumber(9), .done("Window 4"))
        XCTAssertEqual(s.focusNumber(6), .refused("There's no window 6 on the strip."))
        XCTAssertEqual(s.moveToNumber(1), .done("Moved to 1"))
        XCTAssertEqual(s.allWindows, [4, 1, 2, 3])
        XCTAssertEqual(s.focusedWindow, 4)
    }

    func testStackJoinsTheNeighbourAndPopOutGivesItsColumnBack() {
        var s = strip([0.5, 0.5, 0.5], focus: 1)
        XCTAssertEqual(s.stack(into: .left), .done("Stack · joined the column on its left"))
        XCTAssertEqual(s.columns.map(\.windows), [[1, 2], [3]])
        XCTAssertEqual(s.focusedWindow, 2)
        XCTAssertEqual(s.popOut(to: .right), .done("Pop out · its own column again, on the right"))
        XCTAssertEqual(s.columns.map(\.windows), [[1], [2], [3]])
        XCTAssertEqual(s.focusColumn, 1)

        XCTAssertEqual(s.stack(into: .right), .done("Stack · joined the column on its right"))
        XCTAssertEqual(s.columns.map(\.windows), [[1], [3, 2]])
        XCTAssertEqual(s.focusColumn, 1)
        XCTAssertEqual(s.focusedWindow, 2)
        XCTAssertEqual(s.focusUp(), .done("Focus up"))
        XCTAssertEqual(s.focusedWindow, 3)
        XCTAssertEqual(s.popOut(to: .left), .done("Pop out · its own column again, on the left"))
        XCTAssertEqual(s.columns.map(\.windows), [[1], [3], [2]])
        XCTAssertEqual(s.focusedWindow, 3)
    }

    func testStackRefusesAtTheEnds() {
        var s = strip([0.5, 0.5])
        XCTAssertEqual(s.stack(into: .left), .refused("There's no column on the left."))
        XCTAssertEqual(s.popOut(to: .right), .refused("It already has a column of its own."))
        XCTAssertEqual(s.toggleTabbed(), .refused("Stack windows first, then make them tabs."))
    }

    func testTabbedColumnShowsOneWindowAndTheRestWait() {
        var s = strip([0.5, 0.5], focus: 1)
        _ = s.stack(into: .left)
        XCTAssertEqual(s.toggleTabbed(), .done("Tabbed column · one window at full height, the rest behind tabs"))
        XCTAssertEqual(s.focusedWindow, 2)
        XCTAssertEqual(s.focusUp(), .done("Previous tab"))
        XCTAssertEqual(s.focusedWindow, 1)
        XCTAssertEqual(s.focusUp(), .refused("That's the first tab."))

        let geometry = StripGeometry(strip: s, metrics: StripMetrics(area: CGRect(x: 0, y: 25, width: 1000, height: 800), gap: 10))
        let placements = geometry.placements(offset: 0)
        XCTAssertEqual(placements.filter { !$0.isBackgroundTab }.map(\.window), [1])
        XCTAssertEqual(placements[0].frame, placements[1].frame)
        XCTAssertEqual(placements[0].frame.minY, 35 + 28)
        XCTAssertEqual(geometry.tabBars(offset: 0).count, 1)
        XCTAssertEqual(s.toggleTabbed(), .done("Tabbed column · back to a stack"))
    }

    func testHeightsInAStack() {
        var s = Strip(columns: [StripColumn(windows: [1, 2, 3], width: 0.5)], focusColumn: 0, focusRow: 1)
        XCTAssertEqual(s.adjustHeight(by: 0.1), .done("Taller"))
        let heights = s.columns[0].normalizedHeights
        XCTAssertEqual(heights.reduce(0, +), 1, accuracy: 0.0001)
        XCTAssertGreaterThan(heights[1], heights[0])
        XCTAssertEqual(heights[0], heights[2], accuracy: 0.0001)
        for _ in 0..<20 { _ = s.adjustHeight(by: 0.1) }
        XCTAssertGreaterThanOrEqual(s.columns[0].normalizedHeights.min()!, Strip.minimumHeightFraction - 0.0001)
        XCTAssertEqual(s.adjustHeight(by: 0.1), .refused("Already as tall as it goes."))
        XCTAssertEqual(s.equalizeHeights(), .done("Equal heights"))
        XCTAssertEqual(s.columns[0].normalizedHeights, [1.0 / 3, 1.0 / 3, 1.0 / 3])

        let geometry = StripGeometry(strip: s, metrics: StripMetrics(area: CGRect(x: 0, y: 25, width: 1000, height: 800), gap: 10))
        let frames = geometry.placements(offset: 0).map(\.frame)
        XCTAssertEqual(frames.first?.minY, 35)
        XCTAssertEqual(frames.last?.maxY, 815)
        for (upper, lower) in zip(frames, frames.dropFirst()) { XCTAssertEqual(lower.minY - upper.maxY, 10) }
    }

    func testPinnedColumnsStayAtTheEdges() {
        var s = strip([0.5, 0.5, 0.5, 0.5], focus: 2)
        XCTAssertEqual(s.togglePin(.left), .done("Pinned to the left edge"))
        XCTAssertEqual(s.allWindows, [3, 1, 2, 4])
        XCTAssertEqual(s.focusedWindow, 3)
        XCTAssertEqual(s.scrollingRange, 1..<4)
        XCTAssertEqual(s.moveRight(), .refused("A pinned column stays at its edge."))
        XCTAssertEqual(s.focusLast(), .done("Last window"))
        XCTAssertEqual(s.moveToFirst(), .done("Moved to the start"))
        XCTAssertEqual(s.allWindows, [3, 4, 1, 2])

        let metrics = StripMetrics(area: CGRect(x: 0, y: 25, width: 1000, height: 800), gap: 10)
        let geometry = StripGeometry(strip: s, metrics: metrics)
        XCTAssertEqual(geometry.screenX(of: 0, offset: 500), metrics.inner.minX)
        XCTAssertEqual(geometry.viewportMinX, metrics.inner.minX + geometry.widths[0] + 10)
        XCTAssertEqual(s.togglePin(.right), .done("Pinned to the right edge"))
        XCTAssertEqual(s.allWindows, [3, 1, 2, 4])
        _ = s.focusNumber(4)
        XCTAssertEqual(s.togglePin(.right), .done("Unpinned"))
    }

    func testNewWindowsOpenBesideTheFocusedOne() {
        var s = strip([0.5, 0.5, 0.5], focus: 0)
        s.insert(9, width: 0.5)
        XCTAssertEqual(s.allWindows, [1, 9, 2, 3])
        XCTAssertEqual(s.focusedWindow, 9)
        // A background app's window joins at the end without taking focus.
        s.insert(8, width: 0.5, besideFocused: false, focus: false)
        XCTAssertEqual(s.allWindows, [1, 9, 2, 3, 8])
        XCTAssertEqual(s.focusedWindow, 9)
    }

    func testClosingMovesFocusToTheNeighbour() {
        var s = strip([0.5, 0.5, 0.5], focus: 1)
        s.remove(2)
        XCTAssertEqual(s.allWindows, [1, 3])
        XCTAssertEqual(s.focusedWindow, 1)
        s.remove(1)
        XCTAssertEqual(s.focusedWindow, 3)
        s.remove(3)
        XCTAssertTrue(s.isEmpty)
        XCTAssertNil(s.focusedWindow)
    }

    func testMinimizedWindowsComeBackToTheirSlot() {
        var s = strip([0.5, 1.0 / 3.0, 0.5], focus: 0)
        let slot = s.slot(of: 2)!
        s.remove(2)
        s.insert(7, width: 0.5, besideFocused: false, focus: false)
        s.restore(2, to: slot)
        XCTAssertEqual(s.allWindows, [1, 2, 3, 7])
        XCTAssertEqual(s.columns[1].width, 1.0 / 3.0, accuracy: 0.0001)

        var stacked = Strip(columns: [StripColumn(windows: [1, 2], width: 0.5), StripColumn(windows: [3], width: 0.5)])
        let stackSlot = stacked.slot(of: 2)!
        stacked.remove(2)
        stacked.restore(2, to: stackSlot)
        XCTAssertEqual(stacked.columns.map(\.windows), [[1, 2], [3]])
    }

    func testDragReorderLeavesPinsAlone() {
        var s = strip([0.5, 0.5, 0.5, 0.5], focus: 0)
        _ = s.togglePin(.left)
        s.moveColumn(from: 3, to: 0)
        XCTAssertEqual(s.allWindows, [1, 4, 2, 3])
        XCTAssertEqual(s.focusedWindow, 1)
    }
}

final class StripGeometryTests: XCTestCase {
    private let area = CGRect(x: 0, y: 25, width: 1000, height: 800)

    private func geometry(_ widths: [Double], gap: Double = 10) -> StripGeometry {
        let strip = Strip(columns: widths.enumerated().map { StripColumn(windows: [StripWindow($0.offset + 1)], width: $0.element) })
        return StripGeometry(strip: strip, metrics: StripMetrics(area: area, gap: gap))
    }

    func testHalvesFillTheScreenGapsIncluded() {
        let g = geometry([0.5, 0.5, 1])
        XCTAssertEqual(g.widths, [485, 485, 980])
        let frames = g.placements(offset: 0).map(\.frame)
        XCTAssertEqual(frames[0], CGRect(x: 10, y: 35, width: 485, height: 780))
        XCTAssertEqual(frames[1].minX, 505)
        XCTAssertEqual(frames[1].maxX, 990)
        XCTAssertEqual(g.length, 485 + 10 + 485 + 10 + 980)
        XCTAssertEqual(g.maxOffset, g.length - 980)
    }

    func testRevealScrollsJustFarEnough() {
        let g = geometry([2.0 / 3.0, 2.0 / 3.0, 2.0 / 3.0])
        let w = g.widths[0]
        XCTAssertEqual(g.offset(revealing: 0, from: 0, centring: .never), 0)
        // The second column ends past the screen: scroll until its right edge meets the viewport's.
        XCTAssertEqual(g.offset(revealing: 1, from: 0, centring: .never), (w + 10 + w) - 980)
        // Already showing: nothing moves.
        XCTAssertEqual(g.offset(revealing: 1, from: 500, centring: .never), 500)
        // Back to the first: just far enough again, never past the start.
        XCTAssertEqual(g.offset(revealing: 0, from: 500, centring: .never), 0)
        XCTAssertLessThanOrEqual(g.offset(revealing: 2, from: 0, centring: .never), g.maxOffset)
    }

    func testCentringModes() {
        let g = geometry([0.5, 0.5, 0.5, 0.5])
        let centred = g.centredOffset(for: 0)
        XCTAssertLessThan(centred, 0)  // the first column in the middle leaves room on its left
        XCTAssertEqual(g.offset(revealing: 0, from: 0, centring: .always), centred)
        XCTAssertEqual(g.offset(revealing: 0, from: 0, centring: .whenOverflowing), 0)
        XCTAssertEqual(g.offset(revealing: 2, from: 0, centring: .whenOverflowing), g.clamped(g.centredOffset(for: 2)))

        let short = geometry([0.25, 0.25])
        XCTAssertFalse(short.overflows)
        XCTAssertEqual(short.offset(revealing: 1, from: 0, centring: .whenOverflowing), 0)
    }

    func testOutOfViewWindowsAreFound() {
        let g = geometry([0.75, 0.75, 0.75])
        let placements = g.placements(offset: 0)
        XCTAssertTrue(g.isInView(placements[0].frame, column: 0))
        XCTAssertTrue(g.isInView(placements[1].frame, column: 1))  // the next one peeks in
        XCTAssertFalse(g.isInView(placements[2].frame, column: 2))
        XCTAssertEqual(g.visibleFraction(of: 0, offset: 0), 1)
        XCTAssertEqual(g.mostVisibleColumn(offset: g.positions[1]), 1)
    }

    func testDroppingAWindowFindsItsNewColumn() {
        let g = geometry([0.5, 0.5, 0.5])
        XCTAssertEqual(g.column(atScreenX: 100, offset: 0), 0)
        XCTAssertEqual(g.column(atScreenX: 700, offset: 0), 1)
        XCTAssertEqual(g.column(atScreenX: 5000, offset: 0), 2)
    }

    func testSwipesSettleOnAColumnOrWhereTheyStop() {
        let g = geometry([0.5, 0.5, 0.5, 0.5])
        XCTAssertEqual(g.settle(offset: 300, velocity: 0, snap: true), g.positions[1])
        XCTAssertEqual(g.settle(offset: 100, velocity: 0, snap: true), 0)
        XCTAssertEqual(g.settle(offset: 300, velocity: 0, snap: false), 300)
        XCTAssertEqual(g.settle(offset: 900, velocity: 5000, snap: false), g.maxOffset)
        XCTAssertGreaterThan(g.settle(offset: 260, velocity: 3000, snap: true), 300)
    }

    func testAppsThatInsistOnAWidthGetIt() {
        let strip = Strip(columns: [StripColumn(windows: [1], width: 0.25), StripColumn(windows: [2], width: 0.5)])
        let g = StripGeometry(strip: strip, metrics: StripMetrics(area: area, gap: 10), enforcedWidths: [1: 600])
        XCTAssertEqual(g.widths[0], 600)
        XCTAssertEqual(g.placements(offset: 0)[1].frame.minX, 10 + 600 + 10)
    }

    func testKeepOriginalHeightAlignsToTheTop() {
        let strip = Strip(columns: [StripColumn(windows: [1], width: 0.5)])
        let g = StripGeometry(strip: strip, metrics: StripMetrics(area: area, gap: 10, fullHeight: false), naturalHeights: [1: 400])
        XCTAssertEqual(g.placements(offset: 0)[0].frame, CGRect(x: 10, y: 35, width: 485, height: 400))
    }

    func testParkingLeavesOnePointOnItsOwnDisplay() {
        let display = CGRect(x: 0, y: 25, width: 1512, height: 900)
        let size = CGSize(width: 800, height: 600)
        let right = StripParking.frame(size: size, side: .right, display: display, others: [])
        XCTAssertEqual(right.origin, CGPoint(x: 1511, y: 924))
        XCTAssertEqual(display.intersection(right).width, 1)
        let left = StripParking.frame(size: size, side: .left, display: display, others: [])
        XCTAssertEqual(left.maxX, 1)
        XCTAssertTrue(StripParking.isParked(right, display: display))
        XCTAssertTrue(StripParking.isParked(left, display: display))
        XCTAssertFalse(StripParking.isParked(CGRect(x: 10, y: 35, width: 800, height: 600), display: display))
        // An external display to the right: park in the left corner instead of spilling onto it.
        let external = CGRect(x: 1512, y: -100, width: 1920, height: 1080)
        XCTAssertEqual(StripParking.frame(size: size, side: .right, display: display, others: [external]).maxX, 1)
    }
}

final class StripMotionTests: XCTestCase {
    func testSpringArrivesQuicklyWithoutOvershoot() {
        var spring = SpringValue(0)
        let omega = StripAnimation.smooth.omega!
        var time = 0.0
        var peak = 0.0
        while !spring.isSettled(at: 1000), time < 2 {
            spring.step(toward: 1000, omega: omega, dt: 1.0 / 120)
            peak = max(peak, spring.value)
            time += 1.0 / 120
        }
        XCTAssertLessThanOrEqual(peak, 1000.0001)
        XCTAssertLessThan(time, 0.55)
        // Most of the way there in the first fifth of a second.
        var early = SpringValue(0)
        for _ in 0..<24 { early.step(toward: 1000, omega: omega, dt: 1.0 / 120) }
        XCTAssertGreaterThan(early.value, 900)
    }

    func testSpringIsTheSameAtAnyFrameRate() {
        var at60 = SpringValue(0), at120 = SpringValue(0)
        for _ in 0..<15 { at60.step(toward: 500, omega: 24, dt: 1.0 / 60) }
        for _ in 0..<30 { at120.step(toward: 500, omega: 24, dt: 1.0 / 120) }
        XCTAssertEqual(at60.value, at120.value, accuracy: 0.001)
    }

    func testRetargetingKeepsTheMotion() {
        var spring = SpringValue(0)
        for _ in 0..<6 { spring.step(toward: 1000, omega: 24, dt: 1.0 / 120) }
        XCTAssertGreaterThan(spring.velocity, 0)
        spring.step(toward: -1000, omega: 24, dt: 1.0 / 120)
        XCTAssertGreaterThan(spring.velocity, 0)  // still heading the old way for a moment: no jump
    }

    func testSwipeSpeed() {
        var tracker = SwipeTracker()
        for frame in 0..<10 { tracker.record(offset: Double(frame) * 10, at: Double(frame) / 100) }
        XCTAssertEqual(tracker.velocity, 1000, accuracy: 1)
    }
}

final class StripCommandTests: XCTestCase {
    func testEveryDefaultIsControlOptionAndUnique() {
        let shortcuts = StripCommand.allCases.map(\.defaultShortcut)
        XCTAssertEqual(Set(shortcuts).count, shortcuts.count)
        XCTAssertEqual(Set(StripCommand.allCases.map(\.id)).count, StripCommand.allCases.count)
        for shortcut in shortcuts {
            XCTAssertTrue(shortcut.modifiers.contains([.control, .option]), shortcut.displayString)
        }
        XCTAssertEqual(StripCommand.cycleWidth.defaultShortcut.keyCode, UInt16(kVK_ANSI_R))
        XCTAssertEqual(StripCommand.stackLeft.defaultShortcut.keyCode, UInt16(kVK_ANSI_RightBracket))
        XCTAssertEqual(StripCommand.moveToNumber(3).defaultShortcut.modifiers, [.control, .option, .shift])
        XCTAssertEqual(StripCommand.focusNumber(9).title, "Jump to the last window")
    }
}

final class StripRulesTests: XCTestCase {
    private func facts(subrole: String? = "AXStandardWindow", bundle: String = "org.example.editor",
                       size: CGSize = CGSize(width: 900, height: 700), resizable: Bool = true,
                       fullScreen: Bool = false) -> StripWindowFacts {
        StripWindowFacts(role: "AXWindow", subrole: subrole, bundleID: bundle, size: size, canResize: resizable, isFullScreen: fullScreen)
    }

    func testWhatTilesAndWhatFloats() {
        XCTAssertEqual(StripRules.admission(facts()), .tile)
        XCTAssertEqual(StripRules.admission(facts(subrole: "AXDialog")), .float("dialog or panel"))
        XCTAssertEqual(StripRules.admission(facts(resizable: false)), .float("fixed size"))
        XCTAssertEqual(StripRules.admission(facts(bundle: "com.apple.quicklook.QuickLookUIService")), .float("system panel"))
        XCTAssertEqual(StripRules.admission(facts(), floatingApps: ["org.example.editor"]), .float("you float this app"))
        XCTAssertEqual(StripRules.admission(facts(bundle: "ca.bryanyao.Tutto"), ownBundleID: "ca.bryanyao.Tutto"), .float("Tutto's own window"))
        XCTAssertEqual(StripRules.admission(facts(size: CGSize(width: 120, height: 90))), .float("too small"))
        XCTAssertEqual(StripRules.admission(facts(fullScreen: true)), .ignore)
    }

    func testMacSetupFlagsTheSettingsThatFightTheStrip() {
        let defaults = MacSetup.checks(MacSetupReading(), swipeFingers: nil, hasEdgeTiling: true)
        XCTAssertEqual(defaults.map(\.id), ["separateSpaces", "rearrangeSpaces", "stageManager", "edgeTiling"])
        // macOS's defaults: separate Spaces on (fine), rearranging and edge tiling on (not fine).
        XCTAssertEqual(defaults.map(\.isOK), [true, false, true, false])

        let tidy = MacSetupReading(spansDisplays: false, rearrangesSpaces: false, stageManager: false, edgeTiling: false,
                                   threeFingerSwipe: 2, fourFingerSwipe: 0, threeFingerDrag: true)
        let threeFingers = MacSetup.checks(tidy, swipeFingers: 3, hasEdgeTiling: true)
        XCTAssertEqual(threeFingers.filter { !$0.isOK }.map(\.id), ["swipe", "threeFingerDrag"])
        XCTAssertTrue(MacSetup.checks(tidy, swipeFingers: 4, hasEdgeTiling: false).allSatisfy(\.isOK))
    }
}

final class ShortcutTapTests: XCTestCase {
    private final class Box: @unchecked Sendable { var ids: [String] = [] }

    private func key(_ code: Int, down: Bool = true, _ flags: CGEventFlags) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down)!
        event.flags = flags
        return event
    }

    func testExactMatchesAreTakenAndTheRestPassThrough() {
        let box = Box()
        let tap = ShortcutTap { box.ids.append($0) }
        tap.bindings = [StripCommand.focusRight.defaultShortcut: "right", StripCommand.cycleWidth.defaultShortcut: "width"]
        // Arrow keys arrive with the keypad and fn flags too; they don't count.
        XCTAssertNil(tap.handle(type: .keyDown, event: key(kVK_RightArrow, [.maskControl, .maskAlternate, .maskNumericPad, .maskSecondaryFn])))
        XCTAssertNil(tap.handle(type: .keyUp, event: key(kVK_RightArrow, down: false, [.maskControl, .maskAlternate])))
        XCTAssertEqual(box.ids, ["right"])
        // One modifier more is a different shortcut: untouched.
        XCTAssertNotNil(tap.handle(type: .keyDown, event: key(kVK_RightArrow, [.maskControl, .maskAlternate, .maskShift])))
        XCTAssertNotNil(tap.handle(type: .keyUp, event: key(kVK_RightArrow, down: false, [.maskControl, .maskAlternate, .maskShift])))
        XCTAssertNotNil(tap.handle(type: .keyDown, event: key(kVK_ANSI_R, [.maskCommand])))
        XCTAssertNil(tap.handle(type: .keyDown, event: key(kVK_ANSI_R, [.maskControl, .maskAlternate])))
        XCTAssertEqual(box.ids, ["right", "width"])
    }

    func testHoldingModifiersIsReportedOnceAndPassesThrough() {
        final class Held: @unchecked Sendable { var changes: [KeyShortcut.Modifiers] = [] }
        let held = Held()
        let tap = ShortcutTap { _ in }
        tap.onModifiers = { held.changes.append($0) }
        func flags(_ value: CGEventFlags) -> CGEvent {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Control), keyDown: true)!
            event.type = .flagsChanged
            event.flags = value
            return event
        }
        XCTAssertNotNil(tap.handle(type: .flagsChanged, event: flags([.maskControl])))
        XCTAssertNotNil(tap.handle(type: .flagsChanged, event: flags([.maskControl, .maskAlternate])))
        XCTAssertNotNil(tap.handle(type: .flagsChanged, event: flags([.maskControl, .maskAlternate, .maskSecondaryFn])))
        XCTAssertNotNil(tap.handle(type: .flagsChanged, event: flags([])))
        XCTAssertEqual(held.changes, [[.control], [.control, .option], []])
    }

    func testRecordingAShortcutLetsEveryKeyThrough() {
        let box = Box()
        let tap = ShortcutTap { box.ids.append($0) }
        tap.bindings = [StripCommand.focusLeft.defaultShortcut: "left"]
        tap.isSuspended = true
        XCTAssertNotNil(tap.handle(type: .keyDown, event: key(kVK_LeftArrow, [.maskControl, .maskAlternate])))
        XCTAssertTrue(box.ids.isEmpty)
    }
}

/// "Hide the Dock": Tutto hides the Dock while the strip runs and puts back only what it changed.
final class StripDockTests: XCTestCase {
    func testTheStripHidesAShowingDockAndPutsItBack() {
        XCTAssertEqual(StripDock.step(wanted: true, hidByTutto: false, autoHides: false), .hide)
        XCTAssertEqual(StripDock.step(wanted: true, hidByTutto: true, autoHides: true), .none)
        XCTAssertEqual(StripDock.step(wanted: false, hidByTutto: true, autoHides: true), .restore)
        XCTAssertEqual(StripDock.step(wanted: false, hidByTutto: false, autoHides: false), .none)
    }

    func testADockYouSetYourselfIsLeftAlone() {
        // Already hidden by you: nothing to do, and nothing to put back later.
        XCTAssertEqual(StripDock.step(wanted: true, hidByTutto: false, autoHides: true), .none)
        XCTAssertEqual(StripDock.step(wanted: false, hidByTutto: false, autoHides: true), .none)
        // Brought back by you while the strip runs: not hidden again behind your back.
        XCTAssertEqual(StripDock.step(wanted: true, hidByTutto: true, autoHides: false), .none)
        // A macOS without the calls: never touched.
        XCTAssertEqual(StripDock.step(wanted: true, hidByTutto: false, autoHides: nil), .none)
        XCTAssertEqual(StripDock.step(wanted: false, hidByTutto: true, autoHides: nil), .none)
    }
}
