import Foundation
import XCTest
@testable import TuttoKit

final class DiskScannerTests: XCTestCase {
    private var root: URL!
    private var outside: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("tutto-diskmap-\(UUID().uuidString)")
        root = base.appendingPathComponent("root")
        outside = base.appendingPathComponent("outside")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("a/deep/deeper"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("b"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Tool.app/Contents/MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("many"), withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(count: 3_000_000).write(to: root.appendingPathComponent("a/big.bin"))
        try Data(count: 2_000_000).write(to: root.appendingPathComponent("a/deep/deeper/two.bin"))
        try Data("hello".utf8).write(to: root.appendingPathComponent("a/small.txt"))
        try Data(count: 1_500_000).write(to: root.appendingPathComponent("Tool.app/Contents/MacOS/Tool"))
        for i in 0..<50 { try Data(count: 5_000).write(to: root.appendingPathComponent("many/f\(i).txt")) }
        // A hard link to big.bin, and a link to a big file outside the folder.
        try fm.linkItem(at: root.appendingPathComponent("a/big.bin"), to: root.appendingPathComponent("b/same.bin"))
        try Data(count: 4_000_000).write(to: outside.appendingPathComponent("huge.bin"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("link-out"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: root.appendingPathComponent("link-file"), withDestinationURL: outside.appendingPathComponent("huge.bin"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private func scan(_ keepAtLeast: Int64 = 1_000_000) throws -> DiskScanResult {
        var options = DiskScanOptions(root: root.path, title: "Fixture")
        options.keepAtLeast = keepAtLeast
        return try XCTUnwrap(DiskScanner().run(options))
    }

    /// What `du` says, in KiB (it counts allocated blocks and each hard link once too).
    private func du(_ url: URL) throws -> Int64 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-sk", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return Int64(text.split(separator: "\t").first ?? "") ?? -1
    }

    func testSizesAddUpAndMatchDu() throws {
        let result = try scan()
        let tree = result.root
        XCTAssertEqual(tree.name, "Fixture")
        XCTAssertEqual(tree.bytes / 1024, try du(root))
        // Every folder's size is its own entry plus its children (merged ones included).
        func check(_ node: DiskNode) {
            guard node.kind == .folder else { return }
            let sum = node.children.reduce(Int64(0)) { $0 + $1.bytes }
            XCTAssertLessThanOrEqual(sum, node.bytes, node.path)
            XCTAssertLessThan(node.bytes - sum, 64 * 1024, "only the folder's own entry is left over: \(node.path)")
            node.children.forEach(check)
        }
        check(tree)
        // 4 folders + 5 files under a, b, many (50 files) + its folder, the app (4 items), 2 links, and the root.
        XCTAssertEqual(tree.items, 1 + (1 + 1 + 1 + 1 + 1 + 1) + (1 + 1) + (1 + 50) + 4 + 2)
    }

    func testHardLinkCountsOnce() throws {
        let tree = try scan().root
        // Whichever name is met first carries the size (folders are read in parallel); the other
        // adds nothing, so its folder may fall under the threshold and merge into "smaller items".
        let a = tree.find(root.appendingPathComponent("a").path)?.bytes ?? 0
        let b = tree.find(root.appendingPathComponent("b").path)?.bytes ?? 0
        XCTAssertGreaterThanOrEqual(a + b, 3_000_000 + 2_000_000)
        XCTAssertLessThan(a + b, 2 * 3_000_000 + 2_000_000, "the second name for big.bin adds nothing")
        XCTAssertLessThan(tree.bytes, 3_000_000 + 2_000_000 + 1_500_000 + 500_000)
    }

    func testLinksAreNotFollowed() throws {
        let tree = try scan()
        // huge.bin (4 MB) lives outside; reaching it through either link would push the total past it.
        XCTAssertLessThan(tree.root.bytes, 7_500_000)
        XCTAssertNil(tree.root.find(root.appendingPathComponent("link-out/huge.bin").path))
    }

    func testPackageIsOneItem() throws {
        let tree = try scan().root
        let app = try XCTUnwrap(tree.find(root.appendingPathComponent("Tool.app").path))
        XCTAssertEqual(app.kind, .package)
        XCTAssertTrue(app.children.isEmpty)
        XCTAssertFalse(app.canOpen)
        XCTAssertEqual(app.items, 4)
        XCTAssertGreaterThanOrEqual(app.bytes, 1_500_000)
    }

    func testSmallItemsMergeIntoOneNode() throws {
        let tree = try scan().root
        // "many" is 250 KB in all: under the threshold, so it's part of the root's smaller items.
        XCTAssertNil(tree.find(root.appendingPathComponent("many").path))
        let smaller = try XCTUnwrap(tree.children.last)
        XCTAssertEqual(smaller.kind, .smaller)
        XCTAssertGreaterThanOrEqual(smaller.items, 51)
        // With a low threshold it's kept, and its files merge under it instead.
        let fine = try scan(100_000).root
        let many = try XCTUnwrap(fine.find(root.appendingPathComponent("many").path))
        XCTAssertEqual(many.children.count, 1)
        XCTAssertEqual(many.children.first?.items, 50)
    }

    func testChildrenAreBiggestFirstAndCapped() throws {
        var options = DiskScanOptions(root: root.path, title: "Fixture")
        options.keepAtLeast = 1
        options.maxChildren = 10
        let tree = try XCTUnwrap(DiskScanner().run(options)).root
        let many = try XCTUnwrap(tree.find(root.appendingPathComponent("many").path))
        XCTAssertEqual(many.children.count, 11)
        XCTAssertEqual(many.children.last?.kind, .smaller)
        XCTAssertEqual(many.children.last?.items, 40)
        let sizes = tree.children.filter { $0.kind != .smaller }.map(\.bytes)
        XCTAssertEqual(sizes, sizes.sorted(by: >))
    }

    func testCancelStops() throws {
        let scanner = DiskScanner()
        scanner.cancel()
        XCTAssertNil(scanner.run(DiskScanOptions(root: root.path, title: "Fixture")))
        XCTAssertLessThanOrEqual(scanner.progress.items, 1)
    }

    func testProgressCountsEverything() throws {
        let scanner = DiskScanner()
        var options = DiskScanOptions(root: root.path, title: "Fixture")
        options.keepAtLeast = 1_000_000
        let result = try XCTUnwrap(scanner.run(options))
        XCTAssertEqual(scanner.progress.items, result.root.items)
        XCTAssertEqual(scanner.progress.bytes, result.root.bytes)
    }

    func testSkippedFoldersAndUnreadableRoot() throws {
        var options = DiskScanOptions(root: root.path, title: "Fixture")
        options.skip = [root.appendingPathComponent("a").path]
        let tree = try XCTUnwrap(DiskScanner().run(options)).root
        XCTAssertNil(tree.find(root.appendingPathComponent("a").path))
        XCTAssertLessThan(tree.bytes, 3_000_000 + 1_500_000 + 500_000 + 1_000)
        XCTAssertNil(DiskScanner().run(DiskScanOptions(root: root.appendingPathComponent("missing").path, title: "x")))
    }

    func testRemovingShrinksEveryFolderAbove() throws {
        let tree = try scan().root
        let two = root.appendingPathComponent("a/deep/deeper/two.bin").path
        let node = try XCTUnwrap(tree.find(two))
        let updated = try XCTUnwrap(tree.removing(two))
        XCTAssertNil(updated.find(two))
        XCTAssertEqual(updated.bytes, tree.bytes - node.bytes)
        XCTAssertEqual(updated.items, tree.items - 1)
        XCTAssertEqual(updated.find(root.appendingPathComponent("a").path)?.bytes,
                       tree.find(root.appendingPathComponent("a").path).map { $0.bytes - node.bytes })
        XCTAssertNil(tree.removing(tree.path))
        XCTAssertNil(tree.removing("/nowhere/else"))
        let chain = try XCTUnwrap(tree.chain(to: node))
        XCTAssertEqual(chain.map(\.name), ["Fixture", "a", "deep", "deeper", "two.bin"])
    }

    func testPackageNames() {
        XCTAssertTrue(DiskScanner.isPackage("Xcode.app"))
        XCTAssertTrue(DiskScanner.isPackage("Photos Library.photoslibrary"))
        XCTAssertTrue(DiskScanner.isPackage("Thing.APP"))
        XCTAssertFalse(DiskScanner.isPackage(".app"))
        XCTAssertFalse(DiskScanner.isPackage("Projects"))
        XCTAssertFalse(DiskScanner.isPackage("notes.txt"))
    }

    func testWholeDiskSkipsTheSecondCopy() {
        let options = DiskScanOptions.wholeDisk()
        XCTAssertEqual(options.root, "/")
        XCTAssertTrue(options.skip.contains("/System/Volumes"))
    }
}

final class SunburstLayoutTests: XCTestCase {
    struct Item: Sendable {
        var name: String
        var bytes: Int64
        var kids: [Item] = []
    }

    private func layout(_ root: Item, depth: Int = 5) -> [SunburstSlice<Item>] {
        SunburstLayout.slices(root: root, sizeOf: \.bytes, children: \.kids, maxDepth: depth)
    }

    func testAnglesAreProportionalAndFillTheCircle() {
        let root = Item(name: "r", bytes: 100, kids: [Item(name: "a", bytes: 50), Item(name: "b", bytes: 25), Item(name: "c", bytes: 25)])
        let slices = layout(root)
        XCTAssertEqual(slices.map { $0.node?.name }, ["a", "b", "c"])
        XCTAssertEqual(slices[0].span, .pi, accuracy: 1e-9)
        XCTAssertEqual(slices[1].start, .pi, accuracy: 1e-9)
        XCTAssertEqual(slices[2].end, 2 * .pi, accuracy: 1e-9)
        XCTAssertEqual(slices.map(\.branch), [0, 1, 2])
    }

    func testRingsFollowDepthAndStopAtTheLimit() {
        var leaf = Item(name: "6", bytes: 10)
        for level in (1...5).reversed() { leaf = Item(name: "\(level)", bytes: 10, kids: [leaf]) }
        let root = Item(name: "r", bytes: 10, kids: [leaf])
        let slices = layout(root)
        XCTAssertEqual(slices.map(\.depth), [1, 2, 3, 4, 5])
        XCTAssertTrue(slices.allSatisfy { $0.branch == 0 })
        XCTAssertEqual(layout(root, depth: 2).count, 2)
    }

    func testChildrenSitInsideTheirParent() {
        let a = Item(name: "a", bytes: 60, kids: [Item(name: "a1", bytes: 40), Item(name: "a2", bytes: 20)])
        let root = Item(name: "r", bytes: 100, kids: [Item(name: "b", bytes: 40), a])
        let slices = layout(root)
        let parent = slices.first { $0.node?.name == "a" }!
        XCTAssertEqual(parent.start, 0, accuracy: 1e-9)   // biggest first
        for child in slices where child.depth == 2 {
            XCTAssertGreaterThanOrEqual(child.start, parent.start - 1e-9)
            XCTAssertLessThanOrEqual(child.end, parent.end + 1e-9)
            XCTAssertEqual(child.branch, parent.branch)
        }
        XCTAssertEqual(slices.filter { $0.depth == 2 }.reduce(0) { $0 + $1.span }, parent.span, accuracy: 1e-9)
    }

    func testSliversMergeIntoOneSlice() {
        // 1 byte of 1000 is 0.36°, under 1.5°: the twenty of them become one slice.
        var kids = [Item(name: "big", bytes: 980)]
        for i in 0..<20 { kids.append(Item(name: "tiny\(i)", bytes: 1)) }
        let slices = layout(Item(name: "r", bytes: 1000, kids: kids))
        XCTAssertEqual(slices.count, 2)
        let merged = slices[1]
        XCTAssertTrue(merged.isMerged)
        XCTAssertEqual(merged.count, 20)
        XCTAssertEqual(merged.bytes, 20)
        XCTAssertEqual(merged.end, 2 * .pi, accuracy: 1e-9)
        XCTAssertTrue(slices.filter { !$0.isMerged }.allSatisfy { $0.span >= SunburstLayout.defaultMinAngle })
    }

    func testEmptyAndZeroSizedItemsDrawNothing() {
        XCTAssertTrue(layout(Item(name: "r", bytes: 0)).isEmpty)
        XCTAssertEqual(layout(Item(name: "r", bytes: 10, kids: [Item(name: "z", bytes: 0), Item(name: "a", bytes: 10)])).count, 1)
    }

    func testAnglesFromTheCentre() {
        XCTAssertEqual(SunburstLayout.angle(dx: 0, dy: -1), 0, accuracy: 1e-9)           // twelve o'clock
        XCTAssertEqual(SunburstLayout.angle(dx: 1, dy: 0), .pi / 2, accuracy: 1e-9)      // three
        XCTAssertEqual(SunburstLayout.angle(dx: 0, dy: 1), .pi, accuracy: 1e-9)          // six
        XCTAssertEqual(SunburstLayout.angle(dx: -1, dy: 0), 3 * .pi / 2, accuracy: 1e-9) // nine
    }

    func testHitTesting() {
        let root = Item(name: "r", bytes: 100, kids: [Item(name: "a", bytes: 50, kids: [Item(name: "a1", bytes: 50)]),
                                                      Item(name: "b", bytes: 50)])
        let slices = layout(root)
        let geometry = SunburstGeometry(side: 200, rings: 2)
        XCTAssertEqual(geometry.centerRadius, 30, accuracy: 1e-9)
        XCTAssertEqual(geometry.ringWidth, 35, accuracy: 1e-9)
        XCTAssertEqual(geometry.ring(atDistance: 10), 0)
        XCTAssertEqual(geometry.ring(atDistance: 40), 1)
        XCTAssertEqual(geometry.ring(atDistance: 80), 2)
        XCTAssertNil(geometry.ring(atDistance: 101))
        func name(_ x: Double, _ y: Double) -> String? { geometry.slice(atX: x, y: y, in: slices).flatMap { slices[$0].node?.name } }
        XCTAssertEqual(name(40, 0), "a")    // right half, first ring
        XCTAssertEqual(name(80, 0), "a1")   // right half, second ring
        XCTAssertEqual(name(-40, 0), "b")   // left half
        XCTAssertNil(name(-80, 0))          // b has nothing inside
        XCTAssertNil(name(5, 5))            // the middle
    }

    func testPaletteIsOneHuePerBranchLighterOutwards() {
        for dark in [false, true] {
            let inner = SunburstPalette.tone(branch: 2, depth: 1, merged: false, dark: dark)
            let outer = SunburstPalette.tone(branch: 2, depth: 4, merged: false, dark: dark)
            XCTAssertEqual(inner.hue, outer.hue)
            XCTAssertGreaterThan(outer.brightness, inner.brightness)
            XCTAssertLessThan(outer.saturation, inner.saturation)
            XCTAssertNotEqual(SunburstPalette.tone(branch: 0, depth: 1, merged: false, dark: dark).hue, inner.hue)
            XCTAssertEqual(SunburstPalette.tone(branch: 2, depth: 1, merged: true, dark: dark).saturation, 0)
        }
    }
}

final class DiskMapRulesTests: XCTestCase {
    let home = "/Users/me"

    func testInsideTheScanOnly() {
        XCTAssertNil(DiskMapRules.refusal("/Users/me/Projects/old", root: home, home: home))
        XCTAssertNil(DiskMapRules.refusal("/Users/me/Library/Caches/com.foo", root: home, home: home))
        XCTAssertEqual(DiskMapRules.refusal(home, root: home, home: home), .outsideScan)
        XCTAssertEqual(DiskMapRules.refusal("/Users/meme/x", root: home, home: home), .outsideScan)
        XCTAssertEqual(DiskMapRules.refusal("/Users/me/../other/x", root: home, home: home), .outsideScan)
        XCTAssertEqual(DiskMapRules.refusal("relative/x", root: home, home: home), .outsideScan)
        // A link that leads out of the scanned folder.
        XCTAssertEqual(DiskMapRules.refusal("/Users/me/link", root: home, home: home, resolved: "/Library/Stuff"), .outsideScan)
        XCTAssertNil(DiskMapRules.refusal("/Users/me/Projects/x", root: home, home: home, resolved: "/Users/me/Projects/x"))
    }

    func testStandardFoldersStay() {
        for name in ["Documents", "Desktop", "Library", "Downloads", "Pictures"] {
            XCTAssertEqual(DiskMapRules.refusal("/Users/me/\(name)", root: home, home: home), .standardFolder, name)
        }
        XCTAssertEqual(DiskMapRules.refusal("/Users/me/Library/Caches", root: home, home: home), .standardFolder)
        XCTAssertEqual(DiskMapRules.refusal("/Users/me/Library/Mobile Documents", root: home, home: home), .standardFolder)
        XCTAssertEqual(DiskMapRules.refusal("/Users/me/.Trash", root: home, home: home), .standardFolder)
        XCTAssertNil(DiskMapRules.refusal("/Users/me/Documents/big.mov", root: home, home: home))
    }

    func testSystemLocationsInAWholeDiskScan() {
        XCTAssertEqual(DiskMapRules.refusal("/System/Library", root: "/", home: home), .systemLocation)
        XCTAssertEqual(DiskMapRules.refusal("/Library/Caches/x", root: "/", home: home), .systemLocation)
        XCTAssertEqual(DiskMapRules.refusal("/private/var/vm", root: "/", home: home), .systemLocation)
        XCTAssertEqual(DiskMapRules.refusal("/usr/local", root: "/", home: home), .systemLocation)
        XCTAssertEqual(DiskMapRules.refusal("/Users", root: "/", home: home), .systemLocation)
        XCTAssertEqual(DiskMapRules.refusal("/Users/someone", root: "/", home: home), .systemLocation)
        XCTAssertEqual(DiskMapRules.refusal("/Applications", root: "/", home: home), .systemLocation)
        XCTAssertEqual(DiskMapRules.refusal("/Applications/Utilities/Terminal.app", root: "/", home: home), .systemLocation)
        XCTAssertEqual(DiskMapRules.refusal("/", root: "/", home: home), .outsideScan)
        XCTAssertEqual(DiskMapRules.refusal("/Users/me", root: "/", home: home), .standardFolder)
        XCTAssertNil(DiskMapRules.refusal("/Applications/Big Game.app", root: "/", home: home))
        XCTAssertNil(DiskMapRules.refusal("/Users/me/Movies/render.mov", root: "/", home: home))
    }
}
