//
//  ArchiveExtractor.swift
//  TuttoKit — archives (ARC-1, ARC-2, ARC-6, ARC-7)
//
//  Extraction pipeline (see ArchiveTypes.swift for the full contract and support matrix):
//
//   1. Volumes: any member of a multi-volume set expands to the ordered set.
//   2. Pre-flight: RAR5 encryption sniffing; a header-only pre-pass for formats whose names may
//      be legacy-encoded and whose headers are cheap to walk (zip, RAR4, LHA, CAB) collects raw
//      names for one archive-wide encoding guess and catches password-protected zips early.
//      Streaming formats (tar.*, cpio, ar …) decode names entry by entry with the same detector.
//   3. Entries are written by archive_write_disk below a hidden temp folder in the destination.
//   4. The folder rule decides wrapping; results are renamed into place without overwriting.
//

import CBridges
import Darwin
import Foundation

public final class ArchiveExtractor: @unchecked Sendable {
    /// The URL the extractor was created with.
    public let url: URL
    /// The ordered volumes that will be read (just `[url]` for single-file archives).
    public let volumes: [URL]

    public init(url: URL) {
        self.url = url
        self.volumes = ArchiveVolumes.volumes(for: url)
    }

    // MARK: - Listing

    /// Lists every entry with its decoded, sanitised path. Reads headers only, except for
    /// compressed streams (tar.gz …) where reaching each header means decompressing.
    public func listEntries(options: ArchiveExtractionOptions = ArchiveExtractionOptions()) throws -> [ArchiveEntryInfo] {
        let rar5 = try rar5Preflight()
        let scan = try scanHeaders(password: options.password, fullScan: true)
        if scan.isRawWithoutCompression || (scan.format == ARCHIVE_FORMAT_EMPTY && scan.filterCount <= 1) {
            throw LibArchiveReader.notAnArchiveError(volumes[0])
        }
        if scan.format == ARCHIVE_FORMAT_RAW || scan.format == ARCHIVE_FORMAT_EMPTY {
            return [ArchiveEntryInfo(path: ArchiveNaming.singleFileOutputName(for: volumes[0]), isDirectory: false,
                                     size: scan.format == ARCHIVE_FORMAT_EMPTY ? 0 : nil, isEncrypted: false)]
        }
        let encoding = options.encodingOverride ?? FilenameEncoding.detect(scan.entries.map(\.rawPath))
        let encryptedRAR5 = Set(rar5?.encryptedFiles ?? [])
        var result: [ArchiveEntryInfo] = []
        for entry in scan.entries {
            let decoded = FilenameEncoding.decode(entry.rawPath, using: encoding)
            guard let path = EntryPath.sanitize(decoded), !EntryPath.isMacOSXMetadataFolder(path) else { continue }
            let encrypted = entry.isEncrypted || encryptedRAR5.contains(decoded)
            result.append(ArchiveEntryInfo(path: path, isDirectory: entry.isDirectory, isSymlink: entry.isSymlink,
                                           size: entry.isDirectory ? 0 : entry.size, isEncrypted: encrypted))
        }
        return result
    }

    // MARK: - Extraction

