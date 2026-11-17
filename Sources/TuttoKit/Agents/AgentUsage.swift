//
//  AgentUsage.swift
//  TuttoKit
//
//  How close the agents are to their usage limits, and when they'd reach them at the current pace.
//
//  Codex writes its limits into its own logs, exactly: each `token_count` event carries the 5-hour
//  and weekly windows' percent used and when they reset. Claude Code doesn't: its limits reach
//  only the terminal status line, which the desktop app's sessions don't run. So Claude's are
//  estimated from its transcripts:
//  - every reply's tokens, weighted by the model's API price (Opus burns limits faster than
//    Sonnet), each reply counted once (it's written once per content block, and again when a
//    session is resumed);
//  - the 5-hour window starts with the first message after the last one ended; the week resets at
//    a fixed hour, taken from Claude's own record of it;
//  - the limit itself is learned from this Mac: the moment Claude said "You've hit your session
//    limit" (the window was at 100 % then), or a /usage reading Claude Code kept, the most recent
//    one, raised by any later window that went further without hitting it.
//  Checked against a real reading on this Mac: 82 % estimated where /usage said 79 %. Claude chats
//  outside Claude Code count toward the same limits and aren't in these logs, so Claude's numbers
//  are marked as estimates.
//

import Foundation

// MARK: - What's shown

/// One limit window's state.
public struct LimitEstimate: Equatable, Sendable {
    public enum Window: String, Sendable { case fiveHour, week }

    public var window: Window
    /// 0–100.
    public var percent: Double
    public var resetsAt: Date?
    /// The agent said the limit was reached in this window.
    public var reached = false
    /// When it would reach 100 % at the last hour's rate, if that's before it resets.
    public var limitAt: Date?
    /// Read from the agent (Codex), not estimated (Claude).
    public var exact: Bool

    public init(window: Window, percent: Double, resetsAt: Date?, reached: Bool = false, limitAt: Date? = nil, exact: Bool) {
        self.window = window
        self.percent = percent
        self.resetsAt = resetsAt
        self.reached = reached
        self.limitAt = limitAt
        self.exact = exact
    }

    /// Worth a word in the menu bar: reached, nearly full, or on course to run out before it resets.
    public func matters(now: Date) -> Bool {
        reached || percent >= 85 || (limitAt.map { $0.timeIntervalSince(now) < 45 * 60 } ?? false)
    }
}

/// An agent's limits.
public struct AgentLimits: Equatable, Sendable {
    public var tool: AgentTool
    public var fiveHour: LimitEstimate?
    public var week: LimitEstimate?
    /// What Claude's estimate rests on ("the weekly limit you reached Nov 11").
    public var basis: String?

    public init(tool: AgentTool, fiveHour: LimitEstimate?, week: LimitEstimate?, basis: String? = nil) {
        self.tool = tool
        self.fiveHour = fiveHour
        self.week = week
        self.basis = basis
    }

    /// The window that constrains you now: one that's reached, else the one that runs out first at
    /// this pace, else the fuller one.
    public var headline: LimitEstimate? {
        let windows = [fiveHour, week].compactMap { $0 }
        if let reached = windows.first(where: \.reached) { return reached }
        let paced = windows.filter { $0.limitAt != nil }.min { $0.limitAt! < $1.limitAt! }
        return paced ?? windows.max { $0.percent < $1.percent }
    }
}

// MARK: - Pace

public enum LimitPace {
    /// When `current` percent reaches 100 at the rate seen over `samples` (time, percent), if that's
    /// before `resetsAt`. Needs readings at least 10 minutes apart in the last hour, rising.
    public static func limitAt(samples: [(Date, Double)], current: Double, now: Date, resetsAt: Date?,
                               lookback: TimeInterval = 3600) -> Date? {
        guard current < 100 else { return nil }
        let recent = samples.filter { now.timeIntervalSince($0.0) <= lookback && $0.0 <= now }.sorted { $0.0 < $1.0 }
        guard let first = recent.first, let last = recent.last, last.0.timeIntervalSince(first.0) >= 600 else { return nil }
        let rate = (last.1 - first.1) / last.0.timeIntervalSince(first.0)  // percent per second
        guard rate > 0 else { return nil }
        let at = now.addingTimeInterval((100 - current) / rate)
        if let resetsAt, at >= resetsAt { return nil }
        return at
    }
}

// MARK: - Codex (exact)

