//
//  ConvertRules.swift
//  Tutto
//
//  What the converter can make from what, and what it calls the results: the rules behind the
//  Convert window, the drag-and-tap wheel and Finder's Convert menu, kept apart from ImageIO,
//  AVFoundation and PDFKit so they can be tested. Only formats macOS writes by itself are
//  offered (no MP3, WebP or MKV output: there's no encoder for them without bundling one).
//

import Foundation

/// What a file is, as far as converting goes.
public enum FileKind: String, CaseIterable, Codable, Sendable {
    case image, video, audio, pdf, document, subtitles, other

    private static let extensions: [FileKind: Set<String>] = [
        .image: ["jpg", "jpeg", "jpe", "png", "heic", "heif", "hif", "avif", "webp", "tif", "tiff", "gif", "bmp", "jxl", "jp2",
                 "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "srw", "psd", "ico", "icns", "tga", "exr"],
        .video: ["mov", "mp4", "m4v", "3gp", "3g2", "mpg", "mpeg", "mts", "m2ts", "avi"],
        .audio: ["mp3", "m4a", "aac", "wav", "wave", "aif", "aiff", "aifc", "caf", "flac", "ogg", "oga", "opus", "m4b", "amr"],
        .pdf: ["pdf"],
        .document: ["docx", "doc", "rtf", "rtfd", "odt", "html", "htm", "txt", "text", "md", "markdown", "webarchive"],
        .subtitles: ["srt", "vtt"],
    ]

    public static func of(extension ext: String) -> FileKind {
        let lower = ext.lowercased()
        return extensions.first { $0.value.contains(lower) }?.key ?? .other
    }

    public static func of(_ url: URL) -> FileKind { of(extension: url.pathExtension) }

    /// "3 pictures", "1 sound file", "2 PDFs".
    public func count(_ n: Int) -> String {
        let (one, many): (String, String) = switch self {
        case .image: ("picture", "pictures")
        case .video: ("video", "videos")
        case .audio: ("sound file", "sound files")
        case .pdf: ("PDF", "PDFs")
        case .document: ("document", "documents")
        case .subtitles: ("subtitle file", "subtitle files")
        case .other: ("file", "files")
        }
        return "\(n) \(n == 1 ? one : many)"
    }

    public var title: String {
        switch self {
        case .image: "Image"
        case .video: "Video"
        case .audio: "Audio"
        case .pdf: "PDF"
        case .document: "Document"
        case .subtitles: "Subtitles"
        case .other: "File"
        }
    }
}

/// A file type the converter writes.
public enum OutputFormat: String, CaseIterable, Codable, Sendable {
    case jpeg, png, heic, avif, tiff, gif, bmp, pdf
    case mp4, mp4HEVC, mov
    case m4a, m4aLossless, wav, aiff, flac, opus
    case txt, docx, rtf, odt, html
    case srt, vtt

    public var title: String {
        switch self {
        case .jpeg: "JPEG"
        case .png: "PNG"
        case .heic: "HEIC"
        case .avif: "AVIF"
        case .tiff: "TIFF"
        case .gif: "GIF"
        case .bmp: "BMP"
        case .pdf: "PDF"
        case .mp4: "MP4"
        case .mp4HEVC: "MP4 HEVC"
        case .mov: "MOV"
        case .m4a: "M4A"
        case .m4aLossless: "ALAC"
        case .wav: "WAV"
        case .aiff: "AIFF"
        case .flac: "FLAC"
        case .opus: "Opus"
        case .txt: "Text"
        case .docx: "Word"
        case .rtf: "RTF"
        case .odt: "ODT"
        case .html: "HTML"
        case .srt: "SRT"
        case .vtt: "VTT"
        }
    }

    public var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .mp4HEVC: "mp4"
        case .m4aLossless: "m4a"
        case .opus: "ogg"
        default: rawValue
        }
    }
}

