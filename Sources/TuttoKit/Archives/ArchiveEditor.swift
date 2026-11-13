//
//  ArchiveEditor.swift
//  TuttoKit — archives
//
//  Adding files to an archive and taking them out, without unpacking it to disk. The archive is
//  read once and written again next to it: every entry that stays is copied across, removed
//  ones are left out, new files are written in (one that has the same path as an entry replaces
//  it), in the same format and compression (zip stays zip, tar.gz stays tar.gz). The new archive
//  then takes the old one's place in one swap; the old one goes to the Trash, so a change can be
//  undone from there.
//
//  Editable: zip, 7z and tar (plain, .gz, .bz2, .xz), in one file. Read only: RAR (macOS has no
//  RAR writer, and RAR's licence allows none), ISO, CAB and the rest, split archives, and
//  archives with encrypted entries (their contents can't be copied without the password).
//

import CBridges
import Darwin
import Foundation

public struct ArchiveAddition: Sendable, Equatable {
    /// A file or folder on disk.
    public var source: URL
    /// The archive folder it goes into ("" for the top, else ending in "/").
    public var folder: String

    public init(source: URL, folder: String = "") {
        self.source = source
        self.folder = folder.isEmpty || folder.hasSuffix("/") ? folder : folder + "/"
    }
}

public enum ArchiveEditor {
    public enum Kind: Sendable, Equatable {
        case zip, sevenZip
        /// tar, with the compression filters outermost first ([] for a plain .tar).
        case tar([Int32])
    }

    /// Why an archive can't be changed, in a sentence; nil when it can.
    public static func readOnlyReason(_ url: URL) -> String? {
        switch inspect(url) {
        case .success: return nil
        case .failure(let reason): return reason.message
        }
    }

    /// Whether `url` can be changed, and how it's written back.
    public static func kind(of url: URL) -> Kind? {
        if case .success(let kind) = inspect(url) { return kind }
        return nil
    }

    struct Refusal: Error {
        var message: String
    }

    static func inspect(_ url: URL) -> Result<Kind, Refusal> {
        guard ArchiveVolumes.volumes(for: url).count == 1 else {
            return .failure(Refusal(message: "Split archives can be read but not changed."))
        }
        guard let reader = try? LibArchiveReader(volumes: [url], password: nil) else {
            return .failure(Refusal(message: "It couldn't be opened."))
        }
        var first = true
        var encrypted = false
        do {
            while let entry = try reader.nextEntry() {
                if EntryView(entry: entry).isEncrypted { encrypted = true; break }
                if first {
                    first = false
                    // Only the zip and 7z readers know about encryption up front; tar has none.
                    if reader.formatCode != ARCHIVE_FORMAT_ZIP && reader.formatCode != ARCHIVE_FORMAT_7ZIP { break }
                }
            }
        } catch {
            return .failure(Refusal(message: "It couldn't be read to the end."))
        }
        if encrypted { return .failure(Refusal(message: "Archives with encrypted files can be read but not changed.")) }
        switch reader.formatCode {
        case ARCHIVE_FORMAT_ZIP:
            return .success(.zip)
        case ARCHIVE_FORMAT_7ZIP:
            return .success(.sevenZip)
        case ARCHIVE_FORMAT_TAR:
            let filters = reader.filterCodes
            let writable: Set<Int32> = [ARCHIVE_FILTER_GZIP, ARCHIVE_FILTER_BZIP2, ARCHIVE_FILTER_XZ]
            guard filters.count <= 1, filters.allSatisfy(writable.contains) else {
                return .failure(Refusal(message: "This kind of compressed tar can be read but not changed."))
            }
            return .success(.tar(filters))
        case ARCHIVE_FORMAT_RAR, ARCHIVE_FORMAT_RAR_V5:
            return .failure(Refusal(message: "RAR archives can be read and extracted but not changed: macOS has no RAR writer."))
        default:
            return .failure(Refusal(message: "\(reader.formatFamily) archives can be read and extracted but not changed."))
        }
    }

