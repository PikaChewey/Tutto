//
//  AgentsPage.swift
//  Tutto
//
//  Agents in the app: every session with what it costs, both limit windows for each agent and
//  what the estimate rests on, what agents left running (open it, find it, stop it), and the alerts.
//

import AppKit
import SwiftUI
import TuttoKit

struct AgentsPage: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: "Agents",
                       subtitle: "Claude Code and Codex on this Mac: which need you, what each costs, what they left running, and how close you are to your limits.",
                       module: .agents)
            if let agents = model.agents {
                AgentsDetail(agents: agents)
            } else {
                ModuleOffView(module: .agents, model: model)
            }
        }
    }
}

private struct AgentsDetail: View {
    @Bindable var agents: AgentsModule

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            InkGroup("Sessions") {
                if agents.sessions.isEmpty {
                    LabeledRow("No agents running",
                               detail: "Claude Code sessions (in Claude's app or a terminal) and Codex threads show here while they run, the ones waiting on you first.") {
                        EmptyView()
                    }
                } else {
                    ForEach(Array(agents.sessions.enumerated()), id: \.element.id) { index, session in
                        if index > 0 { Hairline().opacity(0.6) }
                        SessionLine(agents: agents, session: session)
                    }
                }
            }
            if let codex = agents.codexLoad {
                InkGroup("Codex app") {
                    LabeledRow("Codex and its agents", detail: AgentText.costLong(codex)) { EmptyView() }
                }
            }
            if !agents.limits.isEmpty {
                InkGroup("Limits") {
                    ForEach(Array(agents.limits.enumerated()), id: \.element.tool) { index, limits in
                        if index > 0 { Hairline().opacity(0.6) }
                        LimitsBlock(limits: limits, now: agents.now)
                    }
                }
            }
            leftovers
            InkGroup("Alerts") {
                LabeledRow("When an agent needs you", detail: "A note at the bottom of the screen when a session stops to ask you something. Click it to open the session. Not while its app is in front.") {
                    InkSwitch(isOn: $agents.alertNeedsYou, label: "When an agent needs you")
                }
                Hairline().opacity(0.6)
                LabeledRow("When an agent finishes", detail: "After a turn that took a minute or more.") {
                    InkSwitch(isOn: $agents.alertFinished, label: "When an agent finishes")
                }
                Hairline().opacity(0.6)
                LabeledRow("A raised hand in the menu bar", detail: "Beside Tutto's icon while a session waits on you, with how many.") {
                    InkSwitch(isOn: $agents.menuBarSignal, label: "A raised hand in the menu bar")
                }
                Hairline().opacity(0.6)
                LabeledRow("Limits in the menu bar", detail: "Only when one is reached, nearly full, or will run out within the hour at this pace.") {
                    InkSwitch(isOn: $agents.menuBarLimits, label: "Limits in the menu bar")
                }
                Hairline().opacity(0.6)
                LabeledRow("Runaway processes", detail: "A note when one agent is running \(AgentLoad.runawayCount) processes or more: something is usually looping.") {
                    InkSwitch(isOn: $agents.warnRunaway, label: "Runaway processes")
                }
            }
            Text("Read on this Mac from the files Claude Code and Codex keep (their session records and logs). Nothing is sent anywhere, and nothing about the agents is changed: Stop asks a process to quit, the way quitting it in a terminal would.")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .background(VisibilityReader { visible in visible ? agents.begin() : agents.end() })
    }

    @ViewBuilder
    private var leftovers: some View {
        let stopAll = agents.leftRunning.count > 1
            ? AnyView(Button("Stop All") { agents.stopAllLeftRunning() }.buttonStyle(OutlineButtonStyle(compact: true)))
            : nil
        InkGroup("Left running", trailing: stopAll) {
            if agents.leftRunning.isEmpty {
                LabeledRow("Nothing left running",
                           detail: "Dev servers and scripts still running in a project folder after their agent or terminal has gone show here, to open or stop.") {
                    EmptyView()
                }
            } else {
                ForEach(Array(agents.leftRunning.enumerated()), id: \.element.id) { index, process in
                    if index > 0 { Hairline().opacity(0.6) }
                    LeftRunningLine(agents: agents, process: process)
                }
            }
        }
    }
}

private struct SessionLine: View {
    @Bindable var agents: AgentsModule
    var session: AgentSession
    @State private var confirming = false

