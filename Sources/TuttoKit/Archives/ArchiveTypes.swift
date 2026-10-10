//
//  ArchiveTypes.swift
//  TuttoKit — archives (requirements ARC-1 … ARC-7)
//
//  Public API of the archive backend that replaces The Unarchiver 4.3.9. Everything here is
//  Foundation-only, uses the libarchive that ships with macOS (/usr/lib/libarchive.2.dylib,
//  libarchive 3.7.4 on macOS 26) and keeps no global state: every call creates and frees its
//  own libarchive objects, so all entry points are safe to call from any background thread.
//
//  API overview
//  ------------
//    ArchiveExtractor(url:)                 any volume of a set may be passed (part2 → whole set)
//      .listEntries(options:)               decoded names, directory flag, size, encryption flag
//      .extract(to:options:progress:isCancelled:) → ArchiveExtractionResult
//    ArchiveCompressor.compress(_:to:format:progress:isCancelled:) → URL actually written
//    ArchiveFormats.isLikelyArchive(_:) / .extractableExtensions      (by name only, no I/O)
//    ArchiveVolumes.volumes(for:) / .firstVolume(for:)                (multi-volume sets)
//    ArchiveNaming.baseName(of:) / .uniqueURL(for:)                   ("Name 2", "Name 3" …)
//    FilenameEncoding.detect(_:) / .decode(_:using:)                  (garbled-name repair)
//    ArchiveSystemInfo.libarchiveVersion
//
//  Extraction contract
//  -------------------
//  • Entries are written by archive_write_disk into a hidden ".Tutto-<UUID>" folder created inside
//    the destination (same volume), with SECURE_SYMLINKS | SECURE_NODOTDOT | PERM | XATTR |
//    MAC_METADATA (+ TIME when keepModificationDates), never OWNER. Every entry path is
//    sanitised first (leading "/" stripped, "." and ".." dropped, empty names refused) and
//    rewritten to an absolute path under the realpath of that folder (SECURE_SYMLINKS rejects
//    symlinks anywhere in the path, so /var → /private/var must be resolved first). Hard-link
//    targets are sanitised the same way and must already exist inside the folder and not be
//    symlinks. Refused entries (unusable names, writing through a symlink, escaping hard links,
//    paths ≥ PATH_MAX where libarchive would chdir() process-wide) are skipped and listed in
//    `ArchiveExtractionResult.skippedEntries`; the rest of the archive still extracts.
//  • Afterwards every extracted folder gets u+rwx and every file u+rw (other bits preserved),
//    like The Unarchiver — otherwise 0555 folders from ISOs can't be moved into place or trashed.
//  • The folder rule is applied and results are moved into place with renamex_np(RENAME_EXCL)
//    under Finder-style unique names, so nothing in the destination is ever overwritten.
//    The temporary folder is removed on success, failure and cancellation.
//  • A com.apple.quarantine attribute on the archive is copied to everything extracted
//    (what Archive Utility and The Unarchiver do, so Gatekeeper still sees downloaded apps).
//
//  Verified support matrix on this Mac (macOS 26.5.2, Apple M5; libarchive 3.7.4 "zlib/1.2.12
//  liblzma/5.4.3 bz2lib/1.0.8"; every row is exercised by ArchiveFormatTests/ArchiveExtractorTests)
//  ---------------------------------------------------------------------------------------------
//    zip       store, deflate; ZipCrypto, WinZip AES-128 and AES-256 decrypt (CommonCrypto);
//              byte splits (.zip.001 …) and Info-ZIP spanned sets (.z01 … .zip, streaming reader)
//    7z        copy, deflate, bzip2, LZMA, LZMA2, PPMd; byte splits (.7z.001 …)
//    RAR5      stored, multi-volume .partN.rar (crafted fixtures — no rar tool on this Mac)
//    RAR4      stored, legacy OEM-encoded names (crafted fixtures)
//    tar       pax, ustar, gnutar; .gz/.tgz, .bz2, .xz, .lzma, .lz (lzip), .Z, uuencoded
//    cpio      odc, newc, .cpgz
//    other     ISO 9660 (Rock Ridge), xar (.xar/.pkg), ar (BSD and GNU, so .deb), WARC,
//              CAB (uncompressed folders), LHA/LZH (-lh0-)
//    single    .gz, .bz2, .xz, .lzma, .lz, .Z via the raw format → "name.txt.gz" gives "name.txt"
//    AppleDouble  zip __MACOSX/._x members and tar "._x" members become xattrs/metadata of x
//    Not supported
//      • encrypted RAR4/RAR5 (data or headers) and encrypted 7z (data or headers): libarchive
//        can't decrypt them → .unsupportedEncryption(format: "RAR" / "7-Zip"), even with a password
//      • zstd and lz4 (.tar.zst, .tar.lz4): this libarchive is built without them and would only
//        shell out to `zstd`/`lz4` binaries; TuttoKit doesn't enable program filters, and reports
//        .unsupportedFormat. Same for lzop, lrzip, grzip. Zip entries using zstd fail per entry.
//      • mtree is disabled on purpose (an mtree file can reference arbitrary local files);
//        shar cannot be read by libarchive.
//    RAR5 caveat: libarchive 3.7.4 neither decrypts nor *flags* encrypted RAR5 entries
//      (archive_entry_is_encrypted == 0; it would write ciphertext out as the file), so
//      RAR5EncryptionSniffer walks the RAR5 block headers first and refuses such archives.
//    RAR4 caveat: encrypted RAR4 entries are flagged but read_data still returns the raw
//      (encrypted) bytes, so the extractor refuses any flagged entry outside zip.
//
//  How libarchive hands us file names (verified in C and UTF-8 locales alike)
//  --------------------------------------------------------------------------
//  • Formats that store Unicode (7z, RAR5, UTF-8-flagged zips, zips with the Info-ZIP Unicode
//    Path extra field 0x7075, pax, xar, ISO Rock Ridge/Joliet) come back from
//    archive_entry_pathname as UTF-8 bytes; archive_entry_pathname_utf8 returns the same bytes.
//  • Zip/LHA/CAB/RAR4 names without a Unicode marker come back from archive_entry_pathname as the
//    raw bytes stored in the archive, and archive_entry_pathname_utf8 returns NULL.
//  • libarchive rewrites every 0x5C byte ("\") in those raw names to "/". That turns Windows
//    separators into real folders (wanted) but also breaks Shift-JIS/Big5/GBK characters whose
//    second byte is 0x5C (表 = 95 5C, ソ = 83 5C …); FilenameEncoding undoes it before decoding.
//  • zip "mac-ext" and tar "mac-ext" are on by default in Apple's build; both are still set
//    explicitly, and any "__MACOSX/" entry that slips through (e.g. streaming reader) is skipped.
//
//  Known limitations
//  -----------------
//  • archive_write_disk_new() briefly sets the process umask to 0 to read it (libarchive design).
//  • Listing a compressed tar (or a solid RAR4) means decompressing it; the extraction pre-pass is
//    therefore only done for zip, RAR4, LHA and CAB, and streams decode names entry by entry.
//  • AppleDouble metadata can carry ACLs, which copyfile applies like Archive Utility does.
//  • libarchive 3.7.4 doesn't verify the CRC32 of *stored* RAR5 entries (compressed ones are
//    checked); zip CRC mismatches are reported and surface as .corrupt (or .wrongPassword).
//  • The compressor stores no extended attributes/resource forks and treats hard links as copies.
//

