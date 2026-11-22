import SQLite3
import XCTest
@testable import TuttoKit

/// Unread chats: Claude's unread list read out of its LevelDB web storage, each session's head
/// fields, and Codex's read receipts.
final class UnreadChatsTests: XCTestCase {

    // MARK: LevelDB pieces

    func testSnappyLiteralAndCopy() {
        // 12 bytes: the literal "abcd", then a copy of 8 from 4 back.
        let compressed: [UInt8] = [12, 0x0C, 0x61, 0x62, 0x63, 0x64, 0x11, 0x04]
        XCTAssertEqual(LevelDBReader.snappy(compressed).map { String(decoding: $0, as: UTF8.self) }, "abcdabcdabcd")
        XCTAssertNil(LevelDBReader.snappy([12, 0x0C, 0x61]), "a cut-short literal fails, never crashes")
        XCTAssertNil(LevelDBReader.snappy([5, 0x11, 0x09]), "a copy reaching before the start fails")
    }

    private func varint(_ value: Int) -> [UInt8] {
        var v = value, out: [UInt8] = []
        while v >= 0x80 { out.append(UInt8(v & 0x7F) | 0x80); v >>= 7 }
        return out + [UInt8(v)]
    }

    private func le(_ value: UInt64, _ count: Int) -> [UInt8] { (0..<count).map { UInt8((value >> (8 * UInt64($0))) & 0xFF) } }

    private let key = Array("_https://claude.ai\u{0}\u{1}epitaxy-unread-v1".utf8)
    private let suffix = Array(ClaudeUnread.storageKey.utf8)

    private func value(_ ids: [String]) -> [UInt8] {
        let json = #"{"state":{"unreadIds":[\#(ids.map { "\"\($0)\"" }.joined(separator: ","))],"explicitUnreadIds":[],"stoppedRuns":[]},"version":0}"#
        return [1] + Array(json.utf8)
    }

    private func logRecord(sequence: UInt64, puts: [([UInt8], [UInt8]?)]) -> [UInt8] {
        var batch = le(sequence, 8) + le(UInt64(puts.count), 4)
        for (k, v) in puts {
            if let v { batch += [1] + varint(k.count) + k + varint(v.count) + v } else { batch += [0] + varint(k.count) + k }
        }
        return [0, 0, 0, 0] + le(UInt64(batch.count), 2) + [1] + batch
    }

    func testLogKeepsTheNewestWrite() {
        let log = logRecord(sequence: 10, puts: [(key, value(["local_a"]))])
            + logRecord(sequence: 12, puts: [(Array("other".utf8), [1, 0x7B]), (key, value(["local_b", "local_c"]))])
        let hit = LevelDBReader.log(log, keySuffix: suffix)
        XCTAssertEqual(hit?.sequence, 13)
        XCTAssertEqual(hit?.value.map { ClaudeUnread.ids(LevelDBReader.chromiumString($0)) }, ["local_b", "local_c"])
    }

    func testLogDeletionMeansNoValue() {
        let log = logRecord(sequence: 10, puts: [(key, value(["local_a"]))]) + logRecord(sequence: 11, puts: [(key, nil)])
        let hit = LevelDBReader.log(log, keySuffix: suffix)
        XCTAssertEqual(hit?.sequence, 11)
        XCTAssertNil(hit?.value)
    }

    /// A table with one data block (stored plain or Snappy-wrapped), an index, and the footer.
    private func table(sequence: UInt64, value: [UInt8], snappy: Bool) -> [UInt8] {
        let internalKey = key + le(sequence << 8 | 1, 8)
        var block = varint(0) + varint(internalKey.count) + varint(value.count) + internalKey + value
        block += le(0, 4) + le(1, 4)  // one restart, at 0
        // Snappy-wrap as one literal (valid Snappy, just not smaller).
        let stored = snappy ? varint(block.count) + literal(block) : block
        var file = stored + [snappy ? 1 : 0] + [0, 0, 0, 0]
        let indexEntryValue = varint(0) + varint(stored.count)
        let indexKey = internalKey
        let indexBlock = varint(0) + varint(indexKey.count) + varint(indexEntryValue.count) + indexKey + indexEntryValue + le(0, 4) + le(1, 4)
        let indexOffset = file.count
        file += indexBlock + [0, 0, 0, 0, 0]
        var footer = varint(0) + varint(0) + varint(indexOffset) + varint(indexBlock.count)
        footer += [UInt8](repeating: 0, count: 40 - footer.count)
        footer += le(0xDB4775248B80FB57, 8)
        return file + footer
    }

    private func literal(_ bytes: [UInt8]) -> [UInt8] {
        // Literal length - 1 in one extra byte (tag 60) or two (tag 61).
        let n = bytes.count - 1
        return n < 256 ? [60 << 2, UInt8(n)] + bytes : [61 << 2, UInt8(n & 0xFF), UInt8(n >> 8)] + bytes
    }

