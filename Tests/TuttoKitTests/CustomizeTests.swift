import XCTest
@testable import TuttoKit

final class ArrangementTests: XCTestCase {
    private let defaults = ["a", "b", "c", "d"]

    func testDefaultOrderWhenNothingArranged() {
        let arrangement = Arrangement()
        XCTAssertEqual(arrangement.all(defaults), defaults)
        XCTAssertEqual(arrangement.visible(defaults), defaults)
    }

    func testHiddenItemsStayInTheListButNotOnShow() {
        var arrangement = Arrangement()
        arrangement.set("b", shown: false)
        XCTAssertEqual(arrangement.all(defaults), defaults)
        XCTAssertEqual(arrangement.visible(defaults), ["a", "c", "d"])
        arrangement.set("b", shown: true)
        XCTAssertEqual(arrangement.visible(defaults), defaults)
    }

    func testMovesLikeAListDrag() {
        var arrangement = Arrangement()
        arrangement.move(fromOffsets: IndexSet(integer: 3), toOffset: 0, available: defaults)
        XCTAssertEqual(arrangement.all(defaults), ["d", "a", "b", "c"])
        arrangement.move(fromOffsets: IndexSet(integer: 0), toOffset: 4, available: defaults)
        XCTAssertEqual(arrangement.all(defaults), ["a", "b", "c", "d"])
        arrangement.move("a", by: 1, available: defaults)
        XCTAssertEqual(arrangement.all(defaults), ["b", "a", "c", "d"])
        arrangement.move("b", by: -1, available: defaults)
        XCTAssertEqual(arrangement.all(defaults), ["b", "a", "c", "d"], "already first")
        arrangement.move("d", by: -1, available: defaults)
        XCTAssertEqual(arrangement.all(defaults), ["b", "a", "d", "c"])
    }

    func testNewItemsArriveAtTheirDefaultPlace() {
        var arrangement = Arrangement()
        arrangement.move(fromOffsets: IndexSet(integer: 2), toOffset: 0, available: ["a", "b", "c"])
        XCTAssertEqual(arrangement.all(["a", "b", "c"]), ["c", "a", "b"])
        // "x" is new, after "b" by default: it lands after "b" in the arranged order.
        XCTAssertEqual(arrangement.all(["a", "b", "x", "c"]), ["c", "a", "b", "x"])
        // A new first item goes first.
        XCTAssertEqual(arrangement.all(["z", "a", "b", "c"]), ["z", "c", "a", "b"])
    }

    func testItemsThatComeAndGoKeepTheirPlace() {
        var arrangement = Arrangement()
        arrangement.move(fromOffsets: IndexSet(integer: 3), toOffset: 0, available: defaults)  // d a b c
        // "a" goes away (its tool switched off), the rest are reordered meanwhile.
        arrangement.move(fromOffsets: IndexSet(integer: 2), toOffset: 0, available: ["b", "c", "d"])  // in d b c → c d b
        XCTAssertEqual(arrangement.all(["b", "c", "d"]), ["c", "d", "b"])
        // It comes back where it was remembered.
        XCTAssertTrue(arrangement.all(defaults).contains("a"))
        XCTAssertEqual(arrangement.all(defaults).count, 4)
    }

    func testDuplicatesAndUnknownIdsAreIgnored() {
        let arrangement = Arrangement(order: ["b", "b", "q", "a"], hidden: ["q"])
        XCTAssertEqual(arrangement.all(["a", "b"]), ["b", "a"])
    }

    func testRowsOfTwoAndOfSix() {
        XCTAssertEqual(PanelLayout.rows([1, 2, 3, 4, 5], perRow: 2), [[1, 2], [3, 4], [5]])
        XCTAssertEqual(PanelLayout.rows(Array(1...8), perRow: 6), [[1, 2, 3, 4, 5, 6], [7, 8]])
        XCTAssertEqual(PanelLayout.rows([Int](), perRow: 2), [])
    }

