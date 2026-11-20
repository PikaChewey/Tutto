//
//  AgentsDashboard.swift
//  Tutto
//
//  The Agents page to go with the new cards: the four limit windows as tiles across the top (figure,
//  pace bar, countdown), then sessions grouped by what they need from you, each one line of name and
//  one quiet line of where and what it costs, with its actions under the pointer. What's left running
//  and the alerts follow.
//

import AppKit
import SwiftUI
import TuttoKit

struct AgentsDashboard: View {
    @Bindable var agents: AgentsModule

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if !agents.limits.isEmpty { limits }
            sessions
            if let codex = agents.codexLoad {
                DashSection("Codex app") {
                    DashRow(title: "Codex and its agents", detail: AgentText.costLong(codex)) {
                        ToolIcon(tool: .codex, size: 24)
                    } trailing: { EmptyView() }
                }
            }
            leftovers
            AgentsAlertSwitches(agents: agents)
            Text("Read on this Mac from the files Claude Code and Codex keep. Nothing is sent anywhere. Stop asks a process to quit, the way quitting it in a terminal would.")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .background(VisibilityReader { visible in visible ? agents.begin() : agents.end() })
    }

    // MARK: Limits

    private var limits: some View {
        let windows: [(AgentLimits, LimitEstimate)] = agents.limits.flatMap { limits in
            [limits.fiveHour, limits.week].compactMap { $0 }.map { (limits, $0) }
        }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Caption("Limits")
                Spacer()
                Text("The tick on each bar is where an even pace would be.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ink3)
            }
            HStack(spacing: 10) {
                ForEach(Array(windows.enumerated()), id: \.offset) { _, pair in
                    BigLimitTile(limits: pair.0, estimate: pair.1, now: agents.now)
                }
            }
            if let claude = agents.claudeLimits {
                Text("Claude's figures are estimates (\"est.\"): Claude Code doesn't report them, so they're worked out from its logs on this Mac, measured against \(claude.basis ?? "your own use"). Chats in Claude's app count too and aren't in the logs, so they can read low.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Sessions

    @ViewBuilder
    private var sessions: some View {
        let shown = AgentSession.shown(agents.sessions, now: agents.now)
        if shown.isEmpty {
            DashSection("Sessions") {
                DashRow(title: "No agents running",
                        detail: "Claude Code sessions (in Claude's app or a terminal) and Codex threads show here while they run, the ones waiting on you first.") {
                    EmptyView()
                } trailing: { EmptyView() }
            }
        } else {
            let groups: [(String, [AgentSession])] = [
                ("Needs you", shown.filter { $0.activity.needsYou }),
                ("Working", shown.filter { $0.activity == .working }),
                ("Your turn", shown.filter { $0.activity == .yourTurn }),
            ].filter { !$0.1.isEmpty }
            ForEach(groups, id: \.0) { title, sessions in
                DashSection(title, count: sessions.count, accent: title == "Needs you") {
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                        if index > 0 { Hairline().opacity(0.5).padding(.leading, 40) }
                        DashSessionRow(agents: agents, session: session)
                    }
                }
            }
        }
    }

    // MARK: Left running

    @ViewBuilder
    private var leftovers: some View {
        if !agents.leftRunning.isEmpty {
            DashSection("Left running", count: agents.leftRunning.count,
                        trailing: agents.leftRunning.count > 1
                            ? AnyView(Button("Stop All") { agents.stopAllLeftRunning() }.buttonStyle(OutlineButtonStyle(compact: true)))
                            : nil) {
                ForEach(Array(agents.leftRunning.enumerated()), id: \.element.id) { index, process in
                    if index > 0 { Hairline().opacity(0.5).padding(.leading, 40) }
                    DashLeftoverRow(agents: agents, process: process)
                }
            }
        }
    }
}

/// The alert switches, as on the page now.
struct AgentsAlertSwitches: View {
    @Bindable var agents: AgentsModule

    var body: some View {
        InkGroup("Alerts") {
            LabeledRow("When an agent needs you", detail: "A note at the bottom of the screen; click it to open the session. Not while its app is in front.") {
                InkSwitch(isOn: $agents.alertNeedsYou, label: "When an agent needs you")
            }
            Hairline().opacity(0.6)
            LabeledRow("When an agent finishes", detail: "After a turn that took a minute or more.") {
                InkSwitch(isOn: $agents.alertFinished, label: "When an agent finishes")
            }
            Hairline().opacity(0.6)
            LabeledRow("A raised hand in the menu bar", detail: "Beside Tutto's icon while a session waits on you.") {
                InkSwitch(isOn: $agents.menuBarSignal, label: "A raised hand in the menu bar")
            }
            Hairline().opacity(0.6)
            LabeledRow("Limits in the menu bar", detail: "Only when one is reached, nearly full, or will run out within the hour at this pace.") {
                InkSwitch(isOn: $agents.menuBarLimits, label: "Limits in the menu bar")
            }
            Hairline().opacity(0.6)
            LabeledRow("Runaway processes", detail: "When one agent runs \(AgentLoad.runawayCount) processes or more: something is usually looping.") {
                InkSwitch(isOn: $agents.warnRunaway, label: "Runaway processes")
            }
        }
    }
}

// MARK: - Parts

private struct DashSection<Content: View>: View {
    var title: String
    var count: Int?
    var accent = false
    var trailing: AnyView?
    @ViewBuilder var content: Content

    init(_ title: String, count: Int? = nil, accent: Bool = false, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.count = count
        self.accent = accent
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Caption(title)
                if let count {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(accent ? Color.themeAccent : Color.ink3)
                }
                Spacer()
                if let trailing { trailing }
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .background(CardSurface(radius: 12))
        }
    }
}

