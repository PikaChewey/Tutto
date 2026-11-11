//
//  PanelLayout.swift
//  Tutto
//
//  How the menu bar panel is arranged, set on the Customize page (Bryan, 2026-11-10: "make it
//  like customizeable with the GUI ... in the settings ... not in the menu bar at all"): which of
//  its parts, readings, controls and tools show, and in what order.
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

/// The panel's arrangement: its parts, the readings tiles, the control rows and the tools row.
public struct PanelLayout: Codable, Equatable, Sendable {
    public var sections = Arrangement()
    public var readings = Arrangement()
    public var controls = Arrangement()
    public var tools = Arrangement()

    public init() {}

    /// The panel's parts, top to bottom by default.
    public static let sectionIDs = ["battery", "readings", "controls", "sound", "tools"]
    /// The readings tiles, two to a row by default.
    public static let readingIDs = ["cpu", "memory", "gpu", "disk", "network", "temperature"]
    /// The control rows.
    public static let controlIDs = ["awake", "clicker", "fan"]
    /// Tools to a row before the row wraps.
    public static let toolsPerRow = 6

    /// Layouts saved by an older Tutto, with parts since added, keep their defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sections = try c.decodeIfPresent(Arrangement.self, forKey: .sections) ?? Arrangement()
        readings = try c.decodeIfPresent(Arrangement.self, forKey: .readings) ?? Arrangement()
        controls = try c.decodeIfPresent(Arrangement.self, forKey: .controls) ?? Arrangement()
        tools = try c.decodeIfPresent(Arrangement.self, forKey: .tools) ?? Arrangement()
    }

    /// The readings tiles laid two to a row: an odd one out takes the whole last row.
    public static func rows<T>(_ items: [T], perRow: Int) -> [[T]] {
        guard perRow > 0 else { return [items] }
        return stride(from: 0, to: items.count, by: perRow).map { Array(items[$0..<min($0 + perRow, items.count)]) }
    }
}
