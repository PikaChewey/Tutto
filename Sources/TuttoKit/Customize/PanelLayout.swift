//
//  PanelLayout.swift
//  Tutto
//
//  How the menu bar panel is arranged, set on the Customize page (Bryan, 2026-11-10: "make it
//  like customizeable with the GUI ... in the settings ... not in the menu bar at all"; then
//  "panel cards you can move anywhere and resize"): every card in one order, which show, how big
//  each is, and what the tools row holds.
//

import Foundation

/// An order and a set of hidden items, over ids that come and go (a tool whose module is off, a
/// plugin added later). Items never arranged take their place in the default order, after the
/// item they follow there; ids no longer available are kept, so they come back where they were.
public struct Arrangement: Codable, Equatable, Sendable {
    public var order: [String]
    public var hidden: Set<String>

    public init(order: [String] = [], hidden: Set<String> = []) {
        self.order = order
        self.hidden = hidden
    }

    /// Every available item, in the arranged order (hidden ones included, for the editor).
    public func all(_ available: [String]) -> [String] {
        let present = Set(available)
        var seen = Set<String>()
        var result = order.filter { present.contains($0) && seen.insert($0).inserted }
        for (index, id) in available.enumerated() where !seen.contains(id) {
            // After the nearest item that comes before it by default and is already placed.
            var position = 0
            for earlier in available[..<index].reversed() {
                if let at = result.firstIndex(of: earlier) {
                    position = at + 1
                    break
                }
            }
            result.insert(id, at: position)
            seen.insert(id)
        }
        return result
    }

    /// The items to show, in order.
    public func visible(_ available: [String]) -> [String] {
        all(available).filter { !hidden.contains($0) }
    }

    public func isShown(_ id: String) -> Bool { !hidden.contains(id) }

    public mutating func set(_ id: String, shown: Bool) {
        if shown { hidden.remove(id) } else { hidden.insert(id) }
    }

    /// Moves items within the full list as the editor shows it (`available`, arranged).
    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int, available: [String]) {
        var list = all(available)
        let moving = source.sorted().filter { list.indices.contains($0) }.map { list[$0] }
        guard !moving.isEmpty else { return }
        let before = list[..<min(max(destination, 0), list.count)].filter { !moving.contains($0) }.count
        list.removeAll { moving.contains($0) }
        list.insert(contentsOf: moving, at: min(before, list.count))
        // Remember where unavailable items were too (after the available ones).
        order = list + order.filter { !list.contains($0) }
    }

    /// Moves one item up (-1) or down (+1) in the editor's list.
    public mutating func move(_ id: String, by step: Int, available: [String]) {
        let list = all(available)
        guard let index = list.firstIndex(of: id) else { return }
        let target = index + step
        guard list.indices.contains(target) else { return }
        move(fromOffsets: IndexSet(integer: index), toOffset: step > 0 ? target + 1 : target, available: available)
    }
}

/// How big a card on the panel is: half its width, or all of it.
public enum WidgetSize: String, Codable, CaseIterable, Sendable {
    case small, wide
}

/// A card as the panel lays it out.
public struct WidgetSlot: Equatable, Sendable {
    public var id: String
    public var size: WidgetSize
    /// A one-line control (Stay awake, the auto clicker, the fan): next to others like it, it
    /// shares their card, a line each.
    public var isRow: Bool

    public init(id: String, size: WidgetSize, isRow: Bool = false) {
        self.id = id
        self.size = size
        self.isRow = isRow
    }
}

/// One line of the panel: one card across, two side by side, or rows sharing a card.
public enum WidgetLine: Hashable, Sendable {
    case cards([String])
    case rows([String])

    /// The cards on the line, left to right or top to bottom.
    public var ids: [String] {
        switch self {
        case .cards(let ids), .rows(let ids): ids
        }
    }
}

/// The panel's arrangement (Bryan, 2026-11-10: "panel cards you can move anywhere and resize"):
/// every card in one order, which are hidden and how big each is, and the tools row's contents.
public struct PanelLayout: Codable, Equatable, Sendable {
    /// Every card, in order, and the hidden ones.
    public var widgets = Arrangement()
    /// Sizes chosen on the Customize page; a card not listed has its own default size.
    public var sizes: [String: WidgetSize] = [:]
    /// The tools row: which tools and plugins, in what order.
    public var tools = Arrangement()

    public init() {}

