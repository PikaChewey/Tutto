//
//  ScriptPlugin.swift
//  Tutto
//
//  Your own plugins: a small action Tutto runs for you, as a shell command, from its shortcut,
//  a link, the Plugins page or (if you put it there) the panel's tools row. Optionally it gets the
//  clipboard's text as its input; its output is shown as a notice, copied, or ignored.
//
//  A plugin is a JSON file in ~/Library/Application Support/Tutto/Plugins, so it can be shared,
//  edited by hand or dropped in. The command runs in a separate process (`/bin/zsh -l -c`, as in
//  Terminal, with your PATH), never inside Tutto, with a time limit and its output capped.
//

import CryptoKit
import Foundation

public struct ScriptPlugin: Codable, Identifiable, Equatable, Sendable {
    public enum Input: String, Codable, CaseIterable, Sendable {
        /// Nothing on standard input.
        case none
        /// The clipboard's text on standard input.
        case clipboard
    }

    public enum Output: String, Codable, CaseIterable, Sendable {
        /// The first lines of what it prints, as a notice.
        case notice
        /// What it prints replaces the clipboard.
        case clipboard
        /// Nothing (a notice only if it fails).
        case silent
    }

    public var id: UUID
    public var name: String
    /// An SF Symbol.
    public var symbol: String
    public var command: String
    public var input: Input
    public var output: Output
    public var enabled: Bool
    /// Seconds before the command is stopped.
    public var timeout: Double

    public static let defaultSymbol = "puzzlepiece.extension"
    public static let longestTimeout: Double = 600

    public init(id: UUID = UUID(), name: String, symbol: String = ScriptPlugin.defaultSymbol, command: String,
                input: Input = .none, output: Output = .notice, enabled: Bool = true, timeout: Double = 30) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.command = command
        self.input = input
        self.output = output
        self.enabled = enabled
        self.timeout = timeout
    }

    /// Hand-written files need only a name and a command.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        command = try c.decode(String.self, forKey: .command)
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? Self.defaultSymbol
        input = try c.decodeIfPresent(Input.self, forKey: .input) ?? .none
        output = try c.decodeIfPresent(Output.self, forKey: .output) ?? .notice
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        timeout = try c.decodeIfPresent(Double.self, forKey: .timeout) ?? 30
    }

    /// Its id in the tools row and among the shortcuts.
    public var toolID: String { "plugin.\(id.uuidString)" }

    /// The name trimmed, or nil when it's empty; the command must have something in it too.
    public var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Starting points on the Plugins page.
    public static let templates: [ScriptPlugin] = [
        ScriptPlugin(name: "Plain Text Clipboard", symbol: "doc.plaintext", command: "cat",
                     input: .clipboard, output: .clipboard),
        ScriptPlugin(name: "Uppercase Clipboard", symbol: "textformat.size.larger", command: "tr '[:lower:]' '[:upper:]'",
                     input: .clipboard, output: .clipboard),
        ScriptPlugin(name: "Count Clipboard Lines", symbol: "list.number", command: "wc -l | tr -d ' '",
                     input: .clipboard, output: .notice),
        ScriptPlugin(name: "Open Downloads", symbol: "arrow.down.circle", command: "open ~/Downloads",
                     input: .none, output: .silent),
    ]
}

// MARK: - Files

/// Plugins as JSON files in a folder: one file each.
public final class PluginStore: @unchecked Sendable {
    public let directory: URL
    /// Where each plugin was read from or written to.
    private var files: [UUID: URL] = [:]
    private let lock = NSLock()

