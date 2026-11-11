//
//  Plugins.swift
//  Tutto
//
//  Your plugins at work: the list from the Plugins folder, which you've approved and switched on,
//  the settings you gave them, their cards' contents and their last runs.
//
//  Trust: a plugin runs only once you've approved it, and an approval holds for exactly what you
//  approved: its file (and a folder plugin's scripts) as they were. One that turns up in the
//  folder, or changes there, waits for you ("New" or "Changed"). Plugins you make or save here
//  are approved as saved. Tutto keeps on and off itself, so switching a plugin never rewrites it.
//
//  Runs happen off the main thread, one at a time per plugin; a trigger can't set a plugin off
//  more than 12 times a minute. A private copy (a password) never reaches a plugin.
//

import AppKit
import LocalAuthentication
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
    /// Where a plugin stands with you.
    enum Standing {
        /// Approved as it is.
        case approved
        /// Never approved.
        case new
        /// Approved once, but its file or scripts have changed on disk since.
        case changed
    }

    private(set) var plugins: [ScriptPlugin] = []
    /// Files in the folder that couldn't be read.
    private(set) var problems: [String] = []
    private(set) var running: Set<UUID> = []
    private(set) var lastResults: [UUID: PluginResult] = [:]
    /// The last runs of each plugin, newest first.
    private(set) var runs: [UUID: [PluginRun]] = [:]
    /// What you approved: each plugin's fingerprint when you did.
    private(set) var approved: [UUID: String]
    /// Plugins you've switched off here.
    private(set) var disabled: Set<UUID>
    /// The settings you've set, by plugin and key (secrets are in the Keychain).
    private(set) var values: [UUID: [String: String]]
    private(set) var cards: [UUID: PluginCardState] = [:]

    let store = PluginStore(directory: PluginStore.defaultDirectory)
    @ObservationIgnored let host = PluginHost()
    /// An offscreen render: cards may fill, but nothing runs by itself.
    @ObservationIgnored var quiet = false
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var budgets: [UUID: RunBudget] = [:]
    /// Secrets read from the Keychain once each (not at every card refresh).
    @ObservationIgnored private var secrets: [UUID: [String: String]] = [:]
    /// The pasteboard's change count after Tutto, or a plugin it ran, last changed it ("You copy
    /// something" skips it).
    @ObservationIgnored private(set) var ownPasteboardChange = -1
    private var model: AppModel { AppModel.shared }

    static let keptRuns = 12

    init() {
        let defaults = UserDefaults.standard
        let savedApprovals = (defaults.dictionary(forKey: Keys.approved) as? [String: String]) ?? [:]
        approved = Dictionary(uniqueKeysWithValues: savedApprovals.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
        disabled = Set((defaults.stringArray(forKey: Keys.disabled) ?? []).compactMap(UUID.init(uuidString:)))
        let saved = defaults.data(forKey: Keys.values)
            .flatMap { try? JSONDecoder().decode([String: [String: String]].self, from: $0) } ?? [:]
        values = Dictionary(uniqueKeysWithValues: saved.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
    }

    var folder: URL { store.directory }

    func plugin(_ id: UUID) -> ScriptPlugin? { plugins.first { $0.id == id } }

    func plugin(named name: String) -> ScriptPlugin? {
        plugins.first { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    func standing(_ plugin: ScriptPlugin) -> Standing {
        guard let fingerprint = approved[plugin.id] else { return .new }
        return fingerprint == store.fingerprint(for: plugin.id) ? .approved : .changed
    }

    /// Approved as it is now, and not switched off.
    func isOn(_ plugin: ScriptPlugin) -> Bool { standing(plugin) == .approved && !disabled.contains(plugin.id) }

    /// Waiting for you to look at it (new, or changed since you approved it).
    func isNew(_ plugin: ScriptPlugin) -> Bool { standing(plugin) != .approved }

    /// Plugins whose card the panel can show.
    var cardPlugins: [ScriptPlugin] { plugins.filter { isOn($0) && $0.hasWidget } }

    // MARK: The folder

    /// Reads the folder again (a file added or edited by hand shows up).
    func load() {
        let loaded = store.load()
        plugins = loaded.plugins
        problems = loaded.problems
        if defaults.object(forKey: Keys.approved) == nil {
            // The first time approvals are kept: what was already here (or approved by the
            // earlier list) was in use, so it stays on as it is.
            let earlier = defaults.stringArray(forKey: Keys.oldAllowed).map { Set($0.compactMap(UUID.init(uuidString:))) }
            for plugin in plugins where earlier?.contains(plugin.id) ?? true {
                approved[plugin.id] = store.fingerprint(for: plugin.id)
            }
            defaults.removeObject(forKey: Keys.oldAllowed)
        }
        // Approvals and switches for plugins that are gone go with them (a different file
        // later saved under the same name starts as new).
        let present = Set(plugins.map(\.id))
        approved = approved.filter { present.contains($0.key) }
        disabled.formIntersection(present)
        // A file that says "enabled": false starts switched off, the first time it's seen.
        var seen = Set(defaults.stringArray(forKey: Keys.seen) ?? [])
        for plugin in plugins where !plugin.enabled && !seen.contains(plugin.toolID) { disabled.insert(plugin.id) }
        saveTrust()
        // A plugin new to Tutto stays out of the tools row until you put it there.
        let unseen = plugins.map(\.toolID).filter { !seen.contains($0) }
        if !unseen.isEmpty {
            model.layout.update { layout in
                for id in unseen where !layout.tools.order.contains(id) { layout.tools.hidden.insert(id) }
            }
            seen.formUnion(unseen)
            defaults.set(Array(seen).sorted(), forKey: Keys.seen)
        }
        cards = cards.filter { id, _ in present.contains(id) }
        secrets = secrets.filter { present.contains($0.key) }
        publish()
        // An offscreen render fills the cards once (nothing refreshes or runs by itself there).
        if quiet { cardPlugins.forEach(refreshCard) }
    }

    /// Saves a new or edited plugin (made here, so it's approved as saved, and on); returns why it
    /// couldn't be.
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
        approved[plugin.id] = store.fingerprint(for: plugin.id)
        disabled.remove(plugin.id)
        saveTrust()
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
        secrets[plugin.id] = nil
        approved[plugin.id] = nil
        disabled.remove(plugin.id)
        saveTrust()
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

    /// On approves it as it is now (a new or changed one too); off stops its card and triggers.
    /// The plugin's file isn't touched.
    func setEnabled(_ plugin: ScriptPlugin, _ on: Bool) {
        if on {
            approved[plugin.id] = store.fingerprint(for: plugin.id)
            disabled.remove(plugin.id)
        } else {
            disabled.insert(plugin.id)
            cards[plugin.id] = nil
        }
        saveTrust()
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
        if setting.kind == .secret { return secret(setting.key, of: plugin.id) ?? "" }
        return values[plugin.id]?[setting.key] ?? setting.defaultValue
    }

    func setValues(_ newValues: [String: String], for plugin: ScriptPlugin) {
        var kept = values[plugin.id] ?? [:]
        for setting in plugin.settings {
            guard let value = newValues[setting.key] else { continue }
            if setting.kind == .secret {
                PluginSecrets.write(value.isEmpty ? nil : value, plugin: plugin.id, key: setting.key)
                secrets[plugin.id, default: [:]][setting.key] = value
                // A setting that became a secret leaves no copy in plain text.
                kept[setting.key] = nil
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

    /// A secret, read from the Keychain the first time it's needed (without ever asking: a locked
    /// keychain gives nothing rather than a prompt at every card refresh).
    private func secret(_ key: String, of plugin: UUID) -> String? {
        if let cached = secrets[plugin]?[key] { return cached }
        let value = PluginSecrets.read(plugin: plugin, key: key) ?? ""
        secrets[plugin, default: [:]][key] = value
        return value
    }

    // MARK: Running

    func run(_ id: UUID, reason: PluginRunReason = .run) {
        guard let plugin = plugin(id) else { return }
        run(plugin, reason: reason)
    }

    /// Runs its command in its own process, off the main thread, at most one run at a time.
    func run(_ plugin: ScriptPlugin, reason: PluginRunReason = .run, event: String? = nil, info: String? = nil) {
        guard isOn(plugin), plugin.hasAction, !running.contains(plugin.id) else { return }
        var input: String?
        if plugin.input == .clipboard {
            // A password (or anything marked private) never goes to a plugin: a run you started
            // gets nothing on its input; one that started by itself doesn't run.
            if Self.clipboardIsPrivate() {
                guard reason != .trigger else {
                    pluginLog.notice("\(plugin.name, privacy: .public): skipped, the clipboard holds something private")
                    return
                }
                input = ""
                Toast.shared.show(plugin.name, detail: "The clipboard holds something private: it got nothing.", duration: 2.5)
            } else {
                input = NSPasteboard.general.string(forType: .string) ?? ""
            }
        }
        if reason == .trigger {
            var budget = budgets[plugin.id] ?? RunBudget()
            defer { budgets[plugin.id] = budget }
            guard budget.allow() else {
                pluginLog.notice("\(plugin.name, privacy: .public): trigger \(event ?? "", privacy: .public) skipped, 12 runs in the last minute")
                return
            }
        }
        running.insert(plugin.id)
        let pasteboardBefore = NSPasteboard.general.changeCount
        let environment = PluginEnvironment.make(plugin: plugin, reason: reason, event: event, info: info,
                                                 values: environmentValues(for: plugin), folder: store.folder(for: plugin))
        pluginLog.notice("run \(plugin.name, privacy: .public) (\(reason.rawValue, privacy: .public)\(event.map { " " + $0 } ?? "", privacy: .public))")
        Self.execute(plugin.command, input: input, timeout: plugin.timeout, name: plugin.name,
                     environment: environment, folder: store.folder(for: plugin)) { [self] result in
            running.remove(plugin.id)
            // A copy the plugin made itself (pbcopy) is Tutto's own: it doesn't set off "You copy something".
            if NSPasteboard.general.changeCount != pasteboardBefore { ownPasteboardChange = NSPasteboard.general.changeCount }
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
            guard let current = self.plugin(plugin.id) else { return }
            var state = cards[plugin.id] ?? PluginCardState()
            let wasAlert = state.content?.level == .alert
            state.running = false
            state.updated = Date()
            if result.succeeded {
                state.content = PluginWidgetContent.parse(result.output)
                state.failure = nil
            } else {
                state.failure = Self.failureLine(result, timeout: min(plugin.timeout, 20))
            }
            cards[plugin.id] = state
            // Cards refresh often: only failures go in the list of runs.
            if !result.succeeded { record(plugin, reason: .widget, event: nil, result: result) }
            // A card watched with the panel closed says when it turns to alert.
            if current.widget?.background == true, !wasAlert, let content = state.content, content.level == .alert {
                Toast.shared.show(content.title ?? plugin.name,
                                  detail: [content.value, content.unit, content.detail].compactMap { $0 }.joined(separator: " "),
                                  duration: 4)
            }
        }
    }

    /// Try It: runs a plugin as it is in the editor (unsaved), with the editor's settings.
    func trial(_ plugin: ScriptPlugin, card: Bool, values draft: [String: String], done: @escaping (PluginResult) -> Void) {
        var input: String?
        if !card && plugin.input == .clipboard {
            input = Self.clipboardIsPrivate() ? "" : (NSPasteboard.general.string(forType: .string) ?? "")
        }
        let environment = PluginEnvironment.make(plugin: plugin, reason: card ? .widget : .test,
                                                 values: environmentValues(for: plugin, overriding: draft),
                                                 folder: store.folder(for: plugin))
        Self.execute(card ? (plugin.widget?.command ?? "") : plugin.command, input: input,
                     timeout: min(plugin.timeout, ScriptPlugin.longestTimeout), name: plugin.name,
                     environment: environment, folder: store.folder(for: plugin), done: done)
    }

    /// Whether what's on the clipboard is marked private (a password manager's copy) or transient.
    static func clipboardIsPrivate() -> Bool {
        let types = Set((NSPasteboard.general.types ?? []).map(\.rawValue))
        return !types.isDisjoint(with: ClipboardModule.skipTypes)
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
            // nothing printed leaves the clipboard alone (an image copied stays copied). Nor is
            // a private copy (a password) ever replaced.
            var text = result.output
            if text.hasSuffix("\n") { text.removeLast() }
            guard !text.isEmpty else {
                if reason != .trigger { Toast.shared.show(plugin.name, detail: "Nothing to copy") }
                return
            }
            guard !Self.clipboardIsPrivate() else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            ownPasteboardChange = NSPasteboard.general.changeCount
            Toast.shared.show(plugin.name, detail: "Copied \(text.count.formatted()) character\(text.count == 1 ? "" : "s")")
        case .silent:
            break
        }
    }

    // MARK: Saving

    private func saveTrust() {
        defaults.set(Dictionary(uniqueKeysWithValues: approved.map { ($0.key.uuidString, $0.value) }), forKey: Keys.approved)
        defaults.set(disabled.map(\.uuidString).sorted(), forKey: Keys.disabled)
    }

    private func saveValues() {
        let plain = Dictionary(uniqueKeysWithValues: values.map { ($0.key.uuidString, $0.value) })
        if let data = try? JSONEncoder().encode(plain) { defaults.set(data, forKey: Keys.values) }
    }

    private enum Keys {
        static let seen = "plugins.seen"
        static let approved = "plugins.approved"
        static let disabled = "plugins.disabled"
        static let values = "plugins.values"
        /// Before approvals held fingerprints: a list of ids.
        static let oldAllowed = "plugins.allowed"
    }
}

// MARK: - Secrets

/// A plugin's secret settings (tokens, passwords), in your login keychain, never in a file.
enum PluginSecrets {
    private static let service = "ca.bryanyao.Tutto.plugin"

    private static func account(_ plugin: UUID, _ key: String) -> String { "\(plugin.uuidString).\(key)" }

    /// The secret, or nil; never shows a prompt (a locked keychain gives nil).
    static func read(plugin: UUID, key: String) -> String? {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account(plugin, key), kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne,
                                    kSecUseAuthenticationContext as String: context]
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
