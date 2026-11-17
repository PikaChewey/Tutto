//
//  AgentSessions.swift
//  TuttoKit
//
//  The coding agents running on this Mac, read from what they already write down (nothing is
//  asked of them, nothing is changed): Claude Code keeps a record per running session in
//  ~/.claude/sessions/<pid>.json, with its name, folder and state (busy, waiting with what for,
//  idle); Codex writes each thread's events to ~/.codex/sessions/…/rollout-*.jsonl (a turn
//  started, finished, stopped) and its names to ~/.codex/session_index.jsonl. Codex doesn't log
//  approval requests, so a Codex thread is working or done, never "needs you".
//

import Foundation

/// Which coding agent.
public enum AgentTool: String, Codable, Sendable, CaseIterable {
    case claude, codex

    public var name: String { self == .claude ? "Claude" : "Codex" }
}

/// What a session is doing, most urgent first.
public enum AgentActivity: Equatable, Sendable {
    /// Stopped on you: a question, an approval, input. `reason` is the agent's own words.
    case needsYou(String?)
    case working
    /// Finished its turn: your move.
    case yourTurn

    /// Sort order: what needs you first.
    public var rank: Int {
        switch self {
        case .needsYou: 0
        case .working: 1
        case .yourTurn: 2
        }
    }

    public var needsYou: Bool { if case .needsYou = self { true } else { false } }
}

/// Where a session runs, which decides how to bring it to the front.
public enum AgentHost: String, Codable, Sendable {
    /// A Code session inside Claude's app (opened with `claude://code/continue?session=…`).
    case claudeApp
    /// A thread in the Codex app (opened with `codex://threads/…`).
    case codexApp
    /// A terminal, an editor, anything else: the app above the agent's process.
    case other
}

/// One session, whichever agent runs it.
public struct AgentSession: Identifiable, Equatable, Sendable {
    public var tool: AgentTool
    /// The agent's own id for it (Claude's session id, Codex's thread id).
    public var sessionID: String
    public var name: String
    /// Its working folder.
    public var folder: String
    public var activity: AgentActivity
    /// When the current activity began.
    public var since: Date
    public var started: Date?
    /// The agent's process, when it has its own.
    public var pid: Int32?
    public var host: AgentHost
    /// The host app's id for it (Claude's `local_…` session), to open that exact session.
    public var hostSessionID: String?
    /// Run by a schedule or a script, not someone at a prompt.
    public var isBackground: Bool

    public var id: String { "\(tool.rawValue):\(sessionID)" }

    public init(tool: AgentTool, sessionID: String, name: String, folder: String, activity: AgentActivity, since: Date,
                started: Date? = nil, pid: Int32? = nil, host: AgentHost, hostSessionID: String? = nil, isBackground: Bool = false) {
        self.tool = tool
        self.sessionID = sessionID
        self.name = name
        self.folder = folder
        self.activity = activity
        self.since = since
        self.started = started
        self.pid = pid
        self.host = host
        self.hostSessionID = hostSessionID
        self.isBackground = isBackground
    }

    /// The link that opens this session in its app, when its app has one.
    public var openURL: URL? {
        switch host {
        case .claudeApp:
            guard let local = hostSessionID, local.hasPrefix("local_") else { return URL(string: "claude://code/continue?session=last") }
            return URL(string: "claude://code/continue?session=\(local)")
        case .codexApp:
            return URL(string: "codex://threads/\(sessionID)")
        case .other:
            return nil
        }
    }

    /// Needs you first, then working, then your turn; the most recent change first within each.
    public static func ordered(_ sessions: [AgentSession]) -> [AgentSession] {
        sessions.sorted { a, b in
            if a.activity.rank != b.activity.rank { return a.activity.rank < b.activity.rank }
            if a.since != b.since { return a.since > b.since }
            return a.id < b.id
        }
    }