    public func extract(to destinationDirectory: URL,
                        options: ArchiveExtractionOptions = ArchiveExtractionOptions(),
                        progress: @escaping @Sendable (ArchiveProgress) -> Void = { _ in },
                        isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> ArchiveExtractionResult {
        guard FileSystem.isDirectory(destinationDirectory) || FileSystem.isDirectory(destinationDirectory.resolvingSymlinksInPath()) else {
            throw ArchiveError.writeFailed("The destination folder doesn't exist: \(destinationDirectory.path)")
        }
        if isCancelled() { throw ArchiveError.cancelled }
        _ = try rar5Preflight(throwOnEncryption: true)

        // Pre-pass: archive-wide encoding guess + early password check for indexed formats.
        let scan = try scanHeaders(password: options.password, fullScan: false)
        if scan.isRawWithoutCompression || (scan.format == ARCHIVE_FORMAT_EMPTY && scan.filterCount <= 1) {
            throw LibArchiveReader.notAnArchiveError(volumes[0])
        }
        var archiveEncoding: String.Encoding? = options.encodingOverride
        if scan.complete, archiveEncoding == nil {
            archiveEncoding = FilenameEncoding.detect(scan.entries.map(\.rawPath))
        }
        if scan.format == ARCHIVE_FORMAT_ZIP, scan.entries.contains(where: \.isEncrypted),
           (options.password ?? "").isEmpty {
            throw ArchiveError.passwordRequired
        }
        if isCancelled() { throw ArchiveError.cancelled }

        // Hidden working folder on the destination volume.
        let tempRoot = destinationDirectory.appendingPathComponent(".Tutto-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: false)
        } catch {
            throw ArchiveError.writeFailed(error.localizedDescription)
        }
        defer { FileSystem.forceRemove(tempRoot) }
        guard let rootPath = FileSystem.realPath(tempRoot) else {
            throw ArchiveError.writeFailed("Couldn't resolve \(tempRoot.path)")
        }

        var session = ExtractionSession(
            volumes: volumes, options: options, rootPath: rootPath, archiveEncoding: archiveEncoding,
            singleFileName: ArchiveNaming.singleFileOutputName(for: volumes[0]),
            progress: progress, isCancelled: isCancelled)
        try session.run()
        FileSystem.ensureOwnerAccess(below: tempRoot)

        if let quarantine = FileSystem.quarantine(of: volumes[0]) {
            FileSystem.applyQuarantine(quarantine, toTree: tempRoot)
        }

        let placement = try place(contentsOf: tempRoot, into: destinationDirectory, rule: options.folderRule,
                                  folderName: ArchiveNaming.baseName(of: volumes[0]))
        progress(ArchiveProgress(fraction: 1, currentItem: "", bytesWritten: session.bytesWritten))
        return ArchiveExtractionResult(items: placement.items, containingFolder: placement.folder,
                                       detectedEncoding: session.usedEncoding, entryCount: session.entryCount,
                                       bytesWritten: session.bytesWritten, skippedEntries: session.skipped)
    }

    // MARK: - Pre-flight

    @discardableResult
    private func rar5Preflight(throwOnEncryption: Bool = false) throws -> RAR5EncryptionSniffer.Report? {
        guard let report = RAR5EncryptionSniffer.inspect(volumes[0]) else { return nil }
        if report.headersEncrypted || (throwOnEncryption && report.isEncrypted) {
            throw ArchiveError.unsupportedEncryption(format: "RAR")
        }
        return report
    }

    struct ScannedEntry {
        var rawPath: Data
        var isDirectory: Bool
        var isSymlink: Bool
        var size: Int64?
        var isEncrypted: Bool
    }

    struct HeaderScan {
        var format: Int32
        var filterCount: Int32
        var entries: [ScannedEntry]
        /// False when the scan stopped after the first header (streaming formats).
        var complete: Bool
        var isRawWithoutCompression: Bool { format == ARCHIVE_FORMAT_RAW && filterCount <= 1 }
    }

    /// Formats whose names may be legacy-encoded and whose headers can be walked cheaply.
    static func benefitsFromPrepass(_ format: Int32) -> Bool {
        [ARCHIVE_FORMAT_ZIP, ARCHIVE_FORMAT_RAR, ARCHIVE_FORMAT_LHA, ARCHIVE_FORMAT_CAB].contains(format)
    }

    func scanHeaders(password: String?, fullScan: Bool) throws -> HeaderScan {
        let reader = try LibArchiveReader(volumes: volumes, password: password)
        var entries: [ScannedEntry] = []
        func record(_ e: OpaquePointer) {
            let v = EntryView(entry: e)
            entries.append(ScannedEntry(rawPath: v.rawPath, isDirectory: v.isDirectory, isSymlink: v.isSymlink,
                                        size: v.size, isEncrypted: v.isEncrypted))
        }
        guard let first = try reader.nextEntry() else {
            return HeaderScan(format: reader.formatCode, filterCount: reader.filterCount, entries: [], complete: true)
        }
        record(first)
        let format = reader.formatCode
        if !fullScan && !Self.benefitsFromPrepass(format) {
            return HeaderScan(format: format, filterCount: reader.filterCount, entries: entries, complete: false)
        }
        if format == ARCHIVE_FORMAT_RAW {
            return HeaderScan(format: format, filterCount: reader.filterCount, entries: entries, complete: true)
        }
        while let e = try reader.nextEntry() { record(e) }
        return HeaderScan(format: format, filterCount: reader.filterCount, entries: entries, complete: true)
    }

    // MARK: - Placement (folder rule)

    struct Placement {
        var items: [URL]
        var folder: URL?
    }

    private func place(contentsOf tempRoot: URL, into destination: URL, rule: ArchiveFolderRule,
                       folderName: String) throws -> Placement {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: tempRoot.path)) ?? [])
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let wrap: Bool
        switch rule {
        case .always: wrap = true
        case .never: wrap = false
        case .smart: wrap = names.count > 1
        }

        if wrap {
            let proposed = destination.appendingPathComponent(folderName, isDirectory: true)
            let folder = try FileSystem.moveExclusively(tempRoot, toUniqueURLFor: proposed, isDirectory: true)
            folder.withUnsafeFileSystemRepresentation { path in
                if let path { _ = chmod(path, 0o755) }
            }
            return Placement(items: [folder], folder: folder)
        }

        var moved: [(from: URL, to: URL)] = []
        do {
            for name in names {
                let source = tempRoot.appendingPathComponent(name)
                let isDirectory = FileSystem.isDirectory(source)
                let target = try FileSystem.moveExclusively(
                    source, toUniqueURLFor: destination.appendingPathComponent(name, isDirectory: isDirectory),
                    isDirectory: isDirectory)
                moved.append((source, target))
            }
        } catch {
            // Put back what already moved so the temp-folder cleanup removes it.
            for item in moved.reversed() {
                _ = item.to.withUnsafeFileSystemRepresentation { dst in
                    item.from.withUnsafeFileSystemRepresentation { src in renamex_np(dst!, src!, UInt32(RENAME_EXCL)) }
                }
            }
            throw error
        }
        return Placement(items: moved.map(\.to), folder: nil)
    }
}