    func testTableReadsPlainAndSnappyBlocks() {
        for snappy in [false, true] {
            let hit = LevelDBReader.table(table(sequence: 7, value: value(["local_x"]), snappy: snappy), keySuffix: suffix)
            XCTAssertEqual(hit?.sequence, 7, "snappy: \(snappy)")
            XCTAssertEqual(hit?.value.map { ClaudeUnread.ids(LevelDBReader.chromiumString($0)) }, ["local_x"])
        }
    }

    func testFolderPrefersTheHighestSequenceAcrossLogAndTables() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("leveldb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(table(sequence: 50, value: value(["local_old"]), snappy: true)).write(to: folder.appendingPathComponent("000010.ldb"))
        try Data(logRecord(sequence: 60, puts: [(key, value(["local_new"]))])).write(to: folder.appendingPathComponent("000011.log"))
        let cache = LevelDBReader.Cache()
        XCTAssertEqual(ClaudeUnread.ids(storage: folder, cache: cache), ["local_new"])
        // The log rolled into a new table and a fresh, empty log.
        try FileManager.default.removeItem(at: folder.appendingPathComponent("000011.log"))
        try Data(table(sequence: 60, value: value(["local_new"]), snappy: false)).write(to: folder.appendingPathComponent("000012.ldb"))
        try Data().write(to: folder.appendingPathComponent("000013.log"))
        XCTAssertEqual(ClaudeUnread.ids(storage: folder, cache: cache), ["local_new"])
    }

    /// A copy of a real storage folder, when one is given (`UNREAD_LEVELDB=<folder> swift test`).
    func testRealStorageCopyIfGiven() throws {
        guard let path = ProcessInfo.processInfo.environment["UNREAD_LEVELDB"] else { throw XCTSkip("no folder given") }
        let ids = try XCTUnwrap(ClaudeUnread.ids(storage: URL(fileURLWithPath: path)))
        print("unread ids:", ids.count)
        XCTAssertTrue(ids.allSatisfy { $0.hasPrefix("local_") })
    }

