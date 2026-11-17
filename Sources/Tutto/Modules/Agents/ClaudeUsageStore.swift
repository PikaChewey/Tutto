//
//  ClaudeUsageStore.swift
//  Tutto
//
//  Claude's replies on this Mac, for its limit estimate (TuttoKit's ClaudeLimitEstimator). Claude
//  Code's transcripts run to gigabytes (tool output, pictures), so they're read once, through a
//  memory map (nothing loaded whole), and after that only the bytes added since; what was found is
//  kept on disk (a few MB) so a launch doesn't read them again. All of it on one background queue.
//

import Foundation
import os
import TuttoKit

final class ClaudeUsageStore: @unchecked Sendable {
    /// How far back replies are kept: calibration points older than this are forgotten.
    static let horizon: TimeInterval = 45 * 86_400

    private struct Mark: Codable {
        var size: Int64
        var offset: Int64
    }

    private struct Cache: Codable {
        var version = 1
        var marks: [String: Mark]
        /// Packed replies: time (Double), cost (Double), key (UInt64), 24 bytes each.
        var events: Data
        var hitTimes: [Double]
        var hitKinds: [String]
    }

    private let queue = DispatchQueue(label: "ca.bryanyao.Tutto.agent-usage", qos: .utility)
    private let log = Logger(subsystem: "ca.bryanyao.Tutto", category: "agents")
    private var marks: [String: Mark] = [:]
    private var events: [ClaudeUsageEvent] = []
    private var keys = Set<UInt64>()
    private var hits: [ClaudeLimitHit] = []
    private var snapshot: ClaudeUsageSnapshot?
    private var snapshotDate: Date?
    private var snapshotRead = Date.distantPast
    private var loaded = false
    private var dirty = Set<String>()
    private var pending: DispatchWorkItem?
    private var lastSaved = Date.distantPast
    private var changedSinceSave = false
    /// Called on the main queue with each new estimate.
    var onEstimate: (@MainActor (AgentLimits?) -> Void)?

