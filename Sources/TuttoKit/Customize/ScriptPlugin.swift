//
//  ScriptPlugin.swift
//  Tutto
//
//  Your own plugins (Bryan, 2026-11-10: "plugins that add real features"). A plugin declares what
//  it adds, and Tutto draws it with its own components and the current theme:
//  - an action: a shell command run from its shortcut, a link, the Plugins page, the panel's tools
//    row or a trigger, optionally with the clipboard's text as input; its output is shown as a
//    notice, copied, or ignored;
//  - a card on the panel: a command whose output (a value, or JSON) is what the card shows,
//    refreshed while the panel is open (or in the background, if asked);
//  - triggers: events that run the action by themselves (wake, battery low, an app opening, …);
//  - settings: typed fields Tutto shows as a form, passed to its commands as TUTTO_SETTING_<KEY>.
//
//  A plugin is a JSON file in ~/Library/Application Support/Tutto/Plugins, or a folder there with
//  a plugin.json and its scripts, so it can be shared, edited by hand or dropped in. Commands run in
//  a separate process (`/bin/zsh -l -c`, as in Terminal, with your PATH), never inside Tutto, with a
//  time limit and their output capped.
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

    /// A card on the panel: what its command prints is what it shows (see `PluginWidgetContent`).
    public struct Widget: Codable, Equatable, Sendable {
        public var command: String
        /// Seconds between runs while it's on screen.
        public var every: Double
        public var size: WidgetSize
        /// Kept up to date while the panel is closed too (at most every 10 s).
        public var background: Bool

        /// The shortest gaps between runs, on screen and in the background.
        public static let shortest: Double = 2
        public static let shortestInBackground: Double = 10

        public init(command: String, every: Double = 30, size: WidgetSize = .small, background: Bool = false) {
            self.command = command
            self.every = every
            self.size = size
            self.background = background
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            command = try c.decode(String.self, forKey: .command)
            every = (try? c.decodeIfPresent(Double.self, forKey: .every)) ?? 30
            size = (try? c.decodeIfPresent(WidgetSize.self, forKey: .size)) ?? .small
            background = (try? c.decodeIfPresent(Bool.self, forKey: .background)) ?? false
        }

        /// The gap between runs, kept to the floors.
        public func interval(background inBackground: Bool) -> Double {
            max(every, inBackground ? Self.shortestInBackground : Self.shortest)
        }
    }

    public var id: UUID
    public var name: String
    /// An SF Symbol.
    public var symbol: String
    /// What it does when it runs; empty for a plugin that only shows a card.
    public var command: String
    public var input: Input
    public var output: Output
    public var enabled: Bool
    /// Seconds before a command is stopped.
    public var timeout: Double
    public var widget: Widget?
    /// Events that run its command by themselves.
    public var triggers: [PluginTrigger]
    /// Fields it asks for, shown as a form on the Plugins page.
    public var settings: [PluginSetting]

    public static let defaultSymbol = "puzzlepiece.extension"
    public static let longestTimeout: Double = 600

    public init(id: UUID = UUID(), name: String, symbol: String = ScriptPlugin.defaultSymbol, command: String,
                input: Input = .none, output: Output = .notice, enabled: Bool = true, timeout: Double = 30,
                widget: Widget? = nil, triggers: [PluginTrigger] = [], settings: [PluginSetting] = []) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.command = command
        self.input = input
        self.output = output
        self.enabled = enabled
        self.timeout = timeout
        self.widget = widget
        self.triggers = triggers
        self.settings = settings
    }

    enum CodingKeys: String, CodingKey {
        case id, name, symbol, command, input, output, enabled, timeout, widget, triggers, settings
    }

    /// Hand-written files need only a name and a command (or a widget). A trigger or setting this
    /// Tutto doesn't know is skipped, not fatal.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? Self.defaultSymbol
        input = try c.decodeIfPresent(Input.self, forKey: .input) ?? .none
        output = try c.decodeIfPresent(Output.self, forKey: .output) ?? .notice
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        timeout = try c.decodeIfPresent(Double.self, forKey: .timeout) ?? 30
        widget = try c.decodeIfPresent(Widget.self, forKey: .widget)
        triggers = ((try? c.decodeIfPresent([Lenient<PluginTrigger>].self, forKey: .triggers)) ?? []).compactMap(\.value)
        settings = ((try? c.decodeIfPresent([Lenient<PluginSetting>].self, forKey: .settings)) ?? []).compactMap(\.value)
        guard hasAction || hasWidget else {
            throw DecodingError.dataCorruptedError(forKey: .command, in: c, debugDescription: "A plugin needs a command or a widget.")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(symbol, forKey: .symbol)
        if hasAction || !triggers.isEmpty {
            try c.encode(command, forKey: .command)
            try c.encode(input, forKey: .input)
            try c.encode(output, forKey: .output)
        }
        try c.encode(enabled, forKey: .enabled)
        try c.encode(timeout, forKey: .timeout)
        try c.encodeIfPresent(widget, forKey: .widget)
        if !triggers.isEmpty { try c.encode(triggers, forKey: .triggers) }
        if !settings.isEmpty { try c.encode(settings, forKey: .settings) }
    }

    /// It has something to run.
    public var hasAction: Bool { !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// It has a card for the panel.
    public var hasWidget: Bool { !(widget?.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }

    /// Its id in the tools row and among the shortcuts.
    public var toolID: String { Self.toolPrefix + id.uuidString }

    public static let toolPrefix = "plugin."

    /// Whether a tools-row id is a plugin's (rather than one of Tutto's tools).
    public static func isToolID(_ id: String) -> Bool { id.hasPrefix(toolPrefix) }

    /// Its card's id among the panel's cards.
    public var widgetID: String { Self.widgetPrefix + id.uuidString }

    public static let widgetPrefix = "widget.plugin."

    /// Whether a panel card is a plugin's.
    public static func isWidgetID(_ id: String) -> Bool { id.hasPrefix(widgetPrefix) }

    /// The plugin a card belongs to.
    public static func pluginID(fromWidgetID id: String) -> UUID? {
        guard isWidgetID(id) else { return nil }
        return UUID(uuidString: String(id.dropFirst(widgetPrefix.count)))
    }

    /// A name, and something to do: a command, or a card (triggers need a command to run).
    public var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (hasAction || hasWidget)
            && (triggers.isEmpty || hasAction)
    }

    /// Why it can't be saved yet, in a line.
    public var problem: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Give it a name." }
        if !hasAction && !hasWidget { return "Give it a command, or a card with a command." }
        if !triggers.isEmpty && !hasAction { return "Its triggers need a command to run." }
        return nil
    }

    /// What kind of plugin it is, for the Plugins page.
    public var kinds: [String] {
        var kinds: [String] = []
        if hasAction { kinds.append(triggers.isEmpty ? "Action" : "Automation") }
        if hasWidget { kinds.append("Card") }
        return kinds
    }

    /// Starting points on the Plugins page: actions, cards and automations that work on any Mac.
    public static let templates: [ScriptPlugin] = [
        // Actions
        ScriptPlugin(name: "Plain Text Clipboard", symbol: "doc.plaintext", command: "cat",
                     input: .clipboard, output: .clipboard),
        ScriptPlugin(name: "Uppercase Clipboard", symbol: "textformat.size.larger", command: "tr '[:lower:]' '[:upper:]'",
                     input: .clipboard, output: .clipboard),
        ScriptPlugin(name: "Count Clipboard Lines", symbol: "list.number", command: "wc -l | tr -d ' '",
                     input: .clipboard, output: .notice),
        ScriptPlugin(name: "Open Downloads", symbol: "arrow.down.circle", command: "open ~/Downloads",
                     input: .none, output: .silent),
        // Cards
        ScriptPlugin(name: "Git Changes", symbol: "arrow.triangle.branch", command: "",
                     widget: Widget(command: """
                     cd "${TUTTO_SETTING_FOLDER/#\\~/$HOME}" 2>/dev/null || { echo '{"value":"—","detail":"Choose a folder in its settings","level":"notice"}'; exit 0; }
                     branch=$(git branch --show-current 2>/dev/null) || { echo '{"value":"—","detail":"Not a repository","level":"notice"}'; exit 0; }
                     changed=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
                     printf '{"value":"%s","unit":"changed","detail":"%s","level":"%s"}\\n' "$changed" "${branch:-detached}" "$([ "$changed" -gt 0 ] && echo notice || echo normal)"
                     """, every: 20),
                     settings: [PluginSetting(key: "folder", title: "Repository", kind: .folder, defaultValue: "~/Documents",
                                              help: "A folder with a Git repository.")]),
        ScriptPlugin(name: "Ping", symbol: "antenna.radiowaves.left.and.right", command: "",
                     widget: Widget(command: """
                     t=$(ping -c 1 -t 2 "$TUTTO_SETTING_HOST" 2>/dev/null | sed -nE 's/.*time=([0-9.]+) ms.*/\\1/p')
                     if [ -n "$t" ]; then printf '{"value":"%.0f","unit":"ms","detail":"%s"}\\n' "$t" "$TUTTO_SETTING_HOST"
                     else printf '{"value":"Offline","detail":"%s didn\u{2019}t reply","level":"alert"}\\n' "$TUTTO_SETTING_HOST"; fi
                     """, every: 15),
                     settings: [PluginSetting(key: "host", title: "Address", kind: .text, defaultValue: "1.1.1.1",
                                              help: "A name or address that answers ping.")]),
        ScriptPlugin(name: "Uptime", symbol: "clock.arrow.circlepath", command: "",
                     widget: Widget(command: """
                     uptime | sed -E 's/.*up +([^,]+),.*/\\1/'
                     echo "since the last restart"
                     """, every: 60)),
        // Automations
        ScriptPlugin(name: "Battery Low Notice", symbol: "battery.25percent",
                     command: "echo \"Battery at ${TUTTO_EVENT_INFO}%: plug in soon\"", output: .notice,
                     triggers: [PluginTrigger(event: .batteryBelow, percent: 20)]),
        ScriptPlugin(name: "When Agents Finish", symbol: "checkmark.circle",
                     command: "afplay /System/Library/Sounds/Glass.aiff &\necho \"Your agents are done\"", output: .notice,
                     triggers: [PluginTrigger(event: .agentsFinished)]),
        ScriptPlugin(name: "Clean Copied Links", symbol: "link",
                     command: """
                     url=$(cat)
                     case "$url" in http*\\?*utm_*|http*\\?*fbclid=*|http*\\?*gclid=*) ;; *) exit 0 ;; esac
                     printf '%s' "$url" | sed -E 's/([?&])(utm_[a-z_]+|fbclid|gclid)=[^&]*&?/\\1/g; s/[?&]$//'
                     """, input: .clipboard, output: .clipboard,
                     triggers: [PluginTrigger(event: .clipboardChanged)]),
        ScriptPlugin(name: "Stretch Reminder", symbol: "figure.walk",
                     command: "echo \"Time to stand up and stretch\"", output: .notice,
                     triggers: [PluginTrigger(event: .every, minutes: 50)]),
        ScriptPlugin(name: "Build Finished", symbol: "hammer",
                     command: "say \"${TUTTO_EVENT_INFO:-Build finished}\"", output: .silent,
                     triggers: [PluginTrigger(event: .custom, name: "build-done")]),
    ]

    /// The templates in their groups, for the New Plugin menu.
    public static var templateGroups: [(title: String, plugins: [ScriptPlugin])] {
        [("Actions", templates.filter { $0.hasAction && $0.triggers.isEmpty && !$0.hasWidget }),
         ("Cards", templates.filter(\.hasWidget)),
         ("Automations", templates.filter { !$0.triggers.isEmpty })]
    }
}

