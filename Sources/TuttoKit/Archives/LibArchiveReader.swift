//
//  LibArchiveReader.swift
//  TuttoKit — archives
//
//  Owns one libarchive read handle (never shared between threads) configured the same way for
//  listing and extraction, and maps libarchive's errors onto ArchiveError.
//

import CBridges
import Foundation

public enum ArchiveSystemInfo {
    /// e.g. "libarchive 3.7.4 zlib/1.2.12 liblzma/5.4.3 bz2lib/1.0.8" (no zstd/lz4 on macOS 26).
    public static var libarchiveVersion: String { String(cString: archive_version_details()) }
}

final class LibArchiveReader {
    let handle: OpaquePointer
    let volumes: [URL]
    private(set) var passwordProvided = false

    /// Opens all `volumes` as one stream. Formats are enabled individually (everything
    /// format_all offers except mtree) plus the raw format for single-file compressors.
    init(volumes: [URL], password: String?, blockSize: Int = 64 * 1024) throws {
        guard let a = archive_read_new() else { throw ArchiveError.cannotOpen("libarchive could not allocate a reader") }
        handle = a
        self.volumes = volumes

        archive_read_support_filter_gzip(a)
        archive_read_support_filter_bzip2(a)
        archive_read_support_filter_xz(a)
        archive_read_support_filter_lzma(a)
        archive_read_support_filter_lzip(a)
        archive_read_support_filter_compress(a)
        archive_read_support_filter_uu(a)
        archive_read_support_filter_rpm(a)

        archive_read_support_format_7zip(a)
        archive_read_support_format_ar(a)
        archive_read_support_format_cab(a)
        archive_read_support_format_cpio(a)
        archive_read_support_format_empty(a)
        archive_read_support_format_iso9660(a)
        archive_read_support_format_lha(a)
        archive_read_support_format_rar(a)
        archive_read_support_format_rar5(a)
        archive_read_support_format_tar(a)
        archive_read_support_format_warc(a)
        archive_read_support_format_xar(a)
        archive_read_support_format_zip(a)
        archive_read_support_format_raw(a)

        // Fold AppleDouble members (zip __MACOSX/._x, tar ._x before x) into their files as
        // metadata; both are already the default in Apple's build, set here to be explicit.
        _ = archive_read_set_options(a, "zip:mac-ext")
        _ = archive_read_set_options(a, "tar:mac-ext")

        if let password, !password.isEmpty {
            archive_read_add_passphrase(a, password)
            passwordProvided = true
        }

        let status: Int32
        if volumes.count == 1 {
            status = volumes[0].withUnsafeFileSystemRepresentation { path in
                archive_read_open_filename(a, path, blockSize)
            }
        } else {
            var cPaths: [UnsafeMutablePointer<CChar>?] = volumes.map { url in
                url.withUnsafeFileSystemRepresentation { $0.flatMap { strdup($0) } }
            }
            cPaths.append(nil)
            defer { cPaths.forEach { free($0) } }
            status = cPaths.withUnsafeMutableBufferPointer { buffer -> Int32 in
                buffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buffer.count) {
                    archive_read_open_filenames(a, $0, blockSize)
                }
            }
        }
        if status != ARCHIVE_OK {
            // All stored properties are set, so deinit runs and frees the handle.
            throw Self.openError(a, volumes: volumes)
        }
    }

    deinit {
        archive_read_free(handle)
    }

    var errorString: String {
        archive_error_string(handle).map { String(cString: $0) } ?? "unknown error"
    }

    var formatCode: Int32 { archive_format(handle) & ARCHIVE_FORMAT_BASE_MASK }

    var filterCount: Int32 { archive_filter_count(handle) }

    var compressedBytesRead: Int64 { archive_filter_bytes(handle, -1) }

    /// Human-readable format family for messages ("ZIP", "RAR", "7-Zip" …).
    var formatFamily: String { Self.family(of: formatCode) }

    static func family(of code: Int32) -> String {
        switch code {
        case ARCHIVE_FORMAT_ZIP: return "ZIP"
        case ARCHIVE_FORMAT_RAR, ARCHIVE_FORMAT_RAR_V5: return "RAR"
        case ARCHIVE_FORMAT_7ZIP: return "7-Zip"
        case ARCHIVE_FORMAT_TAR: return "tar"
        case ARCHIVE_FORMAT_CPIO: return "cpio"
        case ARCHIVE_FORMAT_ISO9660: return "ISO"
        case ARCHIVE_FORMAT_XAR: return "xar"
        case ARCHIVE_FORMAT_CAB: return "CAB"
        case ARCHIVE_FORMAT_LHA: return "LHA"
        case ARCHIVE_FORMAT_AR: return "ar"
        case ARCHIVE_FORMAT_WARC: return "WARC"
        case ARCHIVE_FORMAT_RAW: return "compressed file"
        default: return "archive"
        }
    }

    /// Next header; nil at the end. Warnings are tolerated, failures mapped.
    func nextEntry() throws -> OpaquePointer? {
        var entry: OpaquePointer?
        for _ in 0..<64 {
            let r = archive_read_next_header(handle, &entry)
            switch r {
            case ARCHIVE_OK, ARCHIVE_WARN:
                return entry
            case ARCHIVE_EOF:
                return nil
            case ARCHIVE_RETRY:
                continue
            default:
                throw mapError(encryptedEntry: false)
            }
        }
        throw ArchiveError.corrupt(errorString)
    }

    /// Maps the current libarchive error to ArchiveError.
    func mapError(encryptedEntry: Bool) -> ArchiveError {
        Self.classify(errorString, format: formatCode, encryptedEntry: encryptedEntry, passwordProvided: passwordProvided)
    }

    static func classify(_ message: String, format: Int32, encryptedEntry: Bool, passwordProvided: Bool,
                         fallbackFamily: String? = nil) -> ArchiveError {
        let lower = message.lowercased()
        if lower.contains("incorrect passphrase") { return .wrongPassword }
        if lower.contains("passphrase") {
            return passwordProvided ? .wrongPassword : .passwordRequired
        }
        if lower.contains("encrypt") {
            let family = family(of: format)
            return .unsupportedEncryption(format: family == "archive" ? (fallbackFamily ?? "archive") : family)
        }
        if encryptedEntry && format == ARCHIVE_FORMAT_ZIP {
            // ZipCrypto's 1-byte password check lets ~1/256 wrong passwords through; the
            // garbage then fails to inflate or fails the CRC.
            return passwordProvided ? .wrongPassword : .passwordRequired
        }
        if lower.contains("unrecognized archive format") { return .notAnArchive }
        if lower.contains("unsupported") || lower.contains("not supported") || lower.contains("unable to run program") {
            return .unsupportedFormat(message)
        }
        return .corrupt(message)
    }

    private static func openError(_ a: OpaquePointer, volumes: [URL]) -> ArchiveError {
        let message = archive_error_string(a).map { String(cString: $0) } ?? "unknown error"
        let errnoValue = archive_errno(a)
        let lower = message.lowercased()
        if errnoValue == ENOENT || errnoValue == EACCES || errnoValue == EPERM || errnoValue == EISDIR
            || lower.contains("failed to open") || lower.contains("no such file") {
            return .cannotOpen(message)
        }
        if lower.contains("unrecognized archive format") {
            if let compressor = unsupportedCompressor(volumes.first) { return .unsupportedFormat(compressor) }
            return .notAnArchive
        }
        let format = archive_format(a) & ARCHIVE_FORMAT_BASE_MASK
        let ext = volumes.first.map { ArchiveNaming.formatFamily(forExtensionOf: $0) }
        return classify(message, format: format, encryptedEntry: false, passwordProvided: false, fallbackFamily: ext)
    }

    /// `.notAnArchive`, or `.unsupportedFormat` when the bytes are a known compressor this
    /// libarchive build can't decode (the raw format otherwise accepts them as plain data).
    static func notAnArchiveError(_ url: URL) -> ArchiveError {
        unsupportedCompressor(url).map(ArchiveError.unsupportedFormat) ?? .notAnArchive
    }

    /// Recognises compressors this libarchive build can't decode (only via external programs,
    /// which TuttoKit doesn't enable) so the user gets a precise message.
    static func unsupportedCompressor(_ url: URL?) -> String? {
        guard let url, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 6), head.count >= 4 else { return nil }
        let b = [UInt8](head)
        if b.starts(with: [0x28, 0xB5, 0x2F, 0xFD]) { return "Zstandard (.zst) compression isn't available in macOS's libarchive" }
        if b.starts(with: [0x04, 0x22, 0x4D, 0x18]) { return "LZ4 compression isn't available in macOS's libarchive" }
        if b.starts(with: [0x89, 0x4C, 0x5A, 0x4F]) { return "lzop compression isn't available in macOS's libarchive" }
        if b.starts(with: Array("LRZI".utf8)) { return "lrzip compression isn't available in macOS's libarchive" }
        return nil
    }
}

