//
//  StripLayout.swift
//  Tutto (scrolling strip)
//
//  Where the strip puts every window. Pure geometry in the Accessibility API's space
//  (top-left origin, y down), so it's easy to test and reason about.
//
//  - A column is a fraction of the usable width: 50% + 50% fill the screen exactly, gap
//    between them and at the edges included.
//  - Pinned columns sit at the screen edges; the rest of the strip scrolls in what's left.
//  - The viewport moves just far enough to show the focused column, or centres it (never,
//    only when the strip doesn't fit, or always). It never rests past the strip's ends,
//    except after an explicit Centre.
//  - A window that's out of view waits tucked into a bottom corner of its own display with
//    one point showing: macOS moves a window that has left its display entirely onto
//    whichever display it landed on, and can refuse to put it back.
//

import CoreGraphics
import Foundation

public enum StripCentring: String, Codable, CaseIterable, Sendable {
    case never, whenOverflowing, always
}

/// A display's strip area and spacing.
public struct StripMetrics: Equatable, Sendable {
    /// The display's usable area (below the menu bar, beside the Dock), top-left origin.
    public var area: CGRect
    /// Space between windows and at the screen edges.
    public var gap: Double
    /// Fill the height; false keeps the height each window opened with, aligned to the top.
    public var fullHeight: Bool
    /// Room above a tabbed column for its tab bar.
    public var tabBarHeight: Double

    public init(area: CGRect, gap: Double = 8, fullHeight: Bool = true, tabBarHeight: Double = 28) {
        self.area = area
        self.gap = max(gap, 0)
        self.fullHeight = fullHeight
        self.tabBarHeight = tabBarHeight
    }

    /// The area inside the outer gaps.
    public var inner: CGRect { area.insetBy(dx: gap, dy: gap) }

    /// Points wide for a column `fraction` of the usable width.
    public func width(for fraction: Double) -> Double {
        max((fraction * (inner.width + gap) - gap).rounded(), 40)
    }

    /// The fraction a column `points` wide is.
    public func fraction(for points: Double) -> Double {
        let total = inner.width + gap
        guard total > 0 else { return 0.5 }
        return min(max((points + gap) / total, 0.1), 1)
    }
}

public struct StripPlacement: Equatable, Sendable {
    public var window: StripWindow
    public var column: Int
    public var row: Int
    public var frame: CGRect
    /// A tab that isn't showing; it waits out of view.
    public var isBackgroundTab: Bool
}

public struct StripTabBar: Equatable, Sendable {
    public var column: Int
    public var frame: CGRect
    public var windows: [StripWindow]
    public var active: Int
}

/// The strip laid out on one display.
public struct StripGeometry: Sendable {
    public let strip: Strip
    public let metrics: StripMetrics
    /// Points wide, per column.
    public let widths: [Double]
    /// Where each scrolling column starts along the strip (0 for pinned ones).
    public let positions: [Double]
    /// The part of the screen the strip scrolls in (between pinned columns), screen x.
    public let viewportMinX: Double
    public let viewportMaxX: Double
    /// Length of the scrolling part of the strip.
    public let length: Double
    private let naturalHeights: [StripWindow: Double]

    /// `enforcedWidths`: widths apps insist on after refusing the one they were asked for.
    /// `naturalHeights`: the heights windows opened with, used when `fullHeight` is off.
    public init(strip: Strip, metrics: StripMetrics, enforcedWidths: [StripWindow: Double] = [:],
                naturalHeights: [StripWindow: Double] = [:]) {
        self.strip = strip
        self.metrics = metrics
        self.naturalHeights = naturalHeights
        let inner = metrics.inner
        let widths = strip.columns.map { column -> Double in
            let insisted = column.windows.compactMap { enforcedWidths[$0] }
            let wanted = metrics.width(for: column.width)
            return insisted.isEmpty ? wanted : insisted.max()!.rounded()
        }
        self.widths = widths
        let range = strip.scrollingRange
        var left = inner.minX
        var right = inner.maxX
        if strip.columns.first?.pin == .left, !widths.isEmpty { left += widths[0] + metrics.gap }
        if strip.columns.count > range.upperBound, strip.columns.last?.pin == .right { right -= widths[widths.count - 1] + metrics.gap }
        viewportMinX = left
        viewportMaxX = max(right, left)
        var positions = Array(repeating: 0.0, count: strip.columns.count)
        var running = 0.0
        for index in range {
            positions[index] = running
            running += widths[index] + metrics.gap
        }
        self.positions = positions
        length = range.isEmpty ? 0 : running - metrics.gap
    }