public enum CodexLimits {
    /// The latest reading, as of `now` (a window that has reset since reads 0 %), with its pace.
    public static func limits(latest: CodexLimitReading?, samples: [CodexLimitReading], now: Date) -> AgentLimits? {
        guard let latest else { return nil }
        func window(_ kind: LimitEstimate.Window, _ used: Double?, _ resets: Date?, _ pick: (CodexLimitReading) -> (Double?, Date?)) -> LimitEstimate? {
            guard let used else { return nil }
            if let resets, resets <= now { return LimitEstimate(window: kind, percent: 0, resetsAt: nil, exact: true) }
            // Only readings from this same window count toward its pace.
            let same = samples.compactMap { reading -> (Date, Double)? in
                let (u, r) = pick(reading)
                guard let u, r == resets else { return nil }
                return (reading.at, u)
            }
            return LimitEstimate(window: kind, percent: min(max(used, 0), 100), resetsAt: resets, reached: used >= 100,
                                 limitAt: LimitPace.limitAt(samples: same, current: used, now: now, resetsAt: resets), exact: true)
        }
        return AgentLimits(tool: .codex,
                           fiveHour: window(.fiveHour, latest.fiveHour, latest.fiveHourResets) { ($0.fiveHour, $0.fiveHourResets) },
                           week: window(.week, latest.week, latest.weekResets) { ($0.week, $0.weekResets) })
    }
}

// MARK: - Claude (estimated)

/// One Claude reply's cost, in API dollars (the weight its tokens carry against the limits).
public struct ClaudeUsageEvent: Equatable, Sendable {
    public var time: Date
    public var cost: Double
    /// The reply's identity (message and request id), to count it once.
    public var key: UInt64

    public init(time: Date, cost: Double, key: UInt64) {
        self.time = time
        self.cost = cost
        self.key = key
    }
}

/// Claude saying a limit was reached.
public struct ClaudeLimitHit: Equatable, Sendable {
    public enum Kind: String, Sendable { case session, weekly }
    public var time: Date
    public var kind: Kind

    public init(time: Date, kind: Kind) {
        self.time = time
        self.kind = kind
    }
}

/// The last /usage reading Claude Code kept in ~/.claude.json.
public struct ClaudeUsageSnapshot: Equatable, Sendable {
    public var fetched: Date
    public var fiveHour: Double?
    public var fiveHourResets: Date?
    public var week: Double?
    public var weekResets: Date?

    public init(fetched: Date, fiveHour: Double?, fiveHourResets: Date?, week: Double?, weekResets: Date?) {
        self.fetched = fetched
        self.fiveHour = fiveHour
        self.fiveHourResets = fiveHourResets
        self.week = week
        self.weekResets = weekResets
    }

    /// From the whole of ~/.claude.json (`cachedUsageUtilization`).
    public static func parse(_ data: Data) -> ClaudeUsageSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cached = root["cachedUsageUtilization"] as? [String: Any],
              let fetchedMS = (cached["fetchedAtMs"] as? NSNumber)?.doubleValue,
              let use = cached["utilization"] as? [String: Any] else { return nil }
        func window(_ key: String) -> (Double?, Date?) {
            guard let w = use[key] as? [String: Any] else { return (nil, nil) }
            return ((w["utilization"] as? NSNumber)?.doubleValue, (w["resets_at"] as? String).flatMap(ISOTime.parse))
        }
        let five = window("five_hour"), week = window("seven_day")
        return ClaudeUsageSnapshot(fetched: Date(timeIntervalSince1970: fetchedMS / 1000), fiveHour: five.0, fiveHourResets: five.1,
                                   week: week.0, weekResets: week.1)
    }
}

/// API prices per million tokens: input, output, cache read (a cache write is input × 1.25).
public enum ClaudePricing {
    public static func prices(model: String) -> (input: Double, output: Double, cacheRead: Double) {
        switch model {
        case "claude-fable-5-2": (8, 40, 0.2)
        case "claude-fable-5-1", "claude-fable-5": (10, 50, 1)
        case "claude-opus-5-5": (4, 20, 0.2)
        case "claude-opus-5": (5, 25, 0.5)
        case "claude-sonnet-5-5": (2, 10, 0.1)
        case "claude-sonnet-5": (2, 10, 0.2)
        case "claude-haiku-5-5": (0.1, 0.5, 0.01)
        default:
            if model.contains("fable") || model.contains("mythos") { (8, 40, 0.2) }
            else if model.contains("sonnet") { (2, 10, 0.1) }
            else if model.contains("haiku") { (1, 5, 0.1) }
            else { (4, 20, 0.2) }  // Opus, and anything new: the default model's weight
        }
    }

    public static func cost(model: String, input: Int, output: Int, cacheWrite: Int, cacheRead: Int) -> Double {
        let p = prices(model: model)
        return (Double(input) * p.input + Double(output) * p.output + Double(cacheWrite) * p.input * 1.25
                + Double(cacheRead) * p.cacheRead) / 1_000_000
    }
}

