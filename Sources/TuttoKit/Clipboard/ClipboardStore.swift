//
//  ClipboardStore.swift
//  Tutto
//
//  Clipboard history on disk: a small JSON index plus one file per image or rich-text
//  payload, in ~/Library/Application Support/Tutto/Clipboard. Only the index lives in
//  memory; images are read when something shows them.
//

import CryptoKit
import Foundation

public struct ClipItem: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case text, link, image, file

        public var title: String {
            switch self {
            case .text: "Text"
            case .link: "Link"
            case .image: "Image"
            case .file: "File"
            }
        }
    }

    public var id: UUID
    public var kind: Kind
    /// Plain text for text and links; file names for files.
    public var text: String?
    /// Stored payload file names (inside the blobs folder).
    public var imageFile: String?
    public var richTextFile: String?
    public var imageWidth: Int?
    public var imageHeight: Int?
    public var filePaths: [String]?
    public var sourceBundleID: String?
    public var sourceName: String?
    public var firstCopied: Date
    public var lastCopied: Date
    public var copyCount: Int
    public var pinned: Bool
    public var contentHash: String
    public var byteSize: Int

    public init(id: UUID = UUID(), kind: Kind, text: String? = nil, imageFile: String? = nil, richTextFile: String? = nil,
                imageWidth: Int? = nil, imageHeight: Int? = nil, filePaths: [String]? = nil,
                sourceBundleID: String? = nil, sourceName: String? = nil, date: Date = Date(),
                pinned: Bool = false, contentHash: String, byteSize: Int) {
        self.id = id
        self.kind = kind
        self.text = text
        self.imageFile = imageFile
        self.richTextFile = richTextFile
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.filePaths = filePaths
        self.sourceBundleID = sourceBundleID
        self.sourceName = sourceName
        self.firstCopied = date
        self.lastCopied = date
        self.copyCount = 1
        self.pinned = pinned
        self.contentHash = contentHash
        self.byteSize = byteSize
    }

    /// One line for lists.
    public var title: String {
        switch kind {
        case .text, .link:
            let line = (text ?? "").split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? "Whitespace" : String(trimmed.prefix(300))
        case .image:
            if let imageWidth, let imageHeight { return "Image \(imageWidth) × \(imageHeight)" }
            return "Image"
        case .file:
            let names = (filePaths ?? []).map { ($0 as NSString).lastPathComponent }
            if names.count > 1 { return "\(names[0]) and \(names.count - 1) more" }
            return names.first ?? "File"
        }
    }

    /// Text searched by the palette.
    public var searchText: String {
        [text, filePaths?.joined(separator: " "), sourceName, kind == .image ? "image picture screenshot" : nil]
            .compactMap { $0 }.joined(separator: " ")
    }
}

public enum ClipFilter: String, CaseIterable, Sendable {
    case all, text, images, files, links

    public var title: String {
        switch self {
        case .all: "All"
        case .text: "Text"
        case .images: "Images"
        case .files: "Files"
        case .links: "Links"
        }
    }

    public func matches(_ item: ClipItem) -> Bool {
        switch self {
        case .all: true
        case .text: item.kind == .text
        case .images: item.kind == .image
        case .files: item.kind == .file
        case .links: item.kind == .link
        }
    }
}

/// What a capture hands to the store.
public struct ClipPayload: Sendable {
    public var kind: ClipItem.Kind
    public var text: String?
    public var image: Data?        // PNG
    public var imageWidth: Int?
    public var imageHeight: Int?
    public var richText: Data?     // RTF
    public var filePaths: [String]?
    public var sourceBundleID: String?
    public var sourceName: String?

    public init(kind: ClipItem.Kind, text: String? = nil, image: Data? = nil, imageWidth: Int? = nil, imageHeight: Int? = nil,
                richText: Data? = nil, filePaths: [String]? = nil, sourceBundleID: String? = nil, sourceName: String? = nil) {
        self.kind = kind
        self.text = text
        self.image = image
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.richText = richText
        self.filePaths = filePaths
        self.sourceBundleID = sourceBundleID
        self.sourceName = sourceName
    }

