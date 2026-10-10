//
//  TopProcesses.swift
//  Tutto
//
//  "Which apps are using my battery?" Energy impact is only computable for every
//  process (including root-owned ones like WindowServer) by /usr/bin/top, which is
//  setuid root and uses the same model as Activity Monitor's Energy tab. Tutto runs
//  one streaming `top` only while a view that shows processes is on screen, and
//  stops it the moment that view goes away.
//

import AppKit
import Foundation

public struct ProcessSample: Identifiable, Equatable, Sendable {
    public var id: Int32 { pid }
    public var pid: Int32
    public var name: String
    /// Percent of one core, like Activity Monitor (can exceed 100).
    public var cpu: Double
    public var memory: UInt64
    /// Activity Monitor's "Energy Impact".
    public var energyImpact: Double
}

public final class TopProcessStream: @unchecked Sendable {
    public enum SortKey: String, Sendable {
        case power, cpu, mem
    }

    private let sort: SortKey
    private let count: Int
    private let interval: Int
    private let onSample: @Sendable ([ProcessSample]) -> Void
    private let lock = NSLock()
    private var process: Process?
    private var buffer = ""
    private var samplesSeen = 0

    public init(sort: SortKey, count: Int = 6, interval: Int = 2, onSample: @escaping @Sendable ([ProcessSample]) -> Void) {
        self.sort = sort
        self.count = count
        self.interval = interval
        self.onSample = onSample
    }

    deinit { stop() }

    public var isRunning: Bool { lock.withLock { process?.isRunning ?? false } }

    public func start() {
        stop()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        process.arguments = ["-l", "0", "-s", "\(interval)", "-o", sort.rawValue, "-n", "\(count + 2)",
                             "-stats", "pid,command,cpu,mem,power"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else {
                handle.readabilityHandler = nil
                return
            }
            self.consume(String(decoding: data, as: UTF8.self))
        }
        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return
        }
        lock.withLock {
            self.process = process
            self.buffer = ""
            self.samplesSeen = 0
        }
    }

    public func stop() {
        let running = lock.withLock { () -> Process? in
            defer { process = nil }
            return process
        }
        guard let running else { return }
        (running.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if running.isRunning { running.terminate() }
    }

    // MARK: Parsing

    private func consume(_ text: String) {
        let blocks: [String] = lock.withLock {
            buffer += text
            // Each sample starts with "Processes:"; everything before the last marker is complete.
            var parts = buffer.components(separatedBy: "Processes:")
            buffer = parts.removeLast()
            return parts.filter { !$0.isEmpty }
        }
        for block in blocks {
            let isFirst = lock.withLock { () -> Bool in
                samplesSeen += 1
                return samplesSeen == 1
            }
            // The first sample has no previous one to measure against: CPU and energy read 0.
            if isFirst { continue }
            let samples = Self.parse(block)
            onSample(Array(samples.prefix(count)))
        }
    }

    /// Parses one `top` sample (the rows after the PID header). Exposed for tests.
    public static func parse(_ block: String) -> [ProcessSample] {
        var rows: [ProcessSample] = []
        var inTable = false
        for line in block.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("PID") {
                inTable = true
                continue
            }
            guard inTable else { continue }
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 5, let pid = Int32(fields[0]), pid > 0 else { continue }
            let power = Double(fields[fields.count - 1].filter { $0.isNumber || $0 == "." }) ?? 0
            let memory = parseBytes(String(fields[fields.count - 2]))
            let cpu = Double(fields[fields.count - 3].filter { $0.isNumber || $0 == "." }) ?? 0
            let command = fields[1..<(fields.count - 3)].joined(separator: " ")
            rows.append(ProcessSample(pid: pid, name: displayName(pid: pid, command: command), cpu: cpu,
                                      memory: memory, energyImpact: power))
        }
        return rows
    }

    /// "211M", "81M+", "5424K", "1.2G" → bytes.
    static func parseBytes(_ text: String) -> UInt64 {
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
        guard let unit = trimmed.last else { return 0 }
        let number = Double(trimmed.dropLast()) ?? Double(trimmed) ?? 0
        switch unit {
        case "K": return UInt64(number * 1024)
        case "M": return UInt64(number * 1024 * 1024)
        case "G": return UInt64(number * 1024 * 1024 * 1024)
        case "B": return UInt64(number)
        default: return UInt64(Double(trimmed) ?? 0)
        }
    }

    /// `top` truncates names to 16 characters; apps get their real name.
    static func displayName(pid: Int32, command: String) -> String {
        if let app = NSRunningApplication(processIdentifier: pid), let name = app.localizedName {
            return name
        }
        var buffer = [CChar](repeating: 0, count: 256)
        if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 {
            let name = String(cString: buffer)
            if !name.isEmpty { return name }
        }
        return command
    }
}
