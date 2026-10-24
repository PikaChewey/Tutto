//
//  SwitcherRules.swift
//  Tutto (window switcher)
//
//  The decisions behind the switcher, kept free of system calls so they can be tested:
//  which windows count, what a card is called, in what order cards appear, how search
//  ranks, and how a name you gave a window finds it again after the app restarts.
//

import CoreGraphics
import Foundation

// MARK: - Which windows count

public enum WindowAdmission {
    public struct Options: Sendable, Equatable {
        public var includeMinimized = true
        public var includeHidden = true
        public init(includeMinimized: Bool = true, includeHidden: Bool = true) {
            self.includeMinimized = includeMinimized
            self.includeHidden = includeHidden
        }
    }

    /// A window someone would switch to: a top-level document window that is shown on its
    /// Space, minimized, or belongs to a hidden app. Not helper surfaces, sheets, invisible
    /// windows, or toolbar strips. Without the window server's flags (a future macOS), falls
    /// back to "titled and reasonably large".
    public static func admits(_ window: ServerWindow, options: Options = Options(), haveFlags: Bool = true) -> Bool {
        guard window.layer == 0, window.parent == 0, window.alpha > 0,
              window.frame.width >= 100, window.frame.height >= 50 else { return false }
        guard haveFlags else { return !window.title.isEmpty }
        guard WindowFlags.isDocument(window.tags) else { return false }
        if WindowFlags.isMinimized(window.tags) { return options.includeMinimized }
        if WindowFlags.isAppHidden(window.tags) { return options.includeHidden }
        return WindowFlags.isShown(window.attributes)
    }
}

// MARK: - Titles

public enum WindowTitles {
    private static let separators = [" — ", " – ", " - ", " | ", " · "]

    /// What to show for a window title: the app's own name trimmed off the end
    /// ("Quest — Mozilla Firefox" → "Quest", "general - Discord" → "general") and a file path
    /// shortened to its last part.
    public static func clean(_ title: String, appName: String) -> String {
        var text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        let app = appName.lowercased()
        // The last separator in the title, whichever kind it is.
        let last = separators.compactMap { text.range(of: $0, options: .backwards) }.max { $0.lowerBound < $1.lowerBound }
        if let range = last, !app.isEmpty {
            let suffix = text[range.upperBound...].lowercased()
            let head = text[..<range.lowerBound]
            if !head.isEmpty, suffix.contains(app) || app.contains(suffix) {
                text = String(head).trimmingCharacters(in: .whitespaces)
            }
        }
        if text.hasPrefix("/") || text.hasPrefix("~/"), !text.contains(" "), let last = text.split(separator: "/").last {
            text = String(last)
        }
        return text
    }
}

// MARK: - Order

public enum SwitcherOrder {
    /// Front-to-back order for the cards: windows you used most recently first (`recent`,
    /// newest first), then the rest in the window server's stacking order, and windows that
    /// are minimized or belong to hidden apps after everything else.
    public static func order(_ windows: [(id: CGWindowID, zIndex: Int, demoted: Bool)], recent: [CGWindowID]) -> [CGWindowID] {
        var rank: [CGWindowID: Int] = [:]
        for (index, id) in recent.enumerated() where rank[id] == nil { rank[id] = index }
        return windows.sorted { a, b in
            if a.demoted != b.demoted { return !a.demoted }
            switch (rank[a.id], rank[b.id]) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.zIndex < b.zIndex
            }
        }
        .map(\.id)
    }

    /// Which card is selected when the switcher opens. Forward skips the window you're in, so
    /// one press goes back to the previous window; backward starts from the end.
    public static func initialSelection(count: Int, firstIsCurrent: Bool, backward: Bool) -> Int {
        guard count > 0 else { return 0 }
        if backward { return count - 1 }
        return firstIsCurrent && count > 1 ? 1 : 0
    }

    /// Moves `selection` by `step`, wrapping around.
    public static func move(_ selection: Int, by step: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((selection + step) % count + count) % count
    }
}

/// Windows used most recently, newest first. Bounded; ids of closed windows age out.
/// The pointer picks a card only after it has really moved. A pointer that was resting where
/// the switcher happens to open, or a card sliding under a pointer that's standing still,
/// leaves the selection alone; moving it is what says "this one".
public struct PointerIntent: Sendable, Equatable {
    /// Points it has to travel; a nudge of the desk or a resting finger doesn't count.
    public static let threshold: CGFloat = 2
    private var last: CGPoint

    /// `point`: where the pointer is as the switcher opens.
    public init(at point: CGPoint) {
        last = point
    }

    /// True when the pointer is now somewhere else than it last was (and remembers where).
    public mutating func moved(to point: CGPoint) -> Bool {
        guard abs(point.x - last.x) > Self.threshold || abs(point.y - last.y) > Self.threshold else { return false }
        last = point
        return true
    }
}

public struct RecentWindows: Sendable, Equatable {
    public private(set) var ids: [CGWindowID] = []
    public let limit: Int

