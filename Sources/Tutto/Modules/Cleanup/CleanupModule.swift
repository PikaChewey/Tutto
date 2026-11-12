//
//  CleanupModule.swift
//  Tutto
//
//  Clean Up: finds what apps you removed left behind in ~/Library, caches, logs, developer caches
//  and what's in the Trash. You review everything first; what you remove goes to the Trash (so
//  it can be put back), and emptying the Trash is a separate step with its own warning.
//
//  Only your home folder is looked at, nothing of Apple's is ever touched, a cache whose app is
//  running (or that changed in the last two minutes) is left alone, and every path is checked
//  again right before it moves. Nothing runs until you scan.
//

import AppKit
import os
import TuttoKit

private let log = Logger(subsystem: "ca.bryanyao.Tutto", category: "cleanup")

/// One thing Clean Up found: a folder or file, or (for leftovers) everything one removed app left.
struct CleanupItem: Identifiable, Sendable {
    let id: String
    let category: CleanupCategory
    let title: String
    let detail: String
    let paths: [URL]
    /// The folder each path was found in, for the safety check before it moves.
    let roots: [URL]
    let bytes: Int64
    /// Ticked when found (a guess, a developer cache or a leftover with sign-in data isn't).
    let suggested: Bool
}

@MainActor
@Observable
final class CleanupModule: ModuleController {
    enum State: Equatable {
        case idle
        case scanning(String)
        case ready
        case cleaning
    }

    private(set) var state: State = .idle
    private(set) var items: [CleanupItem] = []
    var selected: Set<String> = []
    /// Places that couldn't be read (no Full Disk Access).
    private(set) var skipped: [String] = []
    private(set) var trash: (count: Int, bytes: Int64)?
    /// What the last clean did, in a sentence.
    private(set) var lastResult: String?
    private(set) var scannedAt: Date?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let cancelled = OSAllocatedUnfairLock(initialState: false)
    /// The page's Disk map: what fills the disk.
    let diskMap = DiskMapModel()

    func start() {}

    func stop() {
        cancelScan()
        diskMap.stop()
    }

