//
//  MediaEdit.swift
//  TuttoKit — converting
//
//  Resizing and cropping pictures, video and PDFs, and compressing new files by themselves
//  (Bryan, 2026-11-13: "Automatically compress images, videos and PDFs; convert formats;
//  resize/crop media"). The rules only: what size a resize gives, which part of a picture a crop
//  keeps, which new files are compressed when they appear, and which kept originals are cleared
//  out. The work itself is ImageIO, AVFoundation and PDFKit in the app.
//

import CoreGraphics
import Foundation

// MARK: - Resize

/// How much smaller to make a picture or a video. Never larger: a resize that would grow it keeps
/// its size.
public enum ResizeSpec: Codable, Hashable, Sendable {
    /// A fraction of each side (0.5 is half the width and half the height).
    case scale(Double)
    /// The longest side at most this many pixels.
    case longSide(Int)

    public var title: String {
        switch self {
        case .scale(let s): s == 0.5 ? "Half" : s == 0.25 ? "Quarter" : "\(Int((s * 100).rounded())) %"
        case .longSide(let n): n == 3840 ? "4K" : "\(n) px"
        }
    }

    /// "50 %", "1920 px": what the menus say next to the title.
    public var detail: String {
        switch self {
        case .scale(let s): "\(Int((s * 100).rounded())) % of each side"
        case .longSide(let n): "Longest side \(n) px"
        }
    }

    /// The code in a `tutto://convert?resize=` link: "50%" or "1920".
    public var code: String {
        switch self {
        case .scale(let s): "\(Int((s * 100).rounded()))%"
        case .longSide(let n): String(n)
        }
    }

    public init?(code: String) {
        let text = code.trimmingCharacters(in: .whitespaces).lowercased()
        if text.hasSuffix("%"), let percent = Double(text.dropLast()), percent > 0, percent < 100 {
            self = .scale(percent / 100)
        } else if text.hasSuffix("x"), let factor = Double(text.dropLast()), factor > 0, factor < 1 {
            self = .scale(factor)
        } else if let pixels = Int(text.replacingOccurrences(of: "px", with: "")), pixels >= 16 {
            self = .longSide(pixels)
        } else {
            return nil
        }
    }

    /// The sizes offered for pictures, most used first.
    public static let picturePresets: [ResizeSpec] = [.scale(0.5), .scale(0.25), .longSide(3840), .longSide(2560), .longSide(1920),
                                                      .longSide(1280), .longSide(1080), .longSide(640)]
    /// For video: half, then the usual heights' long sides (4K, 1080p, 720p, 480p).
    public static let videoPresets: [ResizeSpec] = [.scale(0.5), .longSide(3840), .longSide(1920), .longSide(1280), .longSide(854)]

    /// The size after resizing `width` × `height` (at least 2 × 2; even numbers when `even`, for
    /// video encoders). Never bigger than it was.
    public func size(width: Int, height: Int, even: Bool = false) -> (width: Int, height: Int) {
        let w = max(width, 1), h = max(height, 1)
        let factor: Double
        switch self {
        case .scale(let s): factor = min(max(s, 0.01), 1)
        case .longSide(let n): factor = min(Double(max(n, 2)) / Double(max(w, h)), 1)
        }
        func side(_ value: Int) -> Int {
            var result = max(Int((Double(value) * factor).rounded()), 2)
            if even { result -= result % 2 }
            return max(result, 2)
        }
        return (side(w), side(h))
    }

    /// Whether resizing changes anything at this size.
    public func shrinks(width: Int, height: Int) -> Bool {
        let after = size(width: width, height: height)
        return after.width < width || after.height < height
    }
}

// MARK: - Crop

/// The shape to cut a picture, video or PDF page to.
public enum CropSpec: Codable, Hashable, Sendable {
    /// The largest part of this shape (width : height).
    case aspect(Int, Int)
    /// Exactly this many pixels: the largest part of this shape, then scaled to it (never up).
    case size(Int, Int)

    public var ratio: Double {
        switch self {
        case .aspect(let w, let h), .size(let w, let h): Double(max(w, 1)) / Double(max(h, 1))
        }
    }

    public var title: String {
        switch self {
        case .aspect(let w, let h): w == h ? "Square" : "\(w):\(h)"
        case .size(let w, let h): "\(w) × \(h)"
        }
    }

