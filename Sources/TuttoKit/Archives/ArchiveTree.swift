//
//  ArchiveTree.swift
//  TuttoKit — archives
//
//  An archive's entries as folders and files, for looking inside without unpacking: folders the
//  archive never lists on their own ("a/b/c.txt" alone) are made up from the paths, every folder
//  knows its size and file count, and children sort folders first, then by name as Finder does.
//

import Foundation

public struct ArchiveNode: Sendable, Identifiable, Equatable {
    /// The full path inside the archive ("Docs/img/a.png"); "" for the top.
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public var isSymlink: Bool
    /// A file's size, or everything in a folder.
    public var size: Int64
    /// Files in a folder, counting subfolders' (1 for a file).
    public var fileCount: Int
    public var modified: Date?
    public var isEncrypted: Bool

    public var id: String { path }

    /// The folder it's in ("" for the top, else ending in "/").
    public var parent: String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[...slash])
    }

    /// The extension, lowercased ("png"; "" for folders).
    public var fileExtension: String {
        isDirectory ? "" : (name as NSString).pathExtension.lowercased()
    }
}

public struct ArchiveTree: Sendable {
    private var nodes: [String: ArchiveNode] = [:]
    private var children: [String: [String]] = [:]

    public init(entries: [ArchiveEntryInfo]) {
        nodes[""] = ArchiveNode(path: "", name: "", isDirectory: true, isSymlink: false, size: 0, fileCount: 0,
                                modified: nil, isEncrypted: false)
        for entry in entries {
            let path = entry.path.hasSuffix("/") ? String(entry.path.dropLast()) : entry.path
            guard !path.isEmpty else { continue }
            ensureFolders(above: path)
            if let existing = nodes[path] {
                // A folder listed after its contents (or twice): keep what it knows, take the date.
                if existing.isDirectory, entry.isDirectory, existing.modified == nil {
                    nodes[path]?.modified = entry.modified
                }
                continue
            }
            nodes[path] = ArchiveNode(path: path, name: Self.name(of: path), isDirectory: entry.isDirectory,
                                      isSymlink: entry.isSymlink, size: entry.isDirectory ? 0 : (entry.size ?? 0),
                                      fileCount: entry.isDirectory ? 0 : 1, modified: entry.modified,
                                      isEncrypted: entry.isEncrypted)
            children[Self.parentKey(of: path), default: []].append(path)
        }
        _ = total("")
        var sorted = children
        for key in sorted.keys { sorted[key]?.sort(by: order) }
        children = sorted
    }

    /// The top of the archive.
    public var root: ArchiveNode { nodes[""]! }

    public func node(_ path: String) -> ArchiveNode? {
        nodes[path.hasSuffix("/") ? String(path.dropLast()) : path]
    }

    /// What's in a folder ("" or "Docs" or "Docs/"), folders first, then by name.
    public func children(of folder: String) -> [ArchiveNode] {
        let key = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        return (children[key] ?? []).compactMap { nodes[$0] }
    }

    /// Every node whose name contains `text` (ignoring case and accents), in path order.
    public func search(_ text: String) -> [ArchiveNode] {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        return nodes.values
            .filter { !$0.path.isEmpty && $0.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// The folders from the top down to `folder` ("Docs/img" → ["Docs", "Docs/img"]).
    public static func trail(to folder: String) -> [String] {
        let parts = folder.split(separator: "/").map(String.init)
        return parts.indices.map { parts[...$0].joined(separator: "/") }
    }

    // MARK: Building

    private mutating func ensureFolders(above path: String) {
        var parent = Self.parentKey(of: path)
        var missing: [String] = []
        while !parent.isEmpty, nodes[parent] == nil {
            missing.append(parent)
            parent = Self.parentKey(of: parent)
        }
        for folder in missing.reversed() {
            nodes[folder] = ArchiveNode(path: folder, name: Self.name(of: folder), isDirectory: true, isSymlink: false,
                                        size: 0, fileCount: 0, modified: nil, isEncrypted: false)
            children[Self.parentKey(of: folder), default: []].append(folder)
        }
    }

    /// Sums sizes and file counts up the folders.
    private mutating func total(_ path: String) -> (Int64, Int) {
        guard let node = nodes[path] else { return (0, 0) }
        guard node.isDirectory else { return (node.size, 1) }
        var size: Int64 = 0
        var count = 0
        for child in children[path] ?? [] {
            let (s, c) = total(child)
            size += s
            count += c
        }
        nodes[path]?.size = size
        nodes[path]?.fileCount = count
        return (size, count)
    }

    private func order(_ a: String, _ b: String) -> Bool {
        guard let x = nodes[a], let y = nodes[b] else { return a < b }
        if x.isDirectory != y.isDirectory { return x.isDirectory }
        return x.name.localizedStandardCompare(y.name) == .orderedAscending
    }

    private static func name(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    private static func parentKey(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }
}

/// Names that are archives themselves (opened in place when found inside another).
public enum ArchiveNames {
    public static let extensions: Set<String> = ["zip", "zipx", "rar", "7z", "tar", "tgz", "tbz", "tbz2", "txz", "gz", "bz2",
                                                 "xz", "lzma", "iso", "cab", "lha", "lzh", "xar", "cpio", "deb", "rpm", "jar"]

    public static func isArchive(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tar.bz2") || lower.hasSuffix(".tar.xz") { return true }
        return extensions.contains((lower as NSString).pathExtension)
    }
}