private struct DashRow<Leading: View, Trailing: View>: View {
    var title: String
    var detail: String
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.ink)
                Text(detail).font(.system(size: 11.5)).foregroundStyle(Color.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 9)
    }
}

/// A limit window as a tile: the agent and window, the figure, the pace bar, the countdown.
private struct BigLimitTile: View {
    var limits: AgentLimits
    var estimate: LimitEstimate
    var now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ToolIcon(tool: limits.tool, size: 15)
                Text(limits.tool.name).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.ink2)
                    .lineLimit(1).fixedSize()
                Spacer(minLength: 2)
                Text(estimate.shortWindow + (estimate.exact ? "" : " · est."))
                    .font(.system(size: 11)).foregroundStyle(Color.ink3).lineLimit(1).minimumScaleFactor(0.8)
            }
            PercentFigure(value: estimate.percent, size: 30, color: estimate.urgent ? .themeAccent : .ink)
            PaceBar(estimate: estimate, now: now, height: 5)
            Text(estimate.when(now: now))
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(estimate.urgent ? Color.themeAccent : Color.ink3)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardSurface(radius: 12))
        .help(AgentText.limitsHelp(limits, now: now))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(limits.tool.name), \(estimate.windowName)")
        .accessibilityValue("\(Int(estimate.percent.rounded())) percent, \(estimate.when(now: now))")
    }
}

private struct DashSessionRow: View {
    @Bindable var agents: AgentsModule
    var session: AgentSession
    @State private var hovering = false
    @State private var confirming = false

    private var load: AgentLoad? { session.pid.flatMap { agents.loads[$0] } }

    var body: some View {
        HStack(spacing: 12) {
            SessionAvatar(agents: agents, session: session, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.ink).lineLimit(1)
                Text(detail).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Color.ink3).lineLimit(1)
            }
            Spacer(minLength: 8)
            if confirming {
                Text("Stop it?").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.ink2)
                Button("Keep") { confirming = false }.buttonStyle(OutlineButtonStyle(compact: true))
                Button("Stop") { agents.stop(session); confirming = false }.buttonStyle(InkButtonStyle(compact: true))
            } else {
                if hovering, session.tool == .claude, session.pid != nil {
                    Button("Stop") { confirming = true }
                        .buttonStyle(OutlineButtonStyle(compact: true))
                        .help("Its process quits; the conversation is kept and can be picked up again")
                        .transition(.opacity)
                }
                SessionStatus(agents: agents, session: session, hovering: false)
                Button(session.openURL != nil ? "Open" : "Show") { agents.show(session) }
                    .buttonStyle(OutlineButtonStyle(compact: true))
            }
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(Motion.micro) { hovering = inside } }
        .animation(Motion.micro, value: confirming)
        .accessibilityElement(children: .contain)
    }

    private var detail: String {
        let host = session.host == .claudeApp ? "Claude app" : session.host == .codexApp ? "Codex app" : "Terminal"
        var parts = [host, AgentSession.displayFolder(session.folder)]
        if let load { parts.append("\(Format.bytes(Int64(load.memory))) · \(Int(load.cpu.rounded())) % CPU") }
        if let reason = AgentsModule.reason(session) { parts.insert(reason.capitalizedFirst, at: 0) }
        return parts.joined(separator: " · ")
    }
}

private struct DashLeftoverRow: View {
    @Bindable var agents: AgentsModule
    var process: LeftRunning

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.system(size: 13))
                .foregroundStyle(Color.ink2)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.ink.opacity(0.06)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.ink)
                Text("\(process.name) · \(Format.bytes(Int64(process.memory))) · running \(AgentText.age(since: process.started, now: agents.now))")
                    .font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Color.ink3).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let port = process.ports.first {
                Button("Open") { NSWorkspace.shared.open(URL(string: "http://localhost:\(port)")!) }
                    .buttonStyle(OutlineButtonStyle(compact: true))
                    .help("Open localhost:\(port) in your browser")
            }
            Button("Stop") { agents.stop(process) }
                .buttonStyle(OutlineButtonStyle(compact: true))
                .disabled(agents.stopping.contains(process.pid))
                .help("Asks it to quit; ends it if it hasn't in 3 seconds")
        }
        .padding(.vertical, 9)
        .opacity(agents.stopping.contains(process.pid) ? 0.45 : 1)
    }

    private var title: String {
        let folder = process.folder.map { ($0 as NSString).lastPathComponent } ?? process.name
        return process.ports.isEmpty ? folder : "\(folder)  :\(process.ports.map(String.init).joined(separator: ", :"))"
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
