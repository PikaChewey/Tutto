//
//  Customization.swift
//  Tutto
//
//  What the Customize and Plugins pages change: how the menu bar panel is arranged, and your own
//  plugins. Both live in the app's settings, never in the panel (Bryan, 2026-11-10: "just make it
//  something u can view in the settings of the app (not in the menu bar at all)").
//

import AppKit
import Observation
import os
import TuttoKit

private let pluginLog = Logger(subsystem: "ca.bryanyao.Tutto", category: "plugins")

// MARK: - The panel's arrangement

@MainActor
@Observable
final class PanelLayoutStore {
    enum Section: String, CaseIterable, Identifiable {
        case battery, readings, controls, sound, tools

        var id: String { rawValue }

        var title: String {
            switch self {
            case .battery: "Battery and busiest apps"
            case .readings: "Readings"
            case .controls: "Controls"
            case .sound: "Sound"
            case .tools: "Tools"
            }
        }

        var detail: String {
            switch self {
            case .battery: "Charge, watts, health and the three apps using the processor most."
            case .readings: "CPU, memory, GPU, disk, network and temperature, with the last minute."
            case .controls: "Stay awake, the auto clicker and the fan, a line each."
            case .sound: "Your apps, to mute one with a click."
            case .tools: "Tools and plugins with their keys, to click instead of pressing them."
            }
        }

        var symbol: String {
            switch self {
            case .battery: "battery.75percent"
            case .readings: "square.grid.2x2"
            case .controls: "switch.2"
            case .sound: "speaker.wave.2"
            case .tools: "command"
            }
        }
    }

    enum Reading: String, CaseIterable, Identifiable {
        case cpu, memory, gpu, disk, network, temperature

        var id: String { rawValue }

        var title: String {
            switch self {
            case .cpu: "CPU"
            case .memory: "Memory"
            case .gpu: "GPU"
            case .disk: "Disk"
            case .network: "Network"
            case .temperature: "Temperature"
            }
        }

        var symbol: String {
            switch self {
            case .cpu: "cpu"
            case .memory: "memorychip"
            case .gpu: "square.stack.3d.up"
            case .disk: "internaldrive"
            case .network: "arrow.up.arrow.down"
            case .temperature: "thermometer.medium"
            }
        }
    }

    enum Control: String, CaseIterable, Identifiable {
        case awake, clicker, fan

        var id: String { rawValue }

        var title: String {
            switch self {
            case .awake: "Stay awake"
            case .clicker: "Auto clicker"
            case .fan: "Fan"
            }
        }

        var symbol: String {
            switch self {
            case .awake: ModuleID.awake.symbol
            case .clicker: ModuleID.clicker.symbol
            case .fan: "fan"
            }
        }
    }

    private(set) var layout: PanelLayout
    private let defaults = UserDefaults.standard

    init() {
        if let data = UserDefaults.standard.data(forKey: Keys.layout), let saved = try? JSONDecoder().decode(PanelLayout.self, from: data) {
            layout = saved
        } else {
            // Parts hidden on the General page before there was a Customize page.
            var layout = PanelLayout()
            layout.sections.hidden = Set(UserDefaults.standard.stringArray(forKey: Keys.oldHidden) ?? [])
            self.layout = layout
        }
    }

    var isCustomized: Bool { layout != PanelLayout() }

    func update(_ change: (inout PanelLayout) -> Void) {
        var changed = layout
        change(&changed)
        guard changed != layout else { return }
        layout = changed
        save()
    }

    func reset() {
        // Plugins stay out of the tools row unless you put them there.
        let plugins = layout.tools.hidden.filter { $0.hasPrefix("plugin.") }
        layout = PanelLayout()
        layout.tools.hidden = plugins
        save()
    }

    // MARK: What the panel shows

    func sections() -> [Section] {
        layout.sections.visible(PanelLayout.sectionIDs).compactMap(Section.init(rawValue:))
    }

    func shows(_ section: Section) -> Bool { layout.sections.isShown(section.rawValue) }

    func readings(available: [Reading]) -> [Reading] {
        layout.readings.visible(available.map(\.rawValue)).compactMap(Reading.init(rawValue:))
    }

    func controls(available: [Control]) -> [Control] {
        layout.controls.visible(available.map(\.rawValue)).compactMap(Control.init(rawValue:))
    }

    func tools(available ids: [String]) -> [String] { layout.tools.visible(ids) }

    private func save() {
        if let data = try? JSONEncoder().encode(layout) { defaults.set(data, forKey: Keys.layout) }
        defaults.removeObject(forKey: Keys.oldHidden)
    }

    private enum Keys {
        static let layout = "panel.layout"
        static let oldHidden = "panel.hidden"
    }
}

// MARK: - Your plugins

/// Names of the plugins for their shortcuts (Shortcuts page, conflicts), read off the main actor.
enum PluginShortcuts {
    nonisolated(unsafe) static var names: [UUID: String] = [:]
    nonisolated(unsafe) static var ids: [UUID] = []
    nonisolated(unsafe) static var enabled: Set<UUID> = []
}

