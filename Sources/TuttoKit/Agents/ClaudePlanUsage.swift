//
//  ClaudePlanUsage.swift
//  TuttoKit
//
//  Claude's limits as Claude itself counts them, the numbers its Settings → Usage page shows
//  ("5-hour limit 5 %", "Weekly · all models 63 %"). The estimate from Claude Code's transcripts
//  (AgentUsage.swift) can't see chats on claude.ai or in the desktop app, and read 27 % where
//  Claude said 63 % (Bryan, 2026-11-24). Read the way the open-source usage apps read it (CodexBar,
//  MIT; TokenEater, MIT): Claude Code's own sign-in from the Keychain, and
//  `GET https://api.anthropic.com/api/oauth/usage` with `anthropic-beta: oauth-2025-04-20`.
//

import Foundation

/// Claude Code's sign-in, as it keeps it in the Keychain (`Claude Code-credentials`).
public struct ClaudeSignIn: Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    /// When the access token stops working.
    public var expiresAt: Date?
    public var scopes: [String]

    /// The whole stored item, kept so a renewed sign-in is written back with nothing else lost.
    public var stored: [String: Any] { storedJSON }
    private var storedJSON: [String: Any]

    public static func == (a: ClaudeSignIn, b: ClaudeSignIn) -> Bool {
        a.accessToken == b.accessToken && a.refreshToken == b.refreshToken && a.expiresAt == b.expiresAt && a.scopes == b.scopes
    }

    /// From the item's JSON: `{"claudeAiOauth":{"accessToken","refreshToken","expiresAt" (ms),"scopes"}}`.
    /// Nil when it has no Claude sign-in (Claude Code 2.1 can keep only MCP sign-ins there).
    public init?(json: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        accessToken = token
        refreshToken = oauth["refreshToken"] as? String
        expiresAt = (oauth["expiresAt"] as? NSNumber).map { Self.date(fromEpoch: $0.doubleValue) }
        scopes = oauth["scopes"] as? [String] ?? []
        storedJSON = root
    }

    /// Reading usage needs the profile scope (a `claude setup-token` token is inference only).
    public var canReadUsage: Bool { scopes.isEmpty || scopes.contains("user:profile") }

    public func isExpired(now: Date, margin: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) < margin
    }

    /// The item with a renewed token in it (everything else as it was).
    public func renewed(accessToken: String, refreshToken: String?, expiresIn: TimeInterval, now: Date) -> Data? {
        var root = storedJSON
        var oauth = root["claudeAiOauth"] as? [String: Any] ?? [:]
        oauth["accessToken"] = accessToken
        if let refreshToken { oauth["refreshToken"] = refreshToken }
        oauth["expiresAt"] = Int64((now.timeIntervalSince1970 + expiresIn) * 1000)
        root["claudeAiOauth"] = oauth
        return try? JSONSerialization.data(withJSONObject: root)
    }

    /// Milliseconds since 1970 as Claude Code writes it; seconds tolerated.
    static func date(fromEpoch value: Double) -> Date {
        Date(timeIntervalSince1970: value > 1e11 ? value / 1000 : value)
    }
}

/// One reading of `/api/oauth/usage`.
public struct ClaudePlanUsage: Equatable, Sendable {
    public struct Window: Equatable, Sendable {
        /// 0–100.
        public var percent: Double
        public var resetsAt: Date?
    }

    public var fiveHour: Window?
    public var week: Window?
    public var at: Date

    /// `{"five_hour":{"utilization":5.0,"resets_at":"2026-11-24T19:50:00.12+00:00"},"seven_day":{…}}`;
    /// a window is null on plans without it. Utilization is a percent (0–100).
    public init?(json: Data, at: Date) {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return nil }
        func window(_ key: String) -> Window? {
            guard let entry = root[key] as? [String: Any], let used = (entry["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return Window(percent: min(max(used, 0), 100), resetsAt: (entry["resets_at"] as? String).flatMap(Self.date))
        }
        fiveHour = window("five_hour")
        week = window("seven_day")
        self.at = at
        guard fiveHour != nil || week != nil else { return nil }
    }

    public init(fiveHour: Window?, week: Window?, at: Date) {
        self.fiveHour = fiveHour
        self.week = week
        self.at = at
    }

    /// ISO 8601 with or without fractional seconds, `Z` or `+00:00`.
    static func date(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? plain.date(from: text)
    }

    /// As the card shows limits: exact, with the pace from earlier readings of the same window.
    public func limits(samples: [ClaudePlanUsage], now: Date) -> AgentLimits {
        func estimate(_ kind: LimitEstimate.Window, _ window: Window?, _ pick: (ClaudePlanUsage) -> Window?) -> LimitEstimate? {
            guard let window else { return nil }
            if let resets = window.resetsAt, resets <= now { return LimitEstimate(window: kind, percent: 0, resetsAt: nil, exact: true) }
            let same = samples.compactMap { reading -> (Date, Double)? in
                guard let w = pick(reading), w.resetsAt == window.resetsAt else { return nil }
                return (reading.at, w.percent)
            }
            return LimitEstimate(window: kind, percent: window.percent, resetsAt: window.resetsAt, reached: window.percent >= 100,
                                 limitAt: LimitPace.limitAt(samples: same, current: window.percent, now: now, resetsAt: window.resetsAt),
                                 exact: true)
        }
        return AgentLimits(tool: .claude,
                           fiveHour: estimate(.fiveHour, fiveHour) { $0.fiveHour },
                           week: estimate(.week, week) { $0.week })
    }
}