// MARK: - One extraction run

/// Mutable state of a single extraction: one reader, one disk writer, counters.
private struct ExtractionSession {
    let volumes: [URL]
    let options: ArchiveExtractionOptions
    let rootPath: String
    let archiveEncoding: String.Encoding?
    let singleFileName: String
    let progress: @Sendable (ArchiveProgress) -> Void
    let isCancelled: @Sendable () -> Bool

    var usedEncoding: String.Encoding?
    var streamEncoding: String.Encoding?
    var entryCount = 0
    var bytesWritten: Int64 = 0
    var skipped: [String] = []

    private var totalInputBytes: Int64 = 0
    private var lastReport: TimeInterval = 0
    private var lastFraction: Double = 0

    init(volumes: [URL], options: ArchiveExtractionOptions, rootPath: String, archiveEncoding: String.Encoding?,
         singleFileName: String, progress: @escaping @Sendable (ArchiveProgress) -> Void,
         isCancelled: @escaping @Sendable () -> Bool) {
        self.volumes = volumes
        self.options = options
        self.rootPath = rootPath
        self.archiveEncoding = archiveEncoding
        self.singleFileName = singleFileName
        self.progress = progress
        self.isCancelled = isCancelled
        self.totalInputBytes = volumes.reduce(0) { sum, url in
            sum + Int64(FileSystem.lstatInfo(url.resolvingSymlinksInPath())?.st_size ?? 0)
        }
    }