    var selectedBytes: Int64 { items.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.bytes } }
    var foundBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }

    // MARK: Scanning

    /// Scans unless results are fresh (the Clean tile opens the page this way).
    func scanIfStale() {
        if case .idle = state { return scan() }
        if case .ready = state, let scannedAt, Date().timeIntervalSince(scannedAt) > 300 { scan() }
    }

    func scan() {
        if case .scanning = state { return }
        if case .cleaning = state { return }
        state = .scanning("Getting started")
        lastResult = nil
        cancelled.withLock { $0 = false }
        let fullDiskAccess = Permissions.hasFullDiskAccess()
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier?.lowercased() })
        let runningNames = Set(NSWorkspace.shared.runningApplications.compactMap { $0.localizedName?.lowercased() })
        let cancelled = self.cancelled
        let started = Date()
        task = Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                CleanupScanner.run(fullDiskAccess: fullDiskAccess, running: running, runningNames: runningNames,
                                   progress: { place in
                                       Task { @MainActor in
                                           if case .scanning = self.state { self.state = .scanning(place) }
                                       }
                                   },
                                   isCancelled: { cancelled.withLock { $0 } })
            }.value
            guard !cancelled.withLock({ $0 }) else {
                state = items.isEmpty ? .idle : .ready
                return
            }
            items = result.items.sorted { $0.bytes > $1.bytes }
            selected = Set(result.items.filter(\.suggested).map(\.id))
            skipped = result.skipped
            trash = result.trash
            scannedAt = Date()
            state = .ready
            log.notice("scanned in \(Date().timeIntervalSince(started), format: .fixed(precision: 1)) s: \(result.items.count) items, \(self.foundBytes) bytes")
        }
    }

    func cancelScan() {
        cancelled.withLock { $0 = true }
    }

    // MARK: Cleaning

    private struct Outcome: Sendable {
        var moved = 0
        var bytes: Int64 = 0
        var failed: [String] = []
        var done: Set<String> = []
    }

    /// Moves what's ticked to the Trash, checking each path again first.
    func moveSelectedToTrash() {
        let chosen = items.filter { selected.contains($0.id) }
        guard !chosen.isEmpty, state == .ready else { return }
        state = .cleaning
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier?.lowercased() })
        Task { @MainActor in
            let outcome = await Task.detached(priority: .userInitiated) { Self.trash(chosen, running: running) }.value
            items.removeAll { outcome.done.contains($0.id) }
            selected.subtract(outcome.done)
            let size = ByteCountFormatter.string(fromByteCount: outcome.bytes, countStyle: .file)
            var sentence = "Moved \(outcome.moved) item\(outcome.moved == 1 ? "" : "s") (\(size)) to the Trash. Empty the Trash to get the space back."
            if !outcome.failed.isEmpty {
                sentence += " Left \(outcome.failed.count) that couldn't move: \(outcome.failed.prefix(3).joined(separator: ", "))."
            }
            lastResult = sentence
            state = .ready
            refreshTrash()
            log.notice("moved \(outcome.moved) items, \(outcome.bytes) bytes; \(outcome.failed.count) left")
        }
    }

    private nonisolated static func trash(_ chosen: [CleanupItem], running: Set<String>) -> Outcome {
        var outcome = Outcome()
        for item in chosen {
            var all = true
            for (path, root) in zip(item.paths, item.roots) {
                let resolved = path.resolvingSymlinksInPath().path
                // A cache whose app started since the scan is left alone.
                if item.category == .cache, let id = CleanupRules.bundleID(fromName: path.lastPathComponent),
                   running.contains(id.lowercased()) {
                    outcome.failed.append("\(path.lastPathComponent) (its app is running)")
                    all = false
                    continue
                }
                guard CleanupRules.isSafeToRemove(path.path, root: root.path, resolved: resolved),
                      !CleanupRules.isApple(path.lastPathComponent) else {
                    outcome.failed.append(path.lastPathComponent)
                    all = false
                    continue
                }
                do {
                    try FileManager.default.trashItem(at: path, resultingItemURL: nil)
                    outcome.moved += 1
                } catch {
                    outcome.failed.append(path.lastPathComponent)
                    all = false
                }
            }
            if all {
                outcome.done.insert(item.id)
                outcome.bytes += item.bytes
            }
        }
        return outcome
    }

    /// Empties the Trash for good, after asking. Needs Full Disk Access to reach it.
    func emptyTrash() {
        guard let trash, trash.count > 0 else { return }
        let alert = NSAlert()
        alert.messageText = "Empty the Trash?"
        alert.informativeText = "This permanently deletes \(trash.count) item\(trash.count == 1 ? "" : "s") (\(ByteCountFormatter.string(fromByteCount: trash.bytes, countStyle: .file))). You can't undo this."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Empty Trash")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { @MainActor in
            let removed = await Task.detached(priority: .userInitiated) { () -> Int in
                let folder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash")
                let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
                var removed = 0
                for entry in entries where CleanupRules.isSafeToRemove(entry.path, root: folder.path) {
                    if (try? FileManager.default.removeItem(at: entry)) != nil { removed += 1 }
                }
                return removed
            }.value
            lastResult = "Emptied the Trash: \(removed) item\(removed == 1 ? "" : "s") deleted."
            refreshTrash()
        }
    }

    func refreshTrash() {
        guard Permissions.hasFullDiskAccess() else { trash = nil; return }
        Task { @MainActor in
            trash = await Task.detached(priority: .utility) { CleanupScanner.trashContents() }.value
        }
    }
}

// MARK: - The scan

enum CleanupScanner {
    struct Result: Sendable {
        var items: [CleanupItem] = []
        var skipped: [String] = []
        var trash: (count: Int, bytes: Int64)?
    }

