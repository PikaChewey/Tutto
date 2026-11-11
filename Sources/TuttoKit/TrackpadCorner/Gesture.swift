//
//  Gesture.swift
//  Tutto (trackpad corner engine)
//
//  Pure, allocation-light gesture logic. No AppKit, no private API, fully unit-tested.
//
//  The key idea: macOS already decides *whether* something is a click or a tap
//  (including palm rejection and "Tap to click"). Trackpad Corner only answers
//  *where* the finger was when macOS produced that left click.
//

import Foundation

/// Monotonic nanoseconds, comparable across the multitouch thread and the event tap.
@inline(__always)
public func monotonicNanoseconds() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
}

// MARK: - Zone

public enum Corner: String, CaseIterable, Codable, Sendable {
    case bottomLeft
    case bottomRight
}

/// The right-click hot zone, in normalized trackpad coordinates (origin at the bottom-left).
public struct CornerZone: Equatable, Codable, Sendable {
    public static let minimumSize = 0.08
    public static let maximumSize = 0.6
    /// Close to Apple's own corner zone (roughly the right third of the bottom half),
    /// a little roomier because fingertips land higher than people expect.
    public static let standard = CornerZone(corner: .bottomRight, width: 0.45, height: 0.36)

    public var corner: Corner
    public var width: Double
    public var height: Double

    public init(corner: Corner, width: Double, height: Double) {
        self.corner = corner
        self.width = width
        self.height = height
    }

    public var clamped: CornerZone {
        CornerZone(
            corner: corner,
            width: min(max(width, Self.minimumSize), Self.maximumSize),
            height: min(max(height, Self.minimumSize), Self.maximumSize)
        )
    }

    /// `margin` widens the zone (in the same normalized units), for hysteresis.
    public func contains(x: Double, y: Double, margin: (x: Double, y: Double) = (0, 0)) -> Bool {
        let zone = clamped
        guard y <= zone.height + margin.y else { return false }
        switch zone.corner {
        case .bottomRight: return x >= 1 - zone.width - margin.x
        case .bottomLeft: return x <= zone.width + margin.x
        }
    }
}

/// Physical size of a trackpad surface, used to turn normalized touches into millimetres
/// so the corner feels the same on a 13" Air and a 16" Pro.
public struct TrackpadSize: Equatable, Sendable {
    public var width: Double   // mm
    public var height: Double  // mm

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public static let macBookPro14 = TrackpadSize(width: 124.8, height: 76.8)

    public func distance(dx: Double, dy: Double) -> Double {
        let x = dx * width
        let y = dy * height
        return (x * x + y * y).squareRoot()
    }
}

// MARK: - Touches

public struct Contact: Equatable, Sendable {
    public var id: Int32
    public var x: Double
    public var y: Double
    public var size: Double = 1

    public init(id: Int32, x: Double, y: Double, size: Double = 1) {
        self.id = id
        self.x = x
        self.y = y
        self.size = size
    }

    /// MultitouchSupport path states 3 ("making touch") and 4 ("touching").
    public static func isTouching(state: Int32) -> Bool { state == 3 || state == 4 }
}

/// Follows every finger on one trackpad and remembers the most recent quick tap.
public struct TouchTracker: Sendable {
    public static let tapMaxDuration: UInt64 = 400_000_000      // longer than this is a press, not a tap
    public static let tapMaxTravel = 6.0                         // mm a tap may wander (macOS decides what is a tap)
    /// How far outside the zone a finger may land, or wander, and still be "in the corner" (mm).
    public static let zoneMargin = 3.0
    public static let multiFingerWindow: UInt64 = 150_000_000    // fingers landing this close together = multi-finger tap

    public var size: TrackpadSize = .macBookPro14
    /// The right-click zone, so each finger can be classified the moment it lands.
    public var zone: CornerZone = .standard

    public struct Track: Equatable, Sendable {
        let id: Int32
        let downAt: UInt64
        let startX: Double
        let startY: Double
        var x: Double
        var y: Double
        /// Furthest distance from where it landed, in mm.
        var travel: Double
        /// Landed in the corner, and (for taps) never wandered out of it.
        var landedInZone = false
        var leftZone = false
        /// In the corner right now (with edge forgiveness).
        var inZoneNow = false
        /// Contact size now, and a slow-moving average of it (~150 ms behind).
        /// A finger that is pressing spreads out suddenly; a resting palm or thumb doesn't.
        var size = 0.0
        var baseline = 0.0
        var pressGrowth: Double { size - baseline }