    public var viewportWidth: Double { viewportMaxX - viewportMinX }
    public var maxOffset: Double { max(0, length - viewportWidth) }
    public var overflows: Bool { length > viewportWidth + 0.5 }

    public func clamped(_ offset: Double) -> Double { min(max(offset, 0), maxOffset) }

    /// Screen x of a column's left edge at `offset`.
    public func screenX(of column: Int, offset: Double) -> Double {
        switch strip.columns[column].pin {
        case .left: metrics.inner.minX
        case .right: metrics.inner.maxX - widths[column]
        case nil: (viewportMinX + positions[column] - offset).rounded()
        }
    }

    /// The offset that puts a column in the middle of the viewport (not clamped).
    public func centredOffset(for column: Int) -> Double {
        positions[column] + widths[column] / 2 - viewportWidth / 2
    }

    /// The offset that shows `column`, starting from `current`.
    public func offset(revealing column: Int, from current: Double, centring: StripCentring) -> Double {
        guard strip.columns.indices.contains(column), strip.columns[column].pin == nil else { return current }
        switch centring {
        case .always:
            return centredOffset(for: column)
        case .whenOverflowing:
            return overflows ? clamped(centredOffset(for: column)) : 0
        case .never:
            let start = positions[column]
            let end = start + widths[column]
            if widths[column] >= viewportWidth { return clamped(start) }
            if start < current { return start }
            if end > current + viewportWidth { return end - viewportWidth }
            return current
        }
    }

    /// Every window's frame at `offset`. Frames may lie off screen; see `isInView`.
    public func placements(offset: Double) -> [StripPlacement] {
        let inner = metrics.inner
        var result: [StripPlacement] = []
        for (c, column) in strip.columns.enumerated() {
            let x = screenX(of: c, offset: offset)
            let width = widths[c]
            if column.tabbed {
                let top = inner.minY + metrics.tabBarHeight
                let frame = CGRect(x: x, y: top, width: width, height: max(inner.height - metrics.tabBarHeight, 60))
                for (r, window) in column.windows.enumerated() {
                    result.append(StripPlacement(window: window, column: c, row: r, frame: frame, isBackgroundTab: r != column.activeTab))
                }
            } else if column.windows.count > 1 {
                let available = inner.height - metrics.gap * Double(column.windows.count - 1)
                var used = 0.0
                for (r, fraction) in column.normalizedHeights.enumerated() {
                    let top = (inner.minY + used + metrics.gap * Double(r)).rounded()
                    used += available * fraction
                    let bottom = r == column.windows.count - 1 ? inner.maxY : (inner.minY + used + metrics.gap * Double(r)).rounded()
                    result.append(StripPlacement(window: column.windows[r], column: c, row: r,
                                                 frame: CGRect(x: x, y: top, width: width, height: bottom - top),
                                                 isBackgroundTab: false))
                }
            } else if let window = column.windows.first {
                let height = metrics.fullHeight ? inner.height : min(naturalHeights[window] ?? inner.height, inner.height)
                result.append(StripPlacement(window: window, column: c, row: 0,
                                             frame: CGRect(x: x, y: inner.minY, width: width, height: height),
                                             isBackgroundTab: false))
            }
        }
        return result
    }

    /// Tab bars of tabbed columns at `offset`.
    public func tabBars(offset: Double) -> [StripTabBar] {
        strip.columns.enumerated().compactMap { c, column in
            guard column.tabbed else { return nil }
            let frame = CGRect(x: screenX(of: c, offset: offset), y: metrics.inner.minY,
                               width: widths[c], height: metrics.tabBarHeight - min(metrics.gap, 6))
            return StripTabBar(column: c, frame: frame, windows: column.windows, active: column.activeTab)
        }
    }