/// Decodes what it can and skips the rest (one bad trigger doesn't lose the plugin).
struct Lenient<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

// MARK: - Files

/// Plugins as JSON files in a folder: one file each.
public final class PluginStore: @unchecked Sendable {
    public let directory: URL
    /// Where each plugin was read from or written to.
    private var files: [UUID: URL] = [:]
    /// The folder of a plugin that has one (its commands run there).
    private var folders: [UUID: URL] = [:]
    private let lock = NSLock()

    /// Deleting moves to the Trash (tests delete outright).
    private let usesTrash: Bool

    public init(directory: URL, usesTrash: Bool = true) {
        self.directory = directory
        self.usesTrash = usesTrash
    }

    public static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Tutto/Plugins", isDirectory: true)
    }

    /// Every plugin in the folder, by name, and a line for each file that couldn't be read. A
    /// plugin is a .json file, or a folder with a plugin.json (and the scripts it runs).
    public func load() -> (plugins: [ScriptPlugin], problems: [String]) {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var candidates: [(file: URL, name: String, folder: URL?)] = []
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let manifest = url.appendingPathComponent("plugin.json")
                if FileManager.default.fileExists(atPath: manifest.path) {
                    candidates.append((manifest, url.lastPathComponent + "/plugin.json", url))
                }
            } else if url.pathExtension.lowercased() == "json" {
                candidates.append((url, url.lastPathComponent, nil))
            }
        }
        var plugins: [ScriptPlugin] = []
        var problems: [String] = []
        var found: [UUID: URL] = [:]
        var folders: [UUID: URL] = [:]
        for candidate in candidates {
            do {
                let data = try Data(contentsOf: candidate.file)
                var plugin = try JSONDecoder().decode(ScriptPlugin.self, from: data)
                // A hand-written file without an id gets one from its name, the same every time.
                if (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] == nil {
                    plugin.id = Self.stableID(for: candidate.name)
                }
                guard found[plugin.id] == nil else {
                    problems.append("\(candidate.name): the same id as \(found[plugin.id]!.lastPathComponent)")
                    continue
                }
                found[plugin.id] = candidate.file
                folders[plugin.id] = candidate.folder
                plugins.append(plugin)
            } catch {
                problems.append("\(candidate.name): needs at least a \"name\" and a \"command\" (or a \"widget\")")
            }
        }
        lock.withLock {
            files = found
            self.folders = folders
        }
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

    /// Moves the plugin's file (or its folder) to the Trash.
    public func delete(_ plugin: ScriptPlugin) throws {
        let (file, folder) = lock.withLock { (files[plugin.id], folders[plugin.id]) }
        guard let url = folder ?? file else { return }
        if usesTrash {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } else {
            try FileManager.default.removeItem(at: url)
        }
        lock.withLock {
            files[plugin.id] = nil
            folders[plugin.id] = nil
        }
    }

    public func file(for plugin: ScriptPlugin) -> URL? { lock.withLock { files[plugin.id] } }

    /// The plugin's own folder, when it's a folder plugin.
    public func folder(for plugin: ScriptPlugin) -> URL? { lock.withLock { folders[plugin.id] } }

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
    /// folder (or `directory`, a folder plugin's own), `input` on standard input and `environment`
    /// added to the usual one, stopping it after `timeout` seconds. Blocks: call it off the main thread.
    public static func run(_ command: String, input: String?, timeout: Double, name: String = "plugin",
                           environment extra: [String: String] = [:], directory: URL? = nil,
                           shell: String = "/bin/zsh") -> PluginResult {
        let started = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", command]
        process.currentDirectoryURL = directory ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        var environment = ProcessInfo.processInfo.environment
        environment["TUTTO_PLUGIN"] = name
        environment.merge(extra) { _, new in new }
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