    /// Folders in ~/Library where apps keep things, and whether reading them needs Full Disk Access.
    private static let places: [(folder: String, needsFullDisk: Bool)] = [
        ("Application Support", false), ("Caches", false), ("Preferences", false), ("Saved Application State", false),
        ("HTTPStorages", false), ("WebKit", false), ("Logs", false), ("Cookies", false), ("Application Scripts", false),
        ("LaunchAgents", false), ("Containers", true), ("Group Containers", true),
    ]

    static func run(fullDiskAccess: Bool, running: Set<String>, runningNames: Set<String>,
                    progress: @Sendable (String) -> Void, isCancelled: @Sendable () -> Bool) -> Result {
        var result = Result()
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let library = home.appendingPathComponent("Library")
        progress("Listing your apps")
        let apps = installedApps()
        let installed = CleanupRules.normalized(apps.ids).union(running)
        let installedNames = apps.names.union(runningNames)
        var ownedCache: [String: Bool] = [:]
        func owned(_ id: String) -> Bool {
            if let known = ownedCache[id] { return known }
            // Apps elsewhere (another disk) are known to Launch Services.
            let answer = CleanupRules.isOwned(id, installed: installed)
                || NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
            ownedCache[id] = answer
            return answer
        }

        // Left behind: names that are bundle IDs no app here owns, grouped by app.
        var leftovers: [String: [(url: URL, root: URL, bytes: Int64, latest: Date?, signIn: Bool)]] = [:]
        var listedPaths = Set<String>()
        for place in places {
            if isCancelled() { return result }
            let root = library.appendingPathComponent(place.folder)
            if place.needsFullDisk && !fullDiskAccess {
                result.skipped.append("~/Library/\(place.folder)")
                continue
            }
            progress("Looking in ~/Library/\(place.folder)")
            guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
                if FileManager.default.fileExists(atPath: root.path) { result.skipped.append("~/Library/\(place.folder)") }
                continue
            }
            for entry in entries {
                guard let id = CleanupRules.bundleID(fromName: entry.lastPathComponent), !CleanupRules.isApple(id), !owned(id),
                      !CleanupRules.isDeveloperCache("Library/\(place.folder)/\(entry.lastPathComponent)") else { continue }
                if place.folder == "LaunchAgents", programExists(entry) { continue }
                let size = measure(entry, isCancelled: isCancelled)
                let names = (try? FileManager.default.contentsOfDirectory(atPath: entry.path)) ?? [entry.lastPathComponent]
                leftovers[id.lowercased(), default: []].append((entry, root, size.bytes, size.latest, names.contains(where: CleanupRules.looksLikeSignIn)))
                listedPaths.insert(entry.path)
            }
        }
        for (id, found) in leftovers where found.reduce(0, { $0 + $1.bytes }) > 0 {
            let placeSet = Set(found.map { $0.root.lastPathComponent })
            let dataLatest = found.filter { !CleanupRules.disposablePlaces.contains($0.root.lastPathComponent) }.compactMap(\.latest).max()
            let signIn = found.contains(where: \.signIn)
            let suggested = CleanupRules.suggestsRemoving(places: placeSet, lastChange: dataLatest ?? found.compactMap(\.latest).max(), hasSignIn: signIn)
            var detail = "\(found.count) place\(found.count == 1 ? "" : "s"): \(placeSet.sorted().joined(separator: ", "))"
            if signIn { detail += " · has sign-in data" } else if !suggested { detail += " · used lately" }
            result.items.append(CleanupItem(id: "leftover:\(id)", category: .leftover, title: id, detail: detail,
                                            paths: found.map(\.url), roots: found.map(\.root), bytes: found.reduce(0) { $0 + $1.bytes },
                                            suggested: suggested))
        }

