//
//  DiskScanner.swift
//  Tutto
//
//  Measures a folder for the disk map. It reads directories with the plain POSIX calls (one
//  open folder per worker at a time) and takes sizes from each item's allocated blocks, the way
//  `du` does, so a sparse or compressed file counts what it really takes. Hard links count once,
//  links aren't followed, other volumes are skipped, and an app or other bundle is measured in
//  full but kept as one item. Folders near the top are read in parallel.
//
//  To keep memory modest on a disk with a million files, each folder keeps only what's at least
//  `keepAtLeast` bytes (and at most `maxChildren` of those); the rest becomes one "smaller items"
//  node. Cancelling stops every worker at its next folder.
//

import Darwin
import Foundation
import os

public struct DiskScanOptions: Sendable {
    public var root: String
    /// The name the root goes by ("Home", "Macintosh HD").
    public var title: String
    /// Folders never entered (the whole-disk scan skips /System/Volumes, which holds the same
    /// data a second time).
    public var skip: Set<String> = []
    /// Volumes besides the root's own whose folders count.
    public var extraDevices: Set<Int32> = []
    public var keepAtLeast: Int64 = 1_000_000
    public var maxChildren = 200
    /// Folder levels read in parallel.
    public var parallelDepth = 3

    public init(root: String, title: String) {
        self.root = root
        self.title = title
    }

    public static func home(_ path: String = NSHomeDirectory()) -> DiskScanOptions {
        DiskScanOptions(root: path, title: "Home")
    }

    /// The startup disk: everything from /, macOS's own sealed volume and the data volume
    /// (reached through /Users, /Applications…), but not the same data again under /System/Volumes.
    public static func wholeDisk(title: String = "Macintosh HD") -> DiskScanOptions {
        var options = DiskScanOptions(root: "/", title: title)
        options.skip = ["/System/Volumes", "/Volumes", "/dev"]
        var info = stat()
        if lstat("/System/Volumes/Data", &info) == 0 { options.extraDevices.insert(info.st_dev) }
        return options
    }
}

public struct DiskScanResult: Sendable {
    public let root: DiskNode
    /// Folders and files that couldn't be read (no permission).
    public let unreadable: Int
    public let seconds: Double
}

/// Items and bytes counted so far, readable from any thread while a scan runs.
public final class DiskScanProgress: Sendable {
    private let counts = OSAllocatedUnfairLock(initialState: (items: 0, bytes: Int64(0)))
    public init() {}
    public var items: Int { counts.withLock { $0.items } }
    public var bytes: Int64 { counts.withLock { $0.bytes } }
    func add(items: Int, bytes: Int64) {
        counts.withLock { $0.items += items; $0.bytes += bytes }
    }
}

public final class DiskScanner: Sendable {
    public let progress = DiskScanProgress()
    private let cancelled = OSAllocatedUnfairLock(initialState: false)
    private let unreadable = OSAllocatedUnfairLock(initialState: 0)
    private let seenLinks = OSAllocatedUnfairLock(initialState: Set<LinkKey>())

    private struct LinkKey: Hashable {
        let device: Int32
        let inode: UInt64
    }

    /// Bundles shown as one item: apps, plug-ins, libraries and document packages.
    public static let packageExtensions: Set<String> = [
        "app", "appex", "bundle", "framework", "plugin", "kext", "xpc", "prefpane", "qlgenerator", "mdimporter", "saver",
        "component", "vst", "vst3", "photoslibrary", "photolibrary", "musiclibrary", "tvlibrary", "imovielibrary",
        "fcpbundle", "logicx", "band", "xcarchive", "xcodeproj", "xcworkspace", "playground", "rtfd", "pages",
        "numbers", "key", "sparsebundle", "dSYM", "docarchive", "lpdf", "scriptd",
    ]

    public static func isPackage(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let ext = name[name.index(after: dot)...]
        return packageExtensions.contains(String(ext)) || packageExtensions.contains(ext.lowercased())
    }

    public init() {}

    public func cancel() { cancelled.withLock { $0 = true } }
    public var isCancelled: Bool { cancelled.withLock { $0 } }

