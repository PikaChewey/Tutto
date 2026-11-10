//
//  AwakeRules.swift
//  Tutto
//
//  Stay Awake's decisions, kept apart from the system so they can be tested: what a typed time
//  means, how time left is written, when Low Power Mode is wanted and when a session must end,
//  and which apps are paused while the lid is closed.
//

import Foundation

// MARK: - Typed durations

public enum AwakeDuration {
    /// The panel's chips.
    public static let presets: [TimeInterval] = [3600, 2 * 3600, 4 * 3600, 8 * 3600]
    /// What a running session's chips add.
    public static let additions: [TimeInterval] = [15 * 60, 3600]

    /// Seconds for a time typed the way people type them: "90" is ninety minutes, "2h", "2h30"
    /// (a trailing number takes the next smaller unit), "1.5h", "1d 6h", "45 min", "2 hours",
    /// "2:30" (hours and minutes), "1w". Rounded to the minute; nil when it isn't a time.
    public static func seconds(from text: String) -> TimeInterval? {
        let s = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.contains(":") { return clock(s) }
        var total = 0.0
        var lastUnit: Double?
        var index = s.startIndex
        while index < s.endIndex {
            while index < s.endIndex, s[index] == " " { index = s.index(after: index) }
            guard index < s.endIndex else { break }
            var number = ""
            while index < s.endIndex, s[index].isNumber || s[index] == "." {
                number.append(s[index])
                index = s.index(after: index)
            }
            guard let value = Double(number), value.isFinite, value >= 0 else { return nil }
            while index < s.endIndex, s[index] == " " { index = s.index(after: index) }
            var word = ""
            while index < s.endIndex, s[index].isLetter {
                word.append(s[index])
                index = s.index(after: index)
            }
            let unit: Double
            if word.isEmpty {
                // A bare number: minutes on its own, else the unit below the last one.
                switch lastUnit {
                case nil: unit = 60
                case 604_800?: unit = 86_400
                case 86_400?: unit = 3_600
                case 3_600?: unit = 60
                default: return nil
                }
                guard index == s.endIndex else { return nil }
            } else {
                guard let named = unitSeconds(word) else { return nil }
                unit = named
            }
            // Largest to smallest, never twice.
            if let lastUnit, unit >= lastUnit { return nil }
            total += value * unit
            lastUnit = unit
        }
        let minutes = (total / 60).rounded()
        guard minutes >= 1, minutes <= 400 * 1_440 else { return nil }
        return minutes * 60
    }

    private static func unitSeconds(_ word: String) -> Double? {
        let units: [(names: Set<String>, seconds: Double)] = [
            (["w", "wk", "wks", "week", "weeks"], 604_800),
            (["d", "day", "days"], 86_400),
            (["h", "hr", "hrs", "hour", "hours"], 3_600),
            (["m", "min", "mins", "minute", "minutes"], 60),
        ]
        return units.first { $0.names.contains(word) }?.seconds
    }

    /// "2:30" → 2 h 30 min.
    private static func clock(_ s: String) -> TimeInterval? {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let hours = Int(parts[0]), let minutes = Int(parts[1]),
              hours >= 0, (0..<60).contains(minutes), parts[1].count == 2 else { return nil }
        let total = hours * 60 + minutes
        return total >= 1 ? TimeInterval(total * 60) : nil
    }

    /// A length as a label: "1h", "2h 30m", "1d 6h", "45m".
    public static func label(_ seconds: TimeInterval) -> String {
        let minutes = max(Int((seconds / 60).rounded()), 0)
        let d = minutes / 1_440, h = (minutes % 1_440) / 60, m = minutes % 60
        var parts: [String] = []
        if d > 0 { parts.append("\(d)d") }
        if h > 0 { parts.append("\(h)h") }
        if m > 0, d == 0 { parts.append("\(m)m") }
        return parts.isEmpty ? "0m" : parts.joined(separator: " ")
    }

    /// Time left for the menu bar, in whole minutes rounded up: "2h 14m", "45m", "1d 3h".
    public static func menuBar(_ remaining: TimeInterval) -> String {
        let minutes = max(Int((max(remaining, 0) / 60).rounded(.up)), 0)
        return label(TimeInterval(minutes * 60))
    }

