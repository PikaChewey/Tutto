//
//  Plugins.swift
//  Tutto
//
//  Your plugins at work: the list from the Plugins folder, which you've switched on, the settings
//  you gave them, their cards' contents and their last runs. A plugin found in the folder that you
//  didn't make here starts switched off until you've seen what it runs (it runs as you, like any
//  script). Runs happen off the main thread, one at a time per plugin; a trigger can't set a
//  plugin off more than 12 times a minute.
//

import AppKit
import Observation
import os
import Security
import TuttoKit

let pluginLog = Logger(subsystem: "ca.bryanyao.Tutto", category: "plugins")

/// Names of the plugins for their shortcuts (Shortcuts page, conflicts), read off the main actor.
enum PluginShortcuts {
    nonisolated(unsafe) static var names: [UUID: String] = [:]
    nonisolated(unsafe) static var ids: [UUID] = []
    nonisolated(unsafe) static var enabled: Set<UUID> = []
}

/// One run of a plugin, for the list of its recent runs.
struct PluginRun: Identifiable {
    let id = UUID()
    var date: Date
    var reason: PluginRunReason
    var event: String?
    var result: PluginResult

    /// "Trigger · battery.below", "Card", "Run".
    var why: String {
        let base = switch reason {
        case .run: "Run"
        case .link: "Link"
        case .widget: "Card"
        case .trigger: "Trigger"
        case .test: "Try It"
        }
        return event.map { "\(base) · \($0)" } ?? base
    }
}

/// What a plugin's card shows now.
struct PluginCardState: Equatable {
    var content: PluginWidgetContent?
    var updated: Date?
    var running = false
    /// Why the last run failed, in a line.
    var failure: String?
}

@MainActor
@Observable
final class PluginsModel {
    private(set) var plugins: [ScriptPlugin] = []
    /// Files in the folder that couldn't be read.
    private(set) var problems: [String] = []
    private(set) var running: Set<UUID> = []
    private(set) var lastResults: [UUID: PluginResult] = [:]
    /// The last runs of each plugin, newest first.
    private(set) var runs: [UUID: [PluginRun]] = [:]
    /// Plugins you've switched on or made here.
    private(set) var allowed: Set<UUID>
    /// The settings you've set, by plugin and key (secrets are in the Keychain).
    private(set) var values: [UUID: [String: String]]
    private(set) var cards: [UUID: PluginCardState] = [:]

    let store = PluginStore(directory: PluginStore.defaultDirectory)
    @ObservationIgnored let host = PluginHost()
    /// An offscreen render: cards may fill, but nothing runs by itself.
    @ObservationIgnored var quiet = false
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var budgets: [UUID: RunBudget] = [:]
    /// The pasteboard's change count after Tutto last wrote it ("You copy something" skips it).
    @ObservationIgnored private(set) var ownPasteboardChange = -1
    private var model: AppModel { AppModel.shared }

    static let keptRuns = 12