    public init(limit: Int = 64) { self.limit = limit }

    public mutating func touch(_ id: CGWindowID) {
        ids.removeAll { $0 == id }
        ids.insert(id, at: 0)
        if ids.count > limit { ids.removeLast(ids.count - limit) }
    }

    public mutating func keep(only live: Set<CGWindowID>) {
        ids.removeAll { !live.contains($0) }
    }
}

// MARK: - Search

public enum WindowSearch {
    public struct Item: Sendable, Equatable {
        public let name: String?
        public let title: String
        public let app: String
        public init(name: String?, title: String, app: String) {
            self.name = name
            self.title = title
            self.app = app
        }
    }

    /// Indices of matching items, best first. A name you gave a window outranks its title,
    /// which outranks the app name; a match at the start of a field or of a word ranks higher.
    /// Ties keep the given (recent-first) order.
    public static func rank(_ query: String, in items: [Item]) -> [Int] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return Array(items.indices) }
        return items.enumerated().compactMap { index, item -> (Int, Int)? in
            let fields: [(String?, Int)] = [(item.name, 300), (item.title, 200), (item.app, 100)]
            let best = fields.compactMap { text, weight in score(needle, in: text).map { weight + $0 } }.max()
            return best.map { (index, $0) }
        }
        .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        .map(\.0)
    }

    static func score(_ needle: String, in text: String?) -> Int? {
        guard let text = text?.lowercased(), !text.isEmpty, let range = text.range(of: needle) else { return nil }
        if range.lowerBound == text.startIndex { return 50 }
        let before = text[text.index(before: range.lowerBound)]
        return before.isLetter || before.isNumber ? 0 : 25
    }
}

// MARK: - Names you give windows

/// A name given to a window. It follows the window while it exists and, when the app
/// restarts and reopens its windows, finds the same window again by title (or by place,
/// when that's unambiguous).
public struct WindowName: Codable, Equatable, Sendable {
    public var name: String
    public var bundleID: String
    public var windowID: UInt32
    /// The window's own title when last seen.
    public var title: String
    public var frame: CGRect
    public var lastSeen: Date

    public init(name: String, bundleID: String, windowID: UInt32, title: String, frame: CGRect, lastSeen: Date) {
        self.name = name
        self.bundleID = bundleID
        self.windowID = windowID
        self.title = title
        self.frame = frame
        self.lastSeen = lastSeen
    }
}

public enum WindowNaming {
    public struct Live: Sendable, Equatable {
        public let id: CGWindowID
        public let bundleID: String
        public let title: String
        public let frame: CGRect
        public init(id: CGWindowID, bundleID: String, title: String, frame: CGRect) {
            self.id = id
            self.bundleID = bundleID
            self.title = title
            self.frame = frame
        }
    }

    /// Matches stored names to the windows open now. Returns the name for each window that has
    /// one, and the stored list updated (window ids followed, titles refreshed, names whose
    /// window hasn't been seen for `forgetAfter` dropped).
    public static func assign(_ names: [WindowName], to windows: [Live], now: Date = Date(),
                              forgetAfter: TimeInterval = 14 * 86400) -> (names: [CGWindowID: String], updated: [WindowName]) {
        var updated = names
        var result: [CGWindowID: String] = [:]
        var claimed = Set<CGWindowID>()
        let byID = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        var matched = Set<Int>()
        // 1. The window is still open (same id, same app).
        for index in updated.indices {
            guard let live = byID[updated[index].windowID], live.bundleID == updated[index].bundleID, !claimed.contains(live.id) else { continue }
            claimed.insert(live.id)
            matched.insert(index)
            result[live.id] = updated[index].name
            updated[index].title = live.title.isEmpty ? updated[index].title : live.title
            updated[index].frame = live.frame
            updated[index].lastSeen = now
        }
        // 2. The window was reopened (app restart): same app and exact title, or the same
        //    place when it's the only window of that app in that place.
        for index in updated.indices where !matched.contains(index) {
            let stored = updated[index]
            let candidates = windows.filter { $0.bundleID == stored.bundleID && !claimed.contains($0.id) }
            var match: Live?
            if !stored.title.isEmpty {
                let sameTitle = candidates.filter { $0.title == stored.title }
                if sameTitle.count == 1 { match = sameTitle[0] }
            }
            if match == nil {
                let samePlace = candidates.filter { close($0.frame, stored.frame) }
                if samePlace.count == 1, candidates.count == 1 { match = samePlace[0] }
            }
            guard let found = match else { continue }
            claimed.insert(found.id)
            result[found.id] = stored.name
            updated[index].windowID = found.id
            updated[index].title = found.title.isEmpty ? stored.title : found.title
            updated[index].frame = found.frame
            updated[index].lastSeen = now
        }
        updated.removeAll { now.timeIntervalSince($0.lastSeen) > forgetAfter }
        return (result, updated)
    }

    static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 4 && abs(a.minY - b.minY) <= 4 && abs(a.width - b.width) <= 4 && abs(a.height - b.height) <= 4
    }
}
