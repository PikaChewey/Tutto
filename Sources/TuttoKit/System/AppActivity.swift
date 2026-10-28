//
//  AppActivity.swift
//  TuttoKit
//
//  Which apps are busy right now, read straight from the kernel: each process's CPU time,
//  twice, a moment apart, added up by the app responsible for it, so an app's helper
//  processes count as the app (a browser's forty processes are one row). About 2 ms a
//  reading and no process started, where `top` costs about 100 ms and a child process.
//  Only the logged-in user's processes can be read, so system ones (the window server)
//  are left out; the list is about apps.
//

import AppKit
import Darwin

/// One app and how much processor it used over the last interval.
public struct AppActivity: Equatable, Identifiable, Sendable {
    /// The app's own process (the one responsible for its helpers).
    public let pid: pid_t
    public let name: String
    /// Percent of one core (an app keeping four cores busy shows 400), like Activity Monitor.
    public let cpu: Double
    public var id: pid_t { pid }

    public init(pid: pid_t, name: String, cpu: Double) {
        self.pid = pid
        self.name = name
        self.cpu = cpu
    }
}

/// Samples every readable process's CPU time; `sample()` returns the busiest apps since the
/// previous call. Not thread-safe: call from one queue.
public final class AppActivitySampler {
    private struct Reading {
        let cpuTime: UInt64
        let started: UInt64
    }

    private var last: [pid_t: Reading] = [:]
    private var lastTime: UInt64 = 0
    private let ownPID = getpid()
    private let numer: UInt64
    private let denom: UInt64

    public init() {
        var timebase = mach_timebase_info()
        mach_timebase_info(&timebase)
        numer = UInt64(max(timebase.numer, 1))
        denom = UInt64(max(timebase.denom, 1))
    }

    /// The busiest apps (most first) since the previous call; empty on the first call, which
    /// only takes the starting reading. Apps using less than 0.5 % are left out.
    public func sample(limit: Int = 3) -> [AppActivity] {
        let now = mach_absolute_time()
        var current: [pid_t: Reading] = [:]
        var deltas: [(pid: pid_t, cpuTime: UInt64)] = []
        for pid in Self.allPIDs() where pid > 0 {
            var info = rusage_info_v4()
            let status: Int32 = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { raw -> Int32 in proc_pid_rusage(pid, RUSAGE_INFO_V4, raw) }
            }
            guard status == 0 else { continue }
            let reading = Reading(cpuTime: info.ri_user_time + info.ri_system_time, started: info.ri_proc_start_abstime)
            current[pid] = reading
            // Same process as last time (a reused pid starts at a different moment).
            if let previous = last[pid], previous.started == reading.started, reading.cpuTime > previous.cpuTime {
                deltas.append((pid, reading.cpuTime - previous.cpuTime))
            }
        }
        let elapsed = lastTime == 0 ? 0 : now &- lastTime
        last = current
        lastTime = now
        guard elapsed > 0 else { return [] }
        let ranked = Self.rank(deltas, elapsed: elapsed, responsible: { ProcessInfoLookup.responsiblePID($0) ?? $0 },
                               excluding: [ownPID], limit: limit)
        // Time units cancel out in the percentage, so the timebase isn't needed for it.
        return ranked.map { AppActivity(pid: $0.pid, name: Self.name(of: $0.pid), cpu: $0.cpu) }
    }

    /// Forget the starting reading (the list stopped being shown).
    public func reset() {
        last.removeAll()
        lastTime = 0
    }

    /// Per-process CPU time used over `elapsed` (same units) → per-app percent of one core,
    /// helpers added to the app responsible for them, busiest first, under 0.5 % left out.
    public static func rank(_ deltas: [(pid: pid_t, cpuTime: UInt64)], elapsed: UInt64, responsible: (pid_t) -> pid_t,
                            excluding: Set<pid_t>, limit: Int) -> [(pid: pid_t, cpu: Double)] {
        guard elapsed > 0 else { return [] }
        var byApp: [pid_t: UInt64] = [:]
        for delta in deltas {
            let app = responsible(delta.pid)
            guard !excluding.contains(app), !excluding.contains(delta.pid) else { continue }
            byApp[app, default: 0] += delta.cpuTime
        }
        var apps: [(pid: pid_t, cpu: Double)] = []
        for (pid, time) in byApp {
            let cpu = Double(time) / Double(elapsed) * 100
            if cpu >= 0.5 { apps.append((pid: pid, cpu: cpu)) }
        }
        apps.sort { lhs, rhs in lhs.cpu != rhs.cpu ? lhs.cpu > rhs.cpu : lhs.pid < rhs.pid }
        return Array(apps.prefix(max(limit, 0)))
    }

    /// The app's name, else the process's.
    private static func name(of pid: pid_t) -> String {
        if let name = NSRunningApplication(processIdentifier: pid)?.localizedName { return name }
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : "Process \(pid)"
    }

    private static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(Int(max(filled, 0))))
    }
}