    init() {
        allowed = Set((UserDefaults.standard.stringArray(forKey: Keys.allowed) ?? []).compactMap(UUID.init(uuidString:)))
        let saved = UserDefaults.standard.data(forKey: Keys.values)
            .flatMap { try? JSONDecoder().decode([String: [String: String]].self, from: $0) } ?? [:]
        values = Dictionary(uniqueKeysWithValues: saved.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
    }

    var folder: URL { store.directory }

    func plugin(_ id: UUID) -> ScriptPlugin? { plugins.first { $0.id == id } }

    func plugin(named name: String) -> ScriptPlugin? {
        plugins.first { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    /// Switched on, and allowed to run.
    func isOn(_ plugin: ScriptPlugin) -> Bool { plugin.enabled && allowed.contains(plugin.id) }

    /// Found in the folder and not switched on here yet.
    func isNew(_ plugin: ScriptPlugin) -> Bool { !allowed.contains(plugin.id) }

    /// Plugins whose card the panel can show.
    var cardPlugins: [ScriptPlugin] { plugins.filter { isOn($0) && $0.hasWidget } }

    // MARK: The folder

    /// Reads the folder again (a file added or edited by hand shows up).
    func load() {
        let loaded = store.load()
        plugins = loaded.plugins
        problems = loaded.problems
        if defaults.object(forKey: Keys.allowed) == nil {
            // The first time plugins can be new: the ones already here were in use, so they stay on.
            allowed = Set(plugins.map(\.id))
            saveAllowed()
        }
        // A plugin new to Tutto stays out of the tools row until you put it there.
        var seen = Set(defaults.stringArray(forKey: Keys.seen) ?? [])
        let unseen = plugins.map(\.toolID).filter { !seen.contains($0) }
        if !unseen.isEmpty {
            model.layout.update { layout in
                for id in unseen where !layout.tools.order.contains(id) { layout.tools.hidden.insert(id) }
            }
            seen.formUnion(unseen)
            defaults.set(Array(seen).sorted(), forKey: Keys.seen)
        }
        cards = cards.filter { id, _ in plugins.contains { $0.id == id } }
        publish()
    }

    /// Saves a new or edited plugin (made here, so it's yours and on); returns why it couldn't be.
    @discardableResult
    func save(_ plugin: ScriptPlugin, inPanel: Bool? = nil, values newValues: [String: String]? = nil) -> String? {
        if let problem = plugin.problem { return problem }
        do {
            try store.save(plugin)
        } catch {
            return error.localizedDescription
        }
        let previous = self.plugin(plugin.id)
        if let index = plugins.firstIndex(where: { $0.id == plugin.id }) { plugins[index] = plugin } else { plugins.append(plugin) }
        plugins.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        allowed.insert(plugin.id)
        saveAllowed()
        if previous == nil {
            var seen = Set(defaults.stringArray(forKey: Keys.seen) ?? [])
            seen.insert(plugin.toolID)
            defaults.set(Array(seen).sorted(), forKey: Keys.seen)
        }
        if let inPanel {
            model.layout.update { $0.tools.set(plugin.toolID, shown: inPanel) }
        } else if previous == nil {
            model.layout.update { $0.tools.set(plugin.toolID, shown: false) }
        }
        if let newValues { setValues(newValues, for: plugin) }
        // A card whose command changed shows the new command's output.
        if previous?.widget != plugin.widget { cards[plugin.id] = nil }
        publish()
        return nil
    }

    /// Moves it to the Trash, with its settings, secrets and shortcut.
    func delete(_ plugin: ScriptPlugin) {
        try? store.delete(plugin)
        plugins.removeAll { $0.id == plugin.id }
        lastResults[plugin.id] = nil
        runs[plugin.id] = nil
        cards[plugin.id] = nil
        values[plugin.id] = nil
        saveValues()
        for setting in plugin.settings where setting.kind == .secret { PluginSecrets.write(nil, plugin: plugin.id, key: setting.key) }
        allowed.remove(plugin.id)
        saveAllowed()
        model.shortcuts.reset(.plugin(plugin.id))
        model.layout.update { layout in
            layout.tools.order.removeAll { $0 == plugin.toolID }
            layout.tools.hidden.remove(plugin.toolID)
            layout.widgets.order.removeAll { $0 == plugin.widgetID }
            layout.widgets.hidden.remove(plugin.widgetID)
            layout.sizes[plugin.widgetID] = nil
        }
        publish()
    }

    /// On allows it to run (a new one too); off stops its card and triggers.
    func setEnabled(_ plugin: ScriptPlugin, _ on: Bool) {
        if on {
            allowed.insert(plugin.id)
            saveAllowed()
        }
        guard plugin.enabled != on else { return publish() }
        var changed = plugin
        changed.enabled = on
        do {
            try store.save(changed)
        } catch {
            return Toast.shared.show("Couldn't change \(plugin.name)", detail: error.localizedDescription, duration: 3)
        }
        if let index = plugins.firstIndex(where: { $0.id == plugin.id }) { plugins[index] = changed }
        if !on { cards[plugin.id] = nil }
        publish()
    }

    func isInPanel(_ plugin: ScriptPlugin) -> Bool { model.layout.layout.tools.isShown(plugin.toolID) }

    /// Shortcuts, names, triggers and cards follow the list.
    private func publish() {
        PluginShortcuts.names = Dictionary(uniqueKeysWithValues: plugins.map { ($0.id, $0.name) })
        PluginShortcuts.ids = plugins.map(\.id)
        PluginShortcuts.enabled = Set(plugins.filter(isOn).map(\.id))
        model.bindShortcuts()
        if !quiet { host.refresh() }
    }

    // MARK: Settings

    /// What a setting is set to (its default until you set it).
    func value(_ setting: PluginSetting, of plugin: ScriptPlugin) -> String {
        if setting.kind == .secret { return PluginSecrets.read(plugin: plugin.id, key: setting.key) ?? "" }
        return values[plugin.id]?[setting.key] ?? setting.defaultValue
    }

    func setValues(_ newValues: [String: String], for plugin: ScriptPlugin) {
        var kept = values[plugin.id] ?? [:]
        for setting in plugin.settings {
            guard let value = newValues[setting.key] else { continue }
            if setting.kind == .secret {
                PluginSecrets.write(value.isEmpty ? nil : value, plugin: plugin.id, key: setting.key)
            } else {
                kept[setting.key] = value == setting.defaultValue ? nil : value
            }
        }
        values[plugin.id] = kept.isEmpty ? nil : kept
        saveValues()
    }

    /// What a run is given: each setting's value, or its default.
    func environmentValues(for plugin: ScriptPlugin, overriding draft: [String: String]? = nil) -> [String: String] {
        var result: [String: String] = [:]
        for setting in plugin.settings {
            result[setting.key] = draft?[setting.key] ?? value(setting, of: plugin)
        }
        return result
    }

    // MARK: Running

    func run(_ id: UUID, reason: PluginRunReason = .run) {
        guard let plugin = plugin(id) else { return }
        run(plugin, reason: reason)
    }

    /// Runs its command in its own process, off the main thread, at most one run at a time.
    func run(_ plugin: ScriptPlugin, reason: PluginRunReason = .run, event: String? = nil, info: String? = nil) {
        guard isOn(plugin), plugin.hasAction, !running.contains(plugin.id) else { return }
        if reason == .trigger {
            var budget = budgets[plugin.id] ?? RunBudget()
            defer { budgets[plugin.id] = budget }
            guard budget.allow() else {
                pluginLog.notice("\(plugin.name, privacy: .public): trigger \(event ?? "", privacy: .public) skipped, 12 runs in the last minute")
                return
            }
        }
        running.insert(plugin.id)
        let input = plugin.input == .clipboard ? (NSPasteboard.general.string(forType: .string) ?? "") : nil
        let environment = PluginEnvironment.make(plugin: plugin, reason: reason, event: event, info: info,
                                                 values: environmentValues(for: plugin), folder: store.folder(for: plugin))
        pluginLog.notice("run \(plugin.name, privacy: .public) (\(reason.rawValue, privacy: .public)\(event.map { " " + $0 } ?? "", privacy: .public))")
        Self.execute(plugin.command, input: input, timeout: plugin.timeout, name: plugin.name,
                     environment: environment, folder: store.folder(for: plugin)) { [self] result in
            running.remove(plugin.id)
            record(plugin, reason: reason, event: event, result: result)
            finished(plugin, result, reason: reason)
        }
    }

    /// Fills a plugin's card from its card command.
    func refreshCard(_ plugin: ScriptPlugin) {
        guard isOn(plugin), plugin.hasWidget, let widget = plugin.widget, cards[plugin.id]?.running != true else { return }
        cards[plugin.id, default: PluginCardState()].running = true
        let environment = PluginEnvironment.make(plugin: plugin, reason: .widget, values: environmentValues(for: plugin),
                                                 folder: store.folder(for: plugin))
        Self.execute(widget.command, input: nil, timeout: min(plugin.timeout, 20), name: plugin.name,
                     environment: environment, folder: store.folder(for: plugin)) { [self] result in
            var state = cards[plugin.id] ?? PluginCardState()
            state.running = false
            state.updated = Date()
            if result.succeeded {
                state.content = PluginWidgetContent.parse(result.output)
                state.failure = nil
            } else {
                state.failure = Self.failureLine(result, timeout: min(plugin.timeout, 20))
            }
            guard self.plugin(plugin.id) != nil else { return }
            cards[plugin.id] = state
            // Cards refresh often: only failures go in the list of runs.
            if !result.succeeded { record(plugin, reason: .widget, event: nil, result: result) }
        }
    }

    /// Try It: runs a plugin as it is in the editor (unsaved), with the editor's settings.
    func trial(_ plugin: ScriptPlugin, card: Bool, values draft: [String: String], done: @escaping (PluginResult) -> Void) {
        let input = !card && plugin.input == .clipboard ? (NSPasteboard.general.string(forType: .string) ?? "") : nil
        let environment = PluginEnvironment.make(plugin: plugin, reason: card ? .widget : .test,
                                                 values: environmentValues(for: plugin, overriding: draft),
                                                 folder: store.folder(for: plugin))
        Self.execute(card ? (plugin.widget?.command ?? "") : plugin.command, input: input,
                     timeout: min(plugin.timeout, ScriptPlugin.longestTimeout), name: plugin.name,
                     environment: environment, folder: store.folder(for: plugin), done: done)
    }

    private static func execute(_ command: String, input: String?, timeout: Double, name: String,
                                environment: [String: String], folder: URL?,
                                done: @escaping @MainActor (PluginResult) -> Void) {
        let limit = min(max(timeout, 1), ScriptPlugin.longestTimeout)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = PluginRunner.run(command, input: input, timeout: limit, name: name,
                                          environment: environment, directory: folder)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(result) } }
        }
    }