        /// Clear winner by spread. When it's close, a finger in the corner that is visibly
        /// pressing wins (that's what you meant), then the finger placed last.
        /// A resting palm doesn't spread, so it never wins this way.
        func isMorePressing(than other: Track) -> Bool {
            let difference = pressGrowth - other.pressGrowth
            if abs(difference) > 0.08 { return difference > 0 }
            let selfCorner = inZoneNow && pressGrowth >= 0.05
            let otherCorner = other.inZoneNow && other.pressGrowth >= 0.05
            if selfCorner != otherCorner { return selfCorner }
            if abs(difference) > 0.02 { return difference > 0 }
            return downAt > other.downAt
        }
        /// A physical click happened while this finger was down, so its lift is not a tap.
        var pressed = false
        /// Where this finger was when it last right-clicked in the corner, and how far it has
        /// moved since (mm). After a corner press it stays "the button" only while it stays put.
        var clickX: Double?
        var clickY: Double?
        var travelSinceClick = 0.0
    }

    public struct Tap: Equatable, Sendable {
        let downAt: UInt64
        let liftedAt: UInt64
        let x: Double       // where it landed
        let y: Double
        /// Landed in the corner and never left it.
        let inZone: Bool
        var consumed = false
    }

    /// The most recent finger to leave, for clicks that arrive a moment after the lift frame.
    public struct Lift: Equatable, Sendable {
        let liftedAt: UInt64
        let x: Double
        let y: Double
        let inZone: Bool
    }

    private(set) var active: [Track] = []
    private(set) var lastTap: Tap?
    private(set) var lastLift: Lift?
    private var recentDowns: [UInt64] = []  // touch-down times of recently ended tracks

    public var newest: Track? { active.max { $0.downAt < $1.downAt } }
    public var isTouching: Bool { !active.isEmpty }
    /// Fingers on the glass now (resting ones included).
    public var fingerCount: Int { active.count }

    /// Fingers that landed together with the newest one (within `window`): the fingers of a
    /// gesture, leaving out a thumb or palm that was resting there before it.
    public func fingersLandedTogether(within window: UInt64) -> Int {
        guard let newest = active.map(\.downAt).max() else { return 0 }
        return active.filter { newest &- $0.downAt <= window }.count
    }

    public mutating func reset() {
        active.removeAll(keepingCapacity: true)
        recentDowns.removeAll(keepingCapacity: true)
        lastTap = nil
        lastLift = nil
    }

    /// The finger doing the pressing: the one whose contact just spread the most
    /// (pressing flattens a fingertip). See `Track.isMorePressing`.
    public var pressingFinger: Track? {
        active.max { a, b in b.isMorePressing(than: a) }
    }

    public mutating func consumeTap() {
        lastTap?.consumed = true
    }

    /// Called after every click: fingers down were pressing, not tapping. If the click
    /// became a corner right-click, remember where, so nudging away from there afterwards
    /// (toward a menu item) reads as pointing. A plain left click clears that memory, so
    /// you can left-click, slide into the corner and right-click without lifting.
    public mutating func markPressed(rightClick: Bool = false) {
        lastLift = nil  // a lift explains at most one click
        for i in active.indices {
            active[i].pressed = true
            active[i].clickX = rightClick ? active[i].x : nil
            active[i].clickY = rightClick ? active[i].y : nil
            active[i].travelSinceClick = 0
        }
    }

