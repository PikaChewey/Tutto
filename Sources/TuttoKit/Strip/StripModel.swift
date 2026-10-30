//
//  StripModel.swift
//  Tutto (scrolling strip)
//
//  The scrolling strip as data: every window on a display sits in a column, columns sit
//  side by side on one horizontal strip that runs past the screen's edges, and the screen
//  is a viewport you scroll along it. Nothing here touches the system; the engine turns
//  the model into window frames.
//
//  The commands behave the way the strip is known to, step for step:
//    cycle width 25 → 33 → 50 → 66 → 75 → 25 %, full width toggles back to the width before,
//    focus and move loop round at the ends (a held key stops there instead, so it can't
//    overshoot), stack joins the neighbouring column, pop out gives the
//    window its own column again, tabbed toggles one-at-full-height ↔ stacked, and a pinned
//    column stays at its screen edge (first or last on the strip) while the rest scrolls.
//

import Foundation

public typealias StripWindow = UInt32

public enum StripSide: String, Codable, Sendable { case left, right }

public struct StripColumn: Equatable, Codable, Sendable {
    /// Top to bottom when stacked; tab order when tabbed.
    public var windows: [StripWindow]
    /// Fraction of the usable width (0.1…1).
    public var width: Double
    /// The width before Full Width, to toggle back to.
    public var widthBeforeFull: Double?
    public var tabbed: Bool
    /// Which window shows in a tabbed column.
    public var activeTab: Int
    /// Height fractions of stacked windows; empty means equal.
    public var heights: [Double]
    public var pin: StripSide?

    public init(windows: [StripWindow], width: Double, tabbed: Bool = false, activeTab: Int = 0,
                heights: [Double] = [], pin: StripSide? = nil) {
        self.windows = windows
        self.width = width
        self.tabbed = tabbed
        self.activeTab = activeTab
        self.heights = heights
        self.pin = pin
    }

    /// Height fractions, one per window, summing to 1.
    public var normalizedHeights: [Double] {
        guard windows.count > 1 else { return windows.isEmpty ? [] : [1] }
        if heights.count == windows.count {
            let total = heights.reduce(0, +)
            if total > 0 { return heights.map { $0 / total } }
        }
        return Array(repeating: 1 / Double(windows.count), count: windows.count)
    }
}

/// What a command did, phrased for the strip indicator.
public enum StripOutcome: Equatable, Sendable {
    case done(String)
    /// Nothing changed (at an end, nothing to stack…); the message says why.
    case refused(String)

    public var changed: Bool { if case .done = self { true } else { false } }
    public var message: String {
        switch self { case .done(let text), .refused(let text): text }
    }
}

/// Where a window sat on the strip, kept while it's away (minimized, hidden, full screen)
/// so it comes back to the same place.
public struct StripSlot: Equatable, Codable, Sendable {
    public var index: Int
    public var row: Int
    public var width: Double
    public var leftNeighbour: StripWindow?
    public var rightNeighbour: StripWindow?
    public var stackedWith: [StripWindow]
}

public struct Strip: Equatable, Codable, Sendable {
    public var columns: [StripColumn] = []
    public var focusColumn = 0
    public var focusRow = 0
    /// How far the viewport has scrolled along the strip, in points.
    public var offset: Double = 0

    public init(columns: [StripColumn] = [], focusColumn: Int = 0, focusRow: Int = 0, offset: Double = 0) {
        self.columns = columns
        self.focusColumn = focusColumn
        self.focusRow = focusRow
        self.offset = offset
    }

    public var isEmpty: Bool { columns.isEmpty }
    public var allWindows: [StripWindow] { columns.flatMap(\.windows) }

    public var focusedWindow: StripWindow? {
        guard columns.indices.contains(focusColumn) else { return nil }
        let column = columns[focusColumn]
        let row = column.tabbed ? column.activeTab : focusRow
        return column.windows.indices.contains(row) ? column.windows[row] : column.windows.first
    }

    public func location(of window: StripWindow) -> (column: Int, row: Int)? {
        for (c, column) in columns.enumerated() {
            if let r = column.windows.firstIndex(of: window) { return (c, r) }
        }
        return nil
    }

    public func contains(_ window: StripWindow) -> Bool { location(of: window) != nil }

