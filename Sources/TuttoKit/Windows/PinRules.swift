//
//  PinRules.swift
//  TuttoKit
//
//  Keep on top: macOS has no public way to raise another app's window above the rest, so a
//  pinned window gets a live copy of itself in a floating panel, sitting exactly over it. These
//  are the decisions behind that copy, kept free of AppKit so they can be tested.
//

import CoreGraphics
import Foundation

public enum PinRules {
    /// More than this and the copies start to cost real battery.
    public static let maxPins = 3
    /// Frames a second the copy is refreshed at.
    public static let framesPerSecond = 30

    // MARK: Showing the copy

    /// Whether a pinned window's copy shows. It shows while the window is on screen and you're
    /// somewhere else: another app, or another window of the same app. It hides while you're in
    /// the window itself (you use the real one), and while the window isn't on screen at all
    /// (minimized, its app hidden, on another Space), so nothing floats over an empty spot.
    ///
    /// - Parameters:
    ///   - pinned: the pinned window's window-server id.
    ///   - pinnedPID: the app it belongs to.
    ///   - frontmostPID: the app in front, if any.
    ///   - focusedWindow: the front app's focused window, when the front app is the pinned one
    ///     (nil when it couldn't be read).
    ///   - windowOnScreen: the window server says the window is on screen now.
    public static func showsCopy(pinned: CGWindowID, pinnedPID: pid_t, frontmostPID: pid_t?,
                                 focusedWindow: CGWindowID?, windowOnScreen: Bool) -> Bool {
        guard windowOnScreen else { return false }
        guard let frontmostPID, frontmostPID == pinnedPID else { return true }
        // Its own app is in front. If the focused window can't be read, assume it's this one:
        // a copy over the window you're typing in would swallow your clicks.
        guard let focusedWindow else { return false }
        return focusedWindow != pinned
    }

    // MARK: Pinning

    public enum Toggle: Equatable, Sendable {
        case pin
        case unpin
        /// Already `maxPins` windows on top.
        case full
    }

    /// What pressing the keys does to a window, given the windows already on top.
    public static func toggle(_ window: CGWindowID, pinned: [CGWindowID]) -> Toggle {
        if pinned.contains(window) { return .unpin }
        return pinned.count >= maxPins ? .full : .pin
    }

    public enum Refusal: Equatable, Sendable {
        /// Tutto's own windows (they already float where they need to).
        case ownWindow
        /// Menus, panels and other windows that already sit above normal ones.
        case notAWindow
        /// A window in native full screen has a Space of its own.
        case fullScreen
        /// Too small to be a window worth keeping (a bit of an app's chrome).
        case tooSmall
    }

    /// Why a window can't be kept on top, or nil when it can.
    public static func refusal(pid: pid_t, ownPID: pid_t, layer: Int, size: CGSize, fullScreen: Bool) -> Refusal? {
        if pid == ownPID { return .ownWindow }
        if layer != 0 { return .notAWindow }
        if fullScreen { return .fullScreen }
        if size.width < 40 || size.height < 40 { return .tooSmall }
        return nil
    }

    // MARK: The copy's size and place

    /// The largest side the copy is captured at, in pixels: a 6K window still fits, and nothing
    /// asks the GPU for more.
    public static let maxCaptureSide = 8_192

    /// The pixel size to capture a window at, on a display with this scale: the window's own
    /// size, so the copy is sharp and nothing is scaled. Never below 1 pixel; a huge window is
    /// scaled down evenly to fit `maxCaptureSide`.
    public static func captureSize(points: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
        let scale = scale > 0 ? scale : 1
        var width = max(points.width, 1) * scale
        var height = max(points.height, 1) * scale
        let longest = max(width, height)
        if longest > CGFloat(maxCaptureSide) {
            let shrink = CGFloat(maxCaptureSide) / longest
            width *= shrink
            height *= shrink
        }
        return (max(Int(width.rounded()), 1), max(Int(height.rounded()), 1))
    }

    /// The copy's frame for AppKit (origin at the bottom left of the main display) from the
    /// window's frame as the window server and Accessibility give it (origin at the top left).
    public static func panelFrame(windowBounds: CGRect, primaryHeight: CGFloat) -> CGRect {
        WindowLayout.flip(windowBounds, primaryHeight: primaryHeight)
    }

    /// True when the copy has to move or be resized: changes under half a point are rounding.
    public static func needsMove(from current: CGRect, to target: CGRect) -> Bool {
        abs(current.minX - target.minX) >= 0.5 || abs(current.minY - target.minY) >= 0.5
            || abs(current.width - target.width) >= 0.5 || abs(current.height - target.height) >= 0.5
    }

    // MARK: Words

    /// How a pinned window is named in lists: "TextEdit — Notes.txt", or the app alone when the
    /// window has no title (or its title is just the app's name again).
    public static func label(app: String, title: String) -> String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != app else { return app }
        return "\(app) — \(title)"
    }

    /// The window palette's row.
    public static func paletteTitle(pinned: Bool) -> String {
        pinned ? "Stop Keeping on Top" : "Keep on Top"
    }

    /// Words people type for it in the window palette.
    public static let paletteAliases = ["pin", "always on top", "stay on top", "float", "unpin", "stop keeping on top"]

    /// How well a palette query matches the row (nil: no match), on FuzzyMatcher's scale.
    public static func paletteScore(_ query: String) -> Int? {
        FuzzyMatcher.score(query, title: "Keep on Top", aliases: paletteAliases)
    }

    /// Where the row goes among the palette's window actions (already ranked, with their match
    /// scores), or nil to leave it out. With nothing typed it comes last, so the list you know
    /// doesn't shift; otherwise it goes before the first action that matches less well.
    public static func paletteIndex(query: String, rankedActionScores: [Int]) -> Int? {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return rankedActionScores.count }
        guard let score = paletteScore(query) else { return nil }
        return rankedActionScores.firstIndex { $0 < score } ?? rankedActionScores.count
    }
}