    /// Feeds one frame of *touching* contacts. Returns a tap when a single quick
    /// one-finger tap just lifted off.
    @discardableResult
    public mutating func update(touching: [Contact], now: UInt64) -> Tap? {
        var finishedTap: Tap?

        // Fingers that left the surface.
        var index = active.count - 1
        while index >= 0 {
            let track = active[index]
            if !touching.contains(where: { $0.id == track.id }) {
                active.remove(at: index)
                lastLift = Lift(liftedAt: now, x: track.x, y: track.y, inZone: track.inZoneNow)
                if let tap = tap(endingWith: track, at: now) {
                    lastTap = tap
                    finishedTap = tap
                }
                recentDowns.append(track.downAt)
                if recentDowns.count > 6 { recentDowns.removeFirst() }
            }
            index -= 1
        }

        // Fingers that moved or arrived.
        for contact in touching {
            if let i = active.firstIndex(where: { $0.id == contact.id }) {
                active[i].x = contact.x
                active[i].y = contact.y
                active[i].size = contact.size
                active[i].baseline += (contact.size - active[i].baseline) * 0.06
                active[i].inZoneNow = inZone(contact.x, contact.y)
                let moved = size.distance(dx: contact.x - active[i].startX, dy: contact.y - active[i].startY)
                active[i].travel = max(active[i].travel, moved)
                if active[i].landedInZone, !inZone(contact.x, contact.y) {
                    active[i].leftZone = true
                }
                if let cx = active[i].clickX, let cy = active[i].clickY {
                    let sinceClick = size.distance(dx: contact.x - cx, dy: contact.y - cy)
                    active[i].travelSinceClick = max(active[i].travelSinceClick, sinceClick)
                }
            } else if active.count < 12 {
                let inside = inZone(contact.x, contact.y)
                active.append(Track(id: contact.id, downAt: now, startX: contact.x, startY: contact.y,
                                    x: contact.x, y: contact.y, travel: 0,
                                    landedInZone: inside, inZoneNow: inside,
                                    size: contact.size, baseline: contact.size))
            }
        }
        return finishedTap
    }

    /// Inside the zone, with a little forgiveness around its edges.
    private func inZone(_ x: Double, _ y: Double) -> Bool {
        zone.contains(x: x, y: y, margin: (Self.zoneMargin / size.width, Self.zoneMargin / size.height))
    }

    private func tap(endingWith track: Track, at now: UInt64) -> Tap? {
        guard !track.pressed,
              now >= track.downAt,
              now - track.downAt <= Self.tapMaxDuration,
              track.travel <= Self.tapMaxTravel else { return nil }
        // Another finger landing at almost the same moment means a two/three-finger tap,
        // which macOS handles on its own.
        let others = active.map(\.downAt) + recentDowns
        if others.contains(where: { absDiff($0, track.downAt) <= Self.multiFingerWindow }) {
            return nil
        }
        return Tap(downAt: track.downAt, liftedAt: now, x: track.startX, y: track.startY,
                   inZone: track.landedInZone && !track.leftZone)
    }
}

@inline(__always)
private func absDiff(_ a: UInt64, _ b: UInt64) -> UInt64 { a > b ? a - b : b - a }

// MARK: - Decision

public enum Trigger: String, Sendable {
    case click
    case tap
}

public struct RuleSet: Equatable, Sendable {
    public var zone: CornerZone = .standard
    public var clickEnabled = true
    public var tapEnabled = true
    /// How long after a tap lifts macOS may still deliver its "Tap to click" click.
    /// macOS holds taps back for up to ~0.8 s when tap-to-drag is on.
    public var tapClickWindow: UInt64 = ClickDecider.standardTapClickWindow
    /// A physical click with exactly `ClickDecider.middleClickFingers` fingers down is a middle
    /// click (and its drag a middle drag), anywhere on the trackpad.
    public var middleClick = false

    public init(zone: CornerZone = .standard, clickEnabled: Bool = true, tapEnabled: Bool = true,
                tapClickWindow: UInt64 = ClickDecider.standardTapClickWindow, middleClick: Bool = false) {
        self.zone = zone
        self.clickEnabled = clickEnabled
        self.tapEnabled = tapEnabled
        self.tapClickWindow = tapClickWindow
        self.middleClick = middleClick
    }
}

public enum ClickDecider {
    public static let standardTapClickWindow: UInt64 = 350_000_000
    /// Exactly this many fingers down during a click make it a middle click (more is a palm or a
    /// second hand, fewer are ordinary and secondary clicks).
    public static let middleClickFingers = 3
    /// Fingers of one gesture land within this of each other; a thumb resting longer doesn't count.
    public static let middleClickLandingWindow: UInt64 = 500_000_000