    /// Columns that scroll: everything but the pinned ones at the ends.
    public var scrollingRange: Range<Int> {
        let lower = columns.first?.pin == .left ? 1 : 0
        let upper = columns.count > lower && columns.last?.pin == .right ? columns.count - 1 : columns.count
        return lower..<max(lower, upper)
    }

    // MARK: Focus

    public mutating func focus(_ window: StripWindow) {
        guard let (c, r) = location(of: window) else { return }
        focusColumn = c
        focusRow = r
        if columns[c].tabbed { columns[c].activeTab = r }
    }

    /// One column left; on the first it loops round to the last, unless `wrap` is off (a held key, a
    /// fast wheel spin): then it stops there, and a fresh press loops.
    public mutating func focusLeft(wrap: Bool = true) -> StripOutcome {
        guard !columns.isEmpty else { return .refused("The strip is empty.") }
        if focusColumn > 0 {
            setFocus(column: focusColumn - 1)
            return .done("Focus left")
        }
        guard columns.count > 1 else { return .refused("That's the only window on the strip.") }
        guard wrap else { return .refused("That's the first window on the strip. Press again to loop.") }
        setFocus(column: columns.count - 1)
        return .done("Focus left · looped to the last window")
    }

    /// One column right; on the last it loops round to the first (see `focusLeft`).
    public mutating func focusRight(wrap: Bool = true) -> StripOutcome {
        guard !columns.isEmpty else { return .refused("The strip is empty.") }
        if focusColumn < columns.count - 1 {
            setFocus(column: focusColumn + 1)
            return .done("Focus right")
        }
        guard columns.count > 1 else { return .refused("That's the only window on the strip.") }
        guard wrap else { return .refused("That's the last window on the strip. Press again to loop.") }
        setFocus(column: 0)
        return .done("Focus right · looped to the first window")
    }

    public mutating func focusFirst() -> StripOutcome {
        guard !columns.isEmpty, focusColumn != 0 else { return .refused("That's the first window on the strip.") }
        setFocus(column: 0)
        return .done("First window")
    }

    public mutating func focusLast() -> StripOutcome {
        guard !columns.isEmpty, focusColumn != columns.count - 1 else { return .refused("That's the last window on the strip.") }
        setFocus(column: columns.count - 1)
        return .done("Last window")
    }

    /// 1-based, like tabs in a browser; 9 always means the last.
    public mutating func focusNumber(_ number: Int) -> StripOutcome {
        guard !columns.isEmpty else { return .refused("The strip is empty.") }
        let index = number >= 9 ? columns.count - 1 : number - 1
        guard columns.indices.contains(index) else { return .refused("There's no window \(number) on the strip.") }
        guard index != focusColumn else { return .refused("Already on window \(index + 1).") }
        setFocus(column: index)
        return .done("Window \(index + 1)")
    }

    /// Up and down a stack (or its tabs), looping round at the top and bottom like ← and →.
    public mutating func focusUp(wrap: Bool = true) -> StripOutcome { focusVertically(-1, wrap: wrap) }
    public mutating func focusDown(wrap: Bool = true) -> StripOutcome { focusVertically(1, wrap: wrap) }

    private mutating func focusVertically(_ step: Int, wrap: Bool) -> StripOutcome {
        guard columns.indices.contains(focusColumn) else { return .refused("The strip is empty.") }
        var column = columns[focusColumn]
        guard column.windows.count > 1 else { return .refused("This column has one window.") }
        let current = column.tabbed ? column.activeTab : focusRow
        var next = current + step
        let looped = !column.windows.indices.contains(next)
        if looped {
            guard wrap else {
                if column.tabbed { return .refused(step < 0 ? "That's the first tab. Press again to loop." : "That's the last tab. Press again to loop.") }
                return .refused(step < 0 ? "That's the top of the column. Press again to loop." : "That's the bottom of the column. Press again to loop.")
            }
            next = step < 0 ? column.windows.count - 1 : 0
        }
        if column.tabbed { column.activeTab = next }
        focusRow = next
        columns[focusColumn] = column
        switch (column.tabbed, looped) {
        case (true, true): return .done(step < 0 ? "Previous tab · looped to the last" : "Next tab · looped to the first")
        case (true, false): return .done(step < 0 ? "Previous tab" : "Next tab")
        case (false, true): return .done(step < 0 ? "Focus up · looped to the bottom" : "Focus down · looped to the top")
        case (false, false): return .done(step < 0 ? "Focus up" : "Focus down")
        }
    }