@MainActor
@Observable
final class PluginsModel {
    private(set) var plugins: [ScriptPlugin] = []
    /// Files in the folder that couldn't be read.
    private(set) var problems: [String] = []
    private(set) var running: Set<UUID> = []
    private(set) var lastResults: [UUID: PluginResult] = [:]

    let store = PluginStore(directory: PluginStore.defaultDirectory)
    private let defaults = UserDefaults.standard
    private var model: AppModel { AppModel.shared }

    var folder: URL { store.directory }

    func plugin(_ id: UUID) -> ScriptPlugin? { plugins.first { $0.id == id } }

    func plugin(named name: String) -> ScriptPlugin? {
        plugins.first { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    /// Reads the folder again (a file added or edited by hand shows up).
    func load() {
        let loaded = store.load()
        plugins = loaded.plugins
        problems = loaded.problems
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
        publish()
    }

    /// Saves a new or edited plugin; returns why it couldn't be saved.
    @discardableResult
    func save(_ plugin: ScriptPlugin, inPanel: Bool? = nil) -> String? {
        guard plugin.isValid else { return "A plugin needs a name and a command." }
        do {
            try store.save(plugin)
        } catch {
            return error.localizedDescription
        }
        let isNew = !plugins.contains { $0.id == plugin.id }
        if let index = plugins.firstIndex(where: { $0.id == plugin.id }) { plugins[index] = plugin } else { plugins.append(plugin) }
        plugins.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if isNew {
            var seen = Set(defaults.stringArray(forKey: Keys.seen) ?? [])
            seen.insert(plugin.toolID)
            defaults.set(Array(seen).sorted(), forKey: Keys.seen)
        }
        if let inPanel {
            model.layout.update { $0.tools.set(plugin.toolID, shown: inPanel) }
        } else if isNew {
            model.layout.update { $0.tools.set(plugin.toolID, shown: false) }
        }
        publish()
        return nil
    }

    func delete(_ plugin: ScriptPlugin) {
        try? store.delete(plugin)
        plugins.removeAll { $0.id == plugin.id }
        lastResults[plugin.id] = nil
        model.shortcuts.reset(.plugin(plugin.id))
        model.layout.update { layout in
            layout.tools.order.removeAll { $0 == plugin.toolID }
            layout.tools.hidden.remove(plugin.toolID)
        }
        publish()
    }

    func setEnabled(_ plugin: ScriptPlugin, _ on: Bool) {
        var changed = plugin
        changed.enabled = on
        save(changed)
    }

    func isInPanel(_ plugin: ScriptPlugin) -> Bool { model.layout.layout.tools.isShown(plugin.toolID) }

    /// Shortcuts and names follow the list.
    private func publish() {
        PluginShortcuts.names = Dictionary(uniqueKeysWithValues: plugins.map { ($0.id, $0.name) })
        PluginShortcuts.ids = plugins.map(\.id)
        PluginShortcuts.enabled = Set(plugins.filter(\.enabled).map(\.id))
        model.bindShortcuts()
    }

    // MARK: Running

    func run(_ id: UUID) {
        guard let plugin = plugin(id) else { return }
        run(plugin)
    }

    /// Runs it in its own process: off the main thread, at most one run of a plugin at a time.
    func run(_ plugin: ScriptPlugin) {
        guard plugin.enabled, !running.contains(plugin.id) else { return }
        running.insert(plugin.id)
        let input = plugin.input == .clipboard ? (NSPasteboard.general.string(forType: .string) ?? "") : nil
        pluginLog.notice("run \(plugin.name, privacy: .public)")
        Task.detached(priority: .userInitiated) { [self] in
            let result = PluginRunner.run(plugin.command, input: input, timeout: min(plugin.timeout, ScriptPlugin.longestTimeout),
                                          name: plugin.name)
            await MainActor.run { self.finished(plugin, result) }
        }
    }

    private func finished(_ plugin: ScriptPlugin, _ result: PluginResult) {
        running.remove(plugin.id)
        lastResults[plugin.id] = result
        pluginLog.notice("\(plugin.name, privacy: .public): exit \(result.status) in \(Int(result.seconds * 1000)) ms\(result.timedOut ? ", timed out" : "", privacy: .public)")
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
            Toast.shared.show(plugin.name, detail: text.isEmpty ? "Done" : text, duration: text.count > 60 ? 3 : 1.8)
        case .clipboard:
            // One trailing newline (what most commands end with) isn't part of the result.
            var text = result.output
            if text.hasSuffix("\n") { text.removeLast() }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            Toast.shared.show(plugin.name, detail: "Copied \(text.count.formatted()) character\(text.count == 1 ? "" : "s")")
        case .silent:
            break
        }
    }

    private enum Keys {
        static let seen = "plugins.seen"
    }
}
