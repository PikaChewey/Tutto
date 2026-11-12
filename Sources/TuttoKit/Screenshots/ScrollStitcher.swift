//
//  ScrollStitcher.swift
//  Tutto
//
//  Joins the frames of a scrolling capture into one tall picture. Each frame is reduced to one
//  small fingerprint per row (the brightness at `columns` points across it), and the distance
//  the content moved between two frames is found by letting rows vote: every row of the new
//  frame that looks like a row of the old one says "moved by this much". The winner is checked
//  row by row with the median difference, so a blinking cursor, a playing video or an animated
//  banner can't throw it off. Rows that stay put at the top and bottom while the rest moves are
//  a sticky header and footer: they're left out of matching and kept only once in the result.
//
//  Pure arithmetic on fingerprints, so it can be tested without a screen.
//

import Foundation

public enum ScrollStitcher {
    /// Points sampled across each row.
    public static let columns = 96
    /// A row is the same as another when its samples differ by at most this on average (0–255).
    public static let sameRow = 2.0
    /// A match is accepted when the median row difference over the overlap is at most this.
    public static let acceptableMedian = 1.5
    /// Rows that look like this many others (blank lines, borders) don't vote.
    static let boringRowLimit = 12

    /// One frame: a fingerprint per row, top to bottom, `columns` brightness values each.
    public typealias Fingerprints = [[UInt8]]

    /// Fingerprints from 32-bit pixels (BGRA or RGBA, either way: brightness weights are close
    /// enough for matching) laid out `bytesPerRow` apart.
    public static func fingerprints(pixels: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int) -> Fingerprints {
        guard width > 0, height > 0, pixels.count >= bytesPerRow * height else { return [] }
        let samples = min(columns, width)
        var result: Fingerprints = []
        result.reserveCapacity(height)
        let bytes = pixels.bindMemory(to: UInt8.self)
        for y in 0..<height {
            let row = y * bytesPerRow
            var fingerprint = [UInt8](repeating: 0, count: samples)
            for k in 0..<samples {
                // The middle of the k-th slice, averaged with its neighbours.
                let x = (2 * k + 1) * width / (2 * samples)
                var sum = 0
                var count = 0
                for dx in -1...1 {
                    let px = min(max(x + dx, 0), width - 1)
                    let i = row + px * 4
                    sum += (Int(bytes[i]) * 29 + Int(bytes[i + 1]) * 150 + Int(bytes[i + 2]) * 77) >> 8
                    count += 1
                }
                fingerprint[k] = UInt8(sum / count)
            }
            result.append(fingerprint)
        }
        return result
    }

