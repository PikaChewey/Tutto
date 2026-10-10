//
//  ArchiveNaming.swift
//  TuttoKit — archives
//
//  Name-only helpers: which files look like archives, what folder an archive extracts into,
//  and Finder-style unique names. Nothing here reads file contents.
//

import Foundation

public enum ArchiveFormats {
    /// Lower-cased extensions Tutto offers to extract (the last path extension of the file).
    public static let extractableExtensions: Set<String> = [
        "zip", "zipx", "rar", "7z", "tar", "gz", "gzip", "tgz", "bz2", "bzip2", "tbz", "tbz2",
        "xz", "txz", "lzma", "tlz", "lz", "z", "taz", "cpgz", "iso", "cab", "lha", "lzh",
        "xar", "pkg", "cpio", "ar", "deb", "rpm", "warc",
    ]

    /// Single-file compression extensions (stripped from the archive name to name the output).
    static let compressionExtensions: Set<String> = ["gz", "gzip", "bz2", "bzip2", "xz", "lzma", "lz", "z"]

    /// Shorthand tar extensions and what they stand for.
    static let tarShorthands: Set<String> = ["tgz", "tbz", "tbz2", "txz", "tlz", "taz", "cpgz"]

    /// True when the name looks like an archive or a volume of a multi-part archive
    /// (name.part2.rar, name.r00, name.z01, name.7z.001 …). Cheap: no I/O.
    public static func isLikelyArchive(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        let ext = (name as NSString).pathExtension
        if ext.isEmpty { return false }
        if extractableExtensions.contains(ext) { return true }
        return VolumeName.parse(url.lastPathComponent) != nil
    }
}

public enum ArchiveNaming {
    /// The folder name an archive extracts into: strips .tar.gz/.tgz-style compound
    /// extensions, .partN.rar, .7z.001-style split suffixes, .rNN/.zNN volumes and finally a
    /// single extension ("Photos.zip" → "Photos", "src.tar.gz" → "src", "a.part01.rar" → "a").
    public static func baseName(of archive: URL) -> String {
        let name = archive.lastPathComponent
        var stem = name

        if let volume = VolumeName.parse(name) {
            stem = volume.stem
            // "name.7z.001" → stem "name.7z": drop the inner archive extension too.
            let innerExt = (stem as NSString).pathExtension.lowercased()
            if !innerExt.isEmpty && (ArchiveFormats.extractableExtensions.contains(innerExt)) {
                stem = (stem as NSString).deletingPathExtension
                if (stem as NSString).pathExtension.lowercased() == "tar" {
                    stem = (stem as NSString).deletingPathExtension
                }
            }
        } else {
            let ext = (stem as NSString).pathExtension.lowercased()
            if !ext.isEmpty {
                stem = (stem as NSString).deletingPathExtension
                // Compound tar names: .tar.gz, .tar.bz2, .tar.xz, .tar.Z, .tar.zst …
                if (stem as NSString).pathExtension.lowercased() == "tar" {
                    stem = (stem as NSString).deletingPathExtension
                }
            }
        }
        let trimmed = stem.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "." || trimmed == ".." { return name.isEmpty ? "Archive" : name }
        return stem
    }

    /// Name for the single file inside a raw compressed stream: "notes.txt.gz" → "notes.txt",
    /// "backup.tgz" → "backup.tar", "data.bin.xz" → "data.bin".
    static func singleFileOutputName(for archive: URL) -> String {
        let name = archive.lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        let stem = (name as NSString).deletingPathExtension
        if ArchiveFormats.tarShorthands.contains(ext) {
            return stem.isEmpty ? "Archive.tar" : (ext == "cpgz" ? stem + ".cpio" : stem + ".tar")
        }
        if ArchiveFormats.compressionExtensions.contains(ext), !stem.isEmpty {
            return stem
        }
        return baseName(of: archive)
    }

    /// Format family guessed from the name, for messages when libarchive couldn't tell.
    static func formatFamily(forExtensionOf url: URL) -> String {
        if let volume = VolumeName.parse(url.lastPathComponent) {
            switch volume.kind {
            case .rarPart, .rarOld: return "RAR"
            case .zipSpan: return "ZIP"
            case .numbered: return formatFamily(forExtensionOf: URL(fileURLWithPath: volume.stem))
            }
        }
        switch url.pathExtension.lowercased() {
        case "rar": return "RAR"
        case "7z": return "7-Zip"
        case "zip", "zipx": return "ZIP"
        default: return "archive"
        }
    }

