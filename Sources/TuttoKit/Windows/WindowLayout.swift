//
//  WindowLayout.swift
//  Tutto
//
//  Where each window action puts a window. Pure geometry in a top-left-origin,
//  y-down space (the Accessibility API's), so it is easy to test and reason about.
//

import CoreGraphics
import Foundation

public enum WindowAction: String, CaseIterable, Codable, Sendable, Identifiable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case leftThird, centerThird, rightThird, leftTwoThirds, rightTwoThirds
    case topLeft, topRight, bottomLeft, bottomRight
    case maximize, almostMaximize, maximizeHeight, center
    case nextDisplay, previousDisplay
    case restore

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .leftHalf: "Left Half"
        case .rightHalf: "Right Half"
        case .topHalf: "Top Half"
        case .bottomHalf: "Bottom Half"
        case .leftThird: "First Third"
        case .centerThird: "Center Third"
        case .rightThird: "Last Third"
        case .leftTwoThirds: "First Two Thirds"
        case .rightTwoThirds: "Last Two Thirds"
        case .topLeft: "Top Left Quarter"
        case .topRight: "Top Right Quarter"
        case .bottomLeft: "Bottom Left Quarter"
        case .bottomRight: "Bottom Right Quarter"
        case .maximize: "Maximize"
        case .almostMaximize: "Almost Maximize"
        case .maximizeHeight: "Maximize Height"
        case .center: "Center"
        case .nextDisplay: "Next Display"
        case .previousDisplay: "Previous Display"
        case .restore: "Restore"
        }
    }

    /// Extra words people type for the same thing.
    public var aliases: [String] {
        switch self {
        case .leftHalf: ["lh", "left"]
        case .rightHalf: ["rh", "right"]
        case .topHalf: ["th", "top", "upper half"]
        case .bottomHalf: ["bh", "bottom", "lower half"]
        case .leftThird: ["left third", "first 1/3"]
        case .centerThird: ["middle third"]
        case .rightThird: ["right third", "last 1/3"]
        case .leftTwoThirds: ["left two thirds", "2/3"]
        case .rightTwoThirds: ["right two thirds"]
        case .topLeft: ["tl", "top left"]
        case .topRight: ["tr", "top right"]
        case .bottomLeft: ["bl", "bottom left"]
        case .bottomRight: ["br", "bottom right"]
        case .maximize: ["max", "fill", "full screen", "fullscreen", "zoom"]
        case .almostMaximize: ["almost", "large"]
        case .maximizeHeight: ["tall", "vertical"]
        case .center: ["middle", "centre"]
        case .nextDisplay: ["next screen", "monitor", "move to display"]
        case .previousDisplay: ["previous screen", "prev display"]
        case .restore: ["undo", "reset", "original"]
        }
    }

    /// The target region as a fraction of the screen (x, y from top-left, width, height),
    /// for drawing the little screen glyph. Nil for actions that don't have one.
    public var unitRegion: CGRect? {
        switch self {
        case .leftHalf: CGRect(x: 0, y: 0, width: 0.5, height: 1)
        case .rightHalf: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        case .topHalf: CGRect(x: 0, y: 0, width: 1, height: 0.5)
        case .bottomHalf: CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
        case .leftThird: CGRect(x: 0, y: 0, width: 1.0 / 3, height: 1)
        case .centerThird: CGRect(x: 1.0 / 3, y: 0, width: 1.0 / 3, height: 1)
        case .rightThird: CGRect(x: 2.0 / 3, y: 0, width: 1.0 / 3, height: 1)
        case .leftTwoThirds: CGRect(x: 0, y: 0, width: 2.0 / 3, height: 1)
        case .rightTwoThirds: CGRect(x: 1.0 / 3, y: 0, width: 2.0 / 3, height: 1)
        case .topLeft: CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        case .topRight: CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
        case .bottomLeft: CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)
        case .bottomRight: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        case .maximize: CGRect(x: 0, y: 0, width: 1, height: 1)
        case .almostMaximize: CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
        case .maximizeHeight: CGRect(x: 0.3, y: 0, width: 0.4, height: 1)
        case .center: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        case .nextDisplay, .previousDisplay, .restore: nil
        }
    }

    public var movesBetweenDisplays: Bool { self == .nextDisplay || self == .previousDisplay }
}