    static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        let n = min(a.count, b.count)
        guard n > 0 else { return 0 }
        var total = 0
        for k in 0..<n { total += abs(Int(a[k]) - Int(b[k])) }
        return Double(total) / Double(n)
    }

    /// A row's key for voting: its samples at 1/32 the precision, so tiny rendering differences
    /// still land on the same key.
    static func key(_ row: [UInt8]) -> Int {
        var hasher = Hasher()
        for value in row { hasher.combine(value >> 3) }
        return hasher.finalize()
    }

    /// How a frame relates to the one before it.
    public struct Match: Equatable, Sendable {
        /// Rows the content moved up (0: it didn't move).
        public let offset: Int
        /// Median row difference over the overlap (lower is surer).
        public let median: Double
    }

    /// How far the content moved up from `previous` to `next` (both the same height). `expected`,
    /// when known (the scroll that was asked for), breaks ties between equally good offsets, as
    /// on a page of repeating rows. Nil when nothing lines up (the view changed entirely).
    public static func match(_ previous: Fingerprints, _ next: Fingerprints, expected: Int? = nil) -> Match? {
        let height = min(previous.count, next.count)
        guard height >= 8 else { return nil }

        // Didn't move at all?
        let still = median((0..<height).map { difference(previous[$0], next[$0]) })
        if still <= acceptableMedian / 2 { return Match(offset: 0, median: still) }

        // Votes: every interesting row of `next` that looks like rows of `previous`.
        var rowsByKey: [Int: [Int]] = [:]
        for y in 0..<height { rowsByKey[key(previous[y]), default: []].append(y) }
        var votes: [Int: Int] = [:]
        for y in 0..<height {
            guard let matches = rowsByKey[key(next[y])], matches.count <= boringRowLimit else { continue }
            for source in matches where source > y { votes[source - y, default: 0] += 1 }
        }
        let minimumVotes = max(4, height / 50)
        var candidates = votes.filter { $0.value >= minimumVotes }.sorted { $0.value > $1.value }.prefix(6).map(\.key)
        if let expected, expected > 0, expected < height { candidates.append(expected) }
        guard !candidates.isEmpty else { return nil }

        // Check each candidate (and its neighbours, for a key that rounded the wrong way) row by row.
        var best: Match?
        var tried = Set<Int>()
        for candidate in candidates {
            for offset in (candidate - 1)...(candidate + 1) where offset > 0 && offset < height - 4 && tried.insert(offset).inserted {
                let overlap = (0..<(height - offset)).map { difference(previous[$0 + offset], next[$0]) }
                let score = median(overlap)
                guard score <= acceptableMedian else { continue }
                let agreeing = overlap.filter { $0 <= sameRow }.count
                guard agreeing * 10 >= overlap.count * 3 else { continue }  // at least 30 % line up
                let match = Match(offset: offset, median: score)
                if let current = best {
                    if score < current.median - 0.05 {
                        best = match
                    } else if abs(score - current.median) <= 0.05, let expected,
                              abs(offset - expected) < abs(current.offset - expected) {
                        best = match
                    }
                } else {
                    best = match
                }
            }
        }
        return best
    }

    /// Rows at the top and bottom that stayed put while the content moved by `offset`: a sticky
    /// header and footer. Each band is at most a third of the frame.
    public static func fixedBands(_ previous: Fingerprints, _ next: Fingerprints, offset: Int) -> (top: Int, bottom: Int) {
        let height = min(previous.count, next.count)
        guard offset > 0, height > 0 else { return (0, 0) }
        let limit = height / 3
        var top = 0
        while top < limit, bandDifference(previous[top], next[top]) <= sameRow,
              // A row the scroll explains equally well (a blank line) doesn't make a header longer.
              top + offset >= height || bandDifference(previous[top + offset], next[top]) > sameRow {
            top += 1
        }
        var bottom = 0
        while bottom < limit, bandDifference(previous[height - 1 - bottom], next[height - 1 - bottom]) <= sameRow {
            bottom += 1
        }
        return (top, bottom)
    }

    /// The row difference without the right edge, where the scroll indicator shows while
    /// scrolling: drawn over a header or footer, it would cut the band short.
    static func bandDifference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        let n = min(a.count, b.count)
        let kept = n - max(n / 32, 1)
        guard kept > 0 else { return difference(a, b) }
        return difference(Array(a.prefix(kept)), Array(b.prefix(kept)))
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return .infinity }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}

/// Which rows of which frames make up the tall picture: the first frame down to the footer,
/// then each later frame's newly revealed rows just above the footer, then the last footer.
public struct StitchPlan: Equatable, Sendable {
    public struct Slice: Equatable, Sendable {
        public let frame: Int
        public let rows: Range<Int>
    }

    public let frameHeight: Int
    public private(set) var footer = 0
    public private(set) var header = 0
    /// Each frame after the first: how many new rows it brought.
    public private(set) var steps: [(frame: Int, offset: Int)] = []
    public static let maximumHeight = 16_384

    public init(frameHeight: Int) {
        self.frameHeight = frameHeight
    }

    public static func == (a: StitchPlan, b: StitchPlan) -> Bool {
        a.frameHeight == b.frameHeight && a.footer == b.footer && a.header == b.header
            && a.steps.map(\.frame) == b.steps.map(\.frame) && a.steps.map(\.offset) == b.steps.map(\.offset)
    }

    /// The bands found between the first two frames that moved (later frames can only narrow
    /// them: a footer that seemed fixed once but moved later wasn't one). `offset`: how far the
    /// content moved between the two frames measured. A step shorter than the header (the last
    /// one, at the end of a page) can't tell a plain header row from one the scroll moved into
    /// place, so it doesn't shorten the header.
    public mutating func setBands(top: Int, bottom: Int, offset: Int? = nil) {
        if steps.isEmpty {
            header = top
            footer = bottom
        } else {
            if offset.map({ $0 >= header }) ?? true { header = min(header, top) }
            footer = min(footer, bottom)
        }
    }