    private mutating func setFocus(column index: Int) {
        focusColumn = index
        let column = columns[index]
        focusRow = column.tabbed ? column.activeTab : min(focusRow, max(column.windows.count - 1, 0))
    }

    // MARK: Moving

    /// Swaps the focused column with its neighbour; at the start of the strip it loops round to
    /// the end (the rest keep their order), unless `wrap` is off (a held key): then it stops there.
    public mutating func moveLeft(wrap: Bool = true) -> StripOutcome { moveAlong(-1, wrap: wrap) }

    /// The mirror of `moveLeft`: at the end of the strip it loops round to the start.
    public mutating func moveRight(wrap: Bool = true) -> StripOutcome { moveAlong(1, wrap: wrap) }

    private mutating func moveAlong(_ step: Int, wrap: Bool) -> StripOutcome {
        guard columns.indices.contains(focusColumn) else { return .refused("The strip is empty.") }
        guard columns[focusColumn].pin == nil else { return .refused("A pinned column stays at its edge.") }
        let range = scrollingRange
        let next = focusColumn + step
        if range.contains(next) {
            columns.swapAt(focusColumn, next)
            focusColumn = next
            return .done(step < 0 ? "Move left · swapped places" : "Move right · swapped places")
        }
        guard range.count > 1 else {
            return .refused(columns.count > 1 ? "The other windows are pinned." : "That's the only window on the strip.")
        }
        guard wrap else {
            return .refused(step < 0 ? "Already at the start of the strip. Press again to loop." : "Already at the end of the strip. Press again to loop.")
        }
        let end = step < 0 ? range.upperBound - 1 : range.lowerBound
        columns.insert(columns.remove(at: focusColumn), at: end)
        focusColumn = end
        return .done(step < 0 ? "Move left · looped to the end" : "Move right · looped to the start")
    }

    public mutating func moveToFirst() -> StripOutcome {
        moveFocusedColumn(to: scrollingRange.lowerBound, swap: false, done: "Moved to the start",
                          refused: "Already at the start of the strip.")
    }

    public mutating func moveToLast() -> StripOutcome {
        moveFocusedColumn(to: scrollingRange.upperBound - 1, swap: false, done: "Moved to the end",
                          refused: "Already at the end of the strip.")
    }

    /// Moves the focused column to position `number` (1-based; 9 = last).
    public mutating func moveToNumber(_ number: Int) -> StripOutcome {
        guard !columns.isEmpty else { return .refused("The strip is empty.") }
        let target = number >= 9 ? columns.count - 1 : min(number - 1, columns.count - 1)
        return moveFocusedColumn(to: target, swap: false, done: "Moved to \(target + 1)",
                                 refused: "Already window \(target + 1).")
    }

    private mutating func moveFocusedColumn(to target: Int, swap: Bool, done: String, refused: String) -> StripOutcome {
        guard columns.indices.contains(focusColumn) else { return .refused("The strip is empty.") }
        guard columns[focusColumn].pin == nil else { return .refused("A pinned column stays at its edge.") }
        guard scrollingRange.contains(target), target != focusColumn else { return .refused(refused) }
        if swap {
            columns.swapAt(focusColumn, target)
        } else {
            columns.insert(columns.remove(at: focusColumn), at: target)
        }
        focusColumn = target
        return .done(done)
    }

    /// Moves a column to `index` (dragging a window or a tile to reorder). Pinned columns stay.
    public mutating func moveColumn(from source: Int, to index: Int) {
        guard columns.indices.contains(source), columns[source].pin == nil else { return }
        let range = scrollingRange
        guard !range.isEmpty else { return }
        let target = min(max(index, range.lowerBound), range.upperBound - 1)
        guard target != source else { return }
        let focused = focusedWindow
        columns.insert(columns.remove(at: source), at: target)
        if let focused { focus(focused) }
    }

    /// Moves the focused window up or down inside its stack; past the top or bottom it loops round
    /// to the other end, taking its height with it.
    public mutating func moveUp(wrap: Bool = true) -> StripOutcome { moveInStack(-1, wrap: wrap) }
    public mutating func moveDown(wrap: Bool = true) -> StripOutcome { moveInStack(1, wrap: wrap) }