        // Probably left behind: an app-data folder named for no app here, untouched for a month.
        let support = library.appendingPathComponent("Application Support")
        progress("Looking for old app data")
        for entry in (try? FileManager.default.contentsOfDirectory(at: support, includingPropertiesForKeys: nil)) ?? [] {
            if isCancelled() { return result }
            let name = entry.lastPathComponent
            let lower = name.lowercased()
            guard !name.contains("."), !CleanupRules.neverProbable.contains(lower), !installedNames.contains(lower),
                  !installedNames.contains(where: { $0.hasPrefix(lower) || lower.hasPrefix($0) }),
                  !listedPaths.contains(entry.path) else { continue }
            let inside = Set((try? FileManager.default.contentsOfDirectory(atPath: entry.path)) ?? [])
            guard !inside.isDisjoint(with: CleanupRules.appDataMarkers) else { continue }
            let size = measure(entry, isCancelled: isCancelled)
            guard let latest = size.latest, Date().timeIntervalSince(latest) > CleanupRules.staleAge, size.bytes > 1_000_000 else { continue }
            result.items.append(CleanupItem(id: "probable:\(entry.path)", category: .probableLeftover, title: name,
                                            detail: "~/Library/Application Support/\(name) · untouched since \(latest.formatted(date: .abbreviated, time: .omitted))",
                                            paths: [entry], roots: [support], bytes: size.bytes, suggested: false))
        }