    /// A folder as people say it: "~/Projects/site", a scratch space as "Scratch".
    public static func displayFolder(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path.contains("/scratch-workspaces/") { return "Scratch" }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

// MARK: - Claude Code

/// `~/.claude/sessions/<pid>.json`, as Claude Code writes it for each running session.
public struct ClaudeSessionRecord: Decodable, Equatable, Sendable {
    public var pid: Int32
    public var sessionId: String
    public var cwd: String
    /// Milliseconds since 1970.
    public var startedAt: Double?
    public var kind: String?
    public var entrypoint: String?
    public var name: String?
    public var status: String?
    public var statusUpdatedAt: Double?
    public var updatedAt: Double?
    public var waitingFor: String?
    public var hostSessionId: String?

    public static func decode(_ data: Data) -> ClaudeSessionRecord? {
        try? JSONDecoder().decode(ClaudeSessionRecord.self, from: data)
    }

    /// The session as the list shows it.
    public func session(home: String = NSHomeDirectory()) -> AgentSession {
        let activity: AgentActivity = switch status {
        case "busy": .working
        case "waiting": .needsYou(waitingFor.flatMap { $0.isEmpty ? nil : $0 })
        default: .yourTurn
        }
        let changed = (statusUpdatedAt ?? updatedAt ?? startedAt).map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantPast
        let title = name.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            ?? Self.folderName(cwd, home: home)
        return AgentSession(tool: .claude, sessionID: sessionId, name: title, folder: cwd, activity: activity, since: changed,
                            started: startedAt.map { Date(timeIntervalSince1970: $0 / 1000) }, pid: pid,
                            host: entrypoint == "claude-desktop" ? .claudeApp : .other, hostSessionID: hostSessionId,
                            isBackground: kind.map { $0 != "interactive" } ?? false)
    }

    static func folderName(_ path: String, home: String) -> String {
        if path.contains("/scratch-workspaces/") { return "Scratch session" }
        if path == home || path.isEmpty { return "Home folder" }
        return (path as NSString).lastPathComponent
    }
}

// MARK: - Codex

/// What one Codex rollout file says about its thread so far. Fed line by line, from the start or
/// from where the last read ended.
public struct CodexThreadState: Equatable, Sendable {
    public var threadID: String?
    public var folder: String?
    public var fromApp = false
    public var lastStarted: Date?
    public var lastFinished: Date?
    public var lastEvent: Date?
    /// The latest limits it reported.
    public var limits: CodexLimitReading?
    /// Recent readings of the 5-hour limit, for its pace (kept to the last few hours).
    public var samples: [CodexLimitReading] = []

    public init() {}

    /// Working: a turn began and hasn't ended, and something was written lately (an app that quit
    /// mid-turn leaves it unfinished forever).
    public func activity(now: Date, staleAfter: TimeInterval = 600) -> AgentActivity {
        if let started = lastStarted, (lastFinished.map { started > $0 } ?? true),
           let last = lastEvent, now.timeIntervalSince(last) < staleAfter {
            return .working
        }
        return .yourTurn
    }

    /// When its current state began.
    public var since: Date? {
        guard let started = lastStarted else { return lastFinished ?? lastEvent }
        if let finished = lastFinished, finished > started { return finished }
        return started
    }

    public mutating func read(line: Substring) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let time = (object["timestamp"] as? String).flatMap(ISOTime.parse)
        if let time { lastEvent = max(lastEvent ?? time, time) }
        let payload = object["payload"] as? [String: Any] ?? [:]
        switch object["type"] as? String {
        case "session_meta":
            threadID = payload["id"] as? String ?? payload["session_id"] as? String ?? threadID
            folder = payload["cwd"] as? String ?? folder
            let origin = (payload["originator"] as? String ?? "").lowercased()
            fromApp = origin.contains("desktop")
        case "event_msg":
            switch payload["type"] as? String {
            case "task_started": if let time { lastStarted = time }
            case "task_complete", "turn_aborted": if let time { lastFinished = time }
            case "token_count":
                if let limits = payload["rate_limits"] as? [String: Any], let reading = CodexLimitReading(limits, at: time) {
                    self.limits = reading
                    samples.append(reading)
                    if let first = samples.first, let last = samples.last, last.at.timeIntervalSince(first.at) > 6 * 3600 {
                        samples.removeAll { last.at.timeIntervalSince($0.at) > 6 * 3600 }
                    }
                }
            default: break
            }
        default: break
        }
    }

    /// The thread as the list shows it, named from Codex's index when it has a name.
    public func session(name: String?, now: Date, home: String = NSHomeDirectory()) -> AgentSession? {
        guard let id = threadID else { return nil }
        let folder = self.folder ?? home
        let title = name.flatMap { $0.isEmpty ? nil : $0 } ?? ClaudeSessionRecord.folderName(folder, home: home)
        return AgentSession(tool: .codex, sessionID: id, name: title, folder: folder, activity: activity(now: now),
                            since: since ?? now, started: nil, pid: nil, host: fromApp ? .codexApp : .other)
    }
}

/// One `rate_limits` report from Codex: the 5-hour and weekly windows, exactly.
public struct CodexLimitReading: Equatable, Sendable {
    public var at: Date
    public var fiveHour: Double?
    public var fiveHourResets: Date?
    public var week: Double?
    public var weekResets: Date?