    /// The panel's cards, top to bottom by default.
    public static let widgetIDs = ["battery", "devices", "cpu", "memory", "gpu", "disk", "network", "temperature",
                                   "compress", "awake", "clicker", "fan", "sound", "tools"]
    /// Before cards moved freely (a version 1 layout): the panel's parts, its readings and its controls.
    public static let sectionIDs = ["battery", "readings", "controls", "sound", "tools"]
    public static let readingIDs = ["cpu", "memory", "gpu", "disk", "network", "temperature"]
    public static let controlIDs = ["awake", "clicker", "fan"]
    /// Tools to a row before the row wraps.
    public static let toolsPerRow = 6

    public func size(of id: String, default fallback: WidgetSize) -> WidgetSize { sizes[id] ?? fallback }

    /// Remembers a size only when it differs from the card's default.
    public mutating func setSize(_ size: WidgetSize, of id: String, default fallback: WidgetSize) {
        sizes[id] = size == fallback ? nil : size
    }

    enum CodingKeys: String, CodingKey {
        case widgets, sizes, tools
        case sections, readings, controls  // version 1
    }

    /// Reads this layout, or a version 1 layout (moved to one list of cards, with the same order
    /// and the same things hidden). Anything unreadable keeps its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func arrangement(_ key: CodingKeys) -> Arrangement? { try? c.decodeIfPresent(Arrangement.self, forKey: key) }
        tools = arrangement(.tools) ?? Arrangement()
        let rawSizes = (try? c.decodeIfPresent([String: String].self, forKey: .sizes)) ?? [:]
        sizes = rawSizes.compactMapValues(WidgetSize.init(rawValue:))
        if let widgets = arrangement(.widgets) {
            self.widgets = widgets
        } else {
            widgets = Self.migrate(sections: arrangement(.sections) ?? Arrangement(),
                                   readings: arrangement(.readings) ?? Arrangement(),
                                   controls: arrangement(.controls) ?? Arrangement())
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(widgets, forKey: .widgets)
        if !sizes.isEmpty { try c.encode(sizes, forKey: .sizes) }
        try c.encode(tools, forKey: .tools)
    }

    /// A version 1 layout as one list: each part in its place, its readings or controls in theirs.
    public static func migrate(sections: Arrangement, readings: Arrangement, controls: Arrangement) -> Arrangement {
        var order: [String] = []
        var hidden = Set<String>()
        for section in sections.all(sectionIDs) {
            let members: [String]
            switch section {
            case "readings": members = readings.all(readingIDs)
            case "controls": members = controls.all(controlIDs)
            default: members = [section]
            }
            order += members
            if sections.hidden.contains(section) { hidden.formUnion(members) }
        }
        hidden.formUnion(readings.hidden.intersection(readingIDs))
        hidden.formUnion(controls.hidden.intersection(controlIDs))
        // The devices and compress cards didn't exist in version 1: they aren't part of an untouched old layout.
        return Arrangement(order: order == widgetIDs.filter { $0 != "devices" && $0 != "compress" } ? [] : order, hidden: hidden)
    }

    /// What Restore Defaults gives: the default arrangement, with each of your plugins' tiles and
    /// cards still in or out of the panel as they are now (a new plugin's start out of it).
    public func restored() -> PanelLayout {
        var layout = PanelLayout()
        layout.tools.hidden = tools.hidden.filter(ScriptPlugin.isToolID)
        layout.widgets.hidden = widgets.hidden.filter(ScriptPlugin.isWidgetID)
        return layout
    }

    /// Whether Restore Defaults would change anything (a plugin kept out of the panel doesn't count).
    public var isCustomized: Bool { self != restored() }

    /// The cards laid out in lines: two small cards side by side, a wide card (or a small one
    /// with no partner) across the panel, and one-line controls next to each other in one card.
    public static func lines(_ slots: [WidgetSlot]) -> [WidgetLine] {
        var lines: [WidgetLine] = []
        var waiting = false  // the last line is one small card that a second can join
        for slot in slots {
            if slot.isRow {
                if case .rows(let ids)? = lines.last {
                    lines[lines.count - 1] = .rows(ids + [slot.id])
                } else {
                    lines.append(.rows([slot.id]))
                }
                waiting = false
            } else if slot.size == .wide {
                lines.append(.cards([slot.id]))
                waiting = false
            } else if waiting, case .cards(let ids)? = lines.last {
                lines[lines.count - 1] = .cards(ids + [slot.id])
                waiting = false
            } else {
                lines.append(.cards([slot.id]))
                waiting = true
            }
        }
        return lines
    }

    /// Items in rows of `perRow` (the tools row).
    public static func rows<T>(_ items: [T], perRow: Int) -> [[T]] {
        guard perRow > 0 else { return [items] }
        return stride(from: 0, to: items.count, by: perRow).map { Array(items[$0..<min($0 + perRow, items.count)]) }
    }
}
