//
//  PluginTriggers.swift
//  Tutto
//
//  What makes a plugin run by itself, what it can ask you for, and what every run is told.
//  The events are the ones a Mac watcher usually offers (sleep, wake, lock, apps, power, the
//  clipboard, the network, displays, schedules) plus Tutto's own (agents, Stay Awake) and custom
//  events any script can send with `open -g "tutto://do/event?name=…&info=…"`. A run learns why it
//  ran from its environment: TUTTO_REASON, TUTTO_EVENT, TUTTO_EVENT_INFO and its settings as
//  TUTTO_SETTING_<KEY>.
//

import Foundation

// MARK: - Events

public enum PluginEvent: String, Codable, CaseIterable, Sendable {
    case launch
    case wake
    case sleep
    case lock
    case unlock
    case powerConnected = "power.connected"
    case powerDisconnected = "power.disconnected"
    case batteryBelow = "battery.below"
    case appLaunched = "app.launched"
    case appQuit = "app.quit"
    case appActivated = "app.activated"
    case clipboardChanged = "clipboard.changed"
    case networkChanged = "network.changed"
    case displayChanged = "display.changed"
    case every
    case daily
    case agentsStarted = "agents.started"
    case agentsFinished = "agents.finished"
    case awakeStarted = "stayawake.started"
    case awakeEnded = "stayawake.ended"
    case custom

    /// How the trigger reads in a sentence ("When …").
    public var title: String {
        switch self {
        case .launch: "Tutto starts"
        case .wake: "The Mac wakes"
        case .sleep: "The Mac goes to sleep"
        case .lock: "The screen locks"
        case .unlock: "The screen unlocks"
        case .powerConnected: "Power is connected"
        case .powerDisconnected: "Power is disconnected"
        case .batteryBelow: "The battery falls below"
        case .appLaunched: "An app opens"
        case .appQuit: "An app quits"
        case .appActivated: "You switch to an app"
        case .clipboardChanged: "You copy something"
        case .networkChanged: "The network changes"
        case .displayChanged: "A display is connected or removed"
        case .every: "Every"
        case .daily: "Every day at"
        case .agentsStarted: "Agents start working"
        case .agentsFinished: "Agents finish"
        case .awakeStarted: "Stay Awake starts"
        case .awakeEnded: "Stay Awake ends"
        case .custom: "A custom event"
        }
    }

    /// What TUTTO_EVENT_INFO holds for it.
    public var infoDescription: String? {
        switch self {
        case .batteryBelow, .powerConnected, .powerDisconnected: "the battery's charge in %"
        case .appLaunched, .appQuit, .appActivated: "the app's bundle id"
        case .networkChanged: "the connection: wifi, ethernet, cellular, other or none"
        case .displayChanged: "how many displays there are now"
        case .custom: "the info sent with the event"
        case .clipboardChanged: "nothing (with Input set to Clipboard, the text arrives on standard input)"
        default: nil
        }
    }

    /// The menu order on the Plugins page: what people reach for first.
    public static let menuOrder: [[PluginEvent]] = [
        [.every, .daily],
        [.batteryBelow, .powerConnected, .powerDisconnected],
        [.wake, .sleep, .lock, .unlock, .launch],
        [.appLaunched, .appQuit, .appActivated],
        [.clipboardChanged, .networkChanged, .displayChanged],
        [.agentsStarted, .agentsFinished, .awakeStarted, .awakeEnded],
        [.custom],
    ]
}

/// An event that runs a plugin's command, with what it needs to know.
public struct PluginTrigger: Codable, Equatable, Hashable, Sendable {
    public var event: PluginEvent
    /// battery.below: the charge, in %.
    public var percent: Int?
    /// app.*: a bundle id or an app's name (any app when empty).
    public var app: String?
    /// every: minutes between runs.
    public var minutes: Int?
    /// daily: "HH:MM", 24-hour.
    public var at: String?
    /// custom: the event's name.
    public var name: String?

    public init(event: PluginEvent, percent: Int? = nil, app: String? = nil, minutes: Int? = nil,
                at: String? = nil, name: String? = nil) {
        self.event = event
        self.percent = percent
        self.app = app
        self.minutes = minutes
        self.at = at
        self.name = name
    }

    enum CodingKeys: String, CodingKey {
        case event = "on", percent, app, minutes, at, name
    }

