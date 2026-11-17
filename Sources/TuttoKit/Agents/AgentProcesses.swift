//
//  AgentProcesses.swift
//  TuttoKit
//
//  What each agent costs the Mac: its own process plus everything it started (builds, tests, dev
//  servers), CPU, memory and power added up, read from the kernel (no `ps`, nothing started). And
//  what agents leave behind: dev servers and scripts whose agent has gone, still running with no
//  parent but launchd, often holding a port.
//

import Darwin
import Foundation

/// One process, as the kernel reports it.
public struct ProcessEntry: Equatable, Sendable {
    public var pid: Int32
    public var parent: Int32
    public var uid: UInt32
    public var name: String
    /// CPU time used, in mach time units (as `mach_absolute_time`).
    public var cpuTime: UInt64
    /// Memory, as Activity Monitor's "Memory" (the physical footprint).
    public var memory: UInt64
    /// Energy used so far, in nanojoules.
    public var energy: UInt64
    public var started: Date

    public init(pid: Int32, parent: Int32, uid: UInt32, name: String, cpuTime: UInt64, memory: UInt64, energy: UInt64, started: Date) {
        self.pid = pid
        self.parent = parent
        self.uid = uid
        self.name = name
        self.cpuTime = cpuTime
        self.memory = memory
        self.energy = energy
        self.started = started
    }
}

/// Every readable process now. About 2 ms for 700 processes.
public enum ProcessTable {
    public static func snapshot() -> [Int32: ProcessEntry] {
        var table: [Int32: ProcessEntry] = [:]
        for pid in allPIDs() where pid > 0 {
            if let entry = entry(pid) { table[pid] = entry }
        }
        return table
    }

    public static func entry(_ pid: Int32) -> ProcessEntry? {
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size else { return nil }
        var usage = rusage_info_v6()
        let status: Int32 = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
        }
        let name = withUnsafeBytes(of: bsd.pbi_name) { raw -> String in
            let text = String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            if !text.isEmpty { return text }
            return withUnsafeBytes(of: bsd.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        }
        return ProcessEntry(pid: pid, parent: Int32(bsd.pbi_ppid), uid: bsd.pbi_uid, name: name,
                            cpuTime: status == 0 ? usage.ri_user_time + usage.ri_system_time : 0,
                            memory: status == 0 ? usage.ri_phys_footprint : 0,
                            energy: status == 0 ? usage.ri_energy_nj : 0,
                            started: Date(timeIntervalSince1970: Double(bsd.pbi_start_tvsec) + Double(bsd.pbi_start_tvusec) / 1e6))
    }

    public static func allPIDs() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        return Array(pids.prefix(Int(max(filled, 0))))
    }

    /// The executable's path.
    public static func path(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : nil
    }

    /// Its working folder.
    public static func workingFolder(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return path.isEmpty ? nil : path
    }

    /// TCP ports it's listening on.
    public static func listeningPorts(_ pid: Int32) -> [UInt16] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let count = Int(bytes) / MemoryLayout<proc_fdinfo>.size
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bytes)
        guard filled > 0 else { return [] }
        var ports = Set<UInt16>()
        for fd in fds.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.size) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == SOCKINFO_TCP,
                  info.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let raw = UInt16(truncatingIfNeeded: info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport)
            ports.insert(UInt16(bigEndian: raw))
        }
        return ports.sorted()
    }
}

/// An agent's whole cost: itself and everything under it.
public struct AgentLoad: Equatable, Sendable {
    /// Percent of one core (four busy cores read 400), like Activity Monitor.
    public var cpu: Double
    public var memory: UInt64
    /// Average power over the last interval, in watts, when the kernel reports energy.
    public var watts: Double?
    /// Its processes, itself included.
    public var processes: Int
    /// The busiest process under it when that's not the agent itself ("swift-build").
    public var busiest: String?

    public init(cpu: Double, memory: UInt64, watts: Double?, processes: Int, busiest: String?) {
        self.cpu = cpu
        self.memory = memory
        self.watts = watts
        self.processes = processes
        self.busiest = busiest
    }

    /// So many processes that something is looping (a script spawning without end).
    public static let runawayCount = 200
    public var isRunaway: Bool { processes >= Self.runawayCount }
}

public enum AgentLoads {
    /// Each process's children.
    public static func children(_ table: [Int32: ProcessEntry]) -> [Int32: [Int32]] {
        var children: [Int32: [Int32]] = [:]
        for entry in table.values where entry.parent != entry.pid { children[entry.parent, default: []].append(entry.pid) }
        return children
    }

    /// `root` and everything under it.
    public static func tree(_ root: Int32, children: [Int32: [Int32]]) -> [Int32] {
        var found = [root]
        var seen: Set<Int32> = [root]
        var stack = [root]
        while let pid = stack.popLast() {
            for child in children[pid, default: []] where seen.insert(child).inserted {
                found.append(child)
                stack.append(child)
            }
        }
        return found
    }

