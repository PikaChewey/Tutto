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

// MARK: - The panel's arrangement

@MainActor
@Observable
final class PanelLayoutStore {
    /// Tutto's own cards.
    enum Card: String, CaseIterable, Identifiable {
        case battery, devices, cpu, memory, gpu, disk, network, temperature, agents, compress, awake, clicker, fan, sound, tools

        var id: String { rawValue }

        var title: String {
            switch self {
            case .battery: "Battery"
            case .devices: "Bluetooth devices"
            case .cpu: "CPU"
            case .memory: "Memory"
            case .gpu: "GPU"
            case .disk: "Disk"
            case .network: "Network"
            case .temperature: "Temperature"
            case .agents: "Agents"
            case .compress: "Convert & Compress"
            case .awake: "Stay awake"
            case .clicker: "Auto clicker"
            case .fan: "Fan"
            case .sound: "Sound"
            case .tools: "Tools"
            }
        }

        /// What it shows, for the Customize page.
        var detail: String {
            switch self {
            case .battery: "Wide: charge, watts, health and the busiest apps. Small: charge and watts."
            case .devices: "AirPods, keyboards and mice, with their charge. Shows only while one is connected."
            case .cpu: "Processor load and the last minute."
            case .memory: "Memory used and the last minute."
            case .gpu: "Graphics load and the last minute."
            case .disk: "Free space on the startup disk."
            case .network: "Down and up, and the last minute."
            case .temperature: "The processor's temperature."
            case .agents: "Claude Code and Codex: who needs you, what each costs, and their limits. Shows when you use them."
            case .compress: "Drop files to compress, convert, resize, crop or zip them."
            case .awake: "A timer, and how long is left."
            case .clicker: "Its speed, its keys and a switch."
            case .fan: "Speed, and automatic or your own."
            case .sound: "Your apps, to mute one with a click."
            case .tools: "Tools and plugins with their keys."
            }
        }

        var symbol: String {
            switch self {
            case .battery: "battery.75percent"
            case .devices: "headphones"
            case .cpu: "cpu"
            case .memory: "memorychip"
            case .gpu: "square.stack.3d.up"
            case .disk: "internaldrive"
            case .network: "arrow.up.arrow.down"
            case .temperature: "thermometer.medium"
            case .agents: ModuleID.agents.symbol
            case .compress: ModuleID.converter.symbol
            case .awake: ModuleID.awake.symbol
            case .clicker: ModuleID.clicker.symbol
            case .fan: "fan"
            case .sound: "speaker.wave.2"
            case .tools: "command"
            }
        }

        /// The sizes it comes in, its default first.
        var sizes: [WidgetSize] {
            switch self {
            case .battery: [.wide, .small]
            case .cpu, .memory, .gpu, .disk, .network, .temperature: [.small, .wide]
            case .devices, .agents, .compress, .awake, .clicker, .fan, .sound, .tools: [.wide]
            }
        }

        /// A one-line control: next to others like it, it shares their card.
        var isRow: Bool { self == .awake || self == .clicker || self == .fan }
    }

    /// A card on the panel: one of Tutto's, or a plugin's.
    enum Widget: Hashable, Identifiable {
        case card(Card)
        case plugin(UUID)

        var id: String {
            switch self {
            case .card(let card): card.rawValue
            case .plugin(let id): ScriptPlugin.widgetPrefix + id.uuidString
            }
        }

        init?(id: String) {
            if let card = Card(rawValue: id) {
                self = .card(card)
            } else if let plugin = ScriptPlugin.pluginID(fromWidgetID: id) {
                self = .plugin(plugin)
            } else {
                return nil
            }
        }
    }

    private(set) var layout: PanelLayout
    @ObservationIgnored private let defaults = UserDefaults.standard

    init() {
        if let data = UserDefaults.standard.data(forKey: Keys.layout), let saved = try? JSONDecoder().decode(PanelLayout.self, from: data) {
            layout = saved
        } else {
            // Parts hidden on the General page before there was a Customize page.
            var layout = PanelLayout()
            let hidden = Set(UserDefaults.standard.stringArray(forKey: Keys.oldHidden) ?? [])
            layout.widgets = PanelLayout.migrate(sections: Arrangement(hidden: hidden), readings: Arrangement(), controls: Arrangement())
            self.layout = layout
        }
    }

    var isCustomized: Bool { layout.isCustomized }

    func update(_ change: (inout PanelLayout) -> Void) {
        var changed = layout
        change(&changed)
        guard changed != layout else { return }
        layout = changed
        save()
    }