    /// The event in any case; numbers may be written as text ("15"); an unknown event is an error
    /// (the plugin keeps its other triggers, and Tutto keeps this one in the file).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let text = try c.decode(String.self, forKey: .event)
        guard let event = PluginEvent(rawValue: text.lowercased()) else {
            throw DecodingError.dataCorruptedError(forKey: .event, in: c, debugDescription: "Unknown event \(text)")
        }
        func number(_ key: CodingKeys) -> Int? {
            if let value = try? c.decodeIfPresent(Int.self, forKey: key) { return value }
            if let value = try? c.decodeIfPresent(Double.self, forKey: key), value.isFinite { return Int(exactly: value.rounded()) }
            if let text = try? c.decodeIfPresent(String.self, forKey: key) { return Int(text.trimmingCharacters(in: .whitespaces)) }
            return nil
        }
        self.event = event
        percent = number(.percent).map { min(max($0, 1), 99) }
        minutes = number(.minutes).map { min(max($0, 1), 7 * 24 * 60) }
        app = try? c.decodeIfPresent(String.self, forKey: .app)
        at = try? c.decodeIfPresent(String.self, forKey: .at)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
    }

    /// The trigger as it starts in the editor, with sensible values.
    public static func starting(_ event: PluginEvent) -> PluginTrigger {
        switch event {
        case .batteryBelow: PluginTrigger(event: event, percent: 20)
        case .every: PluginTrigger(event: event, minutes: 30)
        case .daily: PluginTrigger(event: event, at: "09:00")
        case .custom: PluginTrigger(event: event, name: "my-event")
        default: PluginTrigger(event: event)
        }
    }

    /// A line for the Plugins page: "Every 30 min", "When Safari opens", …
    public var summary: String {
        switch event {
        case .every: "Every \(max(minutes ?? 30, 1)) min"
        case .daily: "Every day at \(at ?? "09:00")"
        case .batteryBelow: "Battery below \(percent ?? 20) %"
        case .appLaunched, .appQuit, .appActivated:
            app.map { $0.isEmpty ? event.title : "\(event.title): \($0)" } ?? event.title
        case .custom: "Event “\(name ?? "")”"
        default: event.title
        }
    }

    /// Whether an app event is about this app (any app when the trigger names none).
    public func matches(bundleID: String?, appName: String?) -> Bool {
        guard let wanted = app?.trimmingCharacters(in: .whitespaces), !wanted.isEmpty else { return true }
        return [bundleID, appName].compactMap { $0 }.contains { $0.caseInsensitiveCompare(wanted) == .orderedSame }
    }

    /// "HH:MM" as hour and minute.
    public var dailyTime: (hour: Int, minute: Int)? {
        let parts = (at ?? "").split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
        return (parts[0], parts[1])
    }
}

// MARK: - Settings

/// A field a plugin asks for (a folder, an address, a token), shown as a form on the Plugins page.
public struct PluginSetting: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case text, number, toggle, choice, folder
        /// Kept in the Keychain, never in a file.
        case secret
    }

    public var key: String
    public var title: String
    public var kind: Kind
    public var defaultValue: String
    /// The choices of a `choice`.
    public var options: [String]
    public var help: String?

    public init(key: String, title: String, kind: Kind = .text, defaultValue: String = "", options: [String] = [],
                help: String? = nil) {
        self.key = key
        self.title = title
        self.kind = kind
        self.defaultValue = defaultValue
        self.options = options
        self.help = help
    }

    enum CodingKeys: String, CodingKey {
        case key, title, kind = "type", defaultValue = "default", options, help
    }

    /// A default may be written as text, a number or true/false.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? key
        let kindText = ((try? c.decodeIfPresent(String.self, forKey: .kind)) ?? nil)?.lowercased() ?? "text"
        guard let kind = Kind(rawValue: kindText) else {
            // An unknown type isn't guessed at (a misspelt "secret" mustn't become plain text).
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unknown setting type \(kindText)")
        }
        self.kind = kind
        if let text = try? c.decodeIfPresent(String.self, forKey: .defaultValue) {
            defaultValue = text
        } else if let flag = try? c.decodeIfPresent(Bool.self, forKey: .defaultValue) {
            defaultValue = flag ? "true" : "false"
        } else if let number = try? c.decodeIfPresent(Double.self, forKey: .defaultValue), number.isFinite {
            // Whole numbers without a decimal point, as long as they fit; anything else as written.
            defaultValue = Int(exactly: number).map(String.init) ?? String(number)
        } else {
            defaultValue = ""
        }
        options = (try? c.decodeIfPresent([String].self, forKey: .options)) ?? []
        help = try? c.decodeIfPresent(String.self, forKey: .help)
        guard !key.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .key, in: c, debugDescription: "A setting needs a key.")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .key)
        try c.encode(title, forKey: .title)
        try c.encode(kind, forKey: .kind)
        if !defaultValue.isEmpty { try c.encode(defaultValue, forKey: .defaultValue) }
        if !options.isEmpty { try c.encode(options, forKey: .options) }
        try c.encodeIfPresent(help, forKey: .help)
    }

    /// Its name in a command's environment: "repo-folder" → TUTTO_SETTING_REPO_FOLDER.
    public var environmentName: String {
        "TUTTO_SETTING_" + String(key.uppercased().map { $0.isLetter || $0.isNumber ? $0 : "_" })
    }
}

