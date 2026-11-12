//
//  DiskMapModel.swift
//  Tutto
//
//  Clean Up › Disk map: scans your home folder (or, with Full Disk Access, the whole startup
//  disk) and keeps a compact tree of what takes the space, the folder you're looking at, and
//  its rings. Nothing runs until you scan; while a scan runs, its counts are read four times a
//  second, and that stops with the scan. Everything goes when Clean Up is switched off.
//

import AppKit
import os
import TuttoKit

private let log = Logger(subsystem: "ca.bryanyao.Tutto", category: "diskmap")

@MainActor
@Observable
final class DiskMapModel {
    enum Scope: Hashable {
        case home
        case wholeDisk
    }

    enum State: Equatable {
        case idle
        case scanning
        case ready
    }

    var scope: Scope = .home
    private(set) var state: State = .idle
    /// Counted so far, while scanning.
    private(set) var scannedItems = 0
    private(set) var scannedBytes: Int64 = 0
    private(set) var root: DiskNode?
    private(set) var focus: DiskNode?
    private(set) var slices: [SunburstSlice<DiskNode>] = []
    private(set) var scannedScope: Scope = .home
    private(set) var unreadable = 0
    private(set) var seconds: Double = 0
    /// What the last move to the Trash did, in a sentence.
    private(set) var lastResult: String?

    @ObservationIgnored private var scanner: DiskScanner?
    @ObservationIgnored private var task: Task<Void, Never>?

    /// The folder scanned, as a path.
    var rootPath: String { root?.path ?? NSHomeDirectory() }

    /// From the scanned folder down to the one shown.
    var trail: [DiskNode] {
        guard let root, let focus else { return [] }
        return root.chain(to: focus) ?? [root]
    }

    // MARK: Scanning

    func scan(fullDiskAccess: Bool) {
        guard state != .scanning else { return }
        let scope = fullDiskAccess ? self.scope : .home
        let options: DiskScanOptions
        switch scope {
        case .home: options = .home()
        case .wholeDisk:
            let name = (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]))?.volumeName
            options = .wholeDisk(title: name ?? "Startup disk")
        }
        let scanner = DiskScanner()
        self.scanner = scanner
        state = .scanning
        scannedItems = 0
        scannedBytes = 0
        lastResult = nil
        task = Task { @MainActor [weak self] in
            let work = Task.detached(priority: .userInitiated) { scanner.run(options) }
            // The counts, while it runs (and only then).
            let ticker = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    self?.scannedItems = scanner.progress.items
                    self?.scannedBytes = scanner.progress.bytes
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            let result = await work.value
            ticker.cancel()
            guard let self, self.scanner === scanner else { return }
            self.scanner = nil
            guard let result else {
                self.state = self.root == nil ? .idle : .ready
                return
            }
            self.root = result.root
            self.scannedScope = scope
            self.unreadable = result.unreadable
            self.seconds = result.seconds
            self.show(result.root)
            self.state = .ready
            log.notice("mapped \(result.root.items) items, \(result.root.bytes) bytes in \(result.seconds, format: .fixed(precision: 1)) s; \(result.root.nodeCount) nodes kept, \(result.unreadable) unreadable")
        }
    }

    func cancel() {
        scanner?.cancel()
    }

    /// Clean Up was switched off: stop and let the tree go.
    func stop() {
        scanner?.cancel()
        scanner = nil
        task?.cancel()
        task = nil
        root = nil
        focus = nil
        slices = []
        state = .idle
    }

    // MARK: Moving around

    func show(_ node: DiskNode) {
        guard node.kind == .folder else { return }
        focus = node
        slices = SunburstLayout.slices(root: node, sizeOf: \.bytes, children: \.children)
    }

    func goUp() {
        let trail = trail
        if trail.count > 1 { show(trail[trail.count - 2]) }
    }

    // MARK: Trash

    /// Why this item can't go to the Trash, or nil if it can.
    func refusal(_ node: DiskNode) -> DiskMapRules.Refusal? {
        guard node.kind != .smaller else { return .outsideScan }
        return DiskMapRules.refusal(node.path, root: rootPath, home: NSHomeDirectory())
    }

    /// Asks (stating the size), then moves the item to the Trash and takes it off the map.
    func moveToTrash(_ node: DiskNode) {
        let resolved = URL(fileURLWithPath: node.path).resolvingSymlinksInPath().path
        if let refusal = DiskMapRules.refusal(node.path, root: rootPath, home: NSHomeDirectory(), resolved: resolved) {
            lastResult = "\(node.name) stays where it is. \(refusal.sentence)"
            return
        }
        let size = ByteCountFormatter.string(fromByteCount: node.bytes, countStyle: .file)
        let alert = NSAlert()
        alert.messageText = "Move “\(node.name)” to the Trash?"
        alert.informativeText = "It takes \(size)\(node.items > 1 ? " in \(node.items.formatted()) items" : ""). You can put it back from the Trash; the space comes back when the Trash is emptied."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: node.path), resultingItemURL: nil)
        } catch {
            lastResult = "Couldn't move \(node.name) to the Trash: \(error.localizedDescription)"
            return
        }
        lastResult = "Moved \(node.name) (\(size)) to the Trash. Empty the Trash to get the space back."
        log.notice("moved \(node.bytes) bytes to the Trash")
        guard let root, let updated = root.removing(node.path) else { return }
        let shown = focus?.path ?? root.path
        self.root = updated
        show(updated.find(shown) ?? updated)
    }

    #if DEBUG
    /// Snapshots: a finished scan of any folder, without the progress loop.
    func previewScan(_ path: String) {
        guard let result = DiskScanner().run(DiskScanOptions(root: path, title: (path as NSString).lastPathComponent)) else { return }
        root = result.root
        unreadable = result.unreadable
        seconds = result.seconds
        show(result.root)
        state = .ready
    }
    #endif
}