    func testLayoutRoundTripsAndOldOnesDecode() throws {
        var layout = PanelLayout()
        layout.sections.set("sound", shown: false)
        layout.tools.move(fromOffsets: IndexSet(integer: 1), toOffset: 0, available: ["x", "y"])
        let decoded = try JSONDecoder().decode(PanelLayout.self, from: JSONEncoder().encode(layout))
        XCTAssertEqual(decoded, layout)
        let partial = try JSONDecoder().decode(PanelLayout.self, from: Data(#"{"sections":{"order":[],"hidden":["tools"]}}"#.utf8))
        XCTAssertEqual(partial.sections.hidden, ["tools"])
        XCTAssertEqual(partial.readings, Arrangement())
    }
}

final class ScriptPluginTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("plugins-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    func testHandWrittenFilesNeedOnlyANameAndACommand() throws {
        try #"{"name": "Hello", "command": "echo hi"}"#.write(to: folder.appendingPathComponent("hello.json"), atomically: true, encoding: .utf8)
        try #"{"name": "Broken"}"#.write(to: folder.appendingPathComponent("broken.json"), atomically: true, encoding: .utf8)
        try "not json".write(to: folder.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let store = PluginStore(directory: folder)
        let first = store.load()
        XCTAssertEqual(first.plugins.map(\.name), ["Hello"])
        XCTAssertEqual(first.plugins.first?.output, .notice)
        XCTAssertEqual(first.plugins.first?.symbol, ScriptPlugin.defaultSymbol)
        XCTAssertEqual(first.problems.count, 1, "broken.json is reported; notes.txt isn't a plugin")
        // The id it gets from its file name is the same every time.
        XCTAssertEqual(store.load().plugins.first?.id, first.plugins.first?.id)
    }

    func testSaveEditDelete() throws {
        let store = PluginStore(directory: folder)
        var plugin = ScriptPlugin(name: "Upper Case!", command: "tr a-z A-Z", input: .clipboard, output: .clipboard)
        let url = try store.save(plugin)
        XCTAssertEqual(url.lastPathComponent, "upper-case.json")
        plugin.command = "tr '[:lower:]' '[:upper:]'"
        XCTAssertEqual(try store.save(plugin), url, "edits go to the same file")
        let other = try store.save(ScriptPlugin(name: "upper case", command: "true"))
        XCTAssertEqual(other.lastPathComponent, "upper-case-2.json")
        let loaded = store.load().plugins
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.first { $0.id == plugin.id }, plugin)
        try store.delete(plugin)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(store.load().plugins.map(\.name), ["upper case"])
    }

    func testValidityAndSlugs() {
        XCTAssertFalse(ScriptPlugin(name: "  ", command: "ls").isValid)
        XCTAssertFalse(ScriptPlugin(name: "A", command: "\n").isValid)
        XCTAssertTrue(ScriptPlugin(name: "A", command: "ls").isValid)
        XCTAssertEqual(PluginStore.slug("Plain Text — Clipboard"), "plain-text-clipboard")
        XCTAssertEqual(PluginStore.slug("!!!"), "plugin")
        XCTAssertEqual(ScriptPlugin.templates.count, 4)
        XCTAssertTrue(ScriptPlugin.templates.allSatisfy(\.isValid))
    }

    func testRunsWithInputAndOutput() {
        let result = PluginRunner.run("tr a-z A-Z", input: "hello tutto", timeout: 10, shell: "/bin/zsh")
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.output, "HELLO TUTTO")
        XCTAssertEqual(result.summary(), "HELLO TUTTO")
    }

    func testFailureKeepsTheErrorsAndTheStatus() {
        let result = PluginRunner.run("echo oops >&2; exit 3", input: nil, timeout: 10)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.status, 3)
        XCTAssertEqual(result.summary(), "oops")
    }

    func testTimeoutStopsIt() {
        let result = PluginRunner.run("sleep 5", input: nil, timeout: 0.5)
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.succeeded)
        XCTAssertLessThan(result.seconds, 3)
    }

    func testACommandThatIgnoresItsInputIsFine() {
        // A big input to a command that exits without reading it: the write fails quietly.
        let result = PluginRunner.run("true", input: String(repeating: "x", count: 2_000_000), timeout: 10)
        XCTAssertTrue(result.succeeded)
    }

    func testOutputIsCapped() {
        let result = PluginRunner.run("yes | head -c 200000", input: nil, timeout: 10)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.output.utf8.count, PluginRunner.outputLimit)
    }

    func testRunsInTheHomeFolderWithItsName() {
        let result = PluginRunner.run("pwd; echo $TUTTO_PLUGIN", input: nil, timeout: 10, name: "Check")
        XCTAssertEqual(result.output.split(separator: "\n").map(String.init), [NSHomeDirectory(), "Check"])
    }
}