    private var load: AgentLoad? { session.pid.flatMap { agents.loads[$0] } }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let icon = agents.hostIcon(session) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 26, height: 26)
                    .overlay(alignment: .bottomTrailing) {
                        AgentMark(activity: session.activity)
                            .background(Circle().fill(Color.paper).frame(width: 15, height: 15))
                            .offset(x: 4, y: 4)
                    }
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(session.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(session.activity.needsYou || agents.runaway.contains(session.id) ? Color.themeAccent : Color.ink3)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let load {
                    Text(AgentText.costLong(load))
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(Color.ink3)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if confirming {
                Text("Stop it?")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.ink2)
                Button("Keep") { confirming = false }
                    .buttonStyle(OutlineButtonStyle(compact: true))
                Button("Stop") {
                    agents.stop(session)
                    confirming = false
                }
                .buttonStyle(InkButtonStyle(compact: true))
            } else {
                if session.tool == .claude, session.pid != nil {
                    Button("Stop") { confirming = true }
                        .buttonStyle(OutlineButtonStyle(compact: true))
                        .help("Its process quits; the conversation is kept and can be picked up again")
                        .disabled(session.pid.map { agents.stopping.contains($0) } ?? true)
                }
                Button(session.openURL != nil ? "Open" : "Show") { agents.show(session) }
                    .buttonStyle(OutlineButtonStyle(compact: true))
            }
        }
        .padding(.vertical, 8)
        .animation(Motion.micro, value: confirming)
        .accessibilityElement(children: .contain)
    }

    private var subtitle: String {
        var parts: [String] = []
        switch session.activity {
        case .needsYou: parts.append("Needs you\(AgentsModule.reason(session).map { ": \($0.lowercased())" } ?? "") · \(AgentText.age(since: session.since, now: agents.now))")
        case .working:
            var line = "Working · \(AgentText.age(since: session.since, now: agents.now))"
            if let quiet = agents.quiet(session) { line += ", nothing written for \(AgentText.age(since: agents.now.addingTimeInterval(-quiet), now: agents.now))" }
            parts.append(line)
        case .yourTurn: parts.append("Your turn · idle \(AgentText.age(since: session.since, now: agents.now))")
        }
        parts.append(session.host == .claudeApp ? "in Claude's app" : session.host == .codexApp ? "in the Codex app" : "\(session.tool.name) in a terminal")
        parts.append(AgentSession.displayFolder(session.folder))
        return parts.joined(separator: " · ")
    }
}

private struct LimitsBlock: View {
    var limits: AgentLimits
    var now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(limits.tool.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.ink)
                Spacer()
                Text(limits.tool == .claude ? "Estimated" : "As Codex reports it")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.ink3)
            }
            ForEach([limits.fiveHour, limits.week].compactMap { $0 }, id: \.window) { estimate in
                let urgent = estimate.reached || estimate.limitAt != nil || estimate.percent >= 85
                HStack(spacing: 10) {
                    Text(estimate.window == .fiveHour ? "5 hours" : "This week")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.ink2)
                        .frame(width: 72, alignment: .leading)
                    LimitBar(percent: estimate.percent, urgent: urgent)
                    Text(AgentText.percent(estimate))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(urgent ? Color.themeAccent : Color.ink)
                        .frame(width: 46, alignment: .trailing)
                    Text(timing(estimate))
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(urgent ? Color.themeAccent : Color.ink3)
                        .frame(width: 200, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
            }
            if limits.tool == .claude {
                Text("Claude Code doesn't say how close you are, so this is worked out from its logs on this Mac, measured against \(limits.basis ?? "your own use"). Running /usage in Claude Code sharpens it. Chats in Claude's app count toward the same limits and aren't in the logs, so it can read low.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 8)
    }

    private func timing(_ estimate: LimitEstimate) -> String {
        if estimate.reached { return estimate.resetsAt.map { "Reached · back \(AgentText.clock($0, now: now))" } ?? "Reached" }
        var text = estimate.resetsAt.map { "Resets \(AgentText.clock($0, now: now))" } ?? ""
        if let at = estimate.limitAt { text = "Out at \(AgentText.clock(at, now: now)) at this pace" }
        return text
    }
}

private struct LeftRunningLine: View {
    @Bindable var agents: AgentsModule
    var process: LeftRunning

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.ink)
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.ink3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let port = process.ports.first {
                Button("Open") { NSWorkspace.shared.open(URL(string: "http://localhost:\(port)")!) }
                    .buttonStyle(OutlineButtonStyle(compact: true))
                    .help("Open localhost:\(port) in your browser")
            }
            if let folder = process.folder {
                Button("Show") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder) }
                    .buttonStyle(OutlineButtonStyle(compact: true))
                    .help("Show its folder in Finder")
            }
            Button("Stop") { agents.stop(process) }
                .buttonStyle(OutlineButtonStyle(compact: true))
                .disabled(agents.stopping.contains(process.pid))
                .help("Asks it to quit; ends it if it hasn't in 3 seconds")
        }
        .padding(.vertical, 8)
        .opacity(agents.stopping.contains(process.pid) ? 0.45 : 1)
    }

    private var title: String {
        let folder = process.folder.map { ($0 as NSString).lastPathComponent } ?? process.name
        return process.ports.isEmpty ? folder : "\(folder) on :\(process.ports.map(String.init).joined(separator: ", :"))"
    }

    private var detail: String {
        var parts = [process.name, Format.bytes(Int64(process.memory)), "running \(AgentText.age(since: process.started, now: Date()))"]
        if let folder = process.folder { parts.append(AgentSession.displayFolder(folder)) }
        return parts.joined(separator: " · ")
    }
}