    /// The countdown, split so the seconds can be drawn lighter: ("2:14", ":07"),
    /// ("1d 2:14", ":07"), ("4", ":07") under an hour.
    public static func countdown(_ remaining: TimeInterval) -> (main: String, seconds: String) {
        let total = Int(max(remaining, 0).rounded(.up))
        let s = total % 60, m = (total / 60) % 60, h = (total / 3_600) % 24, d = total / 86_400
        let seconds = String(format: ":%02d", s)
        if d > 0 { return ("\(d)d \(h):" + String(format: "%02d", m), seconds) }
        if h > 0 { return ("\(h):" + String(format: "%02d", m), seconds) }
        return ("\(m)", seconds)
    }
}

// MARK: - Battery and heat

/// The settings Stay Awake acts on.
public struct AwakePolicy: Codable, Equatable, Sendable {
    /// On battery below this charge, Low Power Mode comes on (0 turns it off).
    public var lowPowerBelow = 40
    /// On battery below this charge, the session ends (0 turns it off). Kept below `lowPowerBelow`.
    public var endBelow = 10
    /// Serious heat brings Low Power Mode; critical heat ends the session.
    public var heatRules = true
    // While the lid is closed:
    public var darkenWhenClosed = true
    public var lowPowerWhenClosed = true
    public var muteWhenClosed = true
    public var pauseAppsWhenClosed = true
    /// A session that ends with the lid closed puts the Mac to sleep.
    public var sleepWhenDoneClosed = true
    /// Time left beside the menu bar icon.
    public var showTimeInMenuBar = true

    public init() {}

    /// The end floor stays below the Low Power Mode floor (when both are on).
    public mutating func normalize() {
        lowPowerBelow = min(max(lowPowerBelow, 0), 95)
        endBelow = min(max(endBelow, 0), 50)
        if endBelow > 0, lowPowerBelow > 0, endBelow >= lowPowerBelow { lowPowerBelow = min(endBelow + 5, 95) }
    }
}

public enum Heat: Int, Comparable, Sendable {
    case nominal, fair, serious, critical

    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .serious
        }
    }

    public static func < (a: Heat, b: Heat) -> Bool { a.rawValue < b.rawValue }
}

public struct AwakeConditions: Equatable, Sendable {
    public var onBattery: Bool
    /// Nil on a Mac with no battery, or while it can't be read.
    public var charge: Int?
    public var heat: Heat
    public var lidClosed: Bool
    /// The lid is closed with another display in use: an ordinary desk set-up, so the lid-closed
    /// actions don't apply.
    public var externalDisplay: Bool

    public init(onBattery: Bool, charge: Int?, heat: Heat, lidClosed: Bool, externalDisplay: Bool) {
        self.onBattery = onBattery
        self.charge = charge
        self.heat = heat
        self.lidClosed = lidClosed
        self.externalDisplay = externalDisplay
    }

    /// The lid is closed with no other display: the case the battery actions are for.
    public var closedAlone: Bool { lidClosed && !externalDisplay }
}

public enum AwakeRules {
    /// Why the session must end now, or nil.
    public static func endReason(_ policy: AwakePolicy, _ now: AwakeConditions) -> String? {
        if policy.heatRules, now.heat == .critical { return "The Mac got critically hot" }
        if policy.endBelow > 0, now.onBattery, let charge = now.charge, charge < policy.endBelow {
            return "The battery fell to \(charge)%"
        }
        return nil
    }

    /// Whether Low Power Mode is wanted, and for what (shown in the panel).
    public static func lowPowerReason(_ policy: AwakePolicy, _ now: AwakeConditions) -> String? {
        if policy.lowPowerWhenClosed, now.closedAlone { return "lid closed" }
        if policy.lowPowerBelow > 0, now.onBattery, let charge = now.charge, charge < policy.lowPowerBelow {
            return "battery below \(policy.lowPowerBelow)%"
        }
        if policy.heatRules, now.heat >= .serious { return "running hot" }
        return nil
    }
}

// MARK: - Apps paused while the lid is closed

public struct AwakeApp: Equatable, Hashable, Sendable {
    public var bundleID: String
    public var name: String
    /// `LSApplicationCategoryType` from its Info.plist.
    public var category: String?