    /// Frame `frame` showed the content `offset` rows further on. False once the picture is as
    /// tall as it may get (the step isn't added).
    @discardableResult
    public mutating func add(frame: Int, offset: Int) -> Bool {
        guard offset > 0 else { return true }
        let step = min(offset, max(frameHeight - footer - header, 1))
        guard height + step <= Self.maximumHeight else { return false }
        steps.append((frame, step))
        return true
    }

    /// The finished picture's height.
    public var height: Int { frameHeight + steps.reduce(0) { $0 + $1.offset } }

    /// The rows to copy, in order, reading each step's new rows from whichever of two frames
    /// keeps them clear of the scroll indicator (which macOS shows while anything scrolls): the
    /// frame that brought them, low in its view, or the next frame, where they've moved up. The
    /// indicator travels down the side as the content scrolls, so it's never in both places; this
    /// predicts where it is from how far along the content each frame was, the way a scroller
    /// places its knob. Needs steps of at most half the view, so every row is seen twice.
    /// `minimumThumb`: the knob's least length in rows. `finalFrame`: the last view captured again
    /// once the indicator had faded; every row it shows (the whole last screen and the footer)
    /// comes from it.
    public func sources(minimumThumb: Int = 40, finalFrame: Int? = nil) -> [Slice] {
        let end = frameHeight - footer
        var result = [Slice(frame: 0, rows: 0..<end)]
        let scrolledInAll = height - frameHeight
        let range = max(scrolledInAll, 1)
        let thumb = min(max(frameHeight * frameHeight / max(height, 1), minimumThumb), frameHeight)
        // The knob's rows in a view scrolled this far, on a track the height of the view.
        func knob(scrolled: Int) -> Range<Int> {
            let top = Int((Double(frameHeight - thumb) * Double(min(max(scrolled, 0), range)) / Double(range)).rounded())
            return top..<(top + thumb)
        }
        func distance(_ row: Int, _ knob: Range<Int>) -> Int {
            row < knob.lowerBound ? knob.lowerBound - row : row >= knob.upperBound ? row - knob.upperBound + 1 : 0
        }
        // Rows closer than this to where the knob should be are read from the next frame if it's
        // further away there (a margin for knobs on a shorter track, under a toolbar).
        let margin = frameHeight / 8
        enum From { case this, next, last }
        var scrolled = 0
        for (index, step) in steps.enumerated() {
            scrolled += step.offset
            let next = index + 1 < steps.count ? steps[index + 1] : nil
            let here = knob(scrolled: scrolled)
            let there = next.map { knob(scrolled: scrolled + $0.offset) }
            let lastShift = scrolledInAll - scrolled  // this frame's rows sit this much higher in the last view
            func slice(_ from: From, _ rows: Range<Int>) -> Slice {
                switch from {
                case .this: Slice(frame: step.frame, rows: rows)
                case .next: Slice(frame: next!.frame, rows: (rows.lowerBound - next!.offset)..<(rows.upperBound - next!.offset))
                case .last: Slice(frame: finalFrame!, rows: (rows.lowerBound - lastShift)..<(rows.upperBound - lastShift))
                }
            }
            let start = end - step.offset
            var runStart = start
            var runFrom = From.this
            for row in start..<end {
                let from: From
                if finalFrame != nil, row - lastShift >= header {
                    from = .last
                } else if let next, let there, row - next.offset >= header, distance(row, here) < margin,
                          distance(row - next.offset, there) > distance(row, here) {
                    from = .next
                } else {
                    from = .this
                }
                if row == start {
                    runFrom = from
                } else if from != runFrom {
                    result.append(slice(runFrom, runStart..<row))
                    runStart = row
                    runFrom = from
                }
            }
            if end > runStart { result.append(slice(runFrom, runStart..<end)) }
        }
        if footer > 0 {
            result.append(Slice(frame: finalFrame ?? steps.last?.frame ?? 0, rows: end..<frameHeight))
        }
        return result
    }

    /// The rows to copy, in order, ending with the last frame's footer.
    public var slices: [Slice] {
        var result = [Slice(frame: 0, rows: 0..<(frameHeight - footer))]
        for step in steps {
            let end = frameHeight - footer
            result.append(Slice(frame: step.frame, rows: (end - step.offset)..<end))
        }
        if footer > 0 {
            result.append(Slice(frame: steps.last?.frame ?? 0, rows: (frameHeight - footer)..<frameHeight))
        }
        return result
    }
}