    func testChromiumStringReadsUTF16() {
        let utf16 = [UInt8(0)] + Array("hé".utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        XCTAssertEqual(LevelDBReader.chromiumString(utf16), "hé")
        XCTAssertEqual(LevelDBReader.chromiumString([1] + Array("plain".utf8)), "plain")
    }

    // MARK: Claude

    func testUnreadIdsIncludeMarkedOnesOnce() {
        let json = #"{"state":{"unreadIds":["local_a","local_b"],"explicitUnreadIds":["local_b","local_c"]},"version":0}"#
        XCTAssertEqual(ClaudeUnread.ids(json), ["local_a", "local_b", "local_c"])
        XCTAssertEqual(ClaudeUnread.ids("not json"), [])
    }

    func testEntriesKnowWhichWereMarkedUnreadByHand() {
        let json = #"{"state":{"unreadIds":["local_a","local_b"],"explicitUnreadIds":["local_b"]},"version":0}"#
        let entries = ClaudeUnread.entries(json)
        XCTAssertEqual(entries.map(\.id), ["local_a", "local_b"])
        XCTAssertEqual(entries.map(\.marked), [false, true])
    }

    /// Marked read in Tutto: hidden while the chat stays as it was; back after a new reply or after
    /// "Mark as Unread" in its app.
    func testTuttoReadMarkYieldsToTheApp() {
        let head = Data(#"{"lastTurnEdgeAt":1795312240090,"title":"NeetCode"}"#.utf8)
        let chat = ClaudeUnread.chat(id: "local_a", head: head)!
        let mark: Any = chat.state
        XCTAssertTrue(chat.isCovered(by: mark))
        XCTAssertFalse(ClaudeUnread.chat(id: "local_a", head: head, marked: true)!.isCovered(by: mark), "marked unread in Claude")
        let replied = ClaudeUnread.chat(id: "local_a", head: Data(#"{"lastTurnEdgeAt":1795312999000,"title":"NeetCode"}"#.utf8))!
        XCTAssertFalse(replied.isCovered(by: mark), "a new reply")
        XCTAssertFalse(chat.isCovered(by: nil))
        // An older mark, saved as the turn's time.
        XCTAssertTrue(chat.isCovered(by: NSNumber(value: 1_795_312_240.090)))
        XCTAssertFalse(ClaudeUnread.chat(id: "local_a", head: head, marked: true)!.isCovered(by: NSNumber(value: 1_795_312_240.090)))
        let thread = UnreadChat(tool: .codex, chatID: "t", title: "x", at: Date(), state: "u1|r1")
        XCTAssertTrue(thread.isCovered(by: "u1|r1"))
        XCTAssertFalse(UnreadChat(tool: .codex, chatID: "t", title: "x", at: Date(), state: "u1|r2").isCovered(by: "u1|r1"))
    }

    func testSessionHeadGivesTitleFolderAndTime() {
        let head = #"{"sessionId":"local_a","cwd":"/Users/me/Projects/site","lastFocusedAt":1795312186401,"lastTurnEdgeAt":1795312240090,"isArchived":false,"title":"Fix \"login\" flow","previousTitles":["#
        let chat = ClaudeUnread.chat(id: "local_a", head: Data(head.utf8))
        XCTAssertEqual(chat?.title, #"Fix "login" flow"#)
        XCTAssertEqual(chat?.folder, "/Users/me/Projects/site")
        XCTAssertEqual(chat?.at, Date(timeIntervalSince1970: 1_795_312_240.090))
        XCTAssertEqual(chat?.openURL?.absoluteString, "claude://code/continue?session=local_a")
        XCTAssertNil(ClaudeUnread.chat(id: "local_a", head: Data(#"{"isArchived":true,"title":"x"}"#.utf8)), "archived chats are left out")
        XCTAssertEqual(ClaudeUnread.chat(id: "local_b", head: Data(#"{"title":""}"#.utf8))?.title, "Untitled session")
    }

    func testChatMatchesItsRunningSession() {
        let chat = UnreadChat(tool: .claude, chatID: "local_a", title: "Site", at: Date())
        let session = AgentSession(tool: .claude, sessionID: "8db0", name: "Site", folder: "/", activity: .working, since: Date(),
                                   host: .claudeApp, hostSessionID: "local_a")
        XCTAssertTrue(chat.matches(session))
        let thread = UnreadChat(tool: .codex, chatID: "019a", title: "Fix", at: Date())
        XCTAssertTrue(thread.matches(AgentSession(tool: .codex, sessionID: "019a", name: "Fix", folder: "/", activity: .working,
                                                  since: Date(), host: .codexApp)))
        XCTAssertFalse(thread.matches(session))
    }

    func testHeadlineSkipsMarkupAndCutsShort() {
        XCTAssertEqual(UnreadChat.headline("<context>\n\n  Fix the upload test  \nmore"), "Fix the upload test")
        XCTAssertEqual(UnreadChat.headline(String(repeating: "a", count: 100), limit: 10), "aaaaaaaaa…")
    }

    // MARK: Codex

    func testCodexReadsUnreadUnarchivedThreadsNewestFirst() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("state-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        let setup = """
            CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT NOT NULL, cwd TEXT NOT NULL, updated_at INTEGER NOT NULL,
                                  updated_at_ms INTEGER, archived INTEGER NOT NULL DEFAULT 0, name TEXT);
            CREATE TABLE thread_read_receipts (thread_id TEXT PRIMARY KEY NOT NULL, first_unread_turn TEXT, revision TEXT NOT NULL,
                                               last_published_turn TEXT);
            INSERT INTO threads VALUES ('t1', 'Help me fix the login bug\nmore', '/p/site', 100, 100000, 0, NULL);
            INSERT INTO threads VALUES ('t2', 'whatever', '/p/app', 200, 200000, 0, 'Renamed thread');
            INSERT INTO threads VALUES ('t3', 'read already', '/p/x', 300, 300000, 0, NULL);
            INSERT INTO threads VALUES ('t4', 'archived', '/p/x', 400, 400000, 1, NULL);
            INSERT INTO threads VALUES ('t5', 'named in the index', '/p/x', 50, NULL, 0, NULL);
            INSERT INTO thread_read_receipts VALUES ('t1', 'u1', 'r', 'u1'), ('t2', 'u2', 'r', 'u2'), ('t3', NULL, 'r', 'u3'),
                                                    ('t4', 'u4', 'r', 'u4'), ('t5', 'u5', 'r', 'u5');
            """
        XCTAssertEqual(sqlite3_exec(db, setup, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let chats = try XCTUnwrap(CodexUnread.chats(database: path, names: ["t5": "Index name"]))
        XCTAssertEqual(chats.map(\.chatID), ["t2", "t1", "t5"])
        XCTAssertEqual(chats.map(\.title), ["Renamed thread", "Help me fix the login bug", "Index name"])
        XCTAssertEqual(chats[2].at, Date(timeIntervalSince1970: 50), "seconds when there's no millisecond time")
        XCTAssertEqual(chats[0].openURL?.absoluteString, "codex://threads/t2")
        XCTAssertEqual(chats[0].state, "u2|r", "its read receipt, so marking it unread in Codex shows it again")
        XCTAssertNil(CodexUnread.chats(database: "/nonexistent/state.sqlite"))
    }
}