    var hash: String {
        var hasher = SHA256()
        hasher.update(data: Data(kind.rawValue.utf8))
        if let text { hasher.update(data: Data(text.utf8)) }
        if let image { hasher.update(data: image) }
        if let filePaths { hasher.update(data: Data(filePaths.joined(separator: "\n").utf8)) }
        return hasher.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

public final class ClipboardStore: @unchecked Sendable {
    public private(set) var items: [ClipItem] = []
    public var maxItems: Int { didSet { prune() } }
    public var maxAge: TimeInterval? { didSet { prune() } }
    /// Images are big (a full-screen capture is ~1.5 MB); keep fewer of them than text.
    public var maxImages: Int = 100 { didSet { prune() } }

    public let directory: URL
    private var blobs: URL { directory.appendingPathComponent("blobs", isDirectory: true) }
    private var indexURL: URL { directory.appendingPathComponent("history.json") }
    private var saveWork: DispatchWorkItem?
    private let queue = DispatchQueue(label: "ca.bryanyao.Tutto.clipboard-store", qos: .utility)

    public init(directory: URL, maxItems: Int = 500, maxAge: TimeInterval? = nil) {
        self.directory = directory
        self.maxItems = maxItems
        self.maxAge = maxAge
        try? FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let saved = try? JSONDecoder().decode([ClipItem].self, from: data) {
            items = saved
        }
        prune()
    }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tutto/Clipboard", isDirectory: true)
    }

    // MARK: Adding

    /// Adds a capture, or moves an identical earlier one to the top. Returns the item.
    @discardableResult
    public func add(_ payload: ClipPayload, date: Date = Date()) -> ClipItem {
        let hash = payload.hash
        if let index = items.firstIndex(where: { $0.contentHash == hash }) {
            var item = items.remove(at: index)
            item.lastCopied = date
            item.copyCount += 1
            if let name = payload.sourceName { item.sourceName = name }
            if let id = payload.sourceBundleID { item.sourceBundleID = id }
            items.insert(item, at: 0)
            scheduleSave()
            return item
        }
        let id = UUID()
        var imageFile: String?
        var richFile: String?
        var size = payload.text?.utf8.count ?? 0
        if let image = payload.image {
            imageFile = "\(id.uuidString).png"
            writeBlob(image, named: imageFile!)
            size += image.count
        }
        if let rich = payload.richText {
            richFile = "\(id.uuidString).rtf"
            writeBlob(rich, named: richFile!)
            size += rich.count
        }
        let item = ClipItem(id: id, kind: payload.kind, text: payload.text, imageFile: imageFile, richTextFile: richFile,
                            imageWidth: payload.imageWidth, imageHeight: payload.imageHeight, filePaths: payload.filePaths,
                            sourceBundleID: payload.sourceBundleID, sourceName: payload.sourceName, date: date,
                            contentHash: hash, byteSize: size)
        items.insert(item, at: 0)
        prune()
        scheduleSave()
        return item
    }

    /// Marks an item as just used (pasted from the palette): it moves to the top.
    public func touch(_ id: UUID, date: Date = Date()) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items.remove(at: index)
        item.lastCopied = date
        item.copyCount += 1
        items.insert(item, at: 0)
        scheduleSave()
    }

    public func setPinned(_ id: UUID, _ pinned: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].pinned = pinned
        scheduleSave()
    }

    public func remove(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        deleteBlobs(of: items.remove(at: index))
        scheduleSave()
    }

    /// Clears everything except pinned items.
    public func clearUnpinned() {
        let removed = items.filter { !$0.pinned }
        items.removeAll { !$0.pinned }
        removed.forEach(deleteBlobs)
        scheduleSave()
    }

    public func clearAll() {
        let removed = items
        items.removeAll()
        removed.forEach(deleteBlobs)
        scheduleSave()
    }

    // MARK: Reading

    /// Pinned first, then most recent; filtered by type and a case-insensitive query.
    public func search(_ query: String, filter: ClipFilter = .all) -> [ClipItem] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        let matching = items.filter { item in
            guard filter.matches(item) else { return false }
            guard !words.isEmpty else { return true }
            let haystack = item.searchText.lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
        return matching.filter(\.pinned) + matching.filter { !$0.pinned }
    }

    public func imageURL(for item: ClipItem) -> URL? {
        item.imageFile.map { blobs.appendingPathComponent($0) }
    }

    public func richTextURL(for item: ClipItem) -> URL? {
        item.richTextFile.map { blobs.appendingPathComponent($0) }
    }

    public var totalBytes: Int { items.reduce(0) { $0 + $1.byteSize } }

    // MARK: Persistence

    /// Writes the index now (used on quit).
    public func flush() {
        saveWork?.cancel()
        let snapshot = items
        let url = indexURL
        queue.sync { Self.write(snapshot, to: url) }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let snapshot = items
        let url = indexURL
        let work = DispatchWorkItem { Self.write(snapshot, to: url) }
        saveWork = work
        queue.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private static func write(_ items: [ClipItem], to url: URL) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func writeBlob(_ data: Data, named name: String) {
        let url = blobs.appendingPathComponent(name)
        queue.async { try? data.write(to: url, options: .atomic) }
    }

    private func deleteBlobs(of item: ClipItem) {
        let urls = [imageURL(for: item), richTextURL(for: item)].compactMap { $0 }
        queue.async { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
    }

    private func prune() {
        var removed: [ClipItem] = []
        if let maxAge {
            let cutoff = Date().addingTimeInterval(-maxAge)
            removed += items.filter { !$0.pinned && $0.lastCopied < cutoff }
            items.removeAll { !$0.pinned && $0.lastCopied < cutoff }
        }
        let images = items.filter { !$0.pinned && $0.kind == .image }
        if images.count > maxImages {
            let drop = Set(images.suffix(images.count - maxImages).map(\.id))
            removed += items.filter { drop.contains($0.id) }
            items.removeAll { drop.contains($0.id) }
        }
        let unpinned = items.filter { !$0.pinned }
        if unpinned.count > maxItems {
            let drop = Set(unpinned.suffix(unpinned.count - maxItems).map(\.id))
            removed += items.filter { drop.contains($0.id) }
            items.removeAll { drop.contains($0.id) }
        }
        if !removed.isEmpty {
            removed.forEach(deleteBlobs)
            scheduleSave()
        }
    }

    /// Recognizes a copied link (one line, a URL with a scheme people paste).
    public static func isLink(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace), trimmed.count < 4000,
              let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "mailto", "ftp", "ssh", "file"].contains(scheme) && (url.host != nil || scheme == "mailto")
    }
}