    /// Whether a window of `column` at `frame` can be seen: it overlaps the part of the screen
    /// the strip scrolls in. Pinned columns always can.
    public func isInView(_ frame: CGRect, column: Int) -> Bool {
        if strip.columns.indices.contains(column), strip.columns[column].pin != nil { return true }
        return frame.maxX > viewportMinX + 1 && frame.minX < viewportMaxX - 1
    }

    /// How much of a column shows at `offset`, 0…1.
    public func visibleFraction(of column: Int, offset: Double) -> Double {
        guard strip.columns.indices.contains(column) else { return 0 }
        if strip.columns[column].pin != nil { return 1 }
        let left = screenX(of: column, offset: offset)
        let right = left + widths[column]
        let shown = min(right, viewportMaxX) - max(left, viewportMinX)
        return widths[column] > 0 ? min(max(shown / widths[column], 0), 1) : 0
    }

    /// The column showing the most at `offset` (the leftmost of equals).
    public func mostVisibleColumn(offset: Double) -> Int? {
        var best: (index: Int, fraction: Double)?
        for index in strip.scrollingRange {
            let fraction = visibleFraction(of: index, offset: offset)
            if best == nil || fraction > best!.fraction + 0.001 { best = (index, fraction) }
        }
        return best?.index ?? (strip.columns.isEmpty ? nil : 0)
    }

    /// The scrolling column under screen x (dropping a dragged window), at `offset`.
    public func column(atScreenX x: Double, offset: Double) -> Int? {
        let range = strip.scrollingRange
        guard !range.isEmpty else { return nil }
        for index in range where x < screenX(of: index, offset: offset) + widths[index] + metrics.gap / 2 {
            return index
        }
        return range.upperBound - 1
    }

    /// Where a swipe comes to rest. `velocity` is points per second along the strip.
    /// Snap lines a column's left edge up with the viewport (or the strip's end with its
    /// right edge); free stays where the motion runs out.
    public func settle(offset: Double, velocity: Double, snap: Bool) -> Double {
        let projected = offset + velocity * 0.16
        guard snap else { return clamped(projected) }
        var stops = strip.scrollingRange.map { clamped(positions[$0]) }
        stops.append(maxOffset)
        return stops.min { abs($0 - projected) < abs($1 - projected) } ?? 0
    }
}

/// Where out-of-view windows wait.
public enum StripParking {
    /// One point of the window stays on its display, at its left edge for windows off the left of
    /// the strip and its right edge for the rest (unless that side touches another display), level
    /// with the screen. Parked in a bottom corner instead, off the screen both ways, Mission
    /// Control shrank every window on the desktop to a thumbnail in a corner (measured: off to
    /// the side alone, or below alone, it lays them out as usual).
    /// `display` is the display's usable area; `others` are the other displays' frames.
    public static func frame(size: CGSize, side: StripSide, display: CGRect, others: [CGRect]) -> CGRect {
        func corner(_ side: StripSide) -> CGRect {
            let x = side == .right ? display.maxX - 1 : display.minX - size.width + 1
            return CGRect(x: x.rounded(), y: display.minY.rounded(), width: size.width, height: size.height)
        }
        let preferred = corner(side)
        let other = corner(side == .left ? .right : .left)
        func overlap(_ rect: CGRect) -> CGFloat {
            others.reduce(0) { total, screen in
                let shared = screen.intersection(rect)
                return total + (shared.isNull ? 0 : shared.width * shared.height)
            }
        }
        return overlap(other) < overlap(preferred) ? other : preferred
    }

    /// Whether `frame` is parked on `display`: one point showing at its left or right edge (as
    /// `frame(size:side:display:others:)` puts it, or in a bottom corner as earlier versions did).
    public static func isParked(_ frame: CGRect, display: CGRect, tolerance: CGFloat = 3) -> Bool {
        let right = abs(frame.minX - (display.maxX - 1)) <= tolerance
        let left = abs(frame.maxX - (display.minX + 1)) <= tolerance
        return right || left
    }
}
