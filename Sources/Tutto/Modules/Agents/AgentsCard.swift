//
//  AgentsCard.swift
//  Tutto
//
//  The Agents card on the menu bar panel. What needs you and what's working get a row each: the
//  app with its state in a badge, the name, and a soft accent pill only for the one waiting on you
//  (the rest a quiet time). A click opens that exact session; under the pointer a row says what it
//  costs and offers to stop it, asking in place. Finished sessions fold into one grey line. Then
//  what agents left running, any agent whose processes are multiplying, and each agent's limit as
//  a small meter side by side: the figure, a bar with a tick where an even pace would be, and when
//  it resets. Nothing shows that has nothing to say.
//

import SwiftUI
import TuttoKit

struct AgentsCard: View {
    @Bindable var agents: AgentsModule
    /// On the Customize page: shown, not used.
    var placeholder = false
    @State var confirming: String?
    @State var confirmingLeftovers = false
    @State var allUnread = false

    /// Rows for sessions that need you or are working; past that, "N more".
    static let rows = 4
    /// Rows for unread chats, until "N more unread" shows the rest (up to `unreadMax`).
    static let unreadRows = 3
    static let unreadMax = 12

    var body: some View {
        let sessions = AgentSession.shown(agents.sessions, now: agents.now)
        let active = sessions.filter { $0.activity != .yourTurn }
        let done = sessions.filter { $0.activity == .yourTurn && !agents.isUnread($0) }
        let unread = placeholder ? [] : agents.unread
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(title: "Agents") {
                QuietLink(title: summary) { showInApp(.agents) }
                    .help("Open Agents in Tutto")
            }
            if sessions.isEmpty && unread.isEmpty {
                Text("No agents running")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.ink3)
            }
            if !active.isEmpty || !unread.isEmpty { list(active: active, unread: unread) }
            if !done.isEmpty { DoneLine(agents: agents, sessions: done, placeholder: placeholder) }
            if !agents.runaway.isEmpty { runawayLine }
            if !agents.leftRunning.isEmpty { leftoversLine }
            if !agents.limits.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(agents.limits, id: \.tool) { limits in
                        if let estimate = limits.headline { MiniMeter(limits: limits, estimate: estimate, now: agents.now) }
                    }
                }
            }
        }
        .panelCard()
        .animation(Motion.snappy, value: AgentSession.shown(agents.sessions, now: agents.now).map(\.id))
        .animation(Motion.micro, value: confirming)
        .animation(Motion.snappy, value: agents.unread.map(\.id))
        .animation(Motion.snappy, value: allUnread)
        .background(VisibilityReader { visible in
            guard !placeholder else { return }
            if visible { agents.begin() } else { agents.end() }
        })
    }

    var summary: String {
        let waiting = agents.needsYou.count
        if waiting > 0 { return waiting == 1 ? "1 needs you" : "\(waiting) need you" }
        let working = agents.sessions.filter { $0.activity == .working }.count
        if working > 0 { return "\(working) working" }
        if !agents.unread.isEmpty { return "\(agents.unread.count) unread" }
        return "All"
    }

    /// Sessions that need you or are working, then chats with something you haven't read (newest
    /// first, a click reads it in its app): one list, every row the same step apart, and one line of
    /// links under it.
    func list(active: [AgentSession], unread: [UnreadChat]) -> some View {
        let chats = allUnread ? Array(unread.prefix(Self.unreadMax)) : Array(unread.prefix(Self.unreadRows))
        let moreActive = active.count - Self.rows
        let moreUnread = unread.count - Self.unreadRows
        return VStack(alignment: .leading, spacing: 1) {
            ForEach(active.prefix(Self.rows)) { session in
                AgentSessionRow(agents: agents, session: session, confirming: $confirming, placeholder: placeholder)
            }
            ForEach(chats) { chat in UnreadChatRow(agents: agents, chat: chat) }
            if moreActive > 0 || moreUnread > 0 {
                HStack(spacing: 12) {
                    if moreActive > 0 {
                        QuietLink(title: "\(moreActive) more", size: 11.5) { showInApp(.agents) }
                    }
                    if moreUnread > 0 {
                        QuietLink(title: allUnread ? "Fewer" : "\(moreUnread) more unread", size: 11.5) { allUnread.toggle() }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, -6)
    }

    var runawayLine: some View {
        let names = agents.sessions.filter { agents.runaway.contains($0.id) }
        let count = names.compactMap { $0.pid.flatMap { agents.loads[$0]?.processes } }.max()
        return HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.themeAccent)
            Text("\(names.first?.name ?? "An agent") is running \(count.map { "\($0)" } ?? "hundreds of") processes")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.ink)
                .lineLimit(1)
            Spacer(minLength: 4)
            QuietLink(title: "Show", size: 11.5) { showInApp(.agents) }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    var leftoversLine: some View {
        let count = agents.leftRunning.count
        let memory = agents.leftRunning.reduce(UInt64(0)) { $0 + $1.memory }
        HStack(spacing: 6) {
            if confirmingLeftovers {
                Text(count == 1 ? "Stop it?" : "Stop all \(count)?")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.ink)
                Spacer(minLength: 4)
                QuietLink(title: "Keep", size: 11.5) { confirmingLeftovers = false }
                Button("Stop") {
                    agents.stopAllLeftRunning()
                    confirmingLeftovers = false
                }
                .buttonStyle(OutlineButtonStyle(compact: true))
            } else {
                Text(count == 1 ? "1 dev server left running" : "\(count) dev servers left running")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.ink2)
                Text(Format.bytes(Int64(memory)))
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(Color.ink3)
                Spacer(minLength: 4)
                QuietLink(title: "Stop", size: 11.5) { confirmingLeftovers = true }
                    .disabled(placeholder)
            }
        }
        .help(agents.leftRunning.map { process in
            var line = process.name
            if let port = process.ports.first { line += " on :\(port)" }
            if let folder = process.folder { line += " in \(AgentSession.displayFolder(folder))" }
            return line
        }.joined(separator: "\n"))
    }
}