    /// Whether a click with these trackpads' fingers down is a middle click: exactly three fingers
    /// that landed together, and nothing else on that trackpad.
    public static func isMiddleClick(trackers: [TouchTracker], rules: RuleSet) -> Bool {
        rules.middleClick && trackers.contains { tracker in
            tracker.fingersLandedTogether(within: middleClickLandingWindow) == middleClickFingers
                && tracker.fingerCount == middleClickFingers
        }
    }
    public static let dragDelayedTapClickWindow: UInt64 = 900_000_000
    /// After it has clicked once, a finger must stay this close (mm) to click the corner again.
    /// Nudging toward a menu item means you're pointing now.
    public static let reclickMaxTravel = 3.0
    /// A click can arrive just after the finger's lift frame; use where it was this recently.
    public static let liftGrace: UInt64 = 100_000_000

    /// Like macOS's own bottom-corner secondary click: what counts is where the pressing finger is at the
    /// moment you press. The one exception is a finger that just right-clicked in the corner
    /// and then moved: it's pointing at something now (a menu item), so it gets a normal click.
    public static func isButtonPress(_ finger: TouchTracker.Track) -> Bool {
        finger.inZoneNow && (finger.clickX == nil || finger.travelSinceClick <= reclickMaxTravel)
    }

    public static func isCornerTap(_ tap: TouchTracker.Tap) -> Bool {
        tap.inZone
    }

    public struct Decision: Equatable, Sendable {
        var trigger: Trigger?
        /// Index of the tracker whose tap this click belongs to (must be consumed).
        var consumesTapOf: Int?
        /// Where the finger behind this click was (normalized), for the live preview.
        var x: Double?
        var y: Double?
    }

    /// Called for every left mouse-down macOS produces. Decides whether it was a
    /// corner press or tap that should become a right-click.
    public static func decide(trackers: [TouchTracker], now: UInt64, rules: RuleSet) -> Decision {
        var newest: (track: TouchTracker.Track, size: TrackpadSize)?
        var latestTap: (index: Int, tap: TouchTracker.Tap)?

        for (index, tracker) in trackers.enumerated() {
            if let track = tracker.newest, newest.map({ track.downAt > $0.track.downAt }) ?? true {
                newest = (track, tracker.size)
            }
            if let tap = tracker.lastTap, !tap.consumed,
               now >= tap.liftedAt, now - tap.liftedAt <= rules.tapClickWindow,
               latestTap.map({ tap.liftedAt > $0.tap.liftedAt }) ?? true {
                latestTap = (index, tap)
            }
        }

        // 1. Tap to click: macOS emits the click right after the finger lifts.
        //    Any finger still down must have been there before the tap ended (a resting thumb/palm).
        if let (index, tap) = latestTap, newest.map({ $0.track.downAt <= tap.liftedAt }) ?? true {
            let hit = rules.tapEnabled && isCornerTap(tap)
            return Decision(trigger: hit ? .tap : nil, consumesTapOf: index, x: tap.x, y: tap.y)
        }

        // 2. Physical click: the finger that is pressing decides.
        var pressing: TouchTracker.Track?
        for tracker in trackers {
            guard let candidate = tracker.pressingFinger else { continue }
            if let current = pressing {
                if candidate.isMorePressing(than: current) { pressing = candidate }
            } else {
                pressing = candidate
            }
        }
        guard let finger = pressing else {
            // No finger down: if one lifted a moment ago, the click is its.
            let lift = trackers.compactMap(\.lastLift)
                .filter { now >= $0.liftedAt && now - $0.liftedAt <= liftGrace }
                .max { $0.liftedAt < $1.liftedAt }
            if let lift, lift.inZone, rules.clickEnabled {
                return Decision(trigger: .click, x: lift.x, y: lift.y)
            }
            return Decision(trigger: nil, x: lift?.x, y: lift?.y)
        }
        guard isButtonPress(finger) else {
            return Decision(trigger: nil, x: finger.x, y: finger.y)
        }
        if rules.clickEnabled {
            return Decision(trigger: .click, x: finger.x, y: finger.y)
        }
        // The click for a tap can race ahead of the lift frame; a short, still touch is a tap.
        if rules.tapEnabled, now >= finger.downAt,
           now - finger.downAt <= TouchTracker.tapMaxDuration,
           finger.travel <= TouchTracker.tapMaxTravel {
            return Decision(trigger: .tap, x: finger.x, y: finger.y)
        }
        return Decision(trigger: nil, x: finger.x, y: finger.y)
    }
}
