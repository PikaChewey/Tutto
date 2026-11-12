//
//  MenuBarIconRules.swift
//  TuttoKit
//
//  The rules behind Menu Bar Icons: what the divider looks like and how long it is when it tucks
//  icons away or shows them, when tucked icons hide again by themselves, where the divider starts,
//  and how to tell that Tutto's own icon ended up on the wrong side of it.
//
//  macOS lays menu bar items out from the right. An item made very long pushes every item to its
//  left off the screen, which is all "tucking away" is: nothing is removed or restarted.
//

import CoreGraphics
import Foundation

/// The divider: collapsed (very long, so everything to its left is off screen) or expanded.
public struct MenuBarDivider: Equatable, Sendable {
    /// Long enough to push every icon to its left off the screen.
    public static let collapsedLength: Double = 10_000
    /// Wide enough for the divider line and its chevron.
    public static let expandedLength: Double = 24

    public var isCollapsed: Bool

    public init(isCollapsed: Bool = true) { self.isCollapsed = isCollapsed }

    public var length: Double { isCollapsed ? Self.collapsedLength : Self.expandedLength }

    /// The chevron points the way the icons come back from while they're tucked away, and the way
    /// they go when they are showing.
    public var chevronSymbol: String { isCollapsed ? "chevron.left" : "chevron.right" }

    public var toggled: MenuBarDivider { MenuBarDivider(isCollapsed: !isCollapsed) }

    /// What a click does, for the tooltip and the spoken label.
    public var actionTitle: String { isCollapsed ? "Show hidden menu bar icons" : "Hide menu bar icons" }
}

/// When tucked-away icons hide again.
public enum MenuBarAutoHide: Int, CaseIterable, Codable, Sendable {
    case never = 0
    case fiveSeconds = 5
    case tenSeconds = 10
    case thirtySeconds = 30

    public static let standard: MenuBarAutoHide = .tenSeconds

    /// In the order the page shows them: short to long, "Never" last.
    public static var choices: [MenuBarAutoHide] { [.fiveSeconds, .tenSeconds, .thirtySeconds, .never] }

    public var seconds: TimeInterval? { self == .never ? nil : TimeInterval(rawValue) }

    public var title: String { self == .never ? "Never" : "\(rawValue) s" }

    /// How soon to look again while the pointer rests in the menu bar.
    public static let recheckInterval: TimeInterval = 2

    public enum Decision: Equatable, Sendable {
        /// Leave the icons showing; nothing to schedule.
        case stayOpen
        /// Tuck them away now.
        case hide
        /// Not yet: ask again after this many seconds.
        case checkAgain(after: TimeInterval)
    }

    /// What to do `shown` seconds after the icons were revealed. They stay while the pointer is
    /// in the menu bar (you may be reaching for one, or ⌘-dragging icons around).
    public func decision(shown: TimeInterval, pointerInMenuBar: Bool) -> Decision {
        guard let limit = seconds else { return .stayOpen }
        if shown < limit { return .checkAgain(after: limit - shown) }
        return pointerInMenuBar ? .checkAgain(after: Self.recheckInterval) : .hide
    }

    /// `y` is the pointer's height in screen coordinates (up is larger); the menu bar is the strip
    /// of `barHeight` along the top of the screen whose top edge is `screenTop`.
    public static func pointerIsInMenuBar(y: Double, screenTop: Double, barHeight: Double) -> Bool {
        y >= screenTop - max(barHeight, 1)
    }
}

/// Where the divider starts, in the position numbers macOS keeps for each menu bar item: the
/// distance in points from the right edge of the screen, so a larger number sits further left.
public enum MenuBarDividerPosition {
    /// Room for Tutto's own icon, so the divider starts just to its left.
    public static let gap: Double = 34

    /// The key macOS reads in the app's own defaults for an item saved under `autosaveName`.
    public static func defaultsKey(autosaveName: String) -> String {
        "NSStatusItem Preferred Position \(autosaveName)"
    }

    /// The first position for the divider, from Tutto's own icon's saved position. Nil when Tutto's
    /// icon has none yet: a new item then lands to the left of the ones already there.
    public static func initial(tuttoPosition: Double?) -> Double? {
        guard let tuttoPosition, tuttoPosition > 0 else { return nil }
        return tuttoPosition + gap
    }
}

/// Which side of the divider Tutto's own icon is on.
public enum MenuBarOrder: Equatable, Sendable {
    /// Tutto's icon is to the right of the divider, as it should be.
    case fine
    /// Tutto's icon is to the left of the divider: tucking icons away would hide it too.
    case tuttoWouldBeTucked
    /// Neither icon has a place on screen yet.
    case unknown

    /// The divider's and Tutto's icon's window frames, in screen coordinates.
    public static func check(divider: CGRect?, tutto: CGRect?) -> MenuBarOrder {
        guard let divider, let tutto, divider.width > 0, tutto.width > 0 else { return .unknown }
        // The divider's right edge is the line: nothing left of it survives a collapse.
        return tutto.minX < divider.maxX - 1 ? .tuttoWouldBeTucked : .fine
    }
}