    public init(directory: URL) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Tutto/Plugins", isDirectory: true)
    }

    /// Every plugin in the folder, by name, and a line for each file that couldn't be read.
    public func load() -> (plugins: [ScriptPlugin], problems: [String]) {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var plugins: [ScriptPlugin] = []
        var problems: [String] = []
        var found: [UUID: URL] = [:]
        for url in urls.filter({ $0.pathExtension.lowercased() == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            do {
                let data = try Data(contentsOf: url)
                var plugin = try JSONDecoder().decode(ScriptPlugin.self, from: data)
                // A hand-written file without an id gets one from its name, the same every time.
                if (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] == nil {
                    plugin.id = Self.stableID(for: url.lastPathComponent)
                }
                guard found[plugin.id] == nil else {
                    problems.append("\(url.lastPathComponent): the same id as \(found[plugin.id]!.lastPathComponent)")
                    continue
                }
                found[plugin.id] = url
                plugins.append(plugin)
            } catch {
                problems.append("\(url.lastPathComponent): needs at least a \"name\" and a \"command\"")
            }
        }
        lock.withLock { files = found }
        return (plugins.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }, problems)
    }

    /// Writes the plugin to its file (a new one gets a file named after it).
    @discardableResult
    public func save(_ plugin: ScriptPlugin) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = lock.withLock { files[plugin.id] } ?? newFile(for: plugin.name)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(plugin).write(to: url, options: .atomic)
        lock.withLock { files[plugin.id] = url }
        return url
    }

    public func delete(_ plugin: ScriptPlugin) throws {
        guard let url = lock.withLock({ files[plugin.id] }) else { return }
        try FileManager.default.removeItem(at: url)
        lock.withLock { files[plugin.id] = nil }
    }

    public func file(for plugin: ScriptPlugin) -> URL? { lock.withLock { files[plugin.id] } }

    private func newFile(for name: String) -> URL {
        let slug = Self.slug(name)
        var url = directory.appendingPathComponent("\(slug).json")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(slug)-\(n).json")
            n += 1
        }
        return url
    }

    /// "Plain Text Clipboard" → "plain-text-clipboard".
    public static func slug(_ name: String) -> String {
        let pieces = name.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let joined = pieces.joined(separator: "-")
        return joined.isEmpty ? "plugin" : String(joined.prefix(48))
    }

    static func stableID(for name: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(name.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50  // version 5 style
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let t = (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                 bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])
        return UUID(uuid: t)
    }
}

// MARK: - Running

public struct PluginResult: Equatable, Sendable {
    public var status: Int32
    public var output: String
    public var errors: String
    public var timedOut: Bool
    public var seconds: Double

    public var succeeded: Bool { status == 0 && !timedOut }

    /// The first non-empty lines of what it printed (errors when it failed), for a notice.
    public func summary(lines: Int = 2, of text: String? = nil) -> String {
        let source = text ?? (succeeded ? output : (errors.isEmpty ? output : errors))
        let kept = source.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return kept.prefix(lines).joined(separator: " · ")
    }
}

public enum PluginRunner {
    /// Output beyond this is dropped.
    public static let outputLimit = 64 * 1024

    /// Runs `command` with `/bin/zsh -l -c` (your PATH and settings, as in Terminal) in the home
    /// folder, `input` on standard input, stopping it after `timeout` seconds. Blocks: call it off
    /// the main thread.
    public static func run(_ command: String, input: String?, timeout: Double, name: String = "plugin",
                           shell: String = "/bin/zsh") -> PluginResult {
        let started = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        var environment = ProcessInfo.processInfo.environment
        environment["TUTTO_PLUGIN"] = name
        process.environment = environment
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let stdin = input == nil ? nil : Pipe()
        process.standardInput = stdin ?? FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        let out = Collector(), err = Collector()
        let reading = DispatchGroup()
        for (pipe, collector) in [(stdout, out), (stderr, err)] {
            reading.enter()
            DispatchQueue.global(qos: .utility).async {
                while true {
                    let chunk = pipe.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    collector.append(chunk, limit: outputLimit)
                }
                reading.leave()
            }
        }
        do {
            try process.run()
        } catch {
            return PluginResult(status: -1, output: "", errors: error.localizedDescription, timedOut: false, seconds: 0)
        }
        if let stdin {
            let handle = stdin.fileHandleForWriting
            // A command that exits without reading its input mustn't take Tutto with it: a write to
            // a pipe nobody reads fails with EPIPE here instead of raising SIGPIPE.
            _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
            DispatchQueue.global(qos: .utility).async {
                try? handle.write(contentsOf: Data((input ?? "").utf8))
                try? handle.close()
            }
        }
        var timedOut = false
        if finished.wait(timeout: .now() + max(timeout, 0.1)) == .timedOut {
            timedOut = true
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
        }
        _ = reading.wait(timeout: .now() + 1)
        return PluginResult(status: process.isRunning ? -1 : process.terminationStatus,
                            output: out.text, errors: err.text, timedOut: timedOut,
                            seconds: Date().timeIntervalSince(started))
    }

    private final class Collector: @unchecked Sendable {
        private var data = Data()
        private let lock = NSLock()

        func append(_ chunk: Data, limit: Int) {
            lock.withLock {
                guard data.count < limit else { return }
                data.append(chunk.prefix(limit - data.count))
            }
        }

        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }
}