    /// Scans `options.root`. Returns nil if it was cancelled or the root can't be read.
    public func run(_ options: DiskScanOptions) -> DiskScanResult? {
        let started = Date()
        var info = stat()
        guard lstat(options.root, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
        var devices = options.extraDevices
        devices.insert(info.st_dev)
        let context = Context(options: options, devices: devices)
        let own = Int64(info.st_blocks) * 512
        progress.add(items: 1, bytes: own)
        let measured = folder(path: options.root, name: options.title, ownBytes: own, depth: 0, keepTree: true, context)
        guard !isCancelled, let node = measured.node else { return nil }
        return DiskScanResult(root: node, unreadable: unreadable.withLock { $0 }, seconds: Date().timeIntervalSince(started))
    }

    private struct Context: Sendable {
        let options: DiskScanOptions
        let devices: Set<Int32>
    }

    private struct Measured {
        var bytes: Int64
        var items: Int
        var node: DiskNode?
    }

    private struct Entry {
        let name: String
        let bytes: Int64
        let isFolder: Bool
    }

    /// One folder: reads its entries, closes it, then goes into its subfolders.
    private func folder(path: String, name: String, ownBytes: Int64, depth: Int, keepTree: Bool, _ context: Context) -> Measured {
        if isCancelled { return Measured(bytes: 0, items: 0, node: nil) }
        var entries: [Entry] = []
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd >= 0, let dir = fdopendir(fd) {
            let dirFD = dirfd(dir)
            var batchItems = 0
            var batchBytes: Int64 = 0
            while let entry = readdir(dir) {
                let entryName: String = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                if entryName == "." || entryName == ".." { continue }
                var info = stat()
                let status = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                        fstatat(dirFD, $0, &info, AT_SYMLINK_NOFOLLOW)
                    }
                }
                guard status == 0 else {
                    unreadable.withLock { $0 += 1 }
                    continue
                }
                let type = info.st_mode & S_IFMT
                let blocks = Int64(info.st_blocks) * 512
                if type == S_IFDIR {
                    // Another volume mounted here, or a folder skipped on purpose.
                    guard context.devices.contains(info.st_dev) else { continue }
                    if !context.options.skip.isEmpty, context.options.skip.contains(DiskNode.join(path, entryName)) { continue }
                    entries.append(Entry(name: entryName, bytes: blocks, isFolder: true))
                    batchItems += 1
                    batchBytes += blocks
                } else {
                    var bytes = blocks
                    if info.st_nlink > 1, type == S_IFREG {
                        let key = LinkKey(device: info.st_dev, inode: UInt64(info.st_ino))
                        let first = seenLinks.withLock { $0.insert(key).inserted }
                        if !first { bytes = 0 }
                    }
                    entries.append(Entry(name: entryName, bytes: bytes, isFolder: false))
                    batchItems += 1
                    batchBytes += bytes
                }
            }
            closedir(dir)
            progress.add(items: batchItems, bytes: batchBytes)
        } else {
            if fd >= 0 { close(fd) }
            unreadable.withLock { $0 += 1 }
        }

        let folders = entries.filter(\.isFolder)
        var results = [Measured](repeating: Measured(bytes: 0, items: 0, node: nil), count: folders.count)
        let childPaths = folders.map { DiskNode.join(path, $0.name) }
        func measure(_ i: Int) -> Measured {
            let entry = folders[i]
            if Self.isPackage(entry.name) {
                let inner = folder(path: childPaths[i], name: entry.name, ownBytes: entry.bytes, depth: depth + 1, keepTree: false, context)
                let node = keepTree && inner.bytes >= context.options.keepAtLeast
                    ? DiskNode(name: entry.name, path: childPaths[i], bytes: inner.bytes, items: inner.items, kind: .package) : nil
                return Measured(bytes: inner.bytes, items: inner.items, node: node)
            }
            return folder(path: childPaths[i], name: entry.name, ownBytes: entry.bytes, depth: depth + 1, keepTree: keepTree, context)
        }
        if depth < context.options.parallelDepth, folders.count > 1 {
            let lock = OSAllocatedUnfairLock()
            results.withUnsafeMutableBufferPointer { buffer in
                let base = buffer.baseAddress!
                DispatchQueue.concurrentPerform(iterations: folders.count) { i in
                    let value = measure(i)
                    lock.withLock { base[i] = value }
                }
            }
        } else {
            for i in folders.indices { results[i] = measure(i) }
        }

        var bytes = ownBytes
        var items = 1
        for entry in entries where !entry.isFolder {
            bytes += entry.bytes
            items += 1
        }
        for result in results {
            bytes += result.bytes
            items += result.items
        }
        guard keepTree else { return Measured(bytes: bytes, items: items, node: nil) }

        // Keep the big ones; merge the rest into "smaller items".
        let threshold = context.options.keepAtLeast
        var kept: [DiskNode] = []
        var smallBytes: Int64 = 0
        var smallItems = 0
        for entry in entries where !entry.isFolder {
            if entry.bytes >= threshold {
                kept.append(DiskNode(name: entry.name, path: DiskNode.join(path, entry.name), bytes: entry.bytes, items: 1, kind: .file))
            } else {
                smallBytes += entry.bytes
                smallItems += 1
            }
        }
        for result in results {
            if let node = result.node, result.bytes >= threshold {
                kept.append(node)
            } else {
                smallBytes += result.bytes
                smallItems += result.items
            }
        }
        kept.sort { $0.bytes > $1.bytes }
        if kept.count > context.options.maxChildren {
            for node in kept[context.options.maxChildren...] {
                smallBytes += node.bytes
                smallItems += node.items
            }
            kept.removeSubrange(context.options.maxChildren...)
        }
        if smallItems > 0 {
            kept.append(DiskNode(name: "Smaller items", path: path, bytes: smallBytes, items: smallItems, kind: .smaller))
        }
        return Measured(bytes: bytes, items: items, node: DiskNode(name: name, path: path, bytes: bytes, items: items, kind: .folder, children: kept))
    }
}
