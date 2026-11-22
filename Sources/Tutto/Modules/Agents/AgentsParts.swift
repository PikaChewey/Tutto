//
//  AgentsParts.swift
//  Tutto
//
//  The pieces the Agents card and page are drawn with: a percent the way the rest of the panel
//  writes one (a figure with a small "%" right against it; an estimate says "est."), a thin bar with
//  a tick where an even pace would be, each agent's own icon, a session's app with its state in a
//  small badge, the session row (soft pill only for the one waiting on you), the folded line for
//  finished sessions, and the small meter with when it resets.
//

import AppKit
import SwiftUI
import TuttoKit

/// "66%" with the sign small and close, as the CPU and battery figures are.
struct PercentFigure: View {
    var value: Double
    var size: CGFloat
    var color: Color = .ink

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0.5) {
            Text("\(Int(value.rounded()))")
                .font(.figure(size, weight: .medium))
                .foregroundStyle(color)
                .contentTransition(.numericText())
            Text("%")
                .font(.system(size: (size * 0.55).rounded(), weight: .medium))
                .foregroundStyle(Color.ink3)
        }
        .fixedSize()
    }
}

extension LimitEstimate {
    var urgent: Bool { reached || limitAt != nil || percent >= 85 }

    /// How far through its window we are (0…1): where an even pace would have the bar.
    func elapsed(now: Date) -> Double? {
        guard let resetsAt else { return nil }
        let length: Double = window == .fiveHour ? 5 * 3600 : 7 * 86_400
        return min(max(1 - resetsAt.timeIntervalSince(now) / length, 0), 1)
    }

    var windowName: String { window == .fiveHour ? "5 hours" : "This week" }
    var shortWindow: String { window == .fiveHour ? "5 h" : "Week" }

    /// "Resets in 2 h 30 min", "Resets Sat 10 AM", "Out in 45 min", "Back in 3 h": a countdown
    /// within the day, a weekday and time past it.
    func when(now: Date) -> String {
        func at(_ date: Date) -> String {
            date.timeIntervalSince(now) < 20 * 3600 ? "in \(AgentText.age(since: now, now: date))" : AgentText.clock(date, now: now)
        }
        if reached { return resetsAt.map { "Back \(at($0))" } ?? "Reached" }
        if let limitAt { return "Out \(at(limitAt))" }
        return resetsAt.map { "Resets \(at($0))" } ?? ""
    }

    /// A meter's caption, short enough to sit under half a card at full size: "5 h · Out in 45 min",
    /// "Week est. · Resets in 13 h", "Week est. · Sun 10 AM" (a reset days away is just when).
    func caption(now: Date) -> String {
        let window = shortWindow + (exact ? "" : " est.")
        if !reached, limitAt == nil, let resetsAt, resetsAt.timeIntervalSince(now) >= 20 * 3600 {
            return "\(window) · \(AgentText.clock(resetsAt, now: now))"
        }
        return "\(window) · \(when(now: now))"
    }
}

/// A thin bar with a tick where an even pace would be: past the tick, you're using it faster than
/// the window allows.
struct PaceBar: View {
    var estimate: LimitEstimate
    var now: Date
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.ink.opacity(0.1))
                Capsule()
                    .fill(estimate.urgent ? Color.themeAccent : Color.ink.opacity(0.75))
                    .frame(width: max(width * min(estimate.percent, 100) / 100, estimate.percent > 0 ? height : 0))
                if let elapsed = estimate.elapsed(now: now), elapsed > 0.02, elapsed < 0.98 {
                    Capsule()
                        .fill(Color.ink2)
                        .frame(width: 1.5, height: height + 5)
                        .offset(x: width * elapsed - 0.75)
                }
            }
        }
        .frame(height: height)
        .animation(Motion.snappy, value: estimate.percent)
        .accessibilityHidden(true)
    }
}

/// Claude's or Codex's own icon (the app's, when it's installed).
struct ToolIcon: View {
    var tool: AgentTool
    var size: CGFloat = 14

    @MainActor private static var cache: [AgentTool: NSImage] = [:]

