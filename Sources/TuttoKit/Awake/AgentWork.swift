//
//  AgentWork.swift
//  Tutto
//
//  "While agents work": Stay Awake turns itself on when a coding agent starts working and off
//  once agents have been quiet for a while (Bryan, 2026-11-10: "when an agent is running, it
//  automatically keeps it on ... And then when the agent is done running, it automatically turns
//  off").
//
//  An agent counts as working while it writes its session log (they append to it every few
//  seconds while they work and not at all while they wait for you), or while a command it started
//  keeps the processor busy (a long build writes nothing to the log until it ends). Its process
//  merely being open says nothing: an idle agent stays open for days.
//

import Foundation

public enum AgentWork {
    /// Command names of the agents whose tools are watched (their session logs are watched by folder).
    public static let commandNames: Set<String> = ["claude", "codex"]
    /// Where agents keep their session logs, under the home folder.
    public static let logFolders = [".claude/projects", ".codex/sessions"]
    /// Minutes of quiet before a session it started ends.
    public static let graceChoices = [5, 10, 30]

    /// Whether the commands agents started (everything under an agent's process, not the agent
    /// itself) used at least `threshold` of one core over the interval: a build or test run.
    /// `cpu` is each process's CPU time over `elapsed` (same units).
    public static func toolsBusy(cpu: [Int32: UInt64], parents: [Int32: Int32], names: [Int32: String],
                                 elapsed: UInt64, threshold: Double = 0.05) -> Bool {
        guard elapsed > 0 else { return false }
        func isAgent(_ pid: Int32) -> Bool { names[pid].map { commandNames.contains($0) } ?? false }
        func underAgent(_ pid: Int32) -> Bool {
            var current = parents[pid]
            var hops = 0
            while let parent = current, parent > 1, hops < 64 {
                if isAgent(parent) { return true }
                current = parents[parent]
                hops += 1
            }
            return false
        }
        var total: UInt64 = 0
        for (pid, time) in cpu where !isAgent(pid) && underAgent(pid) { total += time }
        return Double(total) / Double(elapsed) >= threshold
    }
}

/// When a sign of agent work starts or extends a session. Ending a session by hand while agents
/// work keeps it off until they've gone quiet, so the next log write doesn't turn it straight back on.
public struct AgentGate: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case nothing
        case start
        case extend
    }

    public var grace: TimeInterval
    public private(set) var lastActivity: Date?
    public private(set) var heldOff = false

    public init(grace: TimeInterval) {
        self.grace = grace
    }

    /// A sign of work at `now`. `session`: one is running; `ours`: it's one this started.
    public mutating func activity(at now: Date, session: Bool, ours: Bool) -> Action {
        let quietBefore = lastActivity.map { now.timeIntervalSince($0) >= grace } ?? true
        lastActivity = now
        if heldOff {
            guard quietBefore else { return .nothing }
            heldOff = false
        }
        if !session { return .start }
        return ours ? .extend : .nothing
    }

    /// The session it started was ended by hand.
    public mutating func endedByHand() {
        heldOff = true
    }

    /// When a session it started should end: the grace after the last sign of work.
    public func end(after now: Date) -> Date {
        (lastActivity ?? now).addingTimeInterval(grace)
    }
}