        // Caches: each app's, unless it's running, in use, Apple's or a developer cache.
        let caches = library.appendingPathComponent("Caches")
        progress("Measuring caches")
        for entry in (try? FileManager.default.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil)) ?? [] {
            if isCancelled() { return result }
            let name = entry.lastPathComponent
            guard !listedPaths.contains(entry.path), !CleanupRules.isApple(name),
                  !CleanupRules.isDeveloperCache("Library/Caches/\(name)") else { continue }
            // In use: its app (or another app of the same maker) is running.
            if let id = CleanupRules.bundleID(fromName: name) {
                let vendor = CleanupRules.vendor(of: id)
                if running.contains(where: { $0 == vendor || $0.hasPrefix(vendor + ".") }) { continue }
            }
            if runningNames.contains(name.lowercased()) { continue }
            let size = measure(entry, isCancelled: isCancelled)
            guard size.bytes > 100_000 else { continue }
            if let latest = size.latest, Date().timeIntervalSince(latest) < CleanupRules.busyCacheAge { continue }
            result.items.append(CleanupItem(id: "cache:\(entry.path)", category: .cache, title: name, detail: "~/Library/Caches/\(name)",
                                            paths: [entry], roots: [caches], bytes: size.bytes, suggested: true))
        }

        // Logs, unless one is being written.
        let logs = library.appendingPathComponent("Logs")
        progress("Measuring logs")
        for entry in (try? FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil)) ?? [] {
            if isCancelled() { return result }
            guard !listedPaths.contains(entry.path), !CleanupRules.isApple(entry.lastPathComponent) else { continue }
            let size = measure(entry, isCancelled: isCancelled)
            guard size.bytes > 10_000 else { continue }
            if let latest = size.latest, Date().timeIntervalSince(latest) < CleanupRules.busyLogAge { continue }
            result.items.append(CleanupItem(id: "log:\(entry.path)", category: .log, title: entry.lastPathComponent,
                                            detail: "~/Library/Logs/\(entry.lastPathComponent)", paths: [entry], roots: [logs], bytes: size.bytes,
                                            suggested: true))
        }

        // Developer caches that rebuild themselves.
        progress("Measuring developer caches")
        for cache in CleanupRules.developerCaches {
            if isCancelled() { return result }
            let url = home.appendingPathComponent(cache.path)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let size = measure(url, isCancelled: isCancelled)
            guard size.bytes > 1_000_000 else { continue }
            result.items.append(CleanupItem(id: "developer:\(cache.path)", category: .developer, title: cache.title,
                                            detail: "~/\(cache.path) · \(cache.note)", paths: [url], roots: [url.deletingLastPathComponent()],
                                            bytes: size.bytes, suggested: false))
        }

        if fullDiskAccess {
            progress("Measuring the Trash")
            result.trash = trashContents()
        } else {
            result.skipped.append("the Trash")
        }
        return result
    }

    /// Bundle IDs and names of what's installed in the usual places (two folders deep, for
    /// suites): apps, and the plug-ins, preference panes and Java installs that keep settings too.
    static func installedApps() -> (ids: [String], names: Set<String>) {
        var ids: [String] = []
        var names = Set<String>()
        let home = NSHomeDirectory()
        let roots = ["/Applications", home + "/Applications", "/System/Applications", "/System/Library/CoreServices",
                     "/Library/Application Support", "/System/Library/CoreServices/Applications", "/Library/Internet Plug-Ins",
                     home + "/Library/Internet Plug-Ins", "/Library/PreferencePanes", home + "/Library/PreferencePanes",
                     "/Library/Java/JavaVirtualMachines", "/Library/Audio/Plug-Ins/Components", "/Library/Screen Savers"]
        let bundleTypes: Set<String> = ["app", "plugin", "prefpane", "jdk", "component", "vst", "vst3", "saver"]
        func visit(_ folder: URL, depth: Int) {
            guard let entries = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
            for entry in entries {
                if bundleTypes.contains(entry.pathExtension.lowercased()) {
                    if let bundle = Bundle(url: entry) {
                        if let id = bundle.bundleIdentifier { ids.append(id) }
                        for key in ["CFBundleName", "CFBundleDisplayName", "CFBundleExecutable"] {
                            if let name = bundle.object(forInfoDictionaryKey: key) as? String { names.insert(name.lowercased()) }
                        }
                    }
                    names.insert(entry.deletingPathExtension().lastPathComponent.lowercased())
                } else if depth > 0, (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    visit(entry, depth: depth - 1)
                }
            }
        }
        for root in roots { visit(URL(fileURLWithPath: root), depth: 2) }
        return (ids, names)
    }

    /// A LaunchAgent whose program is still on disk belongs to something installed.
    private static func programExists(_ plist: URL) -> Bool {
        guard let info = NSDictionary(contentsOf: plist) as? [String: Any] else { return true }
        let program = (info["Program"] as? String) ?? (info["ProgramArguments"] as? [String])?.first
        guard let program else { return true }
        return FileManager.default.fileExists(atPath: (program as NSString).expandingTildeInPath)
    }

    /// Bytes on disk, and the newest change anywhere inside (links aren't followed).
    static func measure(_ url: URL, isCancelled: () -> Bool) -> (bytes: Int64, latest: Date?) {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .contentModificationDateKey, .isDirectoryKey]
        var total: Int64 = 0
        var latest: Date?
        func add(_ values: URLResourceValues?) {
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
            if let date = values?.contentModificationDate, latest.map({ date > $0 }) ?? true { latest = date }
        }
        let top = try? url.resourceValues(forKeys: Set(keys))
        guard top?.isDirectory == true else {
            add(top)
            return (total, latest)
        }
        if let date = top?.contentModificationDate { latest = date }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [],
                                                              errorHandler: { _, _ in true }) else { return (0, latest) }
        var count = 0
        for case let file as URL in enumerator {
            add(try? file.resourceValues(forKeys: Set(keys)))
            count += 1
            if count % 2000 == 0, isCancelled() { break }
        }
        return (total, latest)
    }

    /// What's in the Trash: items at its top level and their total size.
    static func trashContents() -> (count: Int, bytes: Int64)? {
        let folder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash")
        guard let entries = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return nil }
        let visible = entries.filter { $0.lastPathComponent != ".DS_Store" }
        return (visible.count, visible.reduce(0) { $0 + measure($1, isCancelled: { false }).bytes })
    }
}
