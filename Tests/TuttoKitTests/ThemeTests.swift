import XCTest
@testable import TuttoKit

final class ThemeTests: XCTestCase {
    func testHexReadsAndWrites() {
        XCTAssertEqual(RGBA(hex: "#3E7BFA")?.hex, "#3E7BFA")
        XCTAssertEqual(RGBA(hex: "abc")?.hex, "#AABBCC")
        XCTAssertEqual(RGBA(hex: "#11223380")?.hex, "#11223380")
        XCTAssertEqual(RGBA(hex: "#11223380")?.alpha ?? 0, 128.0 / 255, accuracy: 0.001)
        XCTAssertNil(RGBA(hex: "#12"))
        XCTAssertNil(RGBA(hex: "#GGHHII"))
    }

    func testContrastAndAdjusting() {
        XCTAssertEqual(RGBA.contrast(.black, .white), 21, accuracy: 0.01)
        XCTAssertEqual(RGBA.contrast(.white, .white), 1, accuracy: 0.01)
        let pale = RGBA(hex: "#D0D0D0")!
        XCTAssertLessThan(RGBA.contrast(pale, .white), 4.5)
        let fixed = pale.adjusted(toContrast: 4.5, against: .white)
        XCTAssertGreaterThanOrEqual(RGBA.contrast(fixed, .white), 4.5)
        XCTAssertLessThan(RGBA.contrast(fixed, .white), 4.7, "only as far as it needs to go")
        XCTAssertEqual(RGBA.black.adjusted(toContrast: 4.5, against: .white), .black, "already fine")
    }

    func testTuttoThemeIsTuttosOwnLook() {
        let palette = ThemeSpec.tutto.palette(dark: false)
        XCTAssertNil(palette.ink, "the system's label colour, which keeps the glass vibrant")
        XCTAssertNil(palette.accent, "macOS's accent")
        XCTAssertEqual([palette.secondary, palette.tertiary, palette.faint, palette.line, palette.wash], [0.84, 0.74, 0.30, 0.12, 0.06])
        XCTAssertEqual(palette.cardFill, 0.055)
        XCTAssertFalse(palette.cardStroke)
        XCTAssertFalse(palette.solidBackground)
        XCTAssertEqual(palette.tint, 0)
        XCTAssertEqual(ThemeSpec.tutto.cornerScale, 1)
        XCTAssertEqual(ThemeSpec.tutto.densityScale, 1)
    }

