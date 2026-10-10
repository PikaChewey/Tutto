//
//  FinderSync.swift
//  TuttoFinder
//
//  Adds Extract and Compress to Finder's right-click menu. The extension is sandboxed and tiny: it only builds the menu and hands
//  the selected files to Tutto through a tutto:// URL. Tutto does the work.
//

import AppKit
import FinderSync

@objc(FinderSync)
final class FinderSync: FIFinderSync {
    /// Extensions Tutto can extract (kept in step with TuttoKit's ArchiveFormats).
    private static let archiveExtensions: Set<String> = [
        "zip", "zipx", "rar", "7z", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "lzma", "tlz", "z", "taz",
        "iso", "cab", "lzh", "lha", "xar", "pkg", "cpio", "ar", "deb", "rpm", "warc", "jar", "apk", "epub", "cbz", "cbr",
    ]

    override init() {
        super.init()
        // Every folder, including other disks under /Volumes.
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    static func isArchive(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()
        if archiveExtensions.contains(ext) { return true }
        // Split archives: name.7z.001, name.zip.001, name.r00…
        if ext.count == 3, Int(ext) != nil, name.contains(".7z.") || name.contains(".zip.") || name.contains(".rar.") { return true }
        if ext.hasPrefix("r"), ext.count == 3, Int(ext.dropFirst()) != nil { return true }
        return false
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems,
              let items = FIFinderSyncController.default().selectedItemURLs(), !items.isEmpty else { return nil }
        let archives = items.filter(Self.isArchive)
        let menu = NSMenu(title: "")
        let icon = NSImage(systemSymbolName: "archivebox", accessibilityDescription: nil)

        if archives.count == 1, let archive = archives.first {
            menu.addItem(item("Extract Here", #selector(extractHere(_:)), icon))
            let base = Self.baseName(archive)
            menu.addItem(item("Extract to “\(base)”", #selector(extractToFolder(_:)), icon))
            menu.addItem(item("Extract to…", #selector(extractChoose(_:)), icon))
        } else if archives.count > 1 {
            menu.addItem(item("Extract \(archives.count) Archives Here", #selector(extractHere(_:)), icon))
            menu.addItem(item("Extract Each to Its Own Folder", #selector(extractToFolder(_:)), icon))
        }
        if archives.count != items.count || archives.isEmpty {
            let title = items.count == 1
                ? "Compress “\(items[0].lastPathComponent)” to ZIP"
                : "Compress \(items.count) Items to ZIP"
            menu.addItem(item(title, #selector(compress(_:)), NSImage(systemSymbolName: "doc.zipper", accessibilityDescription: nil)))
        }
        return menu.items.isEmpty ? nil : menu
    }

    private func item(_ title: String, _ action: Selector, _ image: NSImage?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.image = image
        return item
    }

    @objc func extractHere(_ sender: AnyObject?) { send("extract-here", archivesOnly: true) }
    @objc func extractToFolder(_ sender: AnyObject?) { send("extract-folder", archivesOnly: true) }
    @objc func extractChoose(_ sender: AnyObject?) { send("extract-choose", archivesOnly: true) }
    @objc func compress(_ sender: AnyObject?) { send("compress", archivesOnly: false) }

    private func send(_ action: String, archivesOnly: Bool) {
        var urls = FIFinderSyncController.default().selectedItemURLs() ?? []
        if archivesOnly { urls = urls.filter(Self.isArchive) }
        guard !urls.isEmpty else { return }
        var components = URLComponents()
        components.scheme = "tutto"
        components.host = "archive"
        components.queryItems = [URLQueryItem(name: "action", value: action)] + urls.map { URLQueryItem(name: "path", value: $0.path) }
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    private static func baseName(_ url: URL) -> String {
        var name = url.lastPathComponent
        for suffix in [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.lzma", ".tar.z"] where name.lowercased().hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        name = (name as NSString).deletingPathExtension
        // name.part1(.rar) / name.7z(.001)
        if let range = name.range(of: #"\.part0*1$"#, options: [.regularExpression, .caseInsensitive]) { name.removeSubrange(range) }
        for ext in [".7z", ".zip", ".rar"] where name.lowercased().hasSuffix(ext) { name = String(name.dropLast(ext.count)) }
        return name
    }
}