    var body: some View {
        Group {
            if let image = Self.icon(tool) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: tool == .claude ? "sparkle" : "chevron.left.forwardslash.chevron.right")
                    .resizable().scaledToFit().foregroundStyle(Color.ink3).padding(size * 0.15)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    @MainActor static func icon(_ tool: AgentTool) -> NSImage? {
        if let image = cache[tool] { return image }
        let id = tool == .claude ? AgentsModule.claudeAppID : AgentsModule.codexAppID
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache[tool] = image
        return image
    }
}

/// The disc behind a badge: white on a light card, a raised grey on a dark one. The cards are
/// see-through, so the window's own paper (black in dark mode) read as a hole punched in the icon.
let badgeDisc = Color(nsColor: NSColor(name: "agentBadge") { appearance in
    appearance.isDark ? NSColor(white: 0.30, alpha: 1) : .white
})

/// The app a session is in, with its state in a small badge.
struct SessionAvatar: View {
    var agents: AgentsModule
    var session: AgentSession
    var size: CGFloat
    /// Off where every one is the same state (the folded "done" line).
    var badge = true

    var body: some View {
        let big = size >= 24
        Group {
            if let icon = agents.hostIcon(session) {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                ToolIcon(tool: session.tool, size: size)
            }
        }
        .frame(width: size, height: size)
        .opacity(session.activity == .yourTurn ? 0.6 : 1)
        .saturation(session.activity == .yourTurn ? 0.4 : 1)
        .overlay(alignment: .bottomTrailing) {
            if badge {
            AgentMark(activity: session.activity, onBadge: true)
                .scaleEffect(big ? 0.85 : 0.7)
                .background(Circle().fill(badgeDisc).frame(width: big ? 13 : 11, height: big ? 13 : 11)
                    .shadow(color: .black.opacity(0.18), radius: 0.5, y: 0.3))
                .offset(x: big ? 4 : 3, y: big ? 4 : 3)
            }
        }
        .accessibilityHidden(true)
    }
}

/// What a session is doing, short: a soft accent pill when it needs you, otherwise quiet text.
struct SessionStatus: View {
    var agents: AgentsModule
    var session: AgentSession
    var hovering: Bool

    private var load: AgentLoad? { session.pid.flatMap { agents.loads[$0] } }

    var body: some View {
        let age = AgentText.age(since: session.since, now: agents.now)
        Group {
            if hovering, let load {
                Text(AgentText.cost(load))
                    .foregroundStyle(Color.ink2)
            } else {
                switch session.activity {
                case .needsYou:
                    Text("Waiting \(age)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color.themeAccent)
                        .padding(.horizontal, 7)
                        .frame(height: 18)
                        .background(Capsule().fill(Color.themeAccent.opacity(0.14)))
                case .working:
                    if let quiet = agents.quiet(session) {
                        Text("Quiet \(AgentText.age(since: agents.now.addingTimeInterval(-quiet), now: agents.now))")
                            .foregroundStyle(Color.ink2)
                    } else {
                        Text(age).foregroundStyle(Color.ink3)
                    }
                case .yourTurn:
                    Text("Done · \(age)").foregroundStyle(Color.ink3)
                }
            }
        }
        .font(.system(size: 11).monospacedDigit())
        .lineLimit(1)
        .contentTransition(.opacity)
    }
}

/// One session: its app, its name, its state. A click opens it; under the pointer it shows its
/// cost and a stop button that asks first.
struct AgentSessionRow: View {
    @Bindable var agents: AgentsModule
    var session: AgentSession
    @Binding var confirming: String?
    var placeholder: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            if confirming == session.id {
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
            } else {
                SessionAvatar(agents: agents, session: session, size: 16)
                Text(session.name)
                    .font(.system(size: 12.5, weight: session.activity.needsYou ? .semibold : .medium))
                    .foregroundStyle(session.activity == .yourTurn ? Color.ink2 : Color.ink)
                    .lineLimit(1)
                Spacer(minLength: 6)
                SessionStatus(agents: agents, session: session, hovering: hovering && !placeholder)
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
        .opacity(session.pid.map { agents.stopping.contains($0) } == true ? 0.45 : 1)
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.name), \(AgentText.state(session.activity))")
        .accessibilityHint("Opens the session")
        .accessibilityAddTraits(.isButton)
    }