import Foundation

/// Whether extraction wraps the results in a folder named after the archive.
public enum ArchiveFolderRule: String, Codable, Sendable, CaseIterable {
    /// Create a folder only when the archive has more than one top-level item (The Unarchiver's default).
    case smart
    /// Always create a folder named after the archive.
    case always
    /// Never create a folder; top-level items land directly in the destination.
    case never
}

public struct ArchiveExtractionOptions: Sendable {
    public var folderRule: ArchiveFolderRule = .smart
    /// Forces the encoding for names that are not valid UTF-8 (nil = auto-detect).
    /// Names that already are valid UTF-8 are always kept as UTF-8.
    public var encodingOverride: String.Encoding? = nil
    /// Passphrase for encrypted zip entries (ZipCrypto and AES).
    public var password: String? = nil
    public var keepModificationDates = true

    public init() {}

    public init(folderRule: ArchiveFolderRule = .smart, encodingOverride: String.Encoding? = nil,
                password: String? = nil, keepModificationDates: Bool = true) {
        self.folderRule = folderRule
        self.encodingOverride = encodingOverride
        self.password = password
        self.keepModificationDates = keepModificationDates
    }
}

public struct ArchiveExtractionResult: Sendable {
    /// The top-level items now in the destination (the created folder when one was made).
    public var items: [URL]
    /// The folder created by the folder rule, if any.
    public var containingFolder: URL?
    /// The legacy encoding used for non-UTF-8 names (nil = names were UTF-8/ASCII).
    public var detectedEncoding: String.Encoding?
    /// Number of entries written (files, folders, links).
    public var entryCount: Int
    /// Bytes of file data written.
    public var bytesWritten: Int64
    /// Entries refused for safety (unusable names, writing through a symlink, bad hard links).
    public var skippedEntries: [String]

