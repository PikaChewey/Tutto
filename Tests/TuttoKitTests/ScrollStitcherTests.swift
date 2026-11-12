import Foundation
import XCTest
@testable import TuttoKit

/// Synthetic pages: every row a distinct pattern (with some blank lines), seen through a
/// viewport that scrolls, optionally with a sticky header and footer drawn over it and a
/// blinking region. The stitched result must be the page, row for row.
final class ScrollStitcherTests: XCTestCase {
    private let width = ScrollStitcher.columns

    /// A page of `rows` rows; every 7th row blank, the rest a pattern unique to the row.
    private func page(_ rows: Int, seed: UInt64 = 7) -> [[UInt8]] {
        var state = seed
        func next() -> UInt8 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(truncatingIfNeeded: state >> 56)
        }
        return (0..<rows).map { y in
            y % 7 == 3 ? [UInt8](repeating: 250, count: width) : (0..<width).map { _ in next() }
        }
    }

    private struct Viewport {
        var height = 300
        var header: [[UInt8]] = []
        var footer: [[UInt8]] = []
        /// Rows (in the viewport) that change every frame, like a playing video.
        var blinking: Range<Int>? = nil
    }

    private func frame(_ page: [[UInt8]], at position: Int, _ view: Viewport, tick: Int) -> [[UInt8]] {
        var rows = Array(page[position..<(position + view.height)])
        for (i, row) in view.header.enumerated() { rows[i] = row }
        for (i, row) in view.footer.enumerated() { rows[view.height - view.footer.count + i] = row }
        if let blinking = view.blinking {
            for y in blinking { rows[y] = [UInt8](repeating: UInt8((tick * 37 + y) % 256), count: width) }
        }
        return rows
    }

    /// Runs the stitcher over frames at `positions` and returns the picture's rows.
    private func stitch(_ page: [[UInt8]], positions: [Int], _ view: Viewport, expected: Int? = nil) -> (rows: [[UInt8]], plan: StitchPlan) {
        let frames = positions.enumerated().map { frame(page, at: $0.element, view, tick: $0.offset) }
        var plan = StitchPlan(frameHeight: view.height)
        for i in 1..<frames.count {
            guard let match = ScrollStitcher.match(frames[i - 1], frames[i], expected: expected) else {
                XCTFail("no match at frame \(i)")
                continue
            }
            if match.offset > 0 {
                let bands = ScrollStitcher.fixedBands(frames[i - 1], frames[i], offset: match.offset)
                plan.setBands(top: bands.top, bottom: bands.bottom)
            }
            plan.add(frame: i, offset: match.offset)
        }
        let rows = plan.slices.flatMap { slice in slice.rows.map { frames[slice.frame][$0] } }
        return (rows, plan)
    }

    func testPlainPage() {
        let content = page(1200)
        let result = stitch(content, positions: [0, 150, 300, 450, 600, 750, 900], Viewport())
        XCTAssertEqual(result.rows.count, 1200)
        XCTAssertEqual(result.rows, Array(content[0..<1200]))
    }

    func testUnevenStepsAndTheEndOfThePage() {
        let content = page(800)
        // The last scroll only got 80 rows further: the page ended; then it didn't move at all.
        let result = stitch(content, positions: [0, 170, 340, 420, 500, 500], Viewport())
        XCTAssertEqual(result.rows, Array(content[0..<800]))
    }

    func testStickyHeaderAndFooterAreKeptOnce() {
        let content = page(1000)
        var view = Viewport()
        view.header = (0..<24).map { _ in [UInt8](repeating: 40, count: width) }
        view.header[10] = (0..<width).map { UInt8($0 * 2) }  // the header has detail of its own
        view.footer = (0..<16).map { i in (0..<width).map { UInt8((i * 13 + $0) % 200) } }
        let result = stitch(content, positions: [0, 120, 240, 360, 480, 600, 700], view)
        XCTAssertEqual(result.plan.header, 24)
        XCTAssertEqual(result.plan.footer, 16)
        // The header once at the top, the page under it, the footer once at the bottom.
        XCTAssertEqual(Array(result.rows.prefix(24)), view.header)
        XCTAssertEqual(Array(result.rows.suffix(16)), view.footer)
        XCTAssertEqual(Array(result.rows[24..<(result.rows.count - 16)]), Array(content[24..<(700 + 300 - 16)]))
    }

    func testABlinkingRegionDoesNotThrowItOff() {
        let content = page(900)
        var view = Viewport()
        view.blinking = 100..<130
        let positions = [0, 140, 280, 420, 560, 600]
        let frames = positions.enumerated().map { frame(content, at: $0.element, view, tick: $0.offset) }
        for i in 1..<frames.count {
            XCTAssertEqual(ScrollStitcher.match(frames[i - 1], frames[i])?.offset, positions[i] - positions[i - 1])
        }
    }

    func testNoMovementIsOffsetZero() {
        let content = page(400)
        let a = frame(content, at: 50, Viewport(), tick: 0)
        XCTAssertEqual(ScrollStitcher.match(a, a)?.offset, 0)
    }

    func testUnrelatedFramesDoNotMatch() {
        let a = frame(page(400, seed: 1), at: 0, Viewport(), tick: 0)
        let b = frame(page(400, seed: 99), at: 0, Viewport(), tick: 0)
        XCTAssertNil(ScrollStitcher.match(a, b))
    }

    func testRepeatingRowsUseTheExpectedStep() {
        // A list whose rows repeat every 40: offsets 40 apart (10, 50, 90, 130…) look the same, and
        // the scroll that was asked for picks the right one. (A move of exactly 120 would leave two
        // identical frames: honestly "didn't move".)
        let unit = page(40, seed: 3)
        let content = (0..<20).flatMap { _ in unit }
        let a = frame(content, at: 0, Viewport(), tick: 0)
        let b = frame(content, at: 130, Viewport(), tick: 0)
        XCTAssertEqual(ScrollStitcher.match(a, b, expected: 126)?.offset, 130)
        XCTAssertEqual(ScrollStitcher.match(a, b, expected: 52)?.offset, 50)
    }

    func testTheCapStopsAddingSteps() {
        var plan = StitchPlan(frameHeight: 2000)
        var added = 0
        while plan.add(frame: added + 1, offset: 1000) { added += 1 }
        XCTAssertLessThanOrEqual(plan.height, StitchPlan.maximumHeight)
        XCTAssertGreaterThan(plan.height + 1000, StitchPlan.maximumHeight)
    }

    func testFingerprintsFromPixels() {
        // 4 × 2 pixels, BGRA: a black row and a white row.
        var pixels: [UInt8] = []
        for _ in 0..<4 { pixels += [0, 0, 0, 255] }
        for _ in 0..<4 { pixels += [255, 255, 255, 255] }
        let rows = pixels.withUnsafeBytes { ScrollStitcher.fingerprints(pixels: $0, width: 4, height: 2, bytesPerRow: 16) }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0], [0, 0, 0, 0])
        XCTAssertEqual(rows[1], [255, 255, 255, 255])
    }

    // MARK: The scroll indicator

    /// A long page captured in steps a little under half the view, with macOS's scroll knob drawn
    /// over every frame where a scroller would put it (`track`: the rows it runs along). Each
    /// frame is a list of what its rows show: content row numbers, -2 for the sticky header, -3
    /// for the footer, -1 where the knob covers a row. The last frame is taken after the knob faded.
    private func knobbedCapture(track: Range<Int>, content: Int = 13_520) -> (frames: [[Int]], plan: StitchPlan, content: Int) {
        let height = 840, header = 96, footer = 64
        let total = header + content + footer, range = max(total - height, 1)
        let step = (height - header - footer) * 48 / 100
        var positions = [0]
        while positions.last! < range { positions.append(min(positions.last! + step, range)) }
        let knobLength = min(max(track.count * track.count / content, 40), track.count)
        func frame(at scrolled: Int, knob: Bool) -> [Int] {
            var rows = (0..<height).map { y -> Int in
                y < header ? -2 : y >= height - footer ? -3 : scrolled + y - header
            }
            if knob {
                let top = track.lowerBound + Int(Double(track.count - knobLength) * Double(scrolled) / Double(range))
                for y in top..<min(top + knobLength, height) { rows[y] = -1 }
            }
            return rows
        }
        var frames = positions.enumerated().map { frame(at: $1, knob: $0 > 0) }
        frames.append(frame(at: range, knob: false))
        var plan = StitchPlan(frameHeight: height)
        plan.setBands(top: header, bottom: footer)
        for index in 1..<positions.count { plan.add(frame: index, offset: positions[index] - positions[index - 1]) }
        return (frames, plan, content)
    }

    private func compose(_ frames: [[Int]], _ slices: [StitchPlan.Slice]) -> [Int] {
        slices.flatMap { Array(frames[$0.frame][$0.rows]) }
    }

    func testTheScrollKnobIsLeftOutOfThePicture() {
        // Long pages and short ones (a long knob), knobs on the whole view or under a toolbar.
        for content in [900, 1_500, 3_000, 13_520] {
        for track in [0..<840, 96..<776, 40..<800] {
            let capture = knobbedCapture(track: track, content: content)
            let picture = compose(capture.frames, capture.plan.sources(minimumThumb: 40, finalFrame: capture.frames.count - 1))
            XCTAssertEqual(picture.count, capture.plan.height)
            XCTAssertFalse(picture.contains(-1), "knob rows in the picture (\(content) rows, track \(track)): \(picture.indices.filter { picture[$0] == -1 }.count)")
            XCTAssertEqual(Array(picture.prefix(96)), Array(repeating: -2, count: 96), "the header once, at the top")
            XCTAssertEqual(Array(picture.suffix(64)), Array(repeating: -3, count: 64), "the footer once, at the bottom")
            XCTAssertEqual(Array(picture.dropFirst(96).dropLast(64)), Array(0..<capture.content), "every row once, in order")
        }
        }
    }

    func testReadingEachStepFromItsOwnFrameKeepsTheKnob() {
        // The plain slices, as before: the knob comes along in the lower half of the page.
        let capture = knobbedCapture(track: 0..<840)
        let picture = compose(capture.frames, capture.plan.slices)
        XCTAssertGreaterThan(picture.filter { $0 == -1 }.count, 500)
    }

    /// The indicator drawn over a dark sticky header (light, on the last samples) in the frame
    /// after a scroll: the header is still the whole header.
    func testTheIndicatorOverAHeaderDoesNotShortenIt() {
        let columns = ScrollStitcher.columns
        func content(_ row: Int) -> [UInt8] { (0..<columns).map { UInt8((row * 37 + $0 * 11) % 200 + 20) } }
        let header = 96, footer = 64, height = 840, offset = 300
        func frame(scrolled: Int, knobRows: Range<Int>) -> ScrollStitcher.Fingerprints {
            (0..<height).map { y in
                var row = y < header ? [UInt8](repeating: 60, count: columns)
                    : y >= height - footer ? [UInt8](repeating: 90, count: columns) : content(scrolled + y)
                if knobRows.contains(y) { row[columns - 1] = 230; row[columns - 2] = 230 }
                return row
            }
        }
        let before = frame(scrolled: 0, knobRows: 0..<0)
        let after = frame(scrolled: offset, knobRows: 11..<70)
        let bands = ScrollStitcher.fixedBands(before, after, offset: offset)
        XCTAssertEqual(bands.top, header)
        XCTAssertEqual(bands.bottom, footer)
        let atTheEnd = frame(scrolled: offset * 2, knobRows: 760..<829)
        XCTAssertEqual(ScrollStitcher.fixedBands(after, atTheEnd, offset: offset).bottom, footer, "and over a footer")
    }

    /// At the end of a page the last step is short (48 rows, under a 96-row header): a plain
    /// header row matches the header row 48 below it, so the band measured there looks 11 rows
    /// tall. It mustn't shorten the header, or the picture's last screen gets header rows in it.
    func testAShortLastStepDoesNotShortenTheHeader() {
        var plan = StitchPlan(frameHeight: 840)
        plan.setBands(top: 96, bottom: 64, offset: 404)
        plan.add(frame: 1, offset: 404)
        plan.setBands(top: 96, bottom: 64, offset: 326)
        plan.add(frame: 2, offset: 326)
        plan.setBands(top: 11, bottom: 64, offset: 48)
        plan.add(frame: 3, offset: 48)
        XCTAssertEqual(plan.header, 96)
        // A full step that finds less of a header still narrows it.
        plan.setBands(top: 40, bottom: 64, offset: 326)
        XCTAssertEqual(plan.header, 40)
    }
}