/// A session's state at a glance: a raised hand (needs you), the system's spinner (working), a tick
/// (your turn).
struct AgentMark: View {
    var activity: AgentActivity
    /// Drawn on a badge's disc: the tick a step darker so it holds up on the grey.
    var onBadge = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch activity {
            case .needsYou:
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.themeAccent)
            case .working:
                if reduceMotion {
                    Image(systemName: "circle.dotted")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.ink2)
                } else {
                    // AppKit's own spinner: it turns on the render server, not in SwiftUI's layout.
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                        .scaleEffect(0.8)
                }
            case .yourTurn:
                Image(systemName: "checkmark")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(onBadge ? Color.ink2 : Color.ink3)
            }
        }
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
    }
}

// MARK: - Words

enum AgentText {
    static func state(_ activity: AgentActivity) -> String {
        switch activity {
        case .needsYou: "needs you"
        case .working: "working"
        case .yourTurn: "your turn"
        }
    }

    /// "now", "4 min", "1 h 5 min", "3 h", "2 d".
    static func age(since: Date, now: Date) -> String {
        let seconds = max(now.timeIntervalSince(since), 0)
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        if hours < 10 { return minutes % 60 == 0 || hours >= 3 ? "\(hours) h" : "\(hours) h \(minutes % 60) min" }
        if hours < 48 { return "\(hours) h" }
        return "\(hours / 24) d"
    }

    /// "1.2 GB · 142 %".
    static func cost(_ load: AgentLoad) -> String {
        "\(Format.bytes(Int64(load.memory))) · \(Int(load.cpu.rounded())) %"
    }

    static func costLong(_ load: AgentLoad) -> String {
        var parts = ["\(Format.bytes(Int64(load.memory))) of memory", "\(Int(load.cpu.rounded())) % CPU"]
        if let watts = load.watts, watts >= 0.1 { parts.append(String(format: "%.1f W", watts)) }
        parts.append(load.processes == 1 ? "1 process" : "\(load.processes) processes")
        if let busiest = load.busiest { parts.append("busiest: \(busiest)") }
        return parts.joined(separator: " · ")
    }

    /// "31 %", "≈66 %" for an estimate.
    static func percent(_ estimate: LimitEstimate) -> String {
        "\(estimate.exact ? "" : "≈")\(Int(estimate.percent.rounded())) %"
    }

    static func window(_ window: LimitEstimate.Window) -> String {
        window == .fiveHour ? "5 h" : "week"
    }

    /// "5 h · resets 3:40 PM", "Week · resets Thu", "5 h · out at 2:55 PM", "5 h · reached".
    static func timing(_ estimate: LimitEstimate, now: Date) -> String {
        let name = window(estimate.window)
        if estimate.reached { return estimate.resetsAt.map { "\(name) · back \(clock($0, now: now))" } ?? "\(name) · reached" }
        if let at = estimate.limitAt { return "\(name) · out at \(clock(at, now: now))" }
        if let resets = estimate.resetsAt { return "\(name) · resets \(clock(resets, now: now))" }
        return name
    }

    /// A time today, else a weekday and time.
    static func clock(_ date: Date, now: Date) -> String {
        let format = DateFormatter()
        if Calendar.current.isDate(date, inSameDayAs: now) {
            format.timeStyle = .short
        } else if date.timeIntervalSince(now) < 6 * 86_400 {
            format.setLocalizedDateFormatFromTemplate("EEE j")
        } else {
            format.setLocalizedDateFormatFromTemplate("MMMd")
        }
        return format.string(from: date)
    }

    static func limitsHelp(_ limits: AgentLimits, now: Date) -> String {
        var lines: [String] = []
        for estimate in [limits.fiveHour, limits.week].compactMap({ $0 }) {
            var line = "\(estimate.window == .fiveHour ? "5 hours" : "This week"): \(percent(estimate))"
            if let resets = estimate.resetsAt { line += ", resets \(clock(resets, now: now))" }
            if let at = estimate.limitAt { line += "; at this pace it runs out at \(clock(at, now: now))" }
            lines.append(line)
        }
        if limits.tool == .claude, limits.week?.exact == true || limits.fiveHour?.exact == true {
            lines.append("As Claude reports it (its Settings → Usage).")
        } else if limits.tool == .claude {
            lines.append("Estimated from Claude Code's logs on this Mac\(limits.basis.map { ", measured against \($0)" } ?? ""). Chats in Claude's app count toward the same limits and aren't in the logs.")
        } else {
            lines.append("As Codex reports it.")
        }
        return lines.joined(separator: "\n")
    }
}
