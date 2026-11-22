//
//  UnreadChats.swift
//  TuttoKit
//
//  Chats you haven't read yet, as Claude's and Codex's own apps count them (Bryan, 2026-11-21:
//  "if a chat is unread ... click in the agents menu to read the unread chat ... for both claude
//  and codex"). Read-only, from what the apps already keep:
//
//  - Claude's app keeps its sidebar's unread dots in its web storage (a LevelDB folder), under
//    `epitaxy-unread-v1`: `{"state":{"unreadIds":["local_…"],"explicitUnreadIds":[…]}}`. Each
//    session's title and when its last turn ended are in claude-code-sessions/…/local_….json.
//  - Codex keeps a read receipt per thread in ~/.codex/state_5.sqlite: `first_unread_turn` is
//    set when a turn lands that you haven't seen, and cleared when you open the thread.
//
//  Opening the chat in its app marks it read there, which these files then say.
//

import Foundation
import SQLite3

/// One chat with something you haven't read.
public struct UnreadChat: Identifiable, Equatable, Sendable {
    public var tool: AgentTool
    /// Claude's `local_…` session id, or Codex's thread id.
    public var chatID: String
    public var title: String
    public var folder: String?
    /// When its latest turn ended.
    public var at: Date

    public var id: String { "\(tool.rawValue):\(chatID)" }

    public init(tool: AgentTool, chatID: String, title: String, folder: String? = nil, at: Date) {
        self.tool = tool
        self.chatID = chatID
        self.title = title
        self.folder = folder
        self.at = at
    }

    /// Opens exactly this chat in its app.
    public var openURL: URL? {
        switch tool {
        case .claude: URL(string: "claude://code/continue?session=\(chatID)")
        case .codex: URL(string: "codex://threads/\(chatID)")
        }
    }

    /// True when `session` is this chat (a running Claude session's host id, a Codex thread id).
    public func matches(_ session: AgentSession) -> Bool {
        guard session.tool == tool else { return false }
        return tool == .claude ? session.hostSessionID == chatID : session.sessionID == chatID
    }

    /// Newest first.
    public static func ordered(_ chats: [UnreadChat]) -> [UnreadChat] {
        chats.sorted { $0.at != $1.at ? $0.at > $1.at : $0.id < $1.id }
    }

    /// A first message as a title: its first line, trimmed and cut short.
    public static func headline(_ text: String, limit: Int = 80) -> String {
        let line = text.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("<") && !$0.hasPrefix("#") } ?? ""
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }
}

// MARK: - Claude

public enum ClaudeUnread {
    public static let storageKey = "epitaxy-unread-v1"

    /// The ids in the stored state, unread and marked unread.
    public static func ids(_ value: String) -> [String] {
        guard let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = object["state"] as? [String: Any] else { return [] }
        var seen = Set<String>(), ids: [String] = []
        for key in ["unreadIds", "explicitUnreadIds"] {
            for id in state[key] as? [String] ?? [] where seen.insert(id).inserted { ids.append(id) }
        }
        return ids
    }

    /// The unread ids as the app last stored them, from its LevelDB folder.
    public static func ids(storage folder: URL, cache: LevelDBReader.Cache? = nil) -> [String]? {
        guard let value = LevelDBReader.latest(in: folder, keySuffix: Array(storageKey.utf8), cache: cache) else { return nil }
        return ids(LevelDBReader.chromiumString(value))
    }

    /// What a session's record starts with: its title, folder, when its last turn ended, whether
    /// it's archived. Only the head of the file is needed (the fields come first; the rest is
    /// snapshots).
    public static func chat(id: String, head: Data) -> UnreadChat? {
        let text = String(decoding: head, as: UTF8.self)
        if JSONHead.bool("isArchived", in: text) == true { return nil }
        let title = JSONHead.string("title", in: text).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled session"
        let millis = JSONHead.number("lastTurnEdgeAt", in: text) ?? JSONHead.number("lastActivityAt", in: text)
            ?? JSONHead.number("createdAt", in: text) ?? 0
        return UnreadChat(tool: .claude, chatID: id, title: title, folder: JSONHead.string("cwd", in: text),
                          at: Date(timeIntervalSince1970: millis / 1000))
    }
}