    /// Finder-style unique URL: returns `proposed` if nothing exists there (a dangling symlink
    /// counts as existing), otherwise "Name 2.ext", "Name 3.ext" …
    /// Folders (URLs with a directory path) are numbered at the end of the whole name.
    public static func uniqueURL(for proposed: URL) -> URL {
        uniqueURL(for: proposed, isDirectory: proposed.hasDirectoryPath)
    }

    static func uniqueURL(for proposed: URL, isDirectory: Bool) -> URL {
        if !FileSystem.itemExists(proposed) { return proposed }
        let directory = proposed.deletingLastPathComponent()
        let name = proposed.lastPathComponent
        var ext = (name as NSString).pathExtension
        var stem = (name as NSString).deletingPathExtension
        // "Archive.tar.gz" → "Archive 2.tar.gz"
        if (stem as NSString).pathExtension.lowercased() == "tar", !(stem as NSString).deletingPathExtension.isEmpty {
            ext = (stem as NSString).pathExtension + "." + ext
            stem = (stem as NSString).deletingPathExtension
        }
        // Hidden names without a further dot (".config") and folders are numbered at the end.
        let isDotName = name.hasPrefix(".") && !name.dropFirst().contains(".")
        let splitExtension = !isDirectory && !ext.isEmpty && !isDotName && !stem.isEmpty
        if !splitExtension { stem = name }
        var counter = 2
        while true {
            let candidateName = splitExtension ? "\(stem) \(counter).\(ext)" : "\(name) \(counter)"
            let candidate = directory.appendingPathComponent(candidateName, isDirectory: isDirectory)
            if !FileSystem.itemExists(candidate) { return candidate }
            counter += 1
        }
    }
}

/// Parsed multi-volume file name.
struct VolumeName: Equatable {
    enum Kind: Equatable {
        case rarPart(prefix: String, partWord: String, width: Int, ext: String)   // name.part01.rar
        case rarOld                                                               // name.rar, name.r00 …
        case zipSpan                                                              // name.zip, name.z01 …
        case numbered(width: Int)                                                 // name.7z.001
    }

    var kind: Kind
    /// Name without the volume suffix ("name" for name.part1.rar, "name.7z" for name.7z.001).
    var stem: String
    /// 1-based volume index in reading order where known (rarOld: .rar = 0, .r00 = 1 …).
    var index: Int

    /// Recognises volume-style names only (".rar"/".zip" alone return nil).
    static func parse(_ name: String) -> VolumeName? {
        let ns = name as NSString
        let ext = ns.pathExtension
        let lowerExt = ext.lowercased()
        let stem = ns.deletingPathExtension
        guard !ext.isEmpty, !stem.isEmpty else { return nil }

        // name.partN.rar
        if lowerExt == "rar" {
            let inner = (stem as NSString).pathExtension
            let lowerInner = inner.lowercased()
            if lowerInner.hasPrefix("part"), lowerInner.count > 4 {
                let digits = inner.dropFirst(4)
                if digits.allSatisfy(\.isASCIIDigit), let n = Int(digits) {
                    let prefix = (stem as NSString).deletingPathExtension
                    guard !prefix.isEmpty else { return nil }
                    return VolumeName(kind: .rarPart(prefix: prefix, partWord: String(inner.prefix(4)), width: digits.count, ext: ext),
                                      stem: prefix, index: n)
                }
            }
            return nil
        }
        // name.r00 … name.r99
        if lowerExt.count == 3, lowerExt.hasPrefix("r"), lowerExt.dropFirst().allSatisfy(\.isASCIIDigit),
           let n = Int(lowerExt.dropFirst()) {
            return VolumeName(kind: .rarOld, stem: stem, index: n + 1)
        }
        // name.z01 … name.z99 (Info-ZIP spanned/split)
        if lowerExt.count >= 3, lowerExt.hasPrefix("z"), lowerExt.dropFirst().allSatisfy(\.isASCIIDigit),
           let n = Int(lowerExt.dropFirst()), n >= 1 {
            return VolumeName(kind: .zipSpan, stem: stem, index: n)
        }
        // name.001 (byte-split: .7z.001, .zip.001, .rar.001, plain .001)
        if lowerExt.count == 3, lowerExt.allSatisfy(\.isASCIIDigit), let n = Int(lowerExt), n >= 1 {
            return VolumeName(kind: .numbered(width: lowerExt.count), stem: stem, index: n)
        }
        return nil
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