/// Typed accessors for an archive_entry owned by a reader.
struct EntryView {
    let entry: OpaquePointer

    /// The name bytes exactly as libarchive returns them (UTF-8 for Unicode formats, raw legacy
    /// bytes otherwise). Falls back to the UTF-8 accessor when the multibyte form is missing.
    var rawPath: Data {
        if let p = archive_entry_pathname(entry) { return Data(bytes: p, count: strlen(p)) }
        if let p = archive_entry_pathname_utf8(entry) { return Data(bytes: p, count: strlen(p)) }
        return Data()
    }

    var rawHardlink: Data? {
        if let p = archive_entry_hardlink(entry) { return Data(bytes: p, count: strlen(p)) }
        if let p = archive_entry_hardlink_utf8(entry) { return Data(bytes: p, count: strlen(p)) }
        return nil
    }

    var fileType: mode_t { archive_entry_filetype(entry) & AE_IFMT }
    var isDirectory: Bool { fileType == AE_IFDIR }
    var isRegularFile: Bool { fileType == AE_IFREG }
    var isSymlink: Bool { fileType == AE_IFLNK }
    var size: Int64? { archive_entry_size_is_set(entry) != 0 ? archive_entry_size(entry) : nil }
    var isEncrypted: Bool { archive_entry_is_encrypted(entry) != 0 }
}