    /// The load under `root` between two snapshots `elapsed` mach units apart (`nanosPerUnit` to
    /// turn them into time, for power). Without a previous snapshot, CPU and power read nil-like 0.
    public static func load(root: Int32, current: [Int32: ProcessEntry], previous: [Int32: ProcessEntry]?,
                            children: [Int32: [Int32]], elapsed: UInt64, nanosPerUnit: Double) -> AgentLoad? {
        guard current[root] != nil else { return nil }
        let pids = tree(root, children: children)
        var memory: UInt64 = 0, cpu: UInt64 = 0, energy: UInt64 = 0
        var busiest: (String, UInt64)?
        for pid in pids {
            guard let now = current[pid] else { continue }
            memory &+= now.memory
            if let before = previous?[pid], before.started == now.started {
                let used = now.cpuTime > before.cpuTime ? now.cpuTime - before.cpuTime : 0
                cpu &+= used
                energy &+= now.energy > before.energy ? now.energy - before.energy : 0
                if pid != root, used > (busiest?.1 ?? 0) { busiest = (now.name, used) }
            }
        }
        let seconds = Double(elapsed) * nanosPerUnit / 1e9
        let percent = previous != nil && elapsed > 0 ? Double(cpu) / Double(elapsed) * 100 : 0
        let watts = previous != nil && seconds > 0 && energy > 0 ? Double(energy) / 1e9 / seconds : nil
        // Name what's busy under it only when it's doing real work.
        let busy = busiest.flatMap { previous != nil && elapsed > 0 && Double($0.1) / Double(elapsed) > 0.2 ? $0.0 : nil }
        return AgentLoad(cpu: percent, memory: memory, watts: watts, processes: pids.count, busiest: busy)
    }

    public static var nanosPerMachUnit: Double {
        var timebase = mach_timebase_info()
        mach_timebase_info(&timebase)
        return Double(max(timebase.numer, 1)) / Double(max(timebase.denom, 1))
    }
}

/// A dev server or script whose agent (or terminal) is gone and that's still running.
public struct LeftRunning: Identifiable, Equatable, Sendable {
    public var pid: Int32
    public var name: String
    public var folder: String?
    public var ports: [UInt16]
    public var memory: UInt64
    public var started: Date

    public var id: Int32 { pid }

    public init(pid: Int32, name: String, folder: String?, ports: [UInt16], memory: UInt64, started: Date) {
        self.pid = pid
        self.name = name
        self.folder = folder
        self.ports = ports
        self.memory = memory
        self.started = started
    }
}

public enum LeftRunningRules {
    /// Runtimes agents start dev servers, watchers and scripts with.
    static let runtimes = ["node", "bun", "deno", "python", "ruby", "php", "java", "uvicorn", "gunicorn", "puma", "rails",
                           "npm", "pnpm", "yarn", "npx", "tsx", "next-server", "vite", "esbuild", "turbo", "nodemon", "webpack"]

    /// Orphaned (its parent is launchd), yours, a dev runtime, not part of an app or the system,
    /// and older than a minute (a launcher hands off to launchd for a moment).
    public static func isCandidate(_ entry: ProcessEntry, path: String?, uid: UInt32, now: Date) -> Bool {
        guard entry.parent == 1, entry.uid == uid, now.timeIntervalSince(entry.started) > 60 else { return false }
        let name = entry.name.lowercased()
        guard runtimes.contains(where: { name == $0 || name.hasPrefix($0 + " ") || name.hasPrefix($0 + "-") || name.hasPrefix($0 + "3") })
                || name.hasPrefix("python") else { return false }
        if let path {
            if path.contains(".app/") || path.hasPrefix("/System/") || path.hasPrefix("/usr/libexec/") || path.hasPrefix("/Library/Apple/") {
                return false
            }
        }
        return true
    }

    /// Kept only when it works somewhere real: a launchd job runs in "/", a dev server in its project.
    public static func isInProject(folder: String?, home: String = NSHomeDirectory()) -> Bool {
        guard let folder, folder != "/", folder.hasPrefix(home) else { return false }
        return !folder.hasPrefix(home + "/Library/")
    }

    /// Everything left running now, biggest first.
    public static func find(in table: [Int32: ProcessEntry], uid: UInt32 = getuid(), now: Date = Date(),
                            path: (Int32) -> String? = ProcessTable.path,
                            folder: (Int32) -> String? = ProcessTable.workingFolder,
                            ports: (Int32) -> [UInt16] = ProcessTable.listeningPorts) -> [LeftRunning] {
        table.values.compactMap { entry -> LeftRunning? in
            guard entry.parent == 1, entry.uid == uid else { return nil }
            guard isCandidate(entry, path: path(entry.pid), uid: uid, now: now) else { return nil }
            let where_ = folder(entry.pid)
            guard isInProject(folder: where_) else { return nil }
            return LeftRunning(pid: entry.pid, name: entry.name, folder: where_, ports: ports(entry.pid), memory: entry.memory,
                               started: entry.started)
        }
        .sorted { $0.memory != $1.memory ? $0.memory > $1.memory : $0.pid < $1.pid }
    }
}
