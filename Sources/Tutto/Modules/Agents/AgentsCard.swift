//
//  AgentsCard.swift
//  Tutto
//
//  The Agents card on the menu bar panel. Up to four sessions, what needs you first: a raised hand
//  in the accent for one waiting on you, a turning ring while one works, a quiet tick when it's
//  your turn. A click opens that exact session. An idle one that's been sitting a while says what
//  it holds ("idle 2 h · 271 MB"); under the pointer every row says what it costs and offers to
//  stop it, with a confirmation in place. Under them, one line per agent for its limit, in the
//  accent only when it'll run out before it resets; then what agents left running, and any agent
//  whose processes are multiplying. Nothing shows that has nothing to say.
//

import SwiftUI
import TuttoKit

struct AgentsCard: View {
    @Bindable var agents: AgentsModule
    /// On the Customize page: shown, not used.
    var placeholder = false
    @State private var confirming: String?
    @State private var confirmingLeftovers = false

    static let rows = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardTitle(title: "Agents") {
                QuietLink(title: summary) { showInApp(.agents) }
                    .help("Open Agents in Tutto")
            }
            if agents.sessions.isEmpty {
                Text("No agents running")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.ink3)
            } else {
                VStack(spacing: 1) {
                    ForEach(agents.sessions.prefix(Self.rows)) { session in
                        AgentRow(agents: agents, session: session, confirming: $confirming, placeholder: placeholder)
                    }
                }
                .padding(.horizontal, -6)
                if agents.sessions.count > Self.rows {
                    QuietLink(title: "\(agents.sessions.count - Self.rows) more", size: 11.5) { showInApp(.agents) }
                        .padding(.top, -4)
                }
            }
            if !agents.runaway.isEmpty { runawayLine }
            if !agents.limits.isEmpty {
                Hairline().opacity(0.6)
                VStack(spacing: 6) {
                    ForEach(agents.limits, id: \.tool) { limits in
                        if let headline = limits.headline { LimitLine(limits: limits, estimate: headline, now: agents.now) }
                    }
                }
            }
            if !agents.leftRunning.isEmpty { leftoversLine }
        }
        .panelCard()
        .animation(Motion.snappy, value: agents.sessions.map(\.id))
        .animation(Motion.micro, value: confirming)
        .background(VisibilityReader { visible in
            guard !placeholder else { return }
            if visible { agents.begin() } else { agents.end() }
        })
    }

    private var summary: String {
        let waiting = agents.needsYou.count
        if waiting > 0 { return waiting == 1 ? "1 needs you" : "\(waiting) need you" }
        let working = agents.sessions.filter { $0.activity == .working }.count
        if working > 0 { return "\(working) working" }
        return "All"
    }

    private var runawayLine: some View {
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
    private var leftoversLine: some View {
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

// MARK: - A session

private struct AgentRow: View {
    @Bindable var agents: AgentsModule
    var session: AgentSession
    @Binding var confirming: String?
    var placeholder: Bool
    @State private var hovering = false

    private var load: AgentLoad? { session.pid.flatMap { agents.loads[$0] } }
    private var stopping: Bool { session.pid.map { agents.stopping.contains($0) } ?? false }

    var body: some View {
        HStack(spacing: 8) {
            if confirming == session.id {
                confirm
            } else {
                AgentMark(activity: session.activity)
                Text(session.name)
                    .font(.system(size: 12.5, weight: session.activity.needsYou ? .semibold : .medium))
                    .foregroundStyle(session.activity == .yourTurn ? Color.ink2 : Color.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                Text(detail)
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(detailColor)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                if hovering, !placeholder, session.pid != nil, session.tool == .claude {
                    Button {
                        confirming = session.id
                    } label: {
                        Image(systemName: "stop.circle")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color.ink2)
                            .lensHover(cornerRadius: 7, x: 2, y: 2, swell: Motion.iconSwell)
                    }
                    .buttonStyle(PressStyle())
                    .help("Stop this session: its process quits; the conversation is kept")
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 26)
        .hoverBackground(hovering && confirming != session.id, x: 0)
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(Motion.micro) { hovering = inside } }
        .onTapGesture {
            guard !placeholder, confirming != session.id else { return }
            afterPanelCloses { agents.show(session) }
        }
        .opacity(stopping ? 0.45 : 1)
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.name), \(AgentText.state(session.activity))")
        .accessibilityValue(detail)
        .accessibilityHint("Opens the session")
        .accessibilityAddTraits(.isButton)
    }

    private var confirm: some View {
        HStack(spacing: 8) {
            Text("Stop \u{201C}\(session.name)\u{201D}?")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.ink)
                .lineLimit(1)
            Spacer(minLength: 4)
            QuietLink(title: "Keep", size: 11.5) { confirming = nil }
            Button("Stop") {
                agents.stop(session)
                confirming = nil
            }
            .buttonStyle(OutlineButtonStyle(compact: true))
        }
    }

    /// Short: how long, and what it holds when that's worth knowing. Under the pointer, its cost.
    private var detail: String {
        if stopping { return "stopping…" }
        if hovering, let load, session.tool == .claude {
            return AgentText.cost(load)
        }
        if agents.runaway.contains(session.id), let load {
            return "\(load.processes) processes"
        }
        let age = AgentText.age(since: session.since, now: agents.now)
        switch session.activity {
        case .needsYou: return "waiting \(age)"
        case .working:
            if let quiet = agents.quiet(session) { return "quiet \(AgentText.age(since: agents.now.addingTimeInterval(-quiet), now: agents.now))" }
            return age
        case .yourTurn:
            if let load, load.memory >= 150_000_000, agents.now.timeIntervalSince(session.since) >= 1800 {
                return "idle \(age) · \(Format.bytes(Int64(load.memory)))"
            }
            return "idle \(age)"
        }
    }

    private var detailColor: Color {
        if session.activity.needsYou || agents.runaway.contains(session.id) { return .themeAccent }
        return .ink3
    }

    private var help: String {
        var lines = ["\(session.tool.name) · \(AgentSession.displayFolder(session.folder))"]
        if let reason = AgentsModule.reason(session) { lines.append(reason) }
        if agents.quiet(session) != nil { lines.append("Working, but nothing written for a while: it may be stuck, or waiting on a long command") }
        if let load { lines.append(AgentText.costLong(load)) }
        lines.append(session.openURL != nil ? "Click to open it" : "Click to bring its window forward")
        return lines.joined(separator: "\n")
    }
}

/// A session's state at a glance.
struct AgentMark: View {
    var activity: AgentActivity
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turning = false

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
                    Circle()
                        .trim(from: 0, to: 0.7)
                        .stroke(Color.ink2, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                        .frame(width: 10, height: 10)
                        .rotationEffect(.degrees(turning ? 360 : 0))
                        .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: turning)
                        .onAppear { turning = true }
                }
            case .yourTurn:
                Image(systemName: "checkmark")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(Color.ink3)
            }
        }
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
    }
}