/// Reads Claude Code transcript lines (JSONL) for replies' usage and limit messages, without
/// decoding whole lines: a transcript is mostly tool output and pictures, and there are gigabytes.
public enum ClaudeLogScanner {
    public struct Found: Sendable {
        public var events: [ClaudeUsageEvent] = []
        public var hits: [ClaudeLimitHit] = []
        public init() {}
    }

    /// Scans the complete lines in `bytes` and returns how many bytes they took (a last line without
    /// its newline is still being written, and is read next time).
    @discardableResult
    public static func scan(_ bytes: UnsafeRawBufferPointer, into found: inout Found) -> Int {
        guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), bytes.count > 0 else { return 0 }
        var start = 0
        while start < bytes.count {
            guard let newline = memchr(base + start, 0x0A, bytes.count - start) else { break }
            let end = base.distance(to: newline.assumingMemoryBound(to: UInt8.self))
            line(UnsafeBufferPointer(start: base + start, count: end - start), into: &found)
            start = end + 1
        }
        return start
    }

    public static func scan(_ data: Data, into found: inout Found) -> Int {
        data.withUnsafeBytes { scan($0, into: &found) }
    }

    private static let assistant = Array(#""type":"assistant""#.utf8)
    private static let usage = Array(#""usage":{"#.utf8)
    /// Only Claude's own error field (a quote of the message inside a conversation is escaped).
    private static let rateLimit = Array(#""error":"rate_limit""#.utf8)
    private static let hitYour = Array("hit your ".utf8)
    private static let timestamp = Array(#""timestamp":""#.utf8)
    private static let model = Array(#""model":""#.utf8)
    private static let messageID = Array(#""id":"msg_"#.utf8)
    private static let requestID = Array(#""requestId":""#.utf8)
    private static let tokenKeys = [#""input_tokens":"#, #""output_tokens":"#, #""cache_creation_input_tokens":"#,
                                    #""cache_read_input_tokens":"#].map { Array($0.utf8) }

    static func line(_ line: UnsafeBufferPointer<UInt8>, into found: inout Found) {
        if find(rateLimit, in: line) != nil, let hit = find(hitYour, in: line) {
            // "You've hit your session limit · resets 7:10am" / "…your weekly limit…"
            let after = UnsafeBufferPointer(rebasing: line[(hit + hitYour.count)...])
            let word = String(decoding: after.prefix(8), as: UTF8.self)
            let kind: ClaudeLimitHit.Kind? = word.hasPrefix("session") ? .session : word.hasPrefix("weekly") ? .weekly : nil
            if let kind, let time = lastString(timestamp, in: line).flatMap(ISOTime.parse) {
                found.hits.append(ClaudeLimitHit(time: time, kind: kind))
            }
            return
        }
        guard find(assistant, in: line) != nil, let usageAt = findLast(usage, in: line) else { return }
        // The top-level timestamp is the line's last; the reply's model and id come first in its message.
        guard let time = lastString(timestamp, in: line).flatMap(ISOTime.parse) else { return }
        let modelName = string(after: model, in: line) ?? ""
        var key: UInt64 = 0xcbf2_9ce4_8422_2325
        if let id = range(after: messageID, in: line) { key = fnv(line, id, key) }
        if let request = range(after: requestID, in: line) { key = fnv(line, request, key) }
        let block = UnsafeBufferPointer(rebasing: line[usageAt..<min(line.count, usageAt + 700)])
        let counts = tokenKeys.map { number(after: $0, in: block) }
        let cost = ClaudePricing.cost(model: modelName, input: counts[0], output: counts[1], cacheWrite: counts[2], cacheRead: counts[3])
        found.events.append(ClaudeUsageEvent(time: time, cost: cost, key: key))
    }

    // MARK: Bytes

    static func find(_ needle: [UInt8], in hay: UnsafeBufferPointer<UInt8>, from: Int = 0) -> Int? {
        guard let base = hay.baseAddress, hay.count - from >= needle.count, from >= 0 else { return nil }
        return needle.withUnsafeBytes { n -> Int? in
            guard let hit = memmem(base + from, hay.count - from, n.baseAddress, needle.count) else { return nil }
            return base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
        }
    }

    static func findLast(_ needle: [UInt8], in hay: UnsafeBufferPointer<UInt8>) -> Int? {
        var last: Int?
        var from = 0
        while let at = find(needle, in: hay, from: from) {
            last = at
            from = at + needle.count
        }
        return last
    }

    /// The characters after `key` up to the closing quote.
    static func range(after key: [UInt8], in hay: UnsafeBufferPointer<UInt8>, from: Int? = nil) -> Range<Int>? {
        guard let at = from ?? find(key, in: hay) else { return nil }
        let start = at + key.count
        var end = start
        while end < hay.count, hay[end] != 0x22, end - start < 120 { end += 1 }
        return end < hay.count && hay[end] == 0x22 ? start..<end : nil
    }

    static func string(after key: [UInt8], in hay: UnsafeBufferPointer<UInt8>) -> String? {
        range(after: key, in: hay).map { String(decoding: UnsafeBufferPointer(rebasing: hay[$0]), as: UTF8.self) }
    }

    static func lastString(_ key: [UInt8], in hay: UnsafeBufferPointer<UInt8>) -> String? {
        guard let at = findLast(key, in: hay), let r = range(after: key, in: hay, from: at) else { return nil }
        return String(decoding: UnsafeBufferPointer(rebasing: hay[r]), as: UTF8.self)
    }

    static func number(after key: [UInt8], in hay: UnsafeBufferPointer<UInt8>) -> Int {
        guard let at = find(key, in: hay) else { return 0 }
        var i = at + key.count, value = 0
        while i < hay.count, hay[i] == 0x20 { i += 1 }
        while i < hay.count, hay[i] >= 48, hay[i] <= 57 { value = value &* 10 &+ Int(hay[i] - 48); i += 1 }
        return value
    }

    static func fnv(_ hay: UnsafeBufferPointer<UInt8>, _ range: Range<Int>, _ seed: UInt64) -> UInt64 {
        var hash = seed
        for i in range { hash = (hash ^ UInt64(hay[i])) &* 0x0000_0100_0000_01B3 }
        return hash
    }
}

/// Claude's limits, estimated from its replies on this Mac.
public enum ClaudeLimitEstimator {
    public static let fiveHours: TimeInterval = 5 * 3600
    public static let week: TimeInterval = 7 * 86400

    /// `events` in time order, each reply once.
    public static func estimate(events: [ClaudeUsageEvent], hits: [ClaudeLimitHit], snapshot: ClaudeUsageSnapshot?,
                                now: Date) -> AgentLimits? {
        guard !events.isEmpty || snapshot != nil else { return nil }
        let ledger = Ledger(events)
        let fiveHour = fiveHourEstimate(ledger, hits: hits.filter { $0.kind == .session }, snapshot: snapshot, now: now)
        let weekly = weekEstimate(ledger, hits: hits.filter { $0.kind == .weekly }, snapshot: snapshot, now: now)
        guard fiveHour != nil || weekly != nil else { return nil }
        return AgentLimits(tool: .claude, fiveHour: fiveHour?.0, week: weekly?.0, basis: weekly?.1 ?? fiveHour?.1)
    }

    /// Running totals over the replies, for any span's cost.
    struct Ledger {
        let times: [Date]
        let running: [Double]

        init(_ events: [ClaudeUsageEvent]) {
            times = events.map(\.time)
            var total = 0.0
            running = [0] + events.map { total += $0.cost; return total }
        }

        func index(_ date: Date) -> Int {
            var low = 0, high = times.count
            while low < high {
                let mid = (low + high) / 2
                if times[mid] < date { low = mid + 1 } else { high = mid }
            }
            return low
        }

        func cost(from: Date, to: Date) -> Double {
            guard to > from else { return 0 }
            return running[index(to)] - running[index(from)]
        }
    }

    /// 5-hour windows: each starts with the first reply after the last one ended.
    static func windows(_ ledger: Ledger) -> [(start: Date, end: Date)] {
        var result: [(Date, Date)] = []
        for time in ledger.times where result.last.map({ time >= $0.1 }) ?? true {
            result.append((time, time.addingTimeInterval(fiveHours)))
        }
        return result
    }

    static func fiveHourEstimate(_ ledger: Ledger, hits: [ClaudeLimitHit], snapshot: ClaudeUsageSnapshot?,
                                 now: Date) -> (LimitEstimate, String?)? {
        var windows = windows(ledger)
        // A /usage reading names its window's end exactly: use it for that window.
        if let snapshot, let resets = snapshot.fiveHourResets,
           let i = windows.firstIndex(where: { $0.start <= snapshot.fetched && snapshot.fetched < $0.end }) {
            windows[i] = (resets.addingTimeInterval(-fiveHours), resets)
        }
        // Calibration: the latest moment the window's fill is known.
        var points: [(time: Date, limit: Double, basis: String)] = []
        for hit in hits {
            guard let w = windows.last(where: { $0.start <= hit.time && hit.time < $0.end }) else { continue }
            let used = ledger.cost(from: w.start, to: hit.time)
            if used > 0 { points.append((hit.time, used, "the 5-hour limit you reached \(day(hit.time))")) }
        }
        if let snapshot, let percent = snapshot.fiveHour, percent >= 2, let resets = snapshot.fiveHourResets {
            let used = ledger.cost(from: resets.addingTimeInterval(-fiveHours), to: snapshot.fetched)
            if used > 0 { points.append((snapshot.fetched, used / (percent / 100), "Claude's /usage on \(day(snapshot.fetched))")) }
        }
        guard let calibration = points.max(by: { $0.time < $1.time }) else { return nil }
        // A later finished window that went further without a word from Claude: the limit is at least that.
        var limit = calibration.limit
        for w in windows where w.start > calibration.time && w.end <= now
            && !hits.contains(where: { w.start <= $0.time && $0.time < w.end }) {
            limit = max(limit, ledger.cost(from: w.start, to: w.end))
        }
        guard let current = windows.last, now < current.end, now >= current.start else {
            return (LimitEstimate(window: .fiveHour, percent: 0, resetsAt: nil, exact: false), calibration.basis)
        }
        let used = ledger.cost(from: current.start, to: now)
        let reached = hits.contains { current.start <= $0.time && $0.time < current.end }
        let percent = reached ? 100 : min(used / limit * 100, 99)
        return (LimitEstimate(window: .fiveHour, percent: percent, resetsAt: current.end, reached: reached,
                              limitAt: reached ? nil : pace(ledger, limit: limit, used: used, now: now, windowStart: current.start, resets: current.end),
                              exact: false), calibration.basis)
    }

    static func weekEstimate(_ ledger: Ledger, hits: [ClaudeLimitHit], snapshot: ClaudeUsageSnapshot?,
                             now: Date) -> (LimitEstimate, String?)? {
        // The week resets at a fixed hour; Claude's own reading says when.
        guard let anchor = snapshot?.weekResets else { return nil }
        func start(_ t: Date) -> Date {
            let weeks = (t.timeIntervalSince(anchor) / week).rounded(.down)
            return anchor.addingTimeInterval(weeks * week)
        }
        var points: [(time: Date, limit: Double, basis: String)] = []
        for hit in hits {
            let used = ledger.cost(from: start(hit.time), to: hit.time)
            if used > 0 { points.append((hit.time, used, "the weekly limit you reached \(day(hit.time))")) }
        }
        if let snapshot, let percent = snapshot.week, percent >= 5 {
            let used = ledger.cost(from: start(snapshot.fetched), to: snapshot.fetched)
            if used > 0 { points.append((snapshot.fetched, used / (percent / 100), "Claude's /usage on \(day(snapshot.fetched))")) }
        }
        guard let calibration = points.max(by: { $0.time < $1.time }) else { return nil }
        var limit = calibration.limit
        var weekStart = start(calibration.time).addingTimeInterval(week)
        while weekStart.addingTimeInterval(week) <= now {
            let end = weekStart.addingTimeInterval(week)
            if !hits.contains(where: { weekStart <= $0.time && $0.time < end }) {
                limit = max(limit, ledger.cost(from: weekStart, to: end))
            }
            weekStart = end
        }
        let current = start(now), end = current.addingTimeInterval(week)
        let used = ledger.cost(from: current, to: now)
        let reached = hits.contains { current <= $0.time && $0.time < end }
        let percent = reached ? 100 : min(used / limit * 100, 99)
        return (LimitEstimate(window: .week, percent: percent, resetsAt: end, reached: reached,
                              limitAt: reached ? nil : pace(ledger, limit: limit, used: used, now: now, windowStart: current, resets: end),
                              exact: false), calibration.basis)
    }

    /// At the spend of the last hour (or since the window began, if that's sooner, and at least 10
    /// minutes ago), when the window would fill, if that's before it resets.
    static func pace(_ ledger: Ledger, limit: Double, used: Double, now: Date, windowStart: Date, resets: Date) -> Date? {
        let from = max(now.addingTimeInterval(-3600), windowStart)
        let span = now.timeIntervalSince(from)
        let spent = ledger.cost(from: from, to: now)
        guard span >= 600, spent > 0, limit > used else { return nil }
        let at = now.addingTimeInterval((limit - used) / spent * span)
        return at < resets ? at : nil
    }

    static func day(_ date: Date) -> String {
        let format = DateFormatter()
        format.setLocalizedDateFormatFromTemplate("MMMd")
        return format.string(from: date)
    }
}