/// Reads one field from the start of a JSON object without parsing the rest (a session record is a
/// few hundred kilobytes; its fields sit in the first kilobyte or two).
enum JSONHead {
    static func raw(_ key: String, in text: String) -> Substring? {
        guard let range = text.range(of: "\"\(key)\":") else { return nil }
        return text[range.upperBound...].drop { $0 == " " }
    }

    static func string(_ key: String, in text: String) -> String? {
        guard let rest = raw(key, in: text), rest.first == "\"" else { return nil }
        var escaped = false
        var end = rest.index(after: rest.startIndex)
        while end < rest.endIndex {
            let c = rest[end]
            if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { break }
            end = rest.index(after: end)
        }
        guard end < rest.endIndex else { return nil }
        let literal = rest[rest.startIndex...end]
        return try? JSONSerialization.jsonObject(with: Data(literal.utf8), options: .fragmentsAllowed) as? String
    }

    static func number(_ key: String, in text: String) -> Double? {
        guard let rest = raw(key, in: text) else { return nil }
        return Double(rest.prefix { "0123456789.-eE+".contains($0) })
    }

    static func bool(_ key: String, in text: String) -> Bool? {
        guard let rest = raw(key, in: text) else { return nil }
        if rest.hasPrefix("true") { return true }
        if rest.hasPrefix("false") { return false }
        return nil
    }
}

// MARK: - Codex

