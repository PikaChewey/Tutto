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
            menu.addItem(item("Open in Tutto", #selector(browse(_:)), NSImage(systemSymbolName: "archivebox", accessibilityDescription: nil)))
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
        if let convert = convertMenu(for: items) { menu.addItem(convert) }
        return menu.items.isEmpty ? nil : menu
    }

    // MARK: Convert

    /// What each kind of file can become from Finder (the most used; the window has them all).
    /// Mirrors TuttoKit's ConvertPlanner, which the extension doesn't link (to stay small).
    private static let convertKinds: [(extensions: Set<String>, formats: [(title: String, code: String)], compress: Bool)] = [
        (["jpg", "jpeg", "png", "heic", "heif", "avif", "webp", "tif", "tiff", "gif", "bmp", "dng", "cr2", "cr3", "nef", "arw", "raf", "psd"],
         [("JPEG", "jpeg"), ("PNG", "png"), ("HEIC", "heic"), ("PDF", "pdf")], true),
        (["mov", "mp4", "m4v", "3gp", "mpg", "mpeg", "avi"], [("MP4", "mp4"), ("GIF", "gif"), ("Sound only (M4A)", "m4a")], true),
        (["mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac", "ogg", "opus"], [("M4A", "m4a"), ("WAV", "wav"), ("FLAC", "flac")], true),
        (["pdf"], [("PNG Pictures", "png"), ("JPEG Pictures", "jpeg"), ("Text", "txt")], true),
        (["docx", "doc", "rtf", "rtfd", "odt", "html", "htm", "txt", "md", "markdown"], [("PDF", "pdf"), ("Word", "docx"), ("Text", "txt")], false),
        (["srt", "vtt"], [("SRT", "srt"), ("VTT", "vtt")], false),
    ]
    /// Menu item tags index into this.
    private static let formatCodes = ["jpeg", "png", "heic", "pdf", "mp4", "gif", "m4a", "wav", "flac", "txt", "docx", "srt", "vtt"]

    private func convertMenu(for items: [URL]) -> NSMenuItem? {
        let groups = items.map { url in Self.convertKinds.firstIndex { $0.extensions.contains(url.pathExtension.lowercased()) } }
        guard !groups.isEmpty, groups.allSatisfy({ $0 != nil }) else { return nil }
        let distinct = Set(groups.compactMap { $0 })
        var formats: [(title: String, code: String)] = []
        if distinct.count == 1, let group = distinct.first {
            formats = Self.convertKinds[group].formats
        } else if distinct.isSubset(of: [0, 3]) {
            formats = [("One PDF", "pdf")]  // pictures and PDFs together
        }
        if items.count > 1, distinct.isSubset(of: [0, 3]), let index = formats.firstIndex(where: { $0.code == "pdf" }) {
            formats[index].title = "One PDF"
        }
        let compress = distinct.allSatisfy { Self.convertKinds[$0].compress }
        guard !formats.isEmpty || compress else { return nil }

        let submenu = NSMenu(title: "Convert")
        for format in formats {
            guard let tag = Self.formatCodes.firstIndex(of: format.code) else { continue }
            let entry = NSMenuItem(title: format.title, action: #selector(convertTo(_:)), keyEquivalent: "")
            entry.tag = tag
            submenu.addItem(entry)
        }
        if compress {
            if !formats.isEmpty { submenu.addItem(.separator()) }
            submenu.addItem(NSMenuItem(title: "Compress", action: #selector(compressFiles(_:)), keyEquivalent: ""))
        }
        submenu.addItem(NSMenuItem(title: "More…", action: #selector(moreConvert(_:)), keyEquivalent: ""))
        let entry = NSMenuItem(title: "Convert", action: nil, keyEquivalent: "")
        entry.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        entry.submenu = submenu
        return entry
    }

    @objc func convertTo(_ sender: AnyObject?) {
        guard let tag = (sender as? NSMenuItem)?.tag, Self.formatCodes.indices.contains(tag) else { return }
        sendConvert(["to": Self.formatCodes[tag]])
    }

    @objc func compressFiles(_ sender: AnyObject?) { sendConvert(["compress": "1"]) }
    @objc func moreConvert(_ sender: AnyObject?) { sendConvert(["open": "1"]) }

    private func sendConvert(_ parameters: [String: String]) {
        let urls = FIFinderSyncController.default().selectedItemURLs() ?? []
        guard !urls.isEmpty else { return }
        var components = URLComponents()
        components.scheme = "tutto"
        components.host = "convert"
        components.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) } + urls.map { URLQueryItem(name: "path", value: $0.path) }
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    private func item(_ title: String, _ action: Selector, _ image: NSImage?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.image = image
        return item
    }

    @objc func browse(_ sender: AnyObject?) { send("browse", archivesOnly: true) }
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
