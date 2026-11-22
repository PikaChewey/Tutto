//
//  AgentsProbe.swift
//  Tutto
//
//  `--agents-probe [seconds]` (debug copies only): the Agents module against this Mac's real
//  agents, printed: the sessions, the limits, what each costs, what's left running, and how long
//  reading Claude's transcripts took.
//

#if DEBUG
import AppKit
import TuttoKit

@MainActor
enum AgentsProbe {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--agents-probe") else { return false }
        let seconds = args.count > flag + 1 ? Double(args[flag + 1]) ?? 20 : 20
        let agents = AgentsModule()
        let began = Date()
        agents.start()
        agents.begin()
        var printedLimits = false
        while Date().timeIntervalSince(began) < seconds {
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            if !printedLimits, agents.claudeLimits != nil {
                printedLimits = true
                print(String(format: "claude estimate ready after %.1f s", Date().timeIntervalSince(began)))
            }
        }
        let now = Date()
        print("installed:", agents.installed)
        for session in agents.sessions {
            let load = session.pid.flatMap { agents.loads[$0] }.map(AgentText.costLong) ?? "-"
            print("session:", session.tool.name, "|", session.name, "|", AgentText.state(session.activity), AgentText.age(since: session.since, now: now),
                  "|", session.host, "|", session.openURL?.absoluteString ?? "-", "|", load)
        }
        if let codex = agents.codexLoad { print("codex app:", AgentText.costLong(codex)) }
        for limits in agents.limits {
            for estimate in [limits.fiveHour, limits.week].compactMap({ $0 }) {
                print("limit:", limits.tool.name, estimate.window, AgentText.percent(estimate), AgentText.timing(estimate, now: now))
            }
            if let basis = limits.basis { print("  basis:", basis) }
        }
        for process in agents.leftRunning {
            print("left running:", process.pid, process.name, process.ports, process.folder ?? "-", Format.bytes(Int64(process.memory)))
        }
        print("runaway:", agents.runaway)
        if let limit = agents.menuBarLimit { print("menu bar limit:", limit.tool.name, AgentText.percent(limit.estimate)) }
        print("needs you:", agents.needsYou.map(\.name))
        for chat in agents.unread {
            print("unread:", chat.tool.name, "|", chat.title.prefix(50), "|", AgentText.age(since: chat.at, now: now), "|", chat.openURL?.absoluteString ?? "-")
        }
        agents.end()
        agents.stop()
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        return true
    }
}
#endif