public enum ConvertPlanner {
    /// What a kind of file can become, most useful first (the wheel shows them in this order).
    public static func targets(for kind: FileKind) -> [OutputFormat] {
        switch kind {
        case .image: [.jpeg, .png, .heic, .pdf, .avif, .tiff, .gif, .bmp]
        case .video: [.mp4, .mp4HEVC, .mov, .gif, .m4a]
        // (Opus is left out: macOS writes it only into CAF files, which almost nothing plays.)
        case .audio: [.m4a, .wav, .flac, .m4aLossless, .aiff]
        case .pdf: [.png, .jpeg, .txt]
        case .document: [.pdf, .docx, .rtf, .txt, .html, .odt]
        case .subtitles: [.srt, .vtt, .txt]
        case .other: []
        }
    }

    /// What every file of a selection can become: the formats its kinds share. A format a file
    /// already is stays on offer (a JPEG can be re-saved as JPEG, smaller).
    public static func targets(for kinds: [FileKind]) -> [OutputFormat] {
        let distinct = Array(Set(kinds))
        guard let first = distinct.first else { return [] }
        var shared = targets(for: first)
        for kind in distinct.dropFirst() {
            let theirs = Set(targets(for: kind))
            shared.removeAll { !theirs.contains($0) }
        }
        return shared
    }

    /// Kinds that Compress makes smaller.
    public static func canCompress(_ kind: FileKind) -> Bool {
        [.image, .video, .audio, .pdf].contains(kind)
    }

    /// Several files that become one file: images (or PDFs, or both) into one PDF.
    public static func combines(_ kinds: [FileKind], into format: OutputFormat) -> Bool {
        format == .pdf && kinds.count > 1 && kinds.allSatisfy { $0 == .image || $0 == .pdf }
    }
}

/// Names for what the converter writes: beside the original, never over anything.
public enum OutputNames {
    /// The first of "name.ext", "name 2.ext", "name 3.ext"… that `exists` says is free.
    public static func unique(_ base: String, ext: String, in folder: URL, exists: (URL) -> Bool) -> URL {
        var url = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var counter = 2
        while exists(url) {
            url = folder.appendingPathComponent("\(base) \(counter)").appendingPathExtension(ext)
            counter += 1
        }
        return url
    }

    /// "photo.heic" → "photo.jpg"; a file converted to its own type gets "(converted)".
    public static func converted(_ source: URL, ext: String, in folder: URL? = nil, exists: (URL) -> Bool) -> URL {
        let base = source.deletingPathExtension().lastPathComponent
        let same = source.pathExtension.lowercased() == ext.lowercased()
            || (["jpg", "jpeg"].contains(source.pathExtension.lowercased()) && ext == "jpg")
        return unique(same ? "\(base) (converted)" : base, ext: ext, in: folder ?? source.deletingLastPathComponent(), exists: exists)
    }

    /// "photo.jpg" → "photo (compressed).jpg" (or another extension when compressing changes it).
    public static func compressed(_ source: URL, ext: String? = nil, in folder: URL? = nil, exists: (URL) -> Bool) -> URL {
        let base = source.deletingPathExtension().lastPathComponent
        return unique("\(base) (compressed)", ext: ext ?? source.pathExtension, in: folder ?? source.deletingLastPathComponent(), exists: exists)
    }

    /// Several files made into one: "beach.pdf" for one, "beach and 4 more.pdf" for five.
    public static func combined(_ sources: [URL], ext: String, in folder: URL? = nil, exists: (URL) -> Bool) -> URL? {
        guard let first = sources.first else { return nil }
        let base = first.deletingPathExtension().lastPathComponent
        let name = sources.count > 1 ? "\(base) and \(sources.count - 1) more" : base
        return unique(name, ext: ext, in: folder ?? first.deletingLastPathComponent(), exists: exists)
    }

    /// A page of a PDF made into a picture: "report 3.png" (or just "report.png" for one page).
    public static func page(_ source: URL, page: Int, of count: Int, ext: String, exists: (URL) -> Bool) -> URL {
        let base = source.deletingPathExtension().lastPathComponent
        return unique(count == 1 ? base : "\(base) \(page)", ext: ext, in: source.deletingLastPathComponent(), exists: exists)
    }
}

