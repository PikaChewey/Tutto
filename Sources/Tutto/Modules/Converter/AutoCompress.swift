//
//  AutoCompress.swift
//  Tutto
//
//  Compressing by itself (Bryan, 2026-11-13: "Automatically compress images, videos and PDFs"):
//  new pictures, videos and PDFs in the watched folders (the Desktop, where screenshots and screen
//  recordings land, and the screenshots folder if macOS saves them elsewhere), Tutto's own saved
//  screenshots, and pictures copied to the clipboard. Each file is compressed in place; its
//  original is kept in Tutto's folder for a few days, so the compress can be undone from the
//  result card (or the folder, from the Convert page).
//
//  At rest: one FSEvents stream (the kernel's file events, delivered in batches; no timer and no
//  scanning) and, only when the clipboard history is off, the clipboard's change counter read
//  about once a second, slower when you're away.
//

import AppKit
import CoreServices
import Darwin
import os
import TuttoKit

private let log = Logger(subsystem: "ca.bryanyao.Tutto", category: "auto-compress")

// MARK: - Done marks

/// The extended attribute that says a file is done (compressed by Tutto, or put back as it was).
enum DoneMark {
    static func isSet(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return getxattr(path, AutoCompressRules.doneAttribute, nil, 0, 0, XATTR_NOFOLLOW) >= 0
        }
    }

    static func set(_ url: URL, _ value: String = "compressed") {
        let bytes = Array(value.utf8)
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            _ = setxattr(path, AutoCompressRules.doneAttribute, bytes, bytes.count, 0, XATTR_NOFOLLOW)
        }
    }
}

// MARK: - Kept originals

/// Where the originals of files compressed in place are kept (Application Support/Tutto/Originals,
/// one folder per file, named by time), and where in-place work is written first.
enum OriginalsStore {
    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tutto/Originals", isDirectory: true)
    }

    /// A fresh folder for one job's results, on the home volume (so the swap is a rename).
    static func workFolder() throws -> URL {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ca.bryanyao.Tutto/Work/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Moves `file` into the store under `name`; returns where it went.
    static func keep(_ file: URL, name: String) throws -> URL {
        let stamp = Self.stamp.string(from: Date())
        let holder = folder.appendingPathComponent("\(stamp) \(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: holder, withIntermediateDirectories: true)
        let kept = holder.appendingPathComponent(name)
        try FileManager.default.moveItem(at: file, to: kept)
        return kept
    }

    /// Removes a kept original's folder once it's been put back or let go.
    static func forget(_ kept: URL) {
        let holder = kept.deletingLastPathComponent()
        guard holder.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: holder)
    }

    /// Clears out originals older than `keepDays` (and the oldest past 4 GB), off the main thread.
    static func prune(keepDays: Int) {
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.creationDateKey, .totalFileAllocatedSizeKey]
            guard let holders = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return }
            let items = holders.map { holder -> KeptOriginals.Item in
                let date = (try? holder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let files = (try? fm.contentsOfDirectory(at: holder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])) ?? []
                let bytes = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0) }
                return KeptOriginals.Item(url: holder, date: date, bytes: bytes)
            }
            for url in KeptOriginals.toRemove(items, now: Date(), keepDays: keepDays) { try? fm.removeItem(at: url) }
            // Work folders left by a job that didn't finish (a quit mid-video).
            let work = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ca.bryanyao.Tutto/Work")
            for leftover in (try? fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)) ?? [] { try? fm.removeItem(at: leftover) }
        }
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }()
}

// MARK: - Watched folders