    public init(items: [URL], containingFolder: URL?, detectedEncoding: String.Encoding?,
                entryCount: Int, bytesWritten: Int64, skippedEntries: [String] = []) {
        self.items = items
        self.containingFolder = containingFolder
        self.detectedEncoding = detectedEncoding
        self.entryCount = entryCount
        self.bytesWritten = bytesWritten
        self.skippedEntries = skippedEntries
    }
}

public struct ArchiveEntryInfo: Sendable, Equatable {
    /// Decoded, sanitised path inside the archive ("Folder/file.txt").
    public var path: String
    public var isDirectory: Bool
    public var isSymlink: Bool
    /// Uncompressed size, nil when the format doesn't record it (raw single-file streams).
    public var size: Int64?
    public var isEncrypted: Bool

    public init(path: String, isDirectory: Bool, isSymlink: Bool = false, size: Int64?, isEncrypted: Bool) {
        self.path = path
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.size = size
        self.isEncrypted = isEncrypted
    }
}

public enum ArchiveError: LocalizedError, Equatable {
    case notAnArchive
    case cannotOpen(String)
    case passwordRequired
    case wrongPassword
    case unsupportedEncryption(format: String)
    case corrupt(String)
    case cancelled
    case writeFailed(String)
    case unsupportedFormat(String)

    public var errorDescription: String? {
        switch self {
        case .notAnArchive:
            return "This file isn't an archive Tutto can open."
        case .cannotOpen(let reason):
            return "The archive couldn't be opened: \(reason)"
        case .passwordRequired:
            return "This archive is protected by a password."
        case .wrongPassword:
            return "The password is incorrect."
        case .unsupportedEncryption(let format):
            return "This \(format) archive is encrypted in a way macOS's archive library can't decrypt."
        case .corrupt(let reason):
            return "The archive appears to be damaged: \(reason)"
        case .cancelled:
            return "Cancelled."
        case .writeFailed(let reason):
            return "The files couldn't be written: \(reason)"
        case .unsupportedFormat(let what):
            return "Unsupported archive format: \(what)"
        }
    }
}

public struct ArchiveProgress: Sendable {
    /// 0…1, from compressed bytes consumed over the total size of all volumes.
    public var fraction: Double
    /// Path of the entry being processed.
    public var currentItem: String
    /// File bytes written so far.
    public var bytesWritten: Int64

    public init(fraction: Double, currentItem: String, bytesWritten: Int64) {
        self.fraction = fraction
        self.currentItem = currentItem
        self.bytesWritten = bytesWritten
    }
}