    func testThemeFilesAreForgiving() throws {
        let json = ##"{"accent": "#FF0000", "corners": "huge", "density": "Compact", "colors": {"dark": {"background": "#000000"}}}"##
        let spec = try JSONDecoder().decode(ThemeSpec.self, from: Data(json.utf8))
        XCTAssertEqual(spec.name, "Untitled")
        XCTAssertEqual(spec.accent, .color(RGBA(1, 0, 0)))
        XCTAssertEqual(spec.corners, .medium, "unknown values keep the default")
        XCTAssertEqual(spec.density, .compact, "any case")
        XCTAssertEqual(spec.palette(dark: true).background, .black, "an override wins in its mode")
        XCTAssertNotEqual(spec.palette(dark: false).background, .black, "and only there")
        XCTAssertEqual(try JSONDecoder().decode(ThemeSpec.self, from: Data(#"{"accent": "mono"}"#.utf8)).accent, .mono)
    }

    func testBuiltInThemesRoundTripAndReadWell() throws {
        XCTAssertEqual(ThemeSpec.builtIn.first, .tutto)
        XCTAssertEqual(Set(ThemeSpec.builtIn.map(\.name)).count, ThemeSpec.builtIn.count)
        for spec in ThemeSpec.builtIn {
            let decoded = try JSONDecoder().decode(ThemeSpec.self, from: JSONEncoder().encode(spec))
            XCTAssertEqual(decoded, spec, spec.name)
            XCTAssertEqual(spec.contrastProblems(), [], spec.name)
        }
    }

    func testContrastProblemsAreFound() {
        var spec = ThemeSpec(name: "Faint", accent: .color(RGBA(hex: "#F4F4F4")!))
        XCTAssertTrue(spec.contrastProblems().contains { $0.contains("accent") })
        spec.accent = .system
        spec.setOverride(.ink, dark: true, to: RGBA(hex: "#202020"))
        XCTAssertTrue(spec.contrastProblems().contains { $0.contains("dark") })
        spec.setOverride(.ink, dark: true, to: nil)
        XCTAssertEqual(spec.colors, [:], "clearing the last override leaves no empty set behind")
        XCTAssertEqual(spec.contrastProblems(), [])
    }

    func testLooksLikeIgnoresTheName() {
        var mine = ThemeSpec.builtIn[2]
        mine.name = "Mine"
        XCTAssertTrue(mine.looksLike(ThemeSpec.builtIn[2]))
        mine.density = .compact
        XCTAssertFalse(mine.looksLike(ThemeSpec.builtIn[2]))
    }

    func testThemeFilesSaveLoadAndDelete() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("themes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = ThemeFiles(directory: folder, usesTrash: false)
        var spec = ThemeSpec.builtIn[3]
        spec.name = "My Slate"
        let url = try files.save(spec)
        XCTAssertEqual(url.lastPathComponent, "my-slate.json")
        try "[1, 2]".write(to: folder.appendingPathComponent("list.json"), atomically: true, encoding: .utf8)
        try #"{"accent": "mono"}"#.write(to: folder.appendingPathComponent("plain.json"), atomically: true, encoding: .utf8)
        let loaded = files.load()
        XCTAssertEqual(loaded.themes.map(\.spec.name), ["My Slate", "plain"], "a nameless file is named after itself")
        XCTAssertEqual(loaded.themes.first?.spec, spec)
        XCTAssertEqual(loaded.problems.count, 1)
        try files.delete(url)
        XCTAssertEqual(files.load().themes.map(\.spec.name), ["plain"])
    }
}

final class PluginV2Tests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("plugins-v2-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func decode(_ json: String) throws -> ScriptPlugin {
        try JSONDecoder().decode(ScriptPlugin.self, from: Data(json.utf8))
    }

    func testOldFilesStillLoad() throws {
        let plugin = try decode(#"{"name": "Hello", "command": "echo hi"}"#)
        XCTAssertTrue(plugin.hasAction)
        XCTAssertFalse(plugin.hasWidget)
        XCTAssertEqual(plugin.triggers, [])
        XCTAssertEqual(plugin.settings, [])
        XCTAssertEqual(plugin.kinds, ["Action"])
    }

    func testACardNeedsNoCommand() throws {
        let plugin = try decode(#"{"name": "Load", "widget": {"command": "sysctl -n vm.loadavg"}}"#)
        XCTAssertTrue(plugin.hasWidget)
        XCTAssertFalse(plugin.hasAction)
        XCTAssertTrue(plugin.isValid)
        XCTAssertEqual(plugin.kinds, ["Card"])
        XCTAssertEqual(plugin.widget?.every, 30)
        XCTAssertEqual(plugin.widget?.size, .small)
        XCTAssertEqual(plugin.widget?.interval(background: false), 30)
        var fast = plugin.widget!
        fast.every = 0.5
        XCTAssertEqual(fast.interval(background: false), ScriptPlugin.Widget.shortest)
        XCTAssertEqual(fast.interval(background: true), ScriptPlugin.Widget.shortestInBackground)
        XCTAssertThrowsError(try decode(#"{"name": "Nothing"}"#), "nothing to run or show")
    }

    func testTriggersAndSettingsThisTuttoDoesntKnowAreSkipped() throws {
        let plugin = try decode(#"""
        {"name": "Mixed", "command": "true",
         "triggers": [{"on": "wake"}, {"on": "moon.rises"}, {"on": "battery.below", "percent": 15}],
         "settings": [{"key": "token", "type": "secret"}, {"title": "no key"}, {"key": "n", "type": "number", "default": 3}, {"key": "b", "type": "toggle", "default": true}]}
        """#)
        XCTAssertEqual(plugin.triggers, [PluginTrigger(event: .wake), PluginTrigger(event: .batteryBelow, percent: 15)])
        XCTAssertEqual(plugin.settings.map(\.key), ["token", "n", "b"])
        XCTAssertEqual(plugin.settings[0].kind, .secret)
        XCTAssertEqual(plugin.settings[0].title, "token", "the key stands in for a missing title")
        XCTAssertEqual(plugin.settings[1].defaultValue, "3")
        XCTAssertEqual(plugin.settings[2].defaultValue, "true")
        XCTAssertEqual(plugin.kinds, ["Automation"])
    }

    func testEverythingRoundTripsAndQuietFieldsStayOut() throws {
        let full = ScriptPlugin(name: "Full", symbol: "star", command: "echo $TUTTO_EVENT", output: .silent,
                                widget: .init(command: "echo 1", every: 15, size: .wide, background: true),
                                triggers: [.init(event: .daily, at: "08:30"), .init(event: .appActivated, app: "com.apple.Safari")],
                                settings: [.init(key: "folder", title: "Folder", kind: .folder, defaultValue: "~/x")])
        XCTAssertEqual(try JSONDecoder().decode(ScriptPlugin.self, from: JSONEncoder().encode(full)), full)
        let card = ScriptPlugin(name: "Card", command: "", widget: .init(command: "date"))
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(card)) as? [String: Any]).keys
        XCTAssertFalse(keys.contains("command"), "a card-only plugin has no action fields")
        XCTAssertFalse(keys.contains("triggers"))
        XCTAssertFalse(keys.contains("settings"))
    }

    func testValidityExplainsItself() {
        XCTAssertEqual(ScriptPlugin(name: " ", command: "ls").problem, "Give it a name.")
        XCTAssertNotNil(ScriptPlugin(name: "A", command: "").problem)
        let trigger = ScriptPlugin(name: "A", command: "", widget: .init(command: "date"), triggers: [.init(event: .wake)])
        XCTAssertFalse(trigger.isValid)
        XCTAssertEqual(trigger.problem, "Its triggers need a command to run.")
        XCTAssertNil(ScriptPlugin(name: "A", command: "ls").problem)
    }

    func testEnvironmentTellsTheRunWhyAndWhat() {
        let plugin = ScriptPlugin(name: "Env", command: "env", settings: [
            .init(key: "repo-folder", title: "Repo", kind: .folder, defaultValue: "~/a"),
            .init(key: "token", title: "Token", kind: .secret),
        ])
        XCTAssertEqual(plugin.settings[0].environmentName, "TUTTO_SETTING_REPO_FOLDER")
        let environment = PluginEnvironment.make(plugin: plugin, reason: .trigger, event: "battery.below", info: "18",
                                                 values: ["token": "abc"], folder: URL(fileURLWithPath: "/tmp/p"))
        XCTAssertEqual(environment["TUTTO_PLUGIN"], "Env")
        XCTAssertEqual(environment["TUTTO_PLUGIN_ID"], plugin.id.uuidString)
        XCTAssertEqual(environment["TUTTO_REASON"], "trigger")
        XCTAssertEqual(environment["TUTTO_EVENT"], "battery.below")
        XCTAssertEqual(environment["TUTTO_EVENT_INFO"], "18")
        XCTAssertEqual(environment["TUTTO_PLUGIN_DIR"], "/tmp/p")
        XCTAssertEqual(environment["TUTTO_SETTING_REPO_FOLDER"], "~/a", "a setting left alone has its default")
        XCTAssertEqual(environment["TUTTO_SETTING_TOKEN"], "abc")
    }

    func testRunnerTakesTheEnvironmentAndFolder() {
        let result = PluginRunner.run("echo $TUTTO_REASON; pwd", input: nil, timeout: 10,
                                      environment: ["TUTTO_REASON": "test"], directory: folder)
        let lines = result.output.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "test")
        XCTAssertTrue(lines.last?.hasSuffix(folder.lastPathComponent) == true, lines.last ?? "")
    }

    func testCardsReadPlainText() {
        let content = PluginWidgetContent.parse("42\nlast hour\n\nfirst\nsecond\n")
        XCTAssertEqual(content.value, "42")
        XCTAssertEqual(content.detail, "last hour")
        XCTAssertEqual(content.items.map(\.title), ["first", "second"])
        XCTAssertEqual(PluginWidgetContent.parse("  \n").value, "—")
        XCTAssertEqual(PluginWidgetContent.parse("{not json").value, "{not json", "a broken object is just text")
        XCTAssertEqual(PluginWidgetContent.parse(String(repeating: "x", count: 100)).value.count, 48)
    }

    func testCardsReadJSON() {
        let content = PluginWidgetContent.parse(#"""
        {"value": 3, "unit": "open", "title": "PRs", "detail": "2 need review", "symbol": "arrow.triangle.pull",
         "status": "warning", "progress": 40, "series": [1, "x", 2.5], "href": "https://example.com",
         "items": ["plain", {"title": "Fix login", "detail": "api", "url": "https://example.com/1"}, {"no": "title"}]}
        """#)
        XCTAssertEqual(content.value, "3")
        XCTAssertEqual(content.unit, "open")
        XCTAssertEqual(content.title, "PRs")
        XCTAssertEqual(content.level, .notice)
        XCTAssertEqual(content.progress, 0.4, "a percent becomes a fraction")
        XCTAssertEqual(content.series, [1, 2.5])
        XCTAssertEqual(content.url, "https://example.com")
        XCTAssertEqual(content.items, [.init(title: "plain"), .init(title: "Fix login", detail: "api", url: "https://example.com/1")])
        XCTAssertEqual(PluginWidgetContent.parse(#"{"value": "x", "level": "critical"}"#).level, .alert)
        XCTAssertEqual(PluginWidgetContent.parse(#"{"detail": "no value"}"#).value, "—")
    }

    func testSchedules() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 10)))
        XCTAssertEqual(PluginSchedule.next(.init(event: .every, minutes: 30), after: start, calendar: calendar),
                       start.addingTimeInterval(1800))
        XCTAssertEqual(PluginSchedule.next(.init(event: .daily, at: "09:00"), after: start, calendar: calendar),
                       calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 9)))
        XCTAssertEqual(PluginSchedule.next(.init(event: .daily, at: "10:30"), after: start, calendar: calendar),
                       calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 10, minute: 30)), "later today")
        XCTAssertNil(PluginSchedule.next(.init(event: .daily, at: "25:00"), after: start, calendar: calendar))
        XCTAssertNil(PluginSchedule.next(.init(event: .wake), after: start, calendar: calendar))
    }

    func testBatteryBelowFiresOnceUntilItRecovers() {
        var watch = BatteryWatch()
        XCTAssertFalse(watch.update(charge: 25, onBattery: true, below: 20))
        XCTAssertTrue(watch.update(charge: 19, onBattery: true, below: 20))
        XCTAssertFalse(watch.update(charge: 18, onBattery: true, below: 20), "once on the way down")
        XCTAssertFalse(watch.update(charge: 21, onBattery: true, below: 20), "not re-armed by one point")
        XCTAssertFalse(watch.update(charge: 19, onBattery: true, below: 20))
        XCTAssertFalse(watch.update(charge: 19, onBattery: false, below: 20), "plugged in: re-armed, quiet")
        XCTAssertTrue(watch.update(charge: 19, onBattery: true, below: 20), "unplugged again below it")
    }

    func testRunBudgetStopsRunaways() {
        var budget = RunBudget(limit: 3, window: 60)
        let now = Date()
        XCTAssertEqual((0..<4).map { budget.allow(at: now.addingTimeInterval(Double($0))) }, [true, true, true, false])
        XCTAssertTrue(budget.allow(at: now.addingTimeInterval(61)))
    }

    func testAppTriggersMatchByBundleOrName() {
        XCTAssertTrue(PluginTrigger(event: .appLaunched).matches(bundleID: "com.apple.Safari", appName: "Safari"))
        XCTAssertTrue(PluginTrigger(event: .appLaunched, app: "com.apple.Safari").matches(bundleID: "com.apple.Safari", appName: nil))
        XCTAssertTrue(PluginTrigger(event: .appQuit, app: "safari").matches(bundleID: nil, appName: "Safari"))
        XCTAssertFalse(PluginTrigger(event: .appQuit, app: "Notes").matches(bundleID: "com.apple.Safari", appName: "Safari"))
        XCTAssertEqual(PluginTrigger(event: .daily, at: "07:05").dailyTime?.hour, 7)
        XCTAssertNil(PluginTrigger(event: .daily, at: "7").dailyTime)
    }

    func testFolderPlugins() throws {
        let plugin = folder.appendingPathComponent("weather", isDirectory: true)
        try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
        try #"{"name": "Weather", "widget": {"command": "./show.sh"}}"#.write(to: plugin.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
        try "#!/bin/sh\necho 21\n".write(to: plugin.appendingPathComponent("show.sh"), atomically: true, encoding: .utf8)
        let empty = folder.appendingPathComponent("not-a-plugin", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let store = PluginStore(directory: folder, usesTrash: false)
        let loaded = store.load()
        XCTAssertEqual(loaded.plugins.map(\.name), ["Weather"])
        XCTAssertEqual(loaded.problems, [])
        let weather = try XCTUnwrap(loaded.plugins.first)
        XCTAssertEqual(store.folder(for: weather)?.lastPathComponent, "weather")
        XCTAssertEqual(store.load().plugins.first?.id, weather.id, "the same id every time")
        let ran = PluginRunner.run("sh ./show.sh", input: nil, timeout: 10, directory: store.folder(for: weather))
        XCTAssertEqual(PluginWidgetContent.parse(ran.output).value, "21", "its commands run in its folder")
        try store.delete(weather)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plugin.path), "the whole folder goes")
    }

    func testTemplatesWorkAsShipped() {
        for template in ScriptPlugin.templates {
            XCTAssertTrue(template.isValid, template.name)
        }
        let uptime = try? XCTUnwrap(ScriptPlugin.templates.first { $0.name == "Uptime" }?.widget)
        let result = PluginRunner.run(uptime?.command ?? "", input: nil, timeout: 10)
        let content = PluginWidgetContent.parse(result.output)
        XCTAssertTrue(result.succeeded)
        XCTAssertNotEqual(content.value, "—")
        XCTAssertEqual(content.detail, "since the last restart")
        // The link cleaner leaves anything without tracking alone and strips what it finds.
        let cleaner = ScriptPlugin.templates.first { $0.name == "Clean Copied Links" }!
        XCTAssertEqual(PluginRunner.run(cleaner.command, input: "hello", timeout: 10).output, "")
        XCTAssertEqual(PluginRunner.run(cleaner.command, input: "https://a.b/c?x=1&utm_source=t&y=2", timeout: 10).output,
                       "https://a.b/c?x=1&y=2")
        XCTAssertEqual(PluginRunner.run(cleaner.command, input: "https://a.b/c?utm_source=t", timeout: 10).output, "https://a.b/c")
    }
}