    /// Back to the default arrangement; plugins stay in or out of the panel as they are.
    func reset() {
        update { $0 = $0.restored() }
    }

    // MARK: Cards

    /// The cards this Mac and the tools switched on can show, in their default order (a plugin's
    /// card after the readings).
    func available(_ model: AppModel) -> [Widget] {
        var cards: [Widget] = []
        if model.system != nil {
            cards += [.card(.battery), .card(.devices), .card(.cpu), .card(.memory), .card(.gpu), .card(.disk), .card(.network)]
        } else {
            cards.append(.card(.devices))
        }
        if model.sensors != nil { cards.append(.card(.temperature)) }
        if model.agents?.installed == true { cards.append(.card(.agents)) }
        cards += model.plugins.cardPlugins.map { .plugin($0.id) }
        if model.converter != nil { cards.append(.card(.compress)) }
        if model.awake != nil { cards.append(.card(.awake)) }
        if model.clicker != nil { cards.append(.card(.clicker)) }
        if model.sensors?.hasFans == true { cards.append(.card(.fan)) }
        if model.sound != nil, SoundModule.isSupported { cards.append(.card(.sound)) }
        if !ShortcutRows.rows(model).isEmpty { cards.append(.card(.tools)) }
        return cards
    }

    /// Every card that can show, in the panel's order (the hidden ones too, for the editor).
    func all(_ model: AppModel) -> [Widget] {
        let available = available(model)
        let byID = Dictionary(available.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return layout.widgets.all(available.map(\.id)).compactMap { byID[$0] }
    }

    /// The cards the panel shows, in order, with their sizes.
    func slots(_ model: AppModel, editing: Bool = false) -> [WidgetSlot] {
        // A tools row with every tile hidden isn't drawn as an empty card, nor is the devices
        // card when none reports a level (the Customize preview keeps it, to pick up and move).
        // Until macOS lets Tutto read Bluetooth, the card stays, to offer it (AirPods need it).
        let noTools = ShortcutRows.visible(model).isEmpty
        let noDevices = !editing && !BluetoothBatteries.shared.hasDevices && BluetoothBatteries.shared.access == .allowed
        return all(model).filter {
            layout.widgets.isShown($0.id) && !(noTools && $0 == .card(.tools)) && !(noDevices && $0 == .card(.devices))
        }
            .map { WidgetSlot(id: $0.id, size: size(of: $0, model), isRow: isRow($0)) }
    }

    func isShown(_ widget: Widget) -> Bool { layout.widgets.isShown(widget.id) }

    func sizes(of widget: Widget) -> [WidgetSize] {
        switch widget {
        case .card(let card): card.sizes
        case .plugin: [.small, .wide]
        }
    }

    func defaultSize(of widget: Widget, _ model: AppModel) -> WidgetSize {
        switch widget {
        case .card(let card): card.sizes[0]
        case .plugin(let id): model.plugins.plugin(id)?.widget?.size ?? .small
        }
    }

    func size(of widget: Widget, _ model: AppModel) -> WidgetSize {
        let fallback = defaultSize(of: widget, model)
        let size = layout.size(of: widget.id, default: fallback)
        return sizes(of: widget).contains(size) ? size : fallback
    }

    func setSize(_ size: WidgetSize, of widget: Widget, _ model: AppModel) {
        let fallback = defaultSize(of: widget, model)
        update { $0.setSize(size, of: widget.id, default: fallback) }
    }

    func isRow(_ widget: Widget) -> Bool {
        if case .card(let card) = widget { card.isRow } else { false }
    }

    /// Moves a card to where another is (after it when moving down, before it when moving up).
    func move(_ moving: String, onto target: String, _ model: AppModel) {
        let ids = all(model).map(\.id)
        guard let from = ids.firstIndex(of: moving), let to = ids.firstIndex(of: target), from != to else { return }
        update { $0.widgets.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to, available: ids) }
    }

    func title(of widget: Widget, _ model: AppModel) -> String {
        switch widget {
        case .card(let card): card.title
        case .plugin(let id): model.plugins.plugin(id)?.name ?? "Plugin"
        }
    }

    func detail(of widget: Widget) -> String {
        switch widget {
        case .card(let card): card.detail
        case .plugin: "Your plugin's card. Wide shows its list too."
        }
    }

    func symbol(of widget: Widget, _ model: AppModel) -> String {
        switch widget {
        case .card(let card): card.symbol
        case .plugin(let id): model.plugins.plugin(id)?.symbol ?? ScriptPlugin.defaultSymbol
        }
    }

    // MARK: Tools row

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
