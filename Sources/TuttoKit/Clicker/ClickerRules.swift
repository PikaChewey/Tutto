//
//  ClickerRules.swift
//  Tutto
//
//  The auto clicker's decisions, apart from the system so they can be tested: how fast, which
//  button, where, when to stop, and the wait before each click (with an optional random spread so
//  clicks don't land on a perfect metronome).
//

import Foundation

public enum ClickButton: String, Codable, CaseIterable, Sendable {
    case left, right, middle

    public var title: String {
        switch self {
        case .left: "Left"
        case .right: "Right"
        case .middle: "Middle"
        }
    }
}

/// Where the clicks land.
public enum ClickTarget: Codable, Equatable, Sendable {
    /// Wherever the pointer is at each click.
    case pointer
    /// One spot on screen (global top-left points), picked beforehand.
    case point(x: Double, y: Double)
}

/// When a run stops by itself.
public enum ClickStop: Codable, Equatable, Sendable {
    case never
    case afterClicks(Int)
    case afterSeconds(Double)
}

public struct ClickerSettings: Codable, Equatable, Sendable {
    /// Clicks per second, 0.1 … `ClickerSettings.fastest`.
    public var clicksPerSecond: Double = 10
    public var button: ClickButton = .left
    /// Two clicks per tick, posted as a double click (click state 1 then 2).
    public var double = false
    public var target: ClickTarget = .pointer
    public var stop: ClickStop = .never
    /// Each wait varies by up to this share of the interval (0 = exact, 0.3 = ±30 %).
    public var jitter: Double = 0
    /// Seconds between Start and the first click, to get the pointer where it belongs.
    public var startDelay: Double = 0
    /// Moving the pointer to any corner of the screen stops a run.
    public var cornerStops = true
    /// The shortcut clicks only while it's held, instead of turning clicking on and off.
    public var holdToClick = false

    public static let fastest: Double = 100
    public static let slowest: Double = 0.1

    public init() {}

    /// Settings saved by an older Tutto, with fields since added, keep their defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ClickerSettings()
        clicksPerSecond = try c.decodeIfPresent(Double.self, forKey: .clicksPerSecond) ?? d.clicksPerSecond
        button = try c.decodeIfPresent(ClickButton.self, forKey: .button) ?? d.button
        double = try c.decodeIfPresent(Bool.self, forKey: .double) ?? d.double
        target = try c.decodeIfPresent(ClickTarget.self, forKey: .target) ?? d.target
        stop = try c.decodeIfPresent(ClickStop.self, forKey: .stop) ?? d.stop
        jitter = try c.decodeIfPresent(Double.self, forKey: .jitter) ?? d.jitter
        startDelay = try c.decodeIfPresent(Double.self, forKey: .startDelay) ?? d.startDelay
        cornerStops = try c.decodeIfPresent(Bool.self, forKey: .cornerStops) ?? d.cornerStops
        holdToClick = try c.decodeIfPresent(Bool.self, forKey: .holdToClick) ?? d.holdToClick
        normalize()
    }

    /// Keeps every value in range.
    public mutating func normalize() {
        if !clicksPerSecond.isFinite { clicksPerSecond = 10 }
        clicksPerSecond = min(max(clicksPerSecond, Self.slowest), Self.fastest)
        jitter = min(max(jitter.isFinite ? jitter : 0, 0), 0.5)
        startDelay = min(max(startDelay.isFinite ? startDelay : 0, 0), 10)
        switch stop {
        case .afterClicks(let n) where n < 1: stop = .afterClicks(1)
        case .afterSeconds(let s) where !(s >= 1): stop = .afterSeconds(1)
        default: break
        }
    }

    /// Seconds between clicks.
    public var interval: Double { 1 / min(max(clicksPerSecond, Self.slowest), Self.fastest) }

    /// "12 CPS", "0.5 CPS", "100 CPS".
    public var speedLabel: String {
        let rounded = (clicksPerSecond * 10).rounded() / 10
        let text = rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
        return "\(text) CPS"
    }

    /// One line for the panel: "12 CPS · left · at the pointer".
    public var summary: String {
        var parts = [speedLabel, (double ? "double " : "") + button.title.lowercased()]
        if case .point = target { parts.append("at a set spot") }
        switch stop {
        case .never: break
        case .afterClicks(let n): parts.append("\(n.formatted()) clicks")
        case .afterSeconds(let s): parts.append("for \(ClickerRules.duration(s))")
        }
        return parts.joined(separator: " · ")
    }
}

public enum ClickerRules {
    /// The wait before the next click: the interval, spread by `jitter` with `random` in [0, 1).
    public static func wait(_ settings: ClickerSettings, random: Double) -> Double {
        let base = settings.interval
        guard settings.jitter > 0 else { return base }
        let spread = (random * 2 - 1) * settings.jitter
        return max(base * (1 + spread), 0.005)
    }

    /// Whether a run that has made `clicks` clicks over `elapsed` seconds is done.
    public static func isDone(_ settings: ClickerSettings, clicks: Int, elapsed: Double) -> Bool {
        switch settings.stop {
        case .never: false
        case .afterClicks(let n): clicks >= n
        case .afterSeconds(let s): elapsed >= s
        }
    }

    /// Whether a pointer at `point` (global top-left points) sits in a corner of any of `screens`
    /// (each a global top-left rect), within `margin` points.
    public static func inCorner(_ point: CGPoint, screens: [CGRect], margin: Double = 3) -> Bool {
        screens.contains { s in
            let left = point.x <= s.minX + margin, right = point.x >= s.maxX - 1 - margin
            let top = point.y <= s.minY + margin, bottom = point.y >= s.maxY - 1 - margin
            return s.insetBy(dx: -1, dy: -1).contains(point) && (left || right) && (top || bottom)
        }
    }

    /// "30 s", "5 min", "1 h 30 min".
    public static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) s" }
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return m > 0 ? "\(h) h \(m) min" : "\(h) h" }
        return s > 0 ? "\(m) min \(s) s" : "\(m) min"
    }
}