    private mutating func moveInStack(_ step: Int, wrap: Bool) -> StripOutcome {
        guard columns.indices.contains(focusColumn) else { return .refused("The strip is empty.") }
        var column = columns[focusColumn]
        guard column.windows.count > 1 else { return .refused("Stack windows first, then move them up and down.") }
        let row = column.tabbed ? column.activeTab : focusRow
        var target = row + step
        let looped = !column.windows.indices.contains(target)
        let keepsHeights = column.heights.count == column.windows.count
        if looped {
            guard wrap else {
                return .refused(step < 0 ? "Already at the top of the column. Press again to loop." : "Already at the bottom of the column. Press again to loop.")
            }
            target = step < 0 ? column.windows.count - 1 : 0
            column.windows.insert(column.windows.remove(at: row), at: target)
            if keepsHeights { column.heights.insert(column.heights.remove(at: row), at: target) }
        } else {
            column.windows.swapAt(row, target)
            if keepsHeights { column.heights.swapAt(row, target) }
        }
        if column.tabbed { column.activeTab = target }
        focusRow = target
        columns[focusColumn] = column
        if looped { return .done(step < 0 ? "Moved up · looped to the bottom" : "Moved down · looped to the top") }
        return .done(step < 0 ? "Moved up" : "Moved down")
    }

    // MARK: Widths

    public static let defaultPresets: [Double] = [0.25, 1.0 / 3.0, 0.5, 2.0 / 3.0, 0.75]

    /// The next larger preset, thinnest to widest, and the widest is always full width; after
    /// that it wraps to the thinnest. Landing on full width is the same as the full width key:
    /// the width before is remembered, so that key goes back to it.
    public mutating func cycleWidth(presets: [Double] = Strip.defaultPresets) -> StripOutcome {
        guard columns.indices.contains(focusColumn) else { return .refused("The strip is empty.") }
        let steps = presets.filter { $0 < 0.995 }.sorted() + [1]
        let current = columns[focusColumn].width
        let next = steps.first { $0 > current + 0.005 } ?? steps[0]
        columns[focusColumn].widthBeforeFull = next >= 0.999 ? current : nil
        columns[focusColumn].width = next
        return .done("Cycle width · \(next >= 0.999 ? "Full" : Self.percent(next))")
    }

    public mutating func toggleFullWidth(fallback: Double = 0.5) -> StripOutcome {
        guard columns.indices.contains(focusColumn) else { return .refused("The strip is empty.") }
        if columns[focusColumn].width >= 0.999 {
            let back = columns[focusColumn].widthBeforeFull ?? fallback
            columns[focusColumn].width = back
            columns[focusColumn].widthBeforeFull = nil
            return .done("Full width · back to \(Self.percent(back))")
        }
        columns[focusColumn].widthBeforeFull = columns[focusColumn].width
        columns[focusColumn].width = 1
        return .done("Full width · fills the screen")
    }

    public mutating func adjustWidth(by step: Double) -> StripOutcome {
        guard columns.indices.contains(focusColumn) else { return .refused("The strip is empty.") }
        let current = columns[focusColumn].width
        let next = min(max(current + step, 0.1), 1)
        guard abs(next - current) > 0.001 else {
            return .refused(step > 0 ? "Already full width." : "Already as narrow as it goes.")
        }
        columns[focusColumn].width = next
        columns[focusColumn].widthBeforeFull = nil
        return .done("\(step > 0 ? "Wider" : "Narrower") · \(Self.percent(next))")
    }

    /// The width a window was given by hand (resized with the mouse).
    public mutating func setWidth(_ width: Double, forColumnOf window: StripWindow) {
        guard let (c, _) = location(of: window) else { return }
        columns[c].width = min(max(width, 0.1), 1)
        columns[c].widthBeforeFull = nil
    }