/// How hard Compress works, for each kind. Saved; the wheel and Finder use it as it is.
public struct CompressionSettings: Codable, Equatable, Sendable {
    public enum VideoQuality: String, Codable, CaseIterable, Sendable {
        case small, balanced, high
        public var title: String { rawValue.capitalized }
        /// Bits per pixel per frame for H.264; HEVC needs about 60 % of that.
        var bitsPerPixel: Double {
            switch self {
            case .small: 0.045
            case .balanced: 0.08
            case .high: 0.14
            }
        }
    }

    public enum VideoCodec: String, Codable, CaseIterable, Sendable {
        case h264, hevc
        public var title: String { self == .h264 ? "H.264" : "HEVC" }
    }

    public enum PDFLevel: String, Codable, CaseIterable, Sendable {
        case light, strong
        public var title: String { rawValue.capitalized }
    }

    /// 0.1–1, for JPEG, HEIC and AVIF.
    public var imageQuality = 0.75
    /// Longest side in pixels; nil keeps the size.
    public var imageMaxSide: Int?
    /// Aim for at most this many bytes per picture (quality, then size, give way); nil: off.
    public var imageTargetBytes: Int?
    /// Leave out location, camera and editing details (orientation is applied, not lost).
    public var removeImageDetails = true
    public var videoQuality = VideoQuality.balanced
    /// Height in pixels the video is brought down to; nil keeps it.
    public var videoMaxHeight: Int? = 1080
    public var videoCodec = VideoCodec.h264
    public var pdfLevel = PDFLevel.light
    /// AAC bit rate for compressed audio.
    public var audioKbps = 128

    public init() {}

    public static let imageSides: [Int?] = [nil, 3840, 2560, 1920, 1280, 960]
    public static let videoHeights: [Int?] = [nil, 2160, 1080, 720, 480]
    public static let audioRates = [64, 96, 128, 192, 256]

    /// Bits per second for a video of this size and frame rate at this quality.
    public static func videoBitrate(width: Int, height: Int, fps: Double, quality: VideoQuality, codec: VideoCodec) -> Int {
        let fps = min(max(fps.isFinite ? fps : 30, 1), 120)
        var bits = Double(width * height) * fps * quality.bitsPerPixel
        if codec == .hevc { bits *= 0.6 }
        return Int(min(max(bits, 250_000), 80_000_000))
    }

    /// A size after scaling so the taller side is at most `maxHeight` (even numbers, for video).
    public static func fitted(width: Int, height: Int, maxHeight: Int?) -> (width: Int, height: Int) {
        guard let maxHeight, height > maxHeight, height > 0 else { return (width - width % 2, height - height % 2) }
        let scale = Double(maxHeight) / Double(height)
        let w = Int((Double(width) * scale).rounded())
        return (max(w - w % 2, 2), maxHeight - maxHeight % 2)
    }
}

/// Reads a size typed in a field: "500 KB", "2 MB", "1.5mb", "800k", "750000".
public enum ByteSizeText {
    public static func bytes(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: ",", with: ".")
        guard !trimmed.isEmpty else { return nil }
        let digits = trimmed.prefix { "0123456789.".contains($0) }
        guard let number = Double(digits), number > 0 else { return nil }
        let unit = trimmed.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        let multiplier: Double
        switch unit {
        case "", "b", "bytes": multiplier = 1
        case "k", "kb", "kib": multiplier = 1_000
        case "m", "mb", "mib": multiplier = 1_000_000
        case "g", "gb", "gib": multiplier = 1_000_000_000
        default: return nil
        }
        return Int(number * multiplier)
    }
}

/// Finds the best quality that fits a size, in a few encodes.
public enum QualitySearch {
    /// The highest quality between `low` and `high` whose encoded size (from `size`) is at most
    /// `target`, trying at most `steps` qualities; nil when even `low` is too big.
    public static func best(target: Int, low: Double = 0.1, high: Double = 0.95, steps: Int = 7,
                            size: (Double) throws -> Int) rethrows -> Double? {
        if try size(high) <= target { return high }
        guard try size(low) <= target else { return nil }
        var lo = low, hi = high
        for _ in 0..<max(steps - 2, 1) {
            let mid = (lo + hi) / 2
            if try size(mid) <= target { lo = mid } else { hi = mid }
        }
        return lo
    }
}