// MARK: - A limit

struct LimitLine: View {
    var limits: AgentLimits
    var estimate: LimitEstimate
    var now: Date

    private var urgent: Bool { estimate.reached || estimate.limitAt != nil || estimate.percent >= 85 }

    var body: some View {
        HStack(spacing: 8) {
            Text(limits.tool.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.ink2)
                .frame(width: 44, alignment: .leading)
            LimitBar(percent: estimate.percent, urgent: urgent)
            Text(AgentText.percent(estimate))
                .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(urgent ? Color.themeAccent : Color.ink)
                .frame(width: 42, alignment: .trailing)
            Text(AgentText.timing(estimate, now: now))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(urgent ? Color.themeAccent : Color.ink3)
                .lineLimit(1)
                .frame(width: 112, alignment: .trailing)
        }
        .help(AgentText.limitsHelp(limits, now: now))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(limits.tool.name) limit")
        .accessibilityValue("\(AgentText.percent(estimate)), \(AgentText.timing(estimate, now: now))")
    }
}

struct LimitBar: View {
    var percent: Double
    var urgent: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.ink.opacity(0.1))
                Capsule()
                    .fill(urgent ? Color.themeAccent : Color.ink.opacity(0.7))
                    .frame(width: max(proxy.size.width * min(percent, 100) / 100, percent > 0 ? 3 : 0))
            }
        }
        .frame(height: 4)
        .animation(Motion.snappy, value: percent)
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
        window == .fiveHour ? "5 h" : "Week"
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
        if limits.tool == .claude {
            lines.append("Estimated from Claude Code's logs on this Mac\(limits.basis.map { ", measured against \($0)" } ?? ""). Chats in Claude's app count toward the same limits and aren't in the logs.")
        } else {
            lines.append("As Codex reports it.")
        }
        return lines.joined(separator: "\n")
    }
}