    /// What it's for, in the menus.
    public var detail: String {
        switch self {
        case .aspect(1, 1): "1:1"
        case .aspect(4, 5): "Portrait post"
        case .aspect(16, 9): "Widescreen"
        case .aspect(9, 16): "Story, reel, short"
        case .aspect(4, 3): "Classic screen"
        case .aspect(3, 2): "Photo print"
        case .size(1920, 1080): "Full HD"
        case .size(1080, 1080): "Square post"
        case .size(1080, 1350): "Portrait post"
        case .size(1080, 1920): "Story, reel, short"
        case .size(1200, 630): "Link preview"
        case .size(1500, 500): "Profile header"
        default: ""
        }
    }

    /// The code in a `tutto://convert?crop=` link: "16:9" or "1920x1080".
    public var code: String {
        switch self {
        case .aspect(let w, let h): "\(w):\(h)"
        case .size(let w, let h): "\(w)x\(h)"
        }
    }

    public init?(code: String) {
        let text = code.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "×", with: "x")
        if text == "square" { self = .aspect(1, 1); return }
        for (separator, isSize) in [(":", false), ("x", true)] {
            let parts = text.split(separator: Character(separator))
            if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w > 0, h > 0 {
                if isSize, w >= 16, h >= 16 { self = .size(w, h) } else if !isSize, w <= 64, h <= 64 { self = .aspect(w, h) } else { return nil }
                return
            }
        }
        return nil
    }

    public static let aspects: [CropSpec] = [.aspect(1, 1), .aspect(4, 5), .aspect(16, 9), .aspect(9, 16), .aspect(4, 3), .aspect(3, 2)]
    public static let sizes: [CropSpec] = [.size(1920, 1080), .size(1080, 1080), .size(1080, 1350), .size(1080, 1920),
                                           .size(1200, 630), .size(1500, 500)]

    /// The output size for a `width` × `height` source: the crop, then for `.size` brought down
    /// to it (even numbers when `even`).
    public func outputSize(width: Int, height: Int, even: Bool = false) -> (width: Int, height: Int) {
        let rect = CropMath.rect(width: width, height: height, ratio: ratio, even: even)
        var w = Int(rect.width), h = Int(rect.height)
        if case .size(let tw, let th) = self, tw < w || th < h {
            w = min(tw, w)
            h = min(th, h)
            // Keep the shape exact when only one side was over.
            let scale = min(Double(tw) / rect.width, Double(th) / rect.height, 1)
            w = max(Int((rect.width * scale).rounded()), 2)
            h = max(Int((rect.height * scale).rounded()), 2)
        }
        if even {
            w = max(w - w % 2, 2)
            h = max(h - h % 2, 2)
        }
        return (w, h)
    }
}

public enum CropMath {
    /// The largest rectangle of `ratio` (width / height) inside `width` × `height`, centred on
    /// `focus` (0–1 across and down, from the top left) as nearly as it fits. Whole pixels, top-left
    /// origin; even sizes and positions when `even`.
    public static func rect(width: Int, height: Int, ratio: Double, focus: CGPoint = CGPoint(x: 0.5, y: 0.5),
                            even: Bool = false) -> CGRect {
        let w = Double(max(width, 1)), h = Double(max(height, 1))
        let ratio = ratio.isFinite && ratio > 0 ? ratio : 1
        var cropW = w, cropH = h
        if w / h > ratio { cropW = h * ratio } else { cropH = w / ratio }
        var cw = max(Int(cropW.rounded(.down)), 1), ch = max(Int(cropH.rounded(.down)), 1)
        if even {
            cw = max(cw - cw % 2, 2)
            ch = max(ch - ch % 2, 2)
        }
        let fx = min(max(focus.x.isFinite ? focus.x : 0.5, 0), 1)
        let fy = min(max(focus.y.isFinite ? focus.y : 0.5, 0), 1)
        var x = Int((fx * w - Double(cw) / 2).rounded())
        var y = Int((fy * h - Double(ch) / 2).rounded())
        x = min(max(x, 0), max(Int(w) - cw, 0))
        y = min(max(y, 0), max(Int(h) - ch, 0))
        if even {
            x -= x % 2
            y -= y % 2
        }
        return CGRect(x: x, y: y, width: cw, height: ch)
    }