public enum CodexUnread {
    /// Unread, unarchived threads from Codex's state database, newest first.
    public static func chats(database path: String, names: [String: String] = [:], limit: Int = 50) -> [UnreadChat]? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        let sql = """
            SELECT t.id, COALESCE(t.name, ''), t.title, t.cwd, COALESCE(t.updated_at_ms, t.updated_at * 1000)
            FROM thread_read_receipts r JOIN threads t ON t.id = r.thread_id
            WHERE r.first_unread_turn IS NOT NULL AND t.archived = 0
            ORDER BY 5 DESC LIMIT \(limit)
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        func text(_ i: Int32) -> String { sqlite3_column_text(statement, i).map { String(cString: $0) } ?? "" }
        var chats: [UnreadChat] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = text(0)
            let name = [text(1), names[id] ?? ""].first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let title = name ?? UnreadChat.headline(text(2))
            chats.append(UnreadChat(tool: .codex, chatID: id, title: title.isEmpty ? "Untitled thread" : title,
                                    folder: text(3), at: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4) / 1000)))
        }
        return chats
    }
}

// MARK: - LevelDB

/// Just enough of LevelDB to read one key, read-only, from a folder another app has open: its log
/// (the latest writes) and its tables (compacted, often Snappy-compressed). The newest sequence
/// number wins; a deletion means there's no value.
public enum LevelDBReader {
    /// Tables never change once written: what each held for the key, by file name and size.
    public final class Cache: @unchecked Sendable {
        var tables: [String: Hit?] = [:]
        let lock = NSLock()
        public init() {}
    }

    struct Hit: Equatable {
        var sequence: UInt64
        var value: [UInt8]?
    }

    public static func latest(in folder: URL, keySuffix: [UInt8], cache: Cache? = nil) -> [UInt8]? {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var best: Hit?
        func consider(_ hit: Hit?) {
            if let hit, hit.sequence >= (best?.sequence ?? 0) { best = hit }
        }
        for name in files where name.hasSuffix(".ldb") || name.hasSuffix(".sst") {
            let path = folder.appendingPathComponent(name).path
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            let key = "\(name):\(size)"
            if let cache {
                cache.lock.lock()
                let known = cache.tables[key]
                cache.lock.unlock()
                if let known { consider(known); continue }
            }
            guard let bytes = FileManager.default.contents(atPath: path).map([UInt8].init) else { continue }
            let hit = table(bytes, keySuffix: keySuffix)
            if let cache {
                cache.lock.lock()
                cache.tables[key] = .some(hit)
                cache.lock.unlock()
            }
            consider(hit)
        }
        for name in files where name.hasSuffix(".log") {
            guard let bytes = FileManager.default.contents(atPath: folder.appendingPathComponent(name).path).map([UInt8].init) else { continue }
            consider(log(bytes, keySuffix: keySuffix))
        }
        return best?.value
    }

    /// A Chromium web-storage value: a leading 1 means Latin-1, a 0 UTF-16 little-endian.
    public static func chromiumString(_ value: [UInt8]) -> String {
        guard let first = value.first else { return "" }
        let body = value.dropFirst()
        if first == 0 {
            var units: [UInt16] = []
            units.reserveCapacity(body.count / 2)
            var i = body.startIndex
            while i + 1 < body.endIndex { units.append(UInt16(body[i]) | UInt16(body[i + 1]) << 8); i += 2 }
            return String(decoding: units, as: UTF16.self)
        }
        return String(decoding: first == 1 ? Array(body) : value, as: UTF8.self)
    }

    static func hasSuffix(_ key: ArraySlice<UInt8>, _ suffix: [UInt8]) -> Bool {
        key.count >= suffix.count && key.suffix(suffix.count).elementsEqual(suffix)
    }

    // MARK: Log

    /// The write-ahead log: 32 KB blocks of records (whole, or split first/middle/last), each a
    /// write batch: its first sequence number, a count, then puts and deletes.
    static func log(_ bytes: [UInt8], keySuffix: [UInt8]) -> Hit? {
        var best: Hit?
        var pending: [UInt8] = []
        var offset = 0
        while offset + 7 <= bytes.count {
            let blockLeft = 32_768 - offset % 32_768
            if blockLeft < 7 { offset += blockLeft; continue }
            let length = Int(bytes[offset + 4]) | Int(bytes[offset + 5]) << 8
            let type = bytes[offset + 6]
            let start = offset + 7
            guard start + length <= bytes.count else { break }
            if type == 0 && length == 0 { offset += blockLeft; continue }  // preallocated zeros
            let payload = bytes[start..<(start + length)]
            switch type {
            case 1: if let hit = batch(Array(payload), keySuffix: keySuffix), hit.sequence >= (best?.sequence ?? 0) { best = hit }
            case 2: pending = Array(payload)
            case 3: pending += payload
            case 4:
                pending += payload
                if let hit = batch(pending, keySuffix: keySuffix), hit.sequence >= (best?.sequence ?? 0) { best = hit }
                pending = []
            default: break
            }
            offset = start + length
        }
        return best
    }

    static func batch(_ b: [UInt8], keySuffix: [UInt8]) -> Hit? {
        guard b.count >= 12 else { return nil }
        var sequence: UInt64 = 0
        for i in 0..<8 { sequence |= UInt64(b[i]) << (8 * UInt64(i)) }
        var i = 12
        var best: Hit?
        var index: UInt64 = 0
        while i < b.count {
            let kind = b[i]; i += 1
            guard let keyLength = varint(b, &i), i + keyLength <= b.count else { return best }
            let key = b[i..<(i + keyLength)]; i += keyLength
            var value: [UInt8]?
            if kind == 1 {
                guard let valueLength = varint(b, &i), i + valueLength <= b.count else { return best }
                value = Array(b[i..<(i + valueLength)]); i += valueLength
            } else if kind != 0 { return best }
            if hasSuffix(key, keySuffix) { best = Hit(sequence: sequence + index, value: value) }
            index += 1
        }
        return best
    }

    // MARK: Tables

    /// A sorted table: a footer pointing at the index block, whose entries point at data blocks.
    static func table(_ bytes: [UInt8], keySuffix: [UInt8]) -> Hit? {
        guard bytes.count >= 48 else { return nil }
        var i = bytes.count - 48
        guard varint64(bytes, &i) != nil, varint64(bytes, &i) != nil,  // the metaindex
              let indexOffset = varint(bytes, &i), let indexSize = varint(bytes, &i),
              let index = block(bytes, offset: indexOffset, size: indexSize) else { return nil }
        var best: Hit?
        entries(index) { _, handle in
            let h = Array(handle)
            var j = 0
            guard let offset = varint(h, &j), let size = varint(h, &j), let data = block(bytes, offset: offset, size: size) else { return }
            entries(data) { key, value in
                guard key.count >= 8 else { return }
                let user = key.dropLast(8)
                guard hasSuffix(user, keySuffix) else { return }
                var tag: UInt64 = 0
                for (n, byte) in key.suffix(8).enumerated() { tag |= UInt64(byte) << (8 * UInt64(n)) }
                let hit = Hit(sequence: tag >> 8, value: tag & 0xFF == 1 ? Array(value) : nil)
                if hit.sequence >= (best?.sequence ?? 0) { best = hit }
            }
        }
        return best
    }

    /// A block's contents, uncompressed (its trailer: one byte of compression type, four of checksum).
    static func block(_ bytes: [UInt8], offset: Int, size: Int) -> [UInt8]? {
        guard offset >= 0, size >= 0, offset + size + 5 <= bytes.count else { return nil }
        let raw = Array(bytes[offset..<(offset + size)])
        switch bytes[offset + size] {
        case 0: return raw
        case 1: return snappy(raw)
        default: return nil
        }
    }

    /// Each key and value in a block (keys share a prefix with the one before).
    static func entries(_ b: [UInt8], _ visit: (ArraySlice<UInt8>, ArraySlice<UInt8>) -> Void) {
        guard b.count >= 4 else { return }
        let restarts = Int(b[b.count - 4]) | Int(b[b.count - 3]) << 8 | Int(b[b.count - 2]) << 16 | Int(b[b.count - 1]) << 24
        let end = b.count - 4 - restarts * 4
        guard end >= 0 else { return }
        var i = 0
        var key: [UInt8] = []
        while i < end {
            guard let shared = varint(b, &i), let unshared = varint(b, &i), let valueLength = varint(b, &i),
                  shared <= key.count, i + unshared + valueLength <= end else { return }
            key = Array(key.prefix(shared)) + b[i..<(i + unshared)]
            i += unshared
            visit(key[...], b[i..<(i + valueLength)])
            i += valueLength
        }
    }

    // MARK: Bits

    static func varint(_ b: [UInt8], _ i: inout Int) -> Int? {
        varint64(b, &i).flatMap { $0 <= UInt64(Int.max) ? Int($0) : nil }
    }

    static func varint64(_ b: [UInt8], _ i: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while i < b.count, shift < 64 {
            let byte = b[i]; i += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }

    /// Snappy's raw format: the length, then literals and copies of what came before.
    static func snappy(_ b: [UInt8]) -> [UInt8]? {
        var i = 0
        guard let length = varint(b, &i), length < 64 << 20 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(length)
        while i < b.count {
            let tag = b[i]; i += 1
            switch tag & 3 {
            case 0:
                var n = Int(tag >> 2)
                if n >= 60 {
                    let extra = n - 59
                    guard i + extra <= b.count else { return nil }
                    n = 0
                    for k in 0..<extra { n |= Int(b[i + k]) << (8 * k) }
                    i += extra
                }
                n += 1
                guard i + n <= b.count else { return nil }
                out += b[i..<(i + n)]
                i += n
            default:
                var n: Int, distance: Int
                switch tag & 3 {
                case 1:
                    guard i < b.count else { return nil }
                    n = 4 + Int((tag >> 2) & 7)
                    distance = Int(tag >> 5) << 8 | Int(b[i]); i += 1
                case 2:
                    guard i + 2 <= b.count else { return nil }
                    n = 1 + Int(tag >> 2)
                    distance = Int(b[i]) | Int(b[i + 1]) << 8; i += 2
                default:
                    guard i + 4 <= b.count else { return nil }
                    n = 1 + Int(tag >> 2)
                    distance = Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24; i += 4
                }
                guard distance > 0, distance <= out.count else { return nil }
                let from = out.count - distance
                for k in 0..<n { out.append(out[from + k]) }
            }
        }
        return out.count == length ? out : nil
    }
}