    public init(at: Date, fiveHour: Double?, fiveHourResets: Date?, week: Double?, weekResets: Date?) {
        self.at = at
        self.fiveHour = fiveHour
        self.fiveHourResets = fiveHourResets
        self.week = week
        self.weekResets = weekResets
    }

    init?(_ limits: [String: Any], at time: Date?) {
        func window(_ key: String) -> (Double?, Date?, Double?) {
            guard let w = limits[key] as? [String: Any] else { return (nil, nil, nil) }
            let used = (w["used_percent"] as? NSNumber)?.doubleValue
            let resets = (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            let minutes = (w["window_minutes"] as? NSNumber)?.doubleValue
            return (used, resets, minutes)
        }
        let primary = window("primary"), secondary = window("secondary")
        guard primary.0 != nil || secondary.0 != nil, let time else { return nil }
        // Usually primary is the 5-hour window and secondary the week; go by their lengths when given.
        let primaryIsWeek = (primary.2 ?? 300) > 1440
        self.init(at: time,
                  fiveHour: primaryIsWeek ? secondary.0 : primary.0, fiveHourResets: primaryIsWeek ? secondary.1 : primary.1,
                  week: primaryIsWeek ? primary.0 : secondary.0, weekResets: primaryIsWeek ? primary.1 : secondary.1)
    }
}

/// `~/.codex/session_index.jsonl`: thread names, the last line for an id winning.
public enum CodexIndex {
    public static func names(_ text: String) -> [String: String] {
        var names: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["id"] as? String, let name = object["thread_name"] as? String else { continue }
            names[id] = name
        }
        return names
    }
}

/// ISO 8601 times as agents write them ("2026-11-17T03:05:43.838Z", "2026-10-21T23:59:59.925692+00:00"),
/// quickly (thousands of lines a second go through this).
public enum ISOTime {
    public static func parse(_ text: String) -> Date? {
        let b = Array(text.utf8)
        guard b.count >= 19, b[4] == 45, b[7] == 45, b[10] == 84 || b[10] == 32, b[13] == 58, b[16] == 58 else { return nil }
        func number(_ from: Int, _ length: Int) -> Int? {
            var value = 0
            for i in from..<(from + length) {
                guard b[i] >= 48, b[i] <= 57 else { return nil }
                value = value * 10 + Int(b[i] - 48)
            }
            return value
        }
        guard let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
              let hour = number(11, 2), let minute = number(14, 2), let second = number(17, 2), year > 1970 else { return nil }
        var i = 19
        var fraction = 0.0
        if i < b.count, b[i] == 46 {
            var scale = 0.1
            i += 1
            while i < b.count, b[i] >= 48, b[i] <= 57 { fraction += Double(b[i] - 48) * scale; scale /= 10; i += 1 }
        }
        var offset = 0
        if i < b.count {
            switch b[i] {
            case 90: i += 1  // Z
            case 43, 45:  // +HH:MM / -HH:MM
                guard b.count >= i + 6, b[i + 3] == 58, let h = number(i + 1, 2), let m = number(i + 4, 2) else { return nil }
                offset = (h * 3600 + m * 60) * (b[i] == 43 ? 1 : -1)
                i += 6
            default: return nil
            }
        }
        guard i == b.count else { return nil }
        var t = tm()
        t.tm_year = Int32(year - 1900); t.tm_mon = Int32(month - 1); t.tm_mday = Int32(day)
        t.tm_hour = Int32(hour); t.tm_min = Int32(minute); t.tm_sec = Int32(second)
        return Date(timeIntervalSince1970: Double(timegm(&t) - offset) + fraction)
    }
}
