//
//  DiskMapRules.swift
//  Tutto
//
//  What the disk map lets you move to the Trash. It leans safe: only something inside the
//  folder that was scanned (an app in /Applications can go), never macOS's own folders, never
//  your home folder's standard folders (Documents, Library…) or ~/Library's own, and never
//  through a link that leads out.
//

import Foundation

public enum DiskMapRules {
    public enum Refusal: Equatable, Sendable {
        case outsideScan
        case systemLocation
        case standardFolder

        public var sentence: String {
            switch self {
            case .outsideScan: "It isn't inside the folder that was scanned."
            case .systemLocation: "It's part of macOS or shared by every account."
            case .standardFolder: "It's one of your Mac's standard folders."
            }
        }
    }

    /// Why `path` can't go to the Trash, or nil when it can. `resolved` is the path with links
    /// followed (checked against the scanned root too).
    public static func refusal(_ path: String, root: String, home: String, resolved: String? = nil) -> Refusal? {
        let path = trimmed(path), root = trimmed(root), home = trimmed(home)
        guard path.hasPrefix("/"), path != root else { return .outsideScan }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.contains(where: { $0 == ".." || $0 == "." }) else { return .outsideScan }
        let rootWithSlash = root == "/" ? "/" : root + "/"
        guard path.hasPrefix(rootWithSlash) else { return .outsideScan }
        if let resolved {
            let resolved = trimmed(resolved)
            let inside = resolved.hasPrefix(rootWithSlash) || ("/private" + resolved).hasPrefix(rootWithSlash)
                || resolved.hasPrefix("/private" + rootWithSlash)
            guard inside, resolved != root else { return .outsideScan }
        }
        if path == home || standardFolders.contains(where: { path == home + "/" + $0 }) { return .standardFolder }
        // ~/Library's own folders (Caches, Containers, Mobile Documents…) stay; what's in them can go.
        if path.hasPrefix(home + "/Library/"), path.dropFirst(home.count + 9).split(separator: "/").count == 1 { return .standardFolder }
        if path == home + "/.Trash" { return .standardFolder }
        let insideHome = path.hasPrefix(home + "/")
        if !insideHome {
            if systemRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return .systemLocation }
            // Other accounts' folders, and /Users itself.
            if path == "/Users" || (path.hasPrefix("/Users/") && parts.count <= 2) { return .systemLocation }
            if parts.count == 1 { return .systemLocation }
        }
        return nil
    }

    static func trimmed(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// The folders macOS makes in every home.
    public static let standardFolders: [String] = [
        "Applications", "Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures", "Public",
    ]

    /// macOS's own, and folders shared by every account.
    public static let systemRoots: [String] = [
        "/System", "/bin", "/sbin", "/usr", "/etc", "/var", "/private", "/Library", "/Applications/Utilities", "/cores", "/opt",
        "/dev", "/Volumes", "/tmp",
    ]
}
