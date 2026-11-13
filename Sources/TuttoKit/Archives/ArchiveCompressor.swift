//
//  ArchiveCompressor.swift
//  TuttoKit — archives (ARC-3 "Compress")
//
//  Creates zip (deflate), 7z (LZMA2), tar.gz and tar.xz (pax) archives from files and folders.
//  Paths are stored relative to each item's parent ("Folder/sub/file.txt"), symlinks are stored
//  as symlinks (never followed), ".DS_Store" files are skipped, and zip names carry the UTF-8
//  flag. The archive is written to a hidden temporary file next to the output and renamed into
//  place under a unique name ("Archive 2.zip"), so an existing file is never replaced and a
//  cancelled or failed run leaves nothing behind.
//  Not preserved: extended attributes / resource forks (no __MACOSX members are written).
//

import CBridges
import Darwin
import Foundation

public enum ArchiveCompressionFormat: String, CaseIterable, Sendable {
    case zip, sevenZip, tarGzip, tarXz

    /// Extension without the leading dot ("tar.gz" for the tar formats).
    public var fileExtension: String {
        switch self {
        case .zip: return "zip"
        case .sevenZip: return "7z"
        case .tarGzip: return "tar.gz"
        case .tarXz: return "tar.xz"
        }
    }
}

public enum ArchiveCompressor {
    /// Suggested output next to the first item: "Name.zip" for one item, "Archive.zip" for several.
    public static func defaultOutputURL(for items: [URL], format: ArchiveCompressionFormat) -> URL {
        let directory = items.first?.deletingLastPathComponent() ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let stem = items.count == 1 ? (items[0].lastPathComponent.isEmpty ? "Archive" : items[0].lastPathComponent) : "Archive"
        return directory.appendingPathComponent("\(stem).\(format.fileExtension)")
    }

    /// Compresses `items` into `output` (or the next free "Name N" variant of it) and returns
    /// the URL actually written.
    @discardableResult
    public static func compress(_ items: [URL], to output: URL, format: ArchiveCompressionFormat,
                                progress: @escaping @Sendable (ArchiveProgress) -> Void = { _ in },
                                isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> URL {
        guard !items.isEmpty else { throw ArchiveError.cannotOpen("Nothing to compress") }
        let plan = try Plan(items: items)
        if isCancelled() { throw ArchiveError.cancelled }

        let directory = output.deletingLastPathComponent()
        let temp = directory.appendingPathComponent(".Tutto-\(UUID().uuidString).\(format.fileExtension)")
        defer { FileSystem.forceRemove(temp) }

        try write(plan, to: temp, format: format, progress: progress, isCancelled: isCancelled)
        if isCancelled() { throw ArchiveError.cancelled }
        let final = try FileSystem.moveExclusively(temp, toUniqueURLFor: output, isDirectory: false)
        progress(ArchiveProgress(fraction: 1, currentItem: "", bytesWritten: plan.totalBytes))
        return final
    }

    // MARK: - Planning

    struct PlannedEntry {
        enum Kind { case file, directory, symlink }
        var source: URL
        var archivePath: String
        var info: stat
        var kind: Kind
    }

    struct Plan {
        var entries: [PlannedEntry] = []
        var totalBytes: Int64 = 0

        /// `folder` ("" or "Docs/") puts the items inside a folder of the archive (adding to one).
        init(items: [URL], under folder: String = "") throws {
            var usedRoots = Set<String>()
            for item in items {
                guard let st = FileSystem.lstatInfo(item) else {
                    throw ArchiveError.cannotOpen("\(item.lastPathComponent) doesn't exist")
                }
                var root = item.lastPathComponent
                if root.isEmpty || root == "/" { root = "Archive" }
                if usedRoots.contains(root.lowercased()) {
                    var n = 2
                    while usedRoots.contains("\(root) \(n)".lowercased()) { n += 1 }
                    root = "\(root) \(n)"
                }
                usedRoots.insert(root.lowercased())
                try walk(item, archivePath: folder + root, info: st)
            }
        }

        private mutating func walk(_ url: URL, archivePath: String, info: stat) throws {
            if url.lastPathComponent == ".DS_Store" { return }
            switch info.st_mode & S_IFMT {
            case S_IFREG:
                entries.append(PlannedEntry(source: url, archivePath: archivePath, info: info, kind: .file))
                totalBytes += Int64(info.st_size)
            case S_IFLNK:
                entries.append(PlannedEntry(source: url, archivePath: archivePath, info: info, kind: .symlink))
            case S_IFDIR:
                entries.append(PlannedEntry(source: url, archivePath: archivePath, info: info, kind: .directory))
                let children: [String]
                do {
                    children = try FileManager.default.contentsOfDirectory(atPath: url.path)
                } catch {
                    throw ArchiveError.cannotOpen(error.localizedDescription)
                }
                for child in children.sorted() {
                    let childURL = url.appendingPathComponent(child)
                    guard let st = FileSystem.lstatInfo(childURL) else { continue }
                    try walk(childURL, archivePath: archivePath + "/" + child, info: st)
                }
            default:
                break   // sockets, FIFOs, devices
            }
        }
    }

    // MARK: - Writing

    private static func write(_ plan: Plan, to temp: URL, format: ArchiveCompressionFormat,
                              progress: @Sendable (ArchiveProgress) -> Void,
                              isCancelled: @Sendable () -> Bool) throws {
        guard let a = archive_write_new() else { throw ArchiveError.writeFailed("libarchive could not allocate a writer") }
        defer { archive_write_free(a) }
        func check(_ status: Int32) throws {
            if status < ARCHIVE_WARN {
                throw ArchiveError.writeFailed(archive_error_string(a).map { String(cString: $0) } ?? "unknown error")
            }
        }

        switch format {
        case .zip:
            try check(archive_write_set_format_zip(a))
            try check(archive_write_set_options(a, "zip:compression=deflate"))
            // Mark non-ASCII names as UTF-8 (in the C locale libarchive would otherwise write
            // the bytes without the flag and Windows tools would show them as CP437).
            try check(archive_write_set_options(a, "zip:hdrcharset=UTF-8"))
        case .sevenZip:
            try check(archive_write_set_format_7zip(a))
            try check(archive_write_set_options(a, "7zip:compression=lzma2"))
        case .tarGzip:
            try check(archive_write_set_format_pax_restricted(a))
            try check(archive_write_add_filter_gzip(a))
        case .tarXz:
            try check(archive_write_set_format_pax_restricted(a))
            try check(archive_write_add_filter_xz(a))
        }
        try check(temp.withUnsafeFileSystemRepresentation { archive_write_open_filename(a, $0) })

        let chunkSize = 1 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 16)
        defer { buffer.deallocate() }
        var bytesRead: Int64 = 0
        var lastReport: TimeInterval = 0
        func report(_ item: String, force: Bool = false) {
            let now = ProcessInfo.processInfo.systemUptime
            if !force && now - lastReport < 0.05 { return }
            lastReport = now
            let fraction = plan.totalBytes > 0 ? min(1, Double(bytesRead) / Double(plan.totalBytes)) : 0
            progress(ArchiveProgress(fraction: fraction, currentItem: item, bytesWritten: bytesRead))
        }
        report("", force: true)

        for planned in plan.entries {
            if isCancelled() { throw ArchiveError.cancelled }
            report(planned.archivePath)
            try writeEntry(planned, to: a, buffer: buffer, chunkSize: chunkSize, isCancelled: isCancelled) { n in
                bytesRead += Int64(n)
                report(planned.archivePath)
            }
        }
        try check(archive_write_close(a))
    }