    /// Where to centre a crop from the regions that draw the eye (0–1, top-left origin): the middle
    /// of their union, weighted by confidence; the picture's middle when there are none.
    public static func focus(of regions: [(rect: CGRect, confidence: Double)]) -> CGPoint {
        let usable = regions.filter { $0.confidence > 0.1 && $0.rect.width > 0 && $0.rect.height > 0 }
        guard !usable.isEmpty else { return CGPoint(x: 0.5, y: 0.5) }
        let total = usable.reduce(0) { $0 + $1.confidence }
        let x = usable.reduce(0) { $0 + $1.rect.midX * $1.confidence } / total
        let y = usable.reduce(0) { $0 + $1.rect.midY * $1.confidence } / total
        return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }
}

// MARK: - Compressing new files by themselves

/// What Tutto compresses by itself: new pictures, videos and PDFs in the folders it watches
/// (the Desktop, where screenshots and screen recordings land, unless you choose others), and
/// pictures copied to the clipboard. Each is compressed in place; the original is kept for a few
/// days, so a compress can be undone.
public struct AutoCompressSettings: Codable, Equatable, Sendable {
    public var isOn = true
    /// Folders watched, as paths; empty means the Desktop and the screenshots folder.
    public var folders: [String] = []
    public var images = true
    public var videos = true
    public var pdfs = true
    /// Pictures copied to the clipboard (a screenshot copied with ⌃⇧⌘4, say).
    public var clipboard = true
    /// Screenshots from a Retina screen at half their pixels (they look the same on most screens
    /// people share them to).
    public var halveRetinaScreenshots = false
    /// Days a compressed file's original is kept, to undo the compress.
    public var keepOriginalsDays = 3
    /// Bigger files are left alone (megabytes).
    public var maxImageMB = 60
    public var maxVideoMB = 2_000
    public var maxPDFMB = 300

    public init() {}

    enum CodingKeys: String, CodingKey {
        case isOn, folders, images, videos, pdfs, clipboard, halveRetinaScreenshots, keepOriginalsDays, maxImageMB, maxVideoMB, maxPDFMB
    }

    /// Anything missing (a setting added later) keeps its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isOn = (try? c.decodeIfPresent(Bool.self, forKey: .isOn)) ?? true
        folders = (try? c.decodeIfPresent([String].self, forKey: .folders)) ?? []
        images = (try? c.decodeIfPresent(Bool.self, forKey: .images)) ?? true
        videos = (try? c.decodeIfPresent(Bool.self, forKey: .videos)) ?? true
        pdfs = (try? c.decodeIfPresent(Bool.self, forKey: .pdfs)) ?? true
        clipboard = (try? c.decodeIfPresent(Bool.self, forKey: .clipboard)) ?? true
        halveRetinaScreenshots = (try? c.decodeIfPresent(Bool.self, forKey: .halveRetinaScreenshots)) ?? false
        keepOriginalsDays = (try? c.decodeIfPresent(Int.self, forKey: .keepOriginalsDays)) ?? 3
        maxImageMB = (try? c.decodeIfPresent(Int.self, forKey: .maxImageMB)) ?? 60
        maxVideoMB = (try? c.decodeIfPresent(Int.self, forKey: .maxVideoMB)) ?? 2_000
        maxPDFMB = (try? c.decodeIfPresent(Int.self, forKey: .maxPDFMB)) ?? 300
    }

    public static let keepChoices = [1, 3, 7, 30]

    public func handles(_ kind: FileKind) -> Bool {
        switch kind {
        case .image: images
        case .video: videos
        case .pdf: pdfs
        default: false
        }
    }

    public func maxBytes(_ kind: FileKind) -> Int {
        switch kind {
        case .image: maxImageMB * 1_000_000
        case .video: maxVideoMB * 1_000_000
        case .pdf: maxPDFMB * 1_000_000
        default: 0
        }
    }
}

public enum AutoCompressRules {
    /// Files still arriving (a download, a copy in progress) or someone's temporary file.
    public static let unfinishedExtensions: Set<String> = ["crdownload", "download", "part", "partial", "tmp", "opdownload",
                                                           "icloud", "dtapart", "aria2", "filepart"]
    /// Words Tutto puts in the names of what it makes: those are already done.
    public static let ownMarks = ["(compressed)", "(converted)", "(resized)", "(cropped)"]
    /// The extended attribute Tutto sets on a file it compressed (so it's never done twice).
    public static let doneAttribute = "ca.bryanyao.Tutto.compressed"
    /// A new file appears and is compressed only while it's this new (seconds): files moved in
    /// from elsewhere, or found after a restart, are left as they are.
    public static let newWithin: TimeInterval = 180
    /// Smaller than this, there's nothing worth saving.
    public static func minBytes(_ kind: FileKind) -> Int {
        switch kind {
        case .video: 200_000
        case .pdf: 50_000
        default: 30_000
        }
    }