    public static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }

    // MARK: Stacks and tabs

    /// Puts the focused window into the column on its left (`.left`) or right.
    public mutating func stack(into side: StripSide) -> StripOutcome {
        guard columns.indices.contains(focusColumn), let window = focusedWindow else { return .refused("The strip is empty.") }
        var target = side == .left ? focusColumn - 1 : focusColumn + 1
        guard columns.indices.contains(target) else {
            return .refused(side == .left ? "There's no column on the left." : "There's no column on the right.")
        }
        guard columns[target].pin == nil, columns[focusColumn].pin == nil else { return .refused("Pinned columns don't stack.") }
        if removeWindow(window, fromColumn: focusColumn), side == .right { target -= 1 }
        var column = columns[target]
        column.windows.append(window)
        column.heights = []
        if column.tabbed { column.activeTab = column.windows.count - 1 }
        columns[target] = column
        focusColumn = target
        focusRow = column.windows.count - 1
        return .done("Stack · joined the column on its \(side == .left ? "left" : "right")")
    }

    /// Gives the focused window its own column again, to the right (`.right`) or left.
    public mutating func popOut(to side: StripSide) -> StripOutcome {
        guard columns.indices.contains(focusColumn), let window = focusedWindow else { return .refused("The strip is empty.") }
        guard columns[focusColumn].windows.count > 1 else { return .refused("It already has a column of its own.") }
        let source = focusColumn
        let width = columns[source].width
        _ = removeWindow(window, fromColumn: source)
        let range = scrollingRange
        let wanted = side == .right ? source + 1 : source
        let index = min(max(wanted, range.lowerBound), range.upperBound)
        columns.insert(StripColumn(windows: [window], width: width), at: index)
        focusColumn = index
        focusRow = 0
        return .done("Pop out · its own column again, on the \(side == .right ? "right" : "left")")
    }

    public mutating func toggleTabbed() -> StripOutcome {
        guard columns.indices.contains(focusColumn) else { return .refused("The strip is empty.") }
        guard columns[focusColumn].windows.count > 1 else { return .refused("Stack windows first, then make them tabs.") }
        columns[focusColumn].tabbed.toggle()
        if columns[focusColumn].tabbed {
            columns[focusColumn].activeTab = focusRow
            return .done("Tabbed column · one window at full height, the rest behind tabs")
        }
        focusRow = columns[focusColumn].activeTab
        return .done("Tabbed column · back to a stack")
    }

    /// Makes the focused window in a stack taller (positive step) or shorter.
    public mutating func adjustHeight(by step: Double) -> StripOutcome {
        guard columns.indices.contains(focusColumn) else { return .refused("The strip is empty.") }
        var column = columns[focusColumn]
        guard column.windows.count > 1, !column.tabbed else { return .refused("Only windows in a stack have a height to change.") }
        var heights = column.normalizedHeights
        let row = min(focusRow, heights.count - 1)
        let floor = Self.minimumHeightFraction
        let others = heights.indices.filter { $0 != row }
        let room = others.reduce(0) { $0 + max(heights[$1] - floor, 0) }
        let change = step > 0 ? min(step, room) : max(step, floor - heights[row])
        guard abs(change) > 0.001 else {
            return .refused(step > 0 ? "Already as tall as it goes." : "Already as short as it goes.")
        }
        heights[row] += change
        // The others give up (or take back) the difference in proportion to what they have.
        if change > 0 {
            for index in others {
                let spare = max(heights[index] - floor, 0)
                heights[index] -= room > 0 ? change * spare / room : 0
            }
        } else {
            let total = others.reduce(0) { $0 + heights[$1] }
            for index in others { heights[index] += total > 0 ? -change * heights[index] / total : 0 }
        }
        column.heights = heights
        columns[focusColumn] = column
        return .done(step > 0 ? "Taller" : "Shorter")
    }

    public static let minimumHeightFraction = 0.12

    public mutating func equalizeHeights() -> StripOutcome {
        guard columns.indices.contains(focusColumn), columns[focusColumn].windows.count > 1 else {
            return .refused("Only windows in a stack have heights to even out.")
        }
        guard !columns[focusColumn].heights.isEmpty else { return .refused("The heights are already even.") }
        columns[focusColumn].heights = []
        return .done("Equal heights")
    }

    // MARK: Pins

    /// Keeps the focused column at a screen edge, full height, while the rest of the strip
    /// scrolls beside it. It becomes the first (or last) column; the same command unpins it.
    public mutating func togglePin(_ side: StripSide) -> StripOutcome {
        guard columns.indices.contains(focusColumn) else { return .refused("The strip is empty.") }
        if columns[focusColumn].pin == side {
            columns[focusColumn].pin = nil
            return .done("Unpinned")
        }
        let focused = focusedWindow
        for index in columns.indices where columns[index].pin == side { columns[index].pin = nil }
        var column = columns.remove(at: focusColumn)
        column.pin = side
        if side == .left { columns.insert(column, at: 0) } else { columns.append(column) }
        if let focused { focus(focused) }
        return .done(side == .left ? "Pinned to the left edge" : "Pinned to the right edge")
    }

    // MARK: Adding and removing

    /// Adds a window in its own column beside the focused one (or at the end), optionally
    /// focusing it.
    public mutating func insert(_ window: StripWindow, width: Double, besideFocused: Bool = true, focus: Bool = true) {
        guard !contains(window) else { return }
        let range = scrollingRange
        let wanted = columns.isEmpty ? 0 : (besideFocused ? focusColumn + 1 : range.upperBound)
        let index = min(max(wanted, range.lowerBound), range.upperBound)
        columns.insert(StripColumn(windows: [window], width: width), at: index)
        if focus || columns.count == 1 {
            focusColumn = index
            focusRow = 0
        } else if index <= focusColumn {
            focusColumn += 1
        }
    }

    /// Where a window sits, to bring it back to the same place later.
    public func slot(of window: StripWindow) -> StripSlot? {
        guard let (c, r) = location(of: window) else { return nil }
        let column = columns[c]
        return StripSlot(index: c, row: r, width: column.width,
                         leftNeighbour: c > 0 ? columns[c - 1].windows.first : nil,
                         rightNeighbour: c + 1 < columns.count ? columns[c + 1].windows.first : nil,
                         stackedWith: column.windows.filter { $0 != window })
    }

    /// Puts a window back where it was: in its old stack if that's still here, else between
    /// its old neighbours, else at its old position.
    public mutating func restore(_ window: StripWindow, to slot: StripSlot) {
        guard !contains(window) else { return }
        let stack = slot.stackedWith.compactMap { location(of: $0)?.column }.first
        if let c = stack {
            let row = min(slot.row, columns[c].windows.count)
            columns[c].windows.insert(window, at: row)
            columns[c].heights = []
            if c == focusColumn, row <= focusRow, !columns[c].tabbed { focusRow += 1 }
            return
        }
        let range = scrollingRange
        let after = slot.leftNeighbour.flatMap { location(of: $0)?.column }.map { $0 + 1 }
        let before = slot.rightNeighbour.flatMap { location(of: $0)?.column }
        let wanted = after ?? before ?? slot.index
        let index = min(max(wanted, range.lowerBound), range.upperBound)
        columns.insert(StripColumn(windows: [window], width: slot.width), at: index)
        if columns.count > 1, index <= focusColumn { focusColumn += 1 }
    }

    /// Takes a window off the strip. If it had focus, focus moves to the window that takes its
    /// place: the next one in its stack, else the column on its left (the right one at the start).
    @discardableResult
    public mutating func remove(_ window: StripWindow) -> Bool {
        guard let (c, _) = location(of: window) else { return false }
        let wasFocused = focusedWindow == window
        let columnRemoved = removeWindow(window, fromColumn: c)
        if columns.isEmpty {
            focusColumn = 0
            focusRow = 0
        } else if columnRemoved {
            if wasFocused {
                focusColumn = max(c - 1, 0)
                let column = columns[focusColumn]
                focusRow = column.tabbed ? column.activeTab : min(focusRow, column.windows.count - 1)
            } else if c < focusColumn {
                focusColumn -= 1
            }
        }
        focusColumn = min(max(focusColumn, 0), max(columns.count - 1, 0))
        return true
    }

    /// Removes the window from column `c`; true when that emptied and removed the column.
    private mutating func removeWindow(_ window: StripWindow, fromColumn c: Int) -> Bool {
        var column = columns[c]
        guard let r = column.windows.firstIndex(of: window) else { return false }
        column.windows.remove(at: r)
        if column.heights.count > r { column.heights.remove(at: r) }
        if column.windows.isEmpty {
            columns.remove(at: c)
            return true
        }
        if column.activeTab > r || column.activeTab >= column.windows.count { column.activeTab = max(column.activeTab - 1, 0) }
        if column.windows.count == 1 {
            column.tabbed = false
            column.heights = []
        }
        columns[c] = column
        if focusColumn == c {
            if column.tabbed {
                focusRow = column.activeTab
            } else if r < focusRow || focusRow >= column.windows.count {
                focusRow = max(focusRow - 1, 0)
            }
        }
        return false
    }
}