    private var help: String {
        var lines = ["\(session.tool.name) · \(AgentSession.displayFolder(session.folder))"]
        if let reason = AgentsModule.reason(session) { lines.append(reason) }
        if agents.quiet(session) != nil { lines.append("Working, but nothing written for a while: it may be stuck, or waiting on a long command") }
        if let load = session.pid.flatMap({ agents.loads[$0] }) { lines.append(AgentText.costLong(load)) }
        lines.append(session.openURL != nil ? "Click to open it" : "Click to bring its window forward")
        return lines.joined(separator: "\n")
    }
}

/// A chat with something you haven't read, as its own app marks it: a small accent dot, the app's
/// icon, the title, how long ago its last turn ended. A click opens that chat, which reads it.
struct UnreadChatRow: View {
    var agents: AgentsModule
    var chat: UnreadChat
    @State private var hovering = false

    var body: some View {
        Button {
            afterPanelCloses { agents.open(chat) }
        } label: {
            HStack(spacing: 9) {
                ToolIcon(tool: chat.tool, size: 16)
                    .overlay(alignment: .topTrailing) {
                        Circle()
                            .fill(Color.themeAccent)
                            .frame(width: 7, height: 7)
                            .background(Circle().fill(badgeDisc).frame(width: 9, height: 9))
                            .offset(x: 3, y: -3)
                    }
                Text(chat.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                Text(hovering ? "Read" : AgentText.age(since: chat.at, now: agents.now))
                    .font(.system(size: 11, weight: hovering ? .medium : .regular).monospacedDigit())
                    .foregroundStyle(hovering ? Color.themeAccent : Color.ink3)
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
            .padding(.horizontal, 6)
            .frame(height: 26)
            .hoverBackground(hovering, x: 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { inside in withAnimation(Motion.micro) { hovering = inside } }
        .contextMenu {
            Button("Read in \(chat.tool.name)") { afterPanelCloses { agents.open(chat) } }
            Button("Mark as Read") { agents.markRead([chat]) }
        }
        .help(help)
        .accessibilityLabel("Unread: \(chat.title), \(chat.tool.name)")
        .accessibilityHint("Opens the chat in \(chat.tool.name)")
    }

    private var help: String {
        var lines = [chat.tool.name + (chat.folder.map { " · " + AgentSession.displayFolder($0) } ?? "")]
        lines.append("Unread. Click to read it in \(chat.tool.name)")
        return lines.joined(separator: "\n")
    }
}

/// Finished sessions in one line: "2 done · site, Grasp Project", their icons overlapping. A
/// click opens them on the Agents page.
struct DoneLine: View {
    var agents: AgentsModule
    var sessions: [AgentSession]
    var placeholder = false
    @State private var hovering = false

    var body: some View {
        Button {
            guard !placeholder else { return }
            showInApp(.agents)
        } label: {
            HStack(spacing: 8) {
                // Overlapping, each with a thin ring of the card between it and the next, so they read
                // as separate icons rather than one grey smudge.
                HStack(spacing: -4) {
                    ForEach(Array(sessions.prefix(3).enumerated()), id: \.element.id) { index, session in
                        SessionAvatar(agents: agents, session: session, size: 16, badge: false)
                            .padding(1.5)
                            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(badgeDisc))
                            .zIndex(Double(3 - index))
                    }
                }
                Text("\(sessions.count) done")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.ink2)
                Text(sessions.map(\.name).joined(separator: ", "))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.ink3)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: 26)
            .hoverBackground(hovering, x: 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .padding(.horizontal, -6)
        .help("Open them in Tutto")
        .accessibilityLabel("\(sessions.count) finished: \(sessions.map(\.name).joined(separator: ", "))")
    }
}

/// An agent's limit, small: its icon and name, the figure, the pace bar, when it resets.
struct MiniMeter: View {
    var limits: AgentLimits
    var estimate: LimitEstimate
    var now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                ToolIcon(tool: limits.tool, size: 12)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                Text(limits.tool.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.ink2)
                Spacer(minLength: 2)
                PercentFigure(value: estimate.percent, size: 15, color: estimate.urgent ? .themeAccent : .ink)
            }
            PaceBar(estimate: estimate, now: now, height: 4)
            Text(estimate.caption(now: now))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(estimate.urgent ? Color.themeAccent : Color.ink3)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(AgentText.limitsHelp(limits, now: now))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(limits.tool.name) limit")
        .accessibilityValue("\(Int(estimate.percent.rounded())) percent of \(estimate.windowName.lowercased()), \(estimate.when(now: now))")
    }
}