    /// Writes one file, folder or symlink from disk into the open archive `a`.
    static func writeEntry(_ planned: PlannedEntry, to a: OpaquePointer, buffer: UnsafeMutableRawPointer, chunkSize: Int,
                           isCancelled: () -> Bool, wrote: (Int) -> Void) throws {
        func check(_ status: Int32) throws {
            if status < ARCHIVE_WARN {
                throw ArchiveError.writeFailed(archive_error_string(a).map { String(cString: $0) } ?? "unknown error")
            }
        }
        guard let entry = archive_entry_new() else { throw ArchiveError.writeFailed("Out of memory") }
        defer { archive_entry_free(entry) }
        var info = planned.info
        archive_entry_copy_stat(entry, &info)
        archive_entry_copy_pathname(entry, planned.archivePath)
        switch planned.kind {
        case .directory:
            archive_entry_set_size(entry, 0)
        case .symlink:
            guard let target = readLink(planned.source) else { return }
            archive_entry_copy_symlink(entry, target)
            archive_entry_set_size(entry, 0)
        case .file:
            break
        }
        try check(archive_write_header(a, entry))

        if planned.kind == .file && planned.info.st_size > 0 {
            let fd = planned.source.withUnsafeFileSystemRepresentation { open($0!, O_RDONLY | O_NOFOLLOW) }
            guard fd >= 0 else {
                throw ArchiveError.cannotOpen("\(planned.archivePath): \(String(cString: strerror(errno)))")
            }
            defer { close(fd) }
            var remaining = Int64(planned.info.st_size)
            while remaining > 0 {
                let n = read(fd, buffer, min(chunkSize, Int(remaining)))
                if n < 0 {
                    if errno == EINTR { continue }
                    throw ArchiveError.cannotOpen("\(planned.archivePath): \(String(cString: strerror(errno)))")
                }
                if n == 0 { break }   // file shrank; libarchive pads the entry
                if archive_write_data(a, buffer, n) < 0 {
                    throw ArchiveError.writeFailed(archive_error_string(a).map { String(cString: $0) } ?? "write error")
                }
                remaining -= Int64(n)
                wrote(n)
                if isCancelled() { throw ArchiveError.cancelled }
            }
        }
        try check(archive_write_finish_entry(a))
    }

    private static func readLink(_ url: URL) -> String? {
        url.withUnsafeFileSystemRepresentation { path -> String? in
            guard let path else { return nil }
            var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let n = readlink(path, &buf, buf.count - 1)
            guard n >= 0 else { return nil }
            buf[n] = 0
            return String(cString: buf)
        }
    }
}