public enum WindowLayout {
    /// The frame for `action` on a screen whose usable area is `visible`, given the window's current frame.
    /// `gap` insets every edge (and the seam between tiled windows) by that many points.
    public static func frame(for action: WindowAction, visible: CGRect, current: CGRect, gap: CGFloat = 0) -> CGRect {
        let area = visible.insetBy(dx: gap, dy: gap)
        func region(_ unit: CGRect) -> CGRect {
            var rect = CGRect(x: area.minX + unit.minX * area.width,
                              y: area.minY + unit.minY * area.height,
                              width: unit.width * area.width,
                              height: unit.height * area.height)
            // Half the gap on each interior seam, so tiled windows sit `gap` apart.
            if gap > 0 {
                if unit.minX > 0.001 { rect.origin.x += gap / 2; rect.size.width -= gap / 2 }
                if unit.maxX < 0.999 { rect.size.width -= gap / 2 }
                if unit.minY > 0.001 { rect.origin.y += gap / 2; rect.size.height -= gap / 2 }
                if unit.maxY < 0.999 { rect.size.height -= gap / 2 }
            }
            return rect.integral
        }
        switch action {
        case .center:
            let size = CGSize(width: min(current.width, area.width), height: min(current.height, area.height))
            // Round the origin, keep the size exact (integral would grow it by a point).
            return CGRect(x: (area.midX - size.width / 2).rounded(), y: (area.midY - size.height / 2).rounded(),
                          width: size.width, height: size.height)
        case .maximizeHeight:
            let width = min(current.width, area.width)
            let x = min(max(current.minX, area.minX), area.maxX - width)
            return CGRect(x: x.rounded(), y: area.minY, width: width, height: area.height)
        case .almostMaximize:
            return area.insetBy(dx: area.width * 0.05, dy: area.height * 0.05).integral
        case .nextDisplay, .previousDisplay, .restore:
            return current
        default:
            return region(action.unitRegion ?? CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }

    /// Moves a frame from one screen to another, keeping its relative position and size.
    public static func move(_ frame: CGRect, from source: CGRect, to target: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0 else { return frame }
        let relativeX = (frame.minX - source.minX) / source.width
        let relativeY = (frame.minY - source.minY) / source.height
        let width = min(frame.width / source.width * target.width, target.width)
        let height = min(frame.height / source.height * target.height, target.height)
        var x = target.minX + relativeX * target.width
        var y = target.minY + relativeY * target.height
        x = min(max(x, target.minX), target.maxX - width)
        y = min(max(y, target.minY), target.maxY - height)
        return CGRect(x: x.rounded(), y: y.rounded(), width: width.rounded(), height: height.rounded())
    }

    /// Converts a Cocoa screen rect (bottom-left origin) to Accessibility coordinates (top-left origin of
    /// the primary screen), given the primary screen's height.
    public static func flip(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}

/// Small fuzzy matcher for palettes: exact beats prefix beats word prefixes beats initials beats
/// subsequences; aliases count slightly less than titles. Ties are left to the caller's order.
public enum FuzzyMatcher {
    /// Higher is better; nil means no match.
    public static func score(_ query: String, title: String, aliases: [String] = []) -> Int? {
        let q = normalize(query)
        guard !q.isEmpty else { return 0 }
        var best: Int?
        for (index, candidate) in ([title] + aliases).enumerated() {
            guard let s = score(q, against: normalize(candidate)) else { continue }
            let weighted = s - (index == 0 ? 0 : 5)  // the title wins ties
            best = max(best ?? Int.min, weighted)
        }
        return best
    }

    private static func score(_ query: String, against candidate: String) -> Int? {
        if candidate == query { return 1000 }
        if candidate.hasPrefix(query) { return 900 }
        let queryWords = query.split(separator: " ")
        let candidateWords = candidate.split(separator: " ")
        // Every query word is the prefix of some candidate word, in order: "left ha" → "Left Half".
        var position = 0
        var allPrefixes = true
        for word in queryWords {
            guard let found = candidateWords[position...].firstIndex(where: { $0.hasPrefix(word) }) else {
                allPrefixes = false
                break
            }
            position = found + 1
            if position > candidateWords.count { break }
        }
        if allPrefixes { return 700 }
        // Initials: "lh" → "Left Half".
        let initials = String(candidateWords.compactMap(\.first))
        if initials.hasPrefix(query.replacingOccurrences(of: " ", with: "")) { return 600 }
        // Subsequence anywhere.
        var remaining = Substring(query.replacingOccurrences(of: " ", with: ""))
        for character in candidate where character == remaining.first {
            remaining = remaining.dropFirst()
            if remaining.isEmpty { return 300 }
        }
        return nil
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .folding(options: [.diacriticInsensitive], locale: nil)
            .split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" })
            .joined(separator: " ")
    }
}