/// The folders watched by default: the Desktop, and where macOS saves screenshots when that's
/// somewhere else.
enum WatchedFolders {
    static var defaults: [URL] {
        var folders = [FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]]
        if let location = CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) as? String {
            let url = URL(fileURLWithPath: (location as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
            if !folders.contains(where: { $0.standardizedFileURL == url }),
               FileManager.default.fileExists(atPath: url.path) { folders.append(url) }
        }
        return folders
    }

    static func resolve(_ settings: AutoCompressSettings) -> [URL] {
        settings.folders.isEmpty ? defaults : settings.folders.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// "Desktop", "Desktop and Screenshots".
    static func names(_ folders: [URL]) -> String {
        let names = folders.map { $0.lastPathComponent }
        switch names.count {
        case 0: return "no folders"
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return "\(names[0]) and \(names.count - 1) more"
        }
    }
}

/// Watches folders for files that appear in them (not in their subfolders), waits for each to
/// settle (nothing written to it for a moment), and hands over the ones the rules accept.
@MainActor
final class FolderWatcher {
    var onFiles: ([URL]) -> Void = { _ in }
    var settings = AutoCompressSettings()

    private var stream: FSEventStreamRef?
    private var folders: Set<String> = []
    private var pending: [String: Date] = [:]
    private var settle: DispatchWorkItem?
    /// Paths Tutto wrote itself a moment ago (never picked up again).
    private var own: [String: Date] = [:]

    func watch(_ urls: [URL]) {
        let paths = Set(urls.map { $0.standardizedFileURL.path })
        guard paths != folders || stream == nil else { return }
        stop()
        folders = paths
        guard !paths.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
                                           copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let flagList = (0..<count).map { flags[$0] }
            MainActor.assumeIsolated { watcher.received(list, flagList) }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagIgnoreSelf)
        guard let stream = FSEventStreamCreate(nil, callback, &context, Array(paths) as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.4, flags) else {
            log.error("couldn't watch \(paths.joined(separator: ", "), privacy: .public)")
            return
        }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
        log.notice("watching \(paths.count) folder(s)")
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        folders = []
        pending.removeAll()
        settle?.cancel()
    }

    /// A file Tutto just wrote (or put back): not to be compressed again.
    func noteOwn(_ url: URL) {
        let now = Date()
        own = own.filter { now.timeIntervalSince($0.value) < 30 }
        own[url.standardizedFileURL.path] = now
    }

    private func received(_ paths: [String], _ flags: [FSEventStreamEventFlags]) {
        let wanted = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemModified)
        for (path, flag) in zip(paths, flags) {
            guard flag & wanted != 0, flag & UInt32(kFSEventStreamEventFlagItemIsFile) != 0 else { continue }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard folders.contains(url.deletingLastPathComponent().path) else { continue }
            if pending[url.path] == nil { pending[url.path] = Date() }
        }
        guard !pending.isEmpty else { return }
        scheduleSettle()
    }

    private func scheduleSettle() {
        settle?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.check() }
        }
        settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + AutoCompressRules.settleSeconds, execute: work)
    }

    private func check() {
        let now = Date()
        var ready: [URL] = []
        var waiting = false
        for (path, _) in pending {
            let url = URL(fileURLWithPath: path)
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey, .fileSizeKey, .isRegularFileKey])
            guard let values, values.isRegularFile == true else {
                pending[path] = nil
                continue
            }
            // Still being written: look again in a moment.
            if let modified = values.contentModificationDate, now.timeIntervalSince(modified) < AutoCompressRules.settleSeconds {
                waiting = true
                continue
            }
            pending[path] = nil
            if let at = own[path], now.timeIntervalSince(at) < 30 { continue }
            let kind = FileKind.of(url)
            guard AutoCompressRules.shouldCompress(name: url.lastPathComponent, kind: kind, bytes: values.fileSize ?? 0,
                                                   created: values.creationDate, now: now, settings: settings,
                                                   alreadyDone: DoneMark.isSet(url)) else { continue }
            if kind == .pdf, PDFSignatures.isSigned(url) { continue }
            ready.append(url)
        }
        if waiting { scheduleSettle() }
        guard !ready.isEmpty else { return }
        guard AutoCompressRules.withinBurst(ready.map(FileKind.of)) else {
            log.notice("left a batch of \(ready.count) alone (an export or a download, not a screenshot)")
            return
        }
        onFiles(ready)
    }
}