    mutating func run() throws {
        let reader = try LibArchiveReader(volumes: volumes, password: options.password)
        guard let disk = archive_write_disk_new() else { throw ArchiveError.writeFailed("libarchive could not allocate a writer") }
        defer { archive_write_free(disk) }

        var flags = ARCHIVE_EXTRACT_SECURE_SYMLINKS | ARCHIVE_EXTRACT_SECURE_NODOTDOT | ARCHIVE_EXTRACT_PERM
            | ARCHIVE_EXTRACT_XATTR | ARCHIVE_EXTRACT_MAC_METADATA
        if options.keepModificationDates { flags |= ARCHIVE_EXTRACT_TIME }
        archive_write_disk_set_options(disk, Int32(flags))

        report(item: "", force: true, reader: reader)
        while let entry = try reader.nextEntry() {
            if isCancelled() { throw ArchiveError.cancelled }
            try extractEntry(entry, reader: reader, disk: disk)
        }

        // A compressed empty file ("empty.txt.gz") has no header at all.
        if reader.formatCode == ARCHIVE_FORMAT_EMPTY && reader.filterCount > 1 && entryCount == 0 {
            let path = rootPath + "/" + singleFileName
            guard FileManager.default.createFile(atPath: path, contents: Data()) else {
                throw ArchiveError.writeFailed("Couldn't create \(singleFileName)")
            }
            entryCount = 1
        }

        if archive_write_close(disk) == ARCHIVE_FATAL {
            throw ArchiveError.writeFailed(Self.message(disk))
        }
    }

    private mutating func extractEntry(_ e: OpaquePointer, reader: LibArchiveReader, disk: OpaquePointer) throws {
        let view = EntryView(entry: e)
        let isRaw = reader.formatCode == ARCHIVE_FORMAT_RAW
        if isRaw && reader.filterCount <= 1 { throw LibArchiveReader.notAnArchiveError(volumes[0]) }

        // 1. Name: decode, sanitise.
        let decoded: String
        var nameEncoding: String.Encoding? = nil
        if isRaw {
            decoded = singleFileName
        } else {
            let raw = view.rawPath
            nameEncoding = encoding(for: raw)
            decoded = FilenameEncoding.decode(raw, using: nameEncoding)
        }
        guard let relative = EntryPath.sanitize(decoded) else {
            if !view.isDirectory { skipped.append(decoded) }   // "./" roots are just ignored
            return
        }
        if EntryPath.isMacOSXMetadataFolder(relative) { return }

        // 2. Encryption.
        if view.isEncrypted {
            if reader.formatCode == ARCHIVE_FORMAT_ZIP {
                if !reader.passwordProvided { throw ArchiveError.passwordRequired }
            } else {
                throw ArchiveError.unsupportedEncryption(format: reader.formatFamily)
            }
        }

        // 3. Retarget below the temp root (absolute, symlink-free prefix). Paths at or beyond
        //    PATH_MAX are refused: libarchive would chdir() into them, which is process-wide.
        let target = rootPath + "/" + relative
        if target.utf8.count >= Int(PATH_MAX) {
            skipped.append(relative)
            return
        }
        archive_entry_copy_pathname(e, target)
        if let rawLink = view.rawHardlink, !rawLink.isEmpty {
            let linkName = FilenameEncoding.decode(rawLink, using: nameEncoding ?? encoding(for: rawLink))
            guard let linkRelative = EntryPath.sanitize(linkName), isSafeHardlinkTarget(linkRelative) else {
                skipped.append(relative)
                return
            }
            archive_entry_copy_hardlink(e, rootPath + "/" + linkRelative)
        }
        if view.isSymlink, let target = archive_entry_symlink(e) {
            let rawTarget = Data(bytes: target, count: strlen(target))
            if !FilenameEncoding.isValidUTF8(rawTarget) {
                let fixed = FilenameEncoding.decode(rawTarget, using: nameEncoding ?? encoding(for: rawTarget))
                archive_entry_copy_symlink(e, fixed)
            }
        }

        report(item: relative, force: false, reader: reader)

        // 4. Header → disk.
        let headerStatus = archive_write_header(disk, e)
        if headerStatus == ARCHIVE_FATAL {
            throw ArchiveError.writeFailed(Self.message(disk))
        }
        if headerStatus < ARCHIVE_WARN {
            // e.g. "Cannot extract through symlink": refuse this entry, keep going.
            skipped.append(relative)
            return
        }

        // 5. Data (regular files only; RAR5 errors when asked for directory data).
        if view.isRegularFile {
            var buffer: UnsafeRawPointer?
            var size = 0
            var offset: Int64 = 0
            while true {
                let r = archive_read_data_block(reader.handle, &buffer, &size, &offset)
                if r == ARCHIVE_EOF { break }
                if r < ARCHIVE_WARN { throw reader.mapError(encryptedEntry: view.isEncrypted) }
                if r == ARCHIVE_WARN {
                    // Defensive: should a reader report a checksum mismatch only as a warning,
                    // never hand out damaged data (or garbage from a ZipCrypto false positive).
                    let message = reader.errorString.lowercased()
                    if message.contains("crc") || message.contains("checksum") {
                        throw reader.mapError(encryptedEntry: view.isEncrypted)
                    }
                }
                if size > 0, let buffer {
                    let written = archive_write_data_block(disk, buffer, size, offset)
                    if written < 0 {
                        throw ArchiveError.writeFailed(Self.message(disk))
                    }
                    bytesWritten += Int64(size)
                }
                if isCancelled() { throw ArchiveError.cancelled }
                report(item: relative, force: false, reader: reader)
            }
        }

        let finishStatus = archive_write_finish_entry(disk)
        if finishStatus == ARCHIVE_FATAL {
            throw ArchiveError.writeFailed(Self.message(disk))
        }
        entryCount += 1
    }

