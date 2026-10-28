//
//  RecentlyUsed.swift
//  TuttoKit
//
//  A small store that keeps only the most recently stored values: storing past the limit lets
//  go of the oldest. Window pictures are kept this way (for the switcher and the strip bar), so
//  a day of new windows can't pile up pictures of ones long gone.
//

public struct RecentlyUsed<Key: Hashable, Value> {
    public let limit: Int
    private var values: [Key: Value] = [:]
    /// Oldest first.
    private var order: [Key] = []

    public init(limit: Int) {
        self.limit = max(limit, 1)
    }

    public var count: Int { values.count }
    public var isEmpty: Bool { values.isEmpty }
    public var keys: [Key] { order }

    public subscript(key: Key) -> Value? { values[key] }

    /// Stores `value` as the newest; past the limit the oldest go.
    public mutating func set(_ value: Value, for key: Key) {
        if values.updateValue(value, forKey: key) != nil { order.removeAll { $0 == key } }
        order.append(key)
        while order.count > limit { values[order.removeFirst()] = nil }
    }

    public mutating func remove(_ key: Key) {
        guard values.removeValue(forKey: key) != nil else { return }
        order.removeAll { $0 == key }
    }

    /// Lets go of everything not in `keys` (the windows that still exist, say).
    public mutating func keep(only keys: Set<Key>) {
        order.removeAll { !keys.contains($0) }
        values = values.filter { keys.contains($0.key) }
    }

    public mutating func removeAll() {
        values.removeAll()
        order.removeAll()
    }
}