// MARK: - A run's environment

/// Why a plugin ran.
public enum PluginRunReason: String, Sendable {
    /// From its button, shortcut or tile.
    case run
    /// From a tutto:// link.
    case link
    /// To fill its card.
    case widget
    /// By a trigger.
    case trigger
    /// Try It in the editor.
    case test
}

public enum PluginEnvironment {
    /// TUTTO_EVENT_INFO is cut to this many characters (a custom event's info comes from a link,
    /// so it's whatever the sender wrote: quote it, and put `--` before it in commands).
    public static let longestInfo = 1_000

    /// What a run is told, on top of the usual environment.
    public static func make(plugin: ScriptPlugin, reason: PluginRunReason, event: String? = nil, info: String? = nil,
                            values: [String: String] = [:], folder: URL? = nil) -> [String: String] {
        var environment: [String: String] = [
            "TUTTO_PLUGIN": plugin.name,
            "TUTTO_PLUGIN_ID": plugin.id.uuidString,
            "TUTTO_REASON": reason.rawValue,
        ]
        if let event { environment["TUTTO_EVENT"] = String(event.prefix(200)) }
        if let info { environment["TUTTO_EVENT_INFO"] = String(info.prefix(PluginEnvironment.longestInfo)) }
        if let folder { environment["TUTTO_PLUGIN_DIR"] = folder.path }
        for setting in plugin.settings {
            environment[setting.environmentName] = values[setting.key] ?? setting.defaultValue
        }
        return environment
    }
}

// MARK: - Timing

public enum PluginSchedule {
    /// When an `every` or `daily` trigger next fires after `date` (nil for other events or a bad time).
    public static func next(_ trigger: PluginTrigger, after date: Date, calendar: Calendar = .current) -> Date? {
        switch trigger.event {
        case .every:
            return date.addingTimeInterval(Double(max(trigger.minutes ?? 30, 1)) * 60)
        case .daily:
            guard let time = trigger.dailyTime else { return nil }
            return calendar.nextDate(after: date, matching: DateComponents(hour: time.hour, minute: time.minute, second: 0),
                                     matchingPolicy: .nextTime, direction: .forward)
        default:
            return nil
        }
    }
}

/// "Battery below N %" fires once on the way down, on battery; it fires again only after the
/// charge has come back 3 points above N or the Mac was plugged in.
public struct BatteryWatch: Equatable, Sendable {
    public private(set) var armed = true

    public init() {}

    public mutating func update(charge: Int, onBattery: Bool, below threshold: Int) -> Bool {
        if !onBattery || charge >= threshold + 3 {
            armed = true
            return false
        }
        guard armed, charge < threshold else { return false }
        armed = false
        return true
    }
}

/// At most `limit` runs in any `window` seconds: a trigger that sets itself off (a plugin that
/// copies on "You copy something") can't run away.
public struct RunBudget: Sendable {
    public let limit: Int
    public let window: TimeInterval
    private var times: [Date] = []

    public init(limit: Int = 12, window: TimeInterval = 60) {
        self.limit = limit
        self.window = window
    }

    public mutating func allow(at date: Date = Date()) -> Bool {
        times.removeAll { date.timeIntervalSince($0) >= window }
        guard times.count < limit else { return false }
        times.append(date)
        return true
    }
}