    static var projects: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true) }
    static var settings: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json") }
    private static var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tutto", isDirectory: true).appendingPathComponent("agent-usage.plist")
    }

    /// Reads everything new (all of it the first time) and estimates.
    func refresh() {
        queue.async { [self] in
            sweep(full: true)
            publish()
        }
    }

    /// Transcripts were written: read them in a while (they're written many times a minute).
    func changed(_ paths: [String]) {
        queue.async { [self] in
            dirty.formUnion(paths.filter { $0.hasSuffix(".jsonl") })
            guard pending == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pending = nil
                self.sweep(full: false)
                self.publish()
            }
            pending = work
            queue.asyncAfter(deadline: .now() + 15, execute: work)
        }
    }

    /// Estimates again (a window may have reset) without reading anything new.
    func recompute() {
        queue.async { [self] in publish() }
    }

    func save() {
        queue.async { [self] in persist() }
    }

    // MARK: Reading

    private func sweep(full: Bool) {
        if !loaded {
            load()
            loaded = true
        }
        let began = CFAbsoluteTimeGetCurrent()
        var paths: [String]
        if full {
            paths = Self.recentTranscripts()
        } else {
            paths = Array(dirty)
        }
        dirty.removeAll()
        var found = ClaudeLogScanner.Found()
        var read: Int64 = 0
        for path in paths {
            guard let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value else {
                marks[path] = nil
                continue
            }
            var mark = marks[path] ?? Mark(size: 0, offset: 0)
            if size < mark.offset { mark.offset = 0 }  // rewritten: replies already counted are skipped by key
            guard size > mark.offset else { continue }
            autoreleasepool {
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) else { return }
                let consumed = data.withUnsafeBytes { raw -> Int in
                    let slice = UnsafeRawBufferPointer(rebasing: raw[Int(mark.offset)...])
                    return ClaudeLogScanner.scan(slice, into: &found)
                }
                read += Int64(consumed)
                mark.offset += Int64(consumed)
                mark.size = size
            }
            marks[path] = mark
        }
        merge(found)
        if read > 0 {
            changedSinceSave = true
            let ms = Int((CFAbsoluteTimeGetCurrent() - began) * 1000)
            log.notice("agents: read \(read / 1_000_000) MB of Claude transcripts in \(ms) ms, \(self.events.count) replies kept")
        }
        // A large first read is worth keeping at once; after that, every few minutes.
        if changedSinceSave, (read > 50_000_000 || Date().timeIntervalSince(lastSaved) > 300) { persist() }
    }

    private func merge(_ found: ClaudeLogScanner.Found) {
        let cutoff = Date().addingTimeInterval(-Self.horizon)
        var outOfOrder = false
        for event in found.events where event.time > cutoff && keys.insert(event.key).inserted {
            if let last = events.last, event.time < last.time { outOfOrder = true }
            events.append(event)
        }
        if outOfOrder { events.sort { $0.time < $1.time } }
        for hit in found.hits where hit.time > cutoff {
            // The same message comes back on each retry and in resumed transcripts: once per half hour.
            if !hits.contains(where: { $0.kind == hit.kind && abs($0.time.timeIntervalSince(hit.time)) < 1800 }) {
                hits.append(hit)
            }
        }
        hits.sort { $0.time < $1.time }
        if let first = events.first, first.time < cutoff {
            let keep = events.firstIndex { $0.time >= cutoff } ?? events.count
            for event in events[..<keep] { keys.remove(event.key) }
            events.removeFirst(keep)
        }
    }

    /// Transcripts written within the horizon.
    private static func recentTranscripts() -> [String] {
        let cutoff = Date().addingTimeInterval(-horizon)
        guard let walker = FileManager.default.enumerator(at: projects, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                                          options: [.skipsHiddenFiles]) else { return [] }
        var paths: [String] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            if let modified = values?.contentModificationDate, modified >= cutoff { paths.append(url.path) }
        }
        return paths
    }

    // MARK: Estimating

    private func publish() {
        readSnapshot()
        let estimate = ClaudeLimitEstimator.estimate(events: events, hits: hits, snapshot: snapshot, now: Date())
        let callback = onEstimate
        DispatchQueue.main.async { MainActor.assumeIsolated { callback?(estimate) } }
    }

    /// Claude Code's last /usage reading, read again when its settings file changes (at most every
    /// few minutes: it's rewritten whenever a session starts).
    private func readSnapshot() {
        guard Date().timeIntervalSince(snapshotRead) > 180 || snapshot == nil else { return }
        snapshotRead = Date()
        let modified = (try? FileManager.default.attributesOfItem(atPath: Self.settings.path)[.modificationDate]) as? Date
        guard modified != snapshotDate else { return }
        snapshotDate = modified
        if let data = try? Data(contentsOf: Self.settings), let parsed = ClaudeUsageSnapshot.parse(data) { snapshot = parsed }
    }

    // MARK: Keeping

    private func load() {
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let cache = try? PropertyListDecoder().decode(Cache.self, from: data), cache.version == 1 else { return }
        marks = cache.marks
        let count = cache.events.count / 24
        events.reserveCapacity(count)
        cache.events.withUnsafeBytes { raw in
            for i in 0..<count {
                let time = raw.loadUnaligned(fromByteOffset: i * 24, as: Double.self)
                let cost = raw.loadUnaligned(fromByteOffset: i * 24 + 8, as: Double.self)
                let key = raw.loadUnaligned(fromByteOffset: i * 24 + 16, as: UInt64.self)
                events.append(ClaudeUsageEvent(time: Date(timeIntervalSince1970: time), cost: cost, key: key))
                keys.insert(key)
            }
        }
        hits = zip(cache.hitTimes, cache.hitKinds).compactMap { time, kind in
            ClaudeLimitHit.Kind(rawValue: kind).map { ClaudeLimitHit(time: Date(timeIntervalSince1970: time), kind: $0) }
        }
        // Transcripts gone or past the horizon are dropped from the marks.
        let cutoff = Date().addingTimeInterval(-Self.horizon)
        marks = marks.filter { path, _ in
            ((try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date).map { $0 >= cutoff } ?? false
        }
    }

    private func persist() {
        var packed = Data(capacity: events.count * 24)
        for event in events {
            var time = event.time.timeIntervalSince1970, cost = event.cost, key = event.key
            withUnsafeBytes(of: &time) { packed.append(contentsOf: $0) }
            withUnsafeBytes(of: &cost) { packed.append(contentsOf: $0) }
            withUnsafeBytes(of: &key) { packed.append(contentsOf: $0) }
        }
        let cache = Cache(marks: marks, events: packed, hitTimes: hits.map { $0.time.timeIntervalSince1970 }, hitKinds: hits.map(\.kind.rawValue))
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(cache) else { return }
        try? FileManager.default.createDirectory(at: Self.cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.cacheURL, options: .atomic)
        lastSaved = Date()
        changedSinceSave = false
    }
}