    /// Takes `removing` (entry paths; a folder takes everything in it) out of the archive at `url`
    /// and puts `adding` in. Returns the URL the old archive went to in the Trash (nil if it
    /// couldn't be trashed and was deleted instead).
    @discardableResult
    public static func update(_ url: URL, removing: [String] = [], adding: [ArchiveAddition] = [],
                              trashingOld: Bool = true,
                              progress: @escaping @Sendable (ArchiveProgress) -> Void = { _ in },
                              isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> URL? {
        let kind: Kind
        switch inspect(url) {
        case .success(let k): kind = k
        case .failure(let refusal): throw ArchiveError.unsupportedFormat(refusal.message)
        }
        guard !removing.isEmpty || !adding.isEmpty else { return nil }

        // The new files, grouped by the folder they go into.
        var plans: [ArchiveCompressor.Plan] = []
        for (folder, group) in Dictionary(grouping: adding, by: \.folder) {
            plans.append(try ArchiveCompressor.Plan(items: group.map(\.source), under: folder))
        }
        let added = Set(plans.flatMap { $0.entries.map(\.archivePath) })
        let removal = ArchiveSelection(paths: removing)
        let addedBytes = plans.reduce(Int64(0)) { $0 + $1.totalBytes }

        // Names as the archive's listing shows them (legacy encodings decoded the same way).
        let encoding: String.Encoding?
        do {
            let scan = try ArchiveExtractor(url: url).scanHeaders(password: nil, fullScan: true)
            encoding = FilenameEncoding.detect(scan.entries.map(\.rawPath))
        }

        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".Tutto-\(UUID().uuidString)-\(url.lastPathComponent)")
        defer { FileSystem.forceRemove(temp) }

        let reader = try LibArchiveReader(volumes: [url], password: nil)
        guard let w = archive_write_new() else { throw ArchiveError.writeFailed("libarchive could not allocate a writer") }
        defer { archive_write_free(w) }
        func check(_ status: Int32) throws {
            if status < ARCHIVE_WARN {
                throw ArchiveError.writeFailed(archive_error_string(w).map { String(cString: $0) } ?? "unknown error")
            }
        }
        switch kind {
        case .zip:
            try check(archive_write_set_format_zip(w))
            try check(archive_write_set_options(w, "zip:compression=deflate"))
            try check(archive_write_set_options(w, "zip:hdrcharset=UTF-8"))
        case .sevenZip:
            try check(archive_write_set_format_7zip(w))
            try check(archive_write_set_options(w, "7zip:compression=lzma2"))
        case .tar(let filters):
            try check(archive_write_set_format_pax_restricted(w))
            for filter in filters.reversed() {
                switch filter {
                case ARCHIVE_FILTER_GZIP: try check(archive_write_add_filter_gzip(w))
                case ARCHIVE_FILTER_BZIP2: try check(archive_write_add_filter_bzip2(w))
                case ARCHIVE_FILTER_XZ: try check(archive_write_add_filter_xz(w))
                default: break
                }
            }
        }
        try check(temp.withUnsafeFileSystemRepresentation { archive_write_open_filename(w, $0) })

        let total = max(Int64(FileSystem.lstatInfo(url)?.st_size ?? 0), 1) + addedBytes
        var done: Int64 = 0
        var lastReport: TimeInterval = 0
        func report(_ item: String) {
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastReport >= 0.05 else { return }
            lastReport = now
            progress(ArchiveProgress(fraction: min(1, Double(done) / Double(total)), currentItem: item, bytesWritten: done))
        }

        // 1. What stays, copied across.
        while let entry = try reader.nextEntry() {
            if isCancelled() { throw ArchiveError.cancelled }
            let view = EntryView(entry: entry)
            let decoded = FilenameEncoding.decode(view.rawPath, using: FilenameEncoding.isValidUTF8(view.rawPath) ? nil : encoding)
            let path = EntryPath.sanitize(decoded)
            if let path {
                let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
                // Removed, or replaced by a new file (or folder) of the same path.
                if removal.includes(trimmed) || added.contains(trimmed) { continue }
            }
            archive_entry_set_pathname_utf8(entry, decoded)
            try check(archive_write_header(w, entry))
            if view.isRegularFile {
                var buffer: UnsafeRawPointer?
                var size = 0
                var offset: Int64 = 0
                while true {
                    let r = archive_read_data_block(reader.handle, &buffer, &size, &offset)
                    if r == ARCHIVE_EOF { break }
                    if r < ARCHIVE_WARN { throw reader.mapError(encryptedEntry: view.isEncrypted) }
                    if size > 0, let buffer {
                        if archive_write_data(w, buffer, size) < 0 {
                            throw ArchiveError.writeFailed(archive_error_string(w).map { String(cString: $0) } ?? "write error")
                        }
                    }
                    if isCancelled() { throw ArchiveError.cancelled }
                }
            }
            try check(archive_write_finish_entry(w))
            done = reader.compressedBytesRead
            report(path ?? decoded)
        }
        done = max(done, Int64(FileSystem.lstatInfo(url)?.st_size ?? 0))

        // 2. The new files.
        let chunkSize = 1 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 16)
        defer { buffer.deallocate() }
        for plan in plans {
            for planned in plan.entries {
                if isCancelled() { throw ArchiveError.cancelled }
                try ArchiveCompressor.writeEntry(planned, to: w, buffer: buffer, chunkSize: chunkSize, isCancelled: isCancelled) { n in
                    done += Int64(n)
                    report(planned.archivePath)
                }
            }
        }
        try check(archive_write_close(w))
        if isCancelled() { throw ArchiveError.cancelled }

        // 3. The new archive takes the old one's place; the old one goes to the Trash.
        let backupName = ".Tutto-before-\(UUID().uuidString)-\(url.lastPathComponent)"
        let backup = url.deletingLastPathComponent().appendingPathComponent(backupName)
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp, backupItemName: backupName,
                                                      options: [.withoutDeletingBackupItem])
        } catch {
            throw ArchiveError.writeFailed(error.localizedDescription)
        }
        var trashed: NSURL?
        if !trashingOld {
            FileSystem.forceRemove(backup)
        } else if FileSystem.itemExists(backup) {
            do {
                try FileManager.default.trashItem(at: backup, resultingItemURL: &trashed)
                if let trashed = trashed as URL? {
                    // In the Trash under the archive's own name, so it's recognisable there.
                    let named = ArchiveNaming.uniqueURL(for: trashed.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent))
                    if (try? FileManager.default.moveItem(at: trashed, to: named)) != nil { return named }
                    return trashed
                }
            } catch {
                FileSystem.forceRemove(backup)
            }
        }
        progress(ArchiveProgress(fraction: 1, currentItem: "", bytesWritten: done))
        return nil
    }
}