    public init(bundleID: String, name: String, category: String?) {
        self.bundleID = bundleID
        self.name = name
        self.category = category
    }
}

public enum AwakePausing {
    /// App Store categories paused by default: chat, social, games and entertainment, which keep
    /// connections, timers and renderers busy and do nothing useful with the lid shut. Video and
    /// music are left alone (an export or a download may be what's running).
    public static func pausesByDefault(category: String?) -> Bool {
        guard let category else { return false }
        return category == "public.app-category.social-networking"
            || category == "public.app-category.entertainment"
            || category == "public.app-category.games"
            || (category.hasPrefix("public.app-category.") && category.hasSuffix("-games"))
    }

    /// macOS's own apps and Tutto are never paused.
    public static func canPause(_ app: AwakeApp) -> Bool {
        !app.bundleID.hasPrefix("com.apple.") && !app.bundleID.hasPrefix("ca.bryanyao.Tutto")
    }

    /// The user's choice wins; otherwise the category decides.
    public static func pauses(_ app: AwakeApp, choices: [String: Bool]) -> Bool {
        guard canPause(app) else { return false }
        return choices[app.bundleID] ?? pausesByDefault(category: app.category)
    }
}

// MARK: - Process trees

public enum ProcessTree {
    /// `root` and everything it started, children before their parents (the order to stop them
    /// in is the reverse: parent first, so it can't react to a child stopping).
    public static func family(of root: Int32, parents: [Int32: Int32]) -> [Int32] {
        var children: [Int32: [Int32]] = [:]
        for (pid, parent) in parents where pid != parent { children[parent, default: []].append(pid) }
        var order: [Int32] = []
        var seen: Set<Int32> = [root]
        var stack = [root]
        while let pid = stack.popLast() {
            order.append(pid)
            for child in children[pid, default: []].sorted() where seen.insert(child).inserted { stack.append(child) }
        }
        return order.reversed()
    }

    /// pid → parent pid for every process owned by `uid`.
    public static func parents(ownedBy uid: uid_t = getuid()) -> [Int32: Int32] {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: uid)]
        var size = 0
        guard sysctl(&name, 4, nil, &size, nil, 0) == 0, size > 0 else { return [:] }
        size += 16 * MemoryLayout<kinfo_proc>.stride  // room for processes started meanwhile
        var list = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&name, 4, &list, &size, nil, 0) == 0 else { return [:] }
        var result: [Int32: Int32] = [:]
        for info in list.prefix(size / MemoryLayout<kinfo_proc>.stride) {
            result[info.kp_proc.p_pid] = info.kp_eproc.e_ppid
        }
        return result
    }
}

// MARK: - Hotspot fallback

/// When the network drops during a session, when to try joining the hotspot: after 5 s without
/// a network, then again after 5, 10, 20 and every 30 s until the network is back. Pure: the
/// caller owns the clock, the timer and the join.
public struct HotspotFailover: Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        case join
        case retry(after: TimeInterval)
        case recovered(after: TimeInterval)
    }

    public static let firstDelay: TimeInterval = 5
    public static let backoff: [TimeInterval] = [5, 10, 20, 30]

    public private(set) var outageStart: Date?
    public private(set) var joins = 0
    public private(set) var nextAttempt: Date?

    public init() {}

    public var inOutage: Bool { outageStart != nil }

    public static func delay(afterJoin n: Int) -> TimeInterval {
        backoff[min(max(n - 1, 0), backoff.count - 1)]
    }

    public mutating func networkLost(at now: Date) -> [Step] {
        guard outageStart == nil else { return [] }
        outageStart = now
        joins = 0
        nextAttempt = now.addingTimeInterval(Self.firstDelay)
        return [.retry(after: Self.firstDelay)]
    }

    public mutating func networkBack(at now: Date) -> [Step] {
        guard let start = outageStart else { return [] }
        outageStart = nil
        joins = 0
        nextAttempt = nil
        return [.recovered(after: max(0, now.timeIntervalSince(start)))]
    }

    public mutating func timerFired(at now: Date) -> [Step] {
        guard outageStart != nil, let due = nextAttempt, now >= due else { return [] }
        joins += 1
        let delay = Self.delay(afterJoin: joins)
        nextAttempt = now.addingTimeInterval(delay)
        return [.join, .retry(after: delay)]
    }
}
