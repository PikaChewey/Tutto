import XCTest
@testable import TuttoKit

final class ClipboardStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("tutto-clip-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testDuplicatesMoveToTopInsteadOfRepeating() {
        let store = ClipboardStore(directory: directory)
        store.add(ClipPayload(kind: .text, text: "one"))
        store.add(ClipPayload(kind: .text, text: "two"))
        store.add(ClipPayload(kind: .text, text: "one"))
        XCTAssertEqual(store.items.map(\.text), ["one", "two"])
        XCTAssertEqual(store.items.first?.copyCount, 2)
    }

    func testSearchFiltersAndPinsFirst() {
        let store = ClipboardStore(directory: directory)
        store.add(ClipPayload(kind: .text, text: "hello world"))
        let link = store.add(ClipPayload(kind: .link, text: "https://apple.com"))
        store.add(ClipPayload(kind: .text, text: "goodbye"))
        store.setPinned(link.id, true)
        XCTAssertEqual(store.search("").first?.id, link.id)
        XCTAssertEqual(store.search("HELLO").map(\.text), ["hello world"])
        XCTAssertEqual(store.search("", filter: .links).count, 1)
        XCTAssertEqual(store.search("wor hel").count, 1, "every word must match, in any order")
    }

    func testLimitKeepsPinnedItems() {
        let store = ClipboardStore(directory: directory, maxItems: 3)
        let pinned = store.add(ClipPayload(kind: .text, text: "keep me"))
        store.setPinned(pinned.id, true)
        for i in 0..<10 { store.add(ClipPayload(kind: .text, text: "item \(i)")) }
        XCTAssertTrue(store.items.contains { $0.id == pinned.id })
        XCTAssertEqual(store.items.filter { !$0.pinned }.count, 3)
        XCTAssertEqual(store.items.filter { !$0.pinned }.first?.text, "item 9")
    }

    func testPersistsAcrossLaunchesWithImages() throws {
        let store = ClipboardStore(directory: directory)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let image = store.add(ClipPayload(kind: .image, image: png, imageWidth: 10, imageHeight: 20))
        store.add(ClipPayload(kind: .text, text: "persist"))
        store.flush()
        Thread.sleep(forTimeInterval: 0.2)  // blob writes are async
        let reopened = ClipboardStore(directory: directory)
        XCTAssertEqual(reopened.items.count, 2)
        let url = try XCTUnwrap(reopened.imageURL(for: reopened.items.first { $0.id == image.id }!))
        XCTAssertEqual(try Data(contentsOf: url), png)
    }

    func testRemoveDeletesBlob() throws {
        let store = ClipboardStore(directory: directory)
        let item = store.add(ClipPayload(kind: .image, image: Data([1, 2, 3]), imageWidth: 1, imageHeight: 1))
        Thread.sleep(forTimeInterval: 0.2)
        let url = try XCTUnwrap(store.imageURL(for: item))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        store.remove(item.id)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testLinkDetection() {
        XCTAssertTrue(ClipboardStore.isLink("https://example.com/a?b=c"))
        XCTAssertTrue(ClipboardStore.isLink("  mailto:me@example.com\n"))
        XCTAssertFalse(ClipboardStore.isLink("see https://example.com"))
        XCTAssertFalse(ClipboardStore.isLink("example.com"))
        XCTAssertFalse(ClipboardStore.isLink("javascript:alert(1)"))
    }

    func testTitles() {
        XCTAssertEqual(ClipItem(kind: .text, text: "\n  first line\nsecond", contentHash: "a", byteSize: 1).title, "first line",
                       "leading blank lines are skipped")
        XCTAssertEqual(ClipItem(kind: .text, text: "   ", contentHash: "w", byteSize: 1).title, "Whitespace")
        XCTAssertEqual(ClipItem(kind: .text, text: "first line\nsecond", contentHash: "b", byteSize: 1).title, "first line")
        XCTAssertEqual(ClipItem(kind: .file, filePaths: ["/a/b.txt", "/a/c.txt"], contentHash: "c", byteSize: 1).title, "b.txt and 1 more")
    }
}
