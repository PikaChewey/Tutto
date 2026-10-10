//
//  ArchiveVolumes.swift
//  TuttoKit — archives
//
//  Multi-volume sets, ordered for archive_read_open_filenames (libarchive reads them as one
//  concatenated stream; RAR4/RAR5 readers additionally understand their own volume headers).
//  Verified on this Mac: RAR5 .partN.rar, 7z and zip byte-splits (.7z.001, .zip.001) and
//  Info-ZIP spanned sets (.z01, .z02 … .zip, read by libarchive's streaming zip reader).
//
//    name.part1.rar, name.part2.rar …        (also part01/part001; any member → whole set)
//    name.rar, name.r00, name.r01 …          (old RAR naming)
//    name.z01, name.z02 …, name.zip          (.zip is the last volume)
//    name.7z.001, name.7z.002 …              (any name.NNN byte split)
//

import Foundation

public enum ArchiveVolumes {
    /// All volumes of the set `url` belongs to, in reading order. Returns `[url]` for a
    /// single-file archive or when the set is incomplete at its start.
    public static func volumes(for url: URL) -> [URL] {
        let directory = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        func sibling(_ n: String) -> URL { directory.appendingPathComponent(n) }
        func exists(_ u: URL) -> Bool { FileManager.default.fileExists(atPath: u.path) }

        if let volume = VolumeName.parse(name) {
            switch volume.kind {
            case let .rarPart(prefix, partWord, width, ext):
                var result: [URL] = []
                var i = 1
                while true {
                    let candidate = sibling("\(prefix).\(partWord)\(pad(i, width)).\(ext)")
                    guard exists(candidate) else { break }
                    result.append(candidate)
                    i += 1
                }
                return result.contains(where: { $0.lastPathComponent == name }) ? result : [url]

            case .rarOld:
                let upper = (name as NSString).pathExtension.first?.isUppercase == true
                let first = sibling("\(volume.stem).\(upper ? "RAR" : "rar")")
                let firstAlt = sibling("\(volume.stem).\(upper ? "rar" : "RAR")")
                let head = exists(first) ? first : (exists(firstAlt) ? firstAlt : nil)
                guard let head else { return [url] }
                return oldRarSet(head: head, stem: volume.stem, upper: upper, in: directory)

            case .zipSpan:
                let upper = (name as NSString).pathExtension.first?.isUppercase == true
                return zipSpanSet(stem: volume.stem, upper: upper, in: directory) ?? [url]

            case let .numbered(width):
                var result: [URL] = []
                var i = 1
                while true {
                    let candidate = sibling("\(volume.stem).\(pad(i, width))")
                    guard exists(candidate) else { break }
                    result.append(candidate)
                    i += 1
                }
                return result.contains(where: { $0.lastPathComponent == name }) ? result : [url]
            }
        }

        // Plain name.rar / name.zip that heads an old-style set.
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        switch ext.lowercased() {
        case "rar":
            let upper = ext.first?.isUppercase == true
            let set = oldRarSet(head: url, stem: stem, upper: upper, in: directory)
            return set
        case "zip":
            let upper = ext.first?.isUppercase == true
            if let set = zipSpanSet(stem: stem, upper: upper, in: directory) { return set }
            return [url]
        default:
            return [url]
        }
    }

    /// The first volume in reading order (part1, .rar, .z01, .001); `url` itself for single archives.
    public static func firstVolume(for url: URL) -> URL {
        volumes(for: url).first ?? url
    }

    /// True when `url` is a volume other than the first of a set that is present on disk —
    /// useful to avoid extracting the same set once per selected volume.
    public static func isSecondaryVolume(_ url: URL) -> Bool {
        let set = volumes(for: url)
        return set.count > 1 && set.first?.standardizedFileURL != url.standardizedFileURL
    }

    // MARK: - Helpers

    private static func pad(_ n: Int, _ width: Int) -> String {
        let s = String(n)
        return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
    }

    private static func oldRarSet(head: URL, stem: String, upper: Bool, in directory: URL) -> [URL] {
        var result = [head]
        var i = 0
        while i < 100 {
            let ext = (upper ? "R" : "r") + pad(i, 2)
            var candidate = directory.appendingPathComponent("\(stem).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) {
                let alt = (upper ? "r" : "R") + pad(i, 2)
                candidate = directory.appendingPathComponent("\(stem).\(alt)")
                if !FileManager.default.fileExists(atPath: candidate.path) { break }
            }
            result.append(candidate)
            i += 1
        }
        return result
    }

    private static func zipSpanSet(stem: String, upper: Bool, in directory: URL) -> [URL]? {
        var parts: [URL] = []
        var i = 1
        while true {
            let ext = (upper ? "Z" : "z") + pad(i, 2)
            var candidate = directory.appendingPathComponent("\(stem).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) {
                let alt = (upper ? "z" : "Z") + pad(i, 2)
                candidate = directory.appendingPathComponent("\(stem).\(alt)")
                if !FileManager.default.fileExists(atPath: candidate.path) { break }
            }
            parts.append(candidate)
            i += 1
        }
        guard !parts.isEmpty else { return nil }
        let last = directory.appendingPathComponent("\(stem).\(upper ? "ZIP" : "zip")")
        let lastAlt = directory.appendingPathComponent("\(stem).\(upper ? "zip" : "ZIP")")
        if FileManager.default.fileExists(atPath: last.path) { parts.append(last) }
        else if FileManager.default.fileExists(atPath: lastAlt.path) { parts.append(lastAlt) }
        else { return nil }   // the central directory lives in .zip; without it the set is incomplete
        return parts
    }
}