    /// More than this many of a kind arriving together is an export or a download of a batch:
    /// left alone (a screenshot or a recording comes one at a time).
    public static func burstLimit(_ kind: FileKind) -> Int {
        switch kind {
        case .video: 1
        case .pdf: 2
        default: 4
        }
    }

    /// Whether a batch that arrived together is small enough to compress.
    public static func withinBurst(_ kinds: [FileKind]) -> Bool {
        Dictionary(grouping: kinds, by: { $0 }).allSatisfy { $0.value.count <= burstLimit($0.key) }
    }

    /// A file still being written changed this recently (seconds): wait for it to settle.
    public static let settleSeconds: TimeInterval = 1.5
    /// A compress that saves less than this share isn't kept (the original stays as it was).
    public static let minSaving = 0.05

    /// Whether a file that just appeared should be compressed.
    public static func shouldCompress(name: String, kind: FileKind, bytes: Int, created: Date?, now: Date,
                                      settings: AutoCompressSettings, alreadyDone: Bool) -> Bool {
        guard settings.isOn, settings.handles(kind), !alreadyDone else { return false }
        guard !name.hasPrefix("."), !name.hasPrefix("~$") else { return false }
        let lower = name.lowercased()
        let ext = (lower as NSString).pathExtension
        guard !unfinishedExtensions.contains(ext) else { return false }
        guard !ownMarks.contains(where: { lower.contains($0) }) else { return false }
        guard bytes >= minBytes(kind), bytes <= settings.maxBytes(kind) else { return false }
        if let created, now.timeIntervalSince(created) > newWithin { return false }
        return true
    }

    /// Whether a compress saved enough to keep.
    public static func worthKeeping(before: Int, after: Int) -> Bool {
        before > 0 && after > 0 && Double(after) <= Double(before) * (1 - minSaving)
    }

    /// A picture from a Retina screen: a screenshot name or a 144 dpi picture.
    public static func isRetinaScreenshot(name: String, dpi: Double?) -> Bool {
        let lower = name.lowercased()
        let looksLikeScreenshot = lower.hasPrefix("screenshot") || lower.hasPrefix("screen shot") || lower.hasPrefix("cleanshot")
            || lower.hasPrefix("capture")
        return looksLikeScreenshot && (dpi ?? 72) >= 140
    }
}

/// The originals kept for undoing a compress: anything older than the days kept, then the oldest
/// until the rest fit in `maxBytes`.
public enum KeptOriginals {
    public struct Item: Equatable, Sendable {
        public var url: URL
        public var date: Date
        public var bytes: Int

        public init(url: URL, date: Date, bytes: Int) {
            self.url = url
            self.date = date
            self.bytes = bytes
        }
    }

    public static let defaultMaxBytes = 4_000_000_000

    public static func toRemove(_ items: [Item], now: Date, keepDays: Int, maxBytes: Int = defaultMaxBytes) -> [URL] {
        let cutoff = now.addingTimeInterval(-Double(max(keepDays, 0)) * 86_400)
        var remove = items.filter { $0.date < cutoff }.map(\.url)
        var kept = items.filter { $0.date >= cutoff }.sorted { $0.date > $1.date }
        var total = kept.reduce(0) { $0 + $1.bytes }
        while total > maxBytes, let oldest = kept.popLast() {
            remove.append(oldest.url)
            total -= oldest.bytes
        }
        return remove
    }
}

/// Totals for the panel: how much the compressor has saved.
public enum SavedBytes {
    /// "1.2 GB", "340 MB", "12 KB".
    public static func text(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(bytes, 0), countStyle: .file)
    }

    /// "−82 %" (or "" when it didn't get smaller).
    public static func percent(before: Int, after: Int) -> String {
        guard before > 0, after < before else { return "" }
        return "−\(Int(((1 - Double(after) / Double(before)) * 100).rounded())) %"
    }
}