    static func failureLine(_ result: PluginResult, timeout: Double) -> String {
        if result.timedOut { return "Stopped after \(Int(timeout)) s" }
        let why = result.summary(lines: 1)
        return why.isEmpty ? "Exit \(result.status)" : why
    }

    private func record(_ plugin: ScriptPlugin, reason: PluginRunReason, event: String?, result: PluginResult) {
        if reason != .widget { lastResults[plugin.id] = result }
        var list = runs[plugin.id] ?? []
        list.insert(PluginRun(date: Date(), reason: reason, event: event, result: result), at: 0)
        runs[plugin.id] = Array(list.prefix(Self.keptRuns))
        pluginLog.notice("\(plugin.name, privacy: .public): exit \(result.status) in \(Int(result.seconds * 1000)) ms\(result.timedOut ? ", timed out" : "", privacy: .public)")
    }

    private func finished(_ plugin: ScriptPlugin, _ result: PluginResult, reason: PluginRunReason) {
        if result.timedOut {
            return Toast.shared.show("\(plugin.name) stopped", detail: "It ran longer than \(Int(plugin.timeout)) s.", duration: 3)
        }
        guard result.succeeded else {
            let why = result.summary()
            return Toast.shared.show("\(plugin.name) failed", detail: why.isEmpty ? "It exited with \(result.status)." : why, duration: 3)
        }
        switch plugin.output {
        case .notice:
            let text = result.summary()
            // A trigger with nothing to say stays quiet.
            if text.isEmpty && reason == .trigger { return }
            Toast.shared.show(plugin.name, detail: text.isEmpty ? "Done" : text, duration: text.count > 60 ? 3 : 1.8)
        case .clipboard:
            // One trailing newline (what most commands end with) isn't part of the result, and
            // nothing printed leaves the clipboard alone (an image copied stays copied).
            var text = result.output
            if text.hasSuffix("\n") { text.removeLast() }
            guard !text.isEmpty else {
                if reason != .trigger { Toast.shared.show(plugin.name, detail: "Nothing to copy") }
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            ownPasteboardChange = NSPasteboard.general.changeCount
            Toast.shared.show(plugin.name, detail: "Copied \(text.count.formatted()) character\(text.count == 1 ? "" : "s")")
        case .silent:
            break
        }
    }

    // MARK: Saving

    private func saveAllowed() {
        defaults.set(allowed.map(\.uuidString).sorted(), forKey: Keys.allowed)
    }

    private func saveValues() {
        let plain = Dictionary(uniqueKeysWithValues: values.map { ($0.key.uuidString, $0.value) })
        if let data = try? JSONEncoder().encode(plain) { defaults.set(data, forKey: Keys.values) }
    }

    private enum Keys {
        static let seen = "plugins.seen"
        static let allowed = "plugins.allowed"
        static let values = "plugins.values"
    }
}

// MARK: - Secrets

/// A plugin's secret settings (tokens, passwords), in your login keychain, never in a file.
enum PluginSecrets {
    private static let service = "ca.bryanyao.Tutto.plugin"

    private static func account(_ plugin: UUID, _ key: String) -> String { "\(plugin.uuidString).\(key)" }

    static func read(plugin: UUID, key: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account(plugin, key), kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Stores it (nil removes it).
    static func write(_ value: String?, plugin: UUID, key: String) {
        let match: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account(plugin, key)]
        guard let value else {
            SecItemDelete(match as CFDictionary)
            return
        }
        let data = Data(value.utf8)
        if SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var add = match
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Tutto plugin setting"
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