/// A signed PDF changes its signature's meaning when rewritten: those are left alone.
enum PDFSignatures {
    static func isSigned(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        // Signature fields are named in the document's structure; reading the first and last 2 MB finds them
        // in the PDFs people sign (forms, contracts) without loading the whole file.
        let head = (try? handle.read(upToCount: 2_000_000)) ?? Data()
        let end = (try? handle.seekToEnd()) ?? 0
        var tail = Data()
        if end > 4_000_000 {
            try? handle.seek(toOffset: end - 2_000_000)
            tail = (try? handle.read(upToCount: 2_000_000)) ?? Data()
        }
        for chunk in [head, tail] where chunk.range(of: Data("/Sig".utf8)) != nil && chunk.range(of: Data("/ByteRange".utf8)) != nil {
            return true
        }
        return false
    }
}

// MARK: - The clipboard

/// Pictures copied to the clipboard, smaller: a screenshot copied with ⌃⇧⌘4 becomes a palette PNG
/// when that looks the same (most screenshots), and can be brought to half its pixels. Only
/// clipboards that hold nothing but a picture are touched (a copy from a web page keeps its text
/// and links); HEIC stays HEIC; what Tutto put there itself is never done twice.
@MainActor
final class ClipboardShrinker {
    static let marker = NSPasteboard.PasteboardType("ca.bryanyao.Tutto.compressed")
    private static let imageTypes: Set<NSPasteboard.PasteboardType> = [.png, .tiff, NSPasteboard.PasteboardType("public.jpeg")]
    /// Anything besides a picture means the copy is more than a picture (a web page's image with its
    /// link, a document's selection, files): those stay exactly as copied. HEIC stays HEIC.
    private static let others: Set<NSPasteboard.PasteboardType> = [.string, .URL, .fileURL, .html, .rtf, .rtfd, .pdf,
                                                                     NSPasteboard.PasteboardType("public.heic"),
                                                                     NSPasteboard.PasteboardType("public.url"),
                                                                     NSPasteboard.PasteboardType("com.apple.webarchive")]

    struct Done {
        var before: Int
        var after: Int
        var original: Data
        var originalType: NSPasteboard.PasteboardType
        var thumbnail: NSImage?
    }

    /// Whether the clipboard holds just a picture worth looking at.
    static func wants(_ pasteboard: NSPasteboard) -> Bool {
        let types = pasteboard.types ?? []
        guard !types.contains(marker), types.contains(where: imageTypes.contains) else { return false }
        return !types.contains(where: others.contains)
    }

    /// Compresses what's on the clipboard now; `done` gets the result, or nil when it's already
    /// small or the clipboard moved on meanwhile.
    static func shrink(halve: Bool, done: @escaping @MainActor (Done?) -> Void) {
        let pasteboard = NSPasteboard.general
        let count = pasteboard.changeCount
        let type: NSPasteboard.PasteboardType = pasteboard.data(forType: .png) != nil ? .png : (pasteboard.data(forType: .tiff) != nil ? .tiff : NSPasteboard.PasteboardType("public.jpeg"))
        guard let data = pasteboard.data(forType: type), data.count >= AutoCompressRules.minBytes(.image) else {
            done(nil)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = ConvertEngine.smallerPNG(data, halve: halve)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let result, NSPasteboard.general.changeCount == count,
                          AutoCompressRules.worthKeeping(before: data.count, after: result.count) else {
                        done(nil)
                        return
                    }
                    PasteboardImage.write(png: result, marker: marker)
                    done(Done(before: data.count, after: result.count, original: data, originalType: type, thumbnail: NSImage(data: result)))
                }
            }
        }
    }

    /// Puts the picture as it was copied back on the clipboard.
    static func restore(_ done: Done) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([done.originalType, marker], owner: nil)
        pasteboard.setData(done.original, forType: done.originalType)
        pasteboard.setData(Data(), forType: marker)
    }
}
