//
//  AgentWatcher.swift
//  Tutto
//
//  Signs of coding agents at work, for Stay Awake's "While agents work": macOS reports each write
//  to the folders agents keep their session logs in (an FSEvents stream, so nothing runs between
//  writes), and, asked once a minute during a session it started, whether the commands agents
//  started are keeping the processor busy (a build writes nothing to the log until it's done).
//

import CoreServices
import Darwin
import Foundation
import TuttoKit

@MainActor
final class AgentWatcher {
    /// Called on the main thread at most every few seconds while agents write.
    var onActivity: (() -> Void)?

    private var stream: FSEventStreamRef?
    private var lastReported = Date.distantPast
    private var lastCPU: [Int32: (time: UInt64, started: UInt64)] = [:]
    private var lastSample: UInt64 = 0

    /// The log folders that exist on this Mac.
    static var folders: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return AgentWork.logFolders.map { home.appendingPathComponent($0, isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    var isRunning: Bool { stream != nil }

    func start() {
        guard stream == nil else { return }
        let paths = Self.folders.map(\.path) as CFArray
        guard CFArrayGetCount(paths) > 0 else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        guard let stream = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<AgentWatcher>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.changed() }
        }, &context, paths, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        lastCPU.removeAll()
        lastSample = 0
    }

    private func changed() {
        // Logs are written many times a minute while an agent works: one report every 15 s is plenty.
        guard Date().timeIntervalSince(lastReported) >= 15 else { return }
        lastReported = Date()
        onActivity?()
    }

    /// Whether commands agents started kept the processor busy since the last call (false on the
    /// first call, which only takes the starting reading).
    func toolsBusy() -> Bool {
        let now = mach_absolute_time()
        let parents = ProcessTree.parents()
        var current: [Int32: (time: UInt64, started: UInt64)] = [:]
        var deltas: [Int32: UInt64] = [:]
        var names: [Int32: String] = [:]
        var buffer = [CChar](repeating: 0, count: 256)
        for pid in parents.keys where pid > 1 {
            var info = rusage_info_v4()
            let status: Int32 = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard status == 0 else { continue }
            let reading = (time: info.ri_user_time + info.ri_system_time, started: info.ri_proc_start_abstime)
            current[pid] = reading
            if let previous = lastCPU[pid], previous.started == reading.started, reading.time > previous.time {
                deltas[pid] = reading.time - previous.time
            }
            if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 { names[pid] = String(cString: buffer) }
        }
        let elapsed = lastSample == 0 ? 0 : now &- lastSample
        lastCPU = current
        lastSample = now
        return AgentWork.toolsBusy(cpu: deltas, parents: parents, names: names, elapsed: elapsed)
    }
}