    /// Hard links must point at something already extracted inside the root that isn't a
    /// symlink, and whose parent really resolves inside the root.
    private func isSafeHardlinkTarget(_ relative: String) -> Bool {
        let target = rootPath + "/" + relative
        let url = URL(fileURLWithPath: target)
        guard let st = FileSystem.lstatInfo(url), (st.st_mode & S_IFMT) != S_IFLNK else { return false }
        guard let parent = FileSystem.realPath(url.deletingLastPathComponent()) else { return false }
        return parent == rootPath || parent.hasPrefix(rootPath + "/")
    }

    /// Encoding for one raw name: nil for UTF-8, the archive-wide guess when there is one,
    /// otherwise a sticky per-stream guess.
    private mutating func encoding(for raw: Data) -> String.Encoding? {
        if FilenameEncoding.isValidUTF8(raw) { return nil }
        let chosen: String.Encoding?
        if let archiveEncoding {
            chosen = archiveEncoding
        } else if let streamEncoding, FilenameEncoding.strictDecode(raw, streamEncoding) != nil {
            chosen = streamEncoding
        } else {
            streamEncoding = FilenameEncoding.detect([raw])
            chosen = streamEncoding
        }
        if usedEncoding == nil { usedEncoding = chosen }
        return chosen
    }

    private mutating func report(item: String, force: Bool, reader: LibArchiveReader) {
        let now = ProcessInfo.processInfo.systemUptime
        if !force && now - lastReport < 0.05 { return }   // ≤ 20 callbacks per second
        lastReport = now
        var fraction = 0.0
        if totalInputBytes > 0 {
            fraction = min(1, max(0, Double(reader.compressedBytesRead) / Double(totalInputBytes)))
        }
        fraction = max(fraction, lastFraction)
        lastFraction = fraction
        progress(ArchiveProgress(fraction: fraction, currentItem: item, bytesWritten: bytesWritten))
    }

    private static func message(_ a: OpaquePointer) -> String {
        archive_error_string(a).map { String(cString: $0) } ?? "unknown error"
    }
}
