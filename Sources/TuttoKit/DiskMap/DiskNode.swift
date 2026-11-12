//
//  DiskNode.swift
//  Tutto
//
//  The disk map's tree: one node per folder, file or package worth showing, and one "smaller
//  items" node per folder for everything under the size threshold. Nodes never change once
//  built; removing something (after it went to the Trash) builds a new path to the root.
//

import Foundation

public final class DiskNode: Identifiable, Sendable {
    public enum Kind: Sendable, Equatable {
        case folder
        case file
        /// An app or other bundle: measured in full, shown as one item.
        case package
        /// Everything in a folder under the size threshold, merged.
        case smaller
    }

    public let name: String
    /// Full path. A "smaller items" node carries its folder's path.
    public let path: String
    /// Bytes on disk (allocated, not logical), hard links counted once.
    public let bytes: Int64
    /// Files and folders inside, this one included (a "smaller items" node: how many it merges).
    public let items: Int
    public let kind: Kind
    /// Biggest first; a "smaller items" node, if any, is last.
    public let children: [DiskNode]

    public var id: ObjectIdentifier { ObjectIdentifier(self) }
    /// Something you can click into.
    public var canOpen: Bool { kind == .folder && !children.isEmpty }

    public init(name: String, path: String, bytes: Int64, items: Int, kind: Kind, children: [DiskNode] = []) {
        self.name = name
        self.path = path
        self.bytes = bytes
        self.items = items
        self.kind = kind
        self.children = children
    }

    /// Joins a folder path and a name ("/" + "Users" is "/Users").
    public static func join(_ folder: String, _ name: String) -> String {
        folder.hasSuffix("/") ? folder + name : folder + "/" + name
    }

    /// The node at `path` (this one or below it), following real paths only.
    public func find(_ target: String) -> DiskNode? {
        if path == target, kind != .smaller { return self }
        let prefix = path.hasSuffix("/") ? path : path + "/"
        guard target.hasPrefix(prefix) else { return nil }
        for child in children where child.kind != .smaller {
            if let found = child.find(target) { return found }
        }
        return nil
    }

    /// The chain from this node down to `target`, both included.
    public func chain(to target: DiskNode) -> [DiskNode]? {
        if self === target { return [self] }
        let prefix = path.hasSuffix("/") ? path : path + "/"
        guard target.path.hasPrefix(prefix) else { return nil }
        for child in children where child.kind != .smaller {
            if let rest = child.chain(to: target) { return [self] + rest }
        }
        return nil
    }

    /// A copy of the tree without the item at `target`, every folder above it that much smaller.
    /// Returns nil when `target` isn't in the tree (or is the root itself).
    public func removing(_ target: String) -> DiskNode? {
        guard target != path else { return nil }
        guard let index = children.firstIndex(where: { $0.path == target && $0.kind != .smaller }) else {
            let prefix = path.hasSuffix("/") ? path : path + "/"
            guard target.hasPrefix(prefix) else { return nil }
            for (i, child) in children.enumerated() where child.kind == .folder {
                guard let updated = child.removing(target) else { continue }
                var kids = children
                kids[i] = updated
                let bytesGone = child.bytes - updated.bytes
                let itemsGone = child.items - updated.items
                return DiskNode(name: name, path: path, bytes: bytes - bytesGone, items: items - itemsGone, kind: kind,
                                children: Self.sorted(kids))
            }
            return nil
        }
        let gone = children[index]
        var kids = children
        kids.remove(at: index)
        return DiskNode(name: name, path: path, bytes: bytes - gone.bytes, items: items - gone.items, kind: kind, children: kids)
    }

    /// Biggest first, with "smaller items" kept last.
    static func sorted(_ nodes: [DiskNode]) -> [DiskNode] {
        nodes.sorted { a, b in
            if (a.kind == .smaller) != (b.kind == .smaller) { return b.kind == .smaller }
            return a.bytes > b.bytes
        }
    }

    /// How many nodes the tree holds (for keeping memory in check).
    public var nodeCount: Int { 1 + children.reduce(0) { $0 + $1.nodeCount } }
}
