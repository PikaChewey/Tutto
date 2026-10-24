import Carbon.HIToolbox
import CoreGraphics
import XCTest
@testable import TuttoKit

final class SwitcherRulesTests: XCTestCase {
    // Flag values read from the window server on a MacBook Pro (macOS 26.5).
    private func window(_ id: CGWindowID, _ w: CGFloat, _ h: CGFloat, tags: UInt64, attrs: UInt64, alpha: Double = 1,
                        title: String = "", parent: CGWindowID = 0) -> ServerWindow {
        ServerWindow(id: id, pid: 1, title: title, frame: CGRect(x: 0, y: 0, width: w, height: h), alpha: alpha,
                     tags: tags, attributes: attrs, parent: parent)
    }

    func testRealWindowsAreAdmitted() {
        // Firefox in full screen on another Space, and a normal Notion window on Desktop 1.
        XCTAssertTrue(WindowAdmission.admits(window(44091, 1512, 949, tags: 0x0300_0401_0048_2401, attrs: 0x3, title: "Startup Cold Email Kit")))
        XCTAssertTrue(WindowAdmission.admits(window(49295, 1320, 858, tags: 0x0300_0001_0008_2401, attrs: 0x3, title: "Passwords")))
    }

    func testHelperSurfacesAreNot() {
        // Menu bar ghosts (never shown), full-screen toolbar strips (no document flag, some
        // even opaque), off-screen buffers, closed-but-kept windows, invisible windows, sheets.
        XCTAssertFalse(WindowAdmission.admits(window(44090, 1512, 33, tags: 0x0000_2000_0009_0040, attrs: 0x1)))
        XCTAssertFalse(WindowAdmission.admits(window(44101, 1512, 68, tags: 0x0804_0401_400c_2080, attrs: 0x3)))
        XCTAssertFalse(WindowAdmission.admits(window(49314, 500, 500, tags: 0x0000_0001_0008_0001, attrs: 0x1)))
        XCTAssertFalse(WindowAdmission.admits(window(39104, 960, 720, tags: 0x0300_0001_0008_0401, attrs: 0x1)))
        XCTAssertFalse(WindowAdmission.admits(window(1, 800, 600, tags: 0x0300_0001_0008_2401, attrs: 0x3, alpha: 0)))
        XCTAssertFalse(WindowAdmission.admits(window(2, 800, 600, tags: 0x0300_0001_0008_2401, attrs: 0x3, parent: 49295)))
    }

    func testMinimizedAndHiddenFollowTheOptions() {
        let minimized = window(49295, 1320, 858, tags: 0x1300_0001_0008_0401, attrs: 0x1)
        let hidden = window(49295, 1320, 858, tags: 0x0300_0081_0008_0401, attrs: 0x1)
        XCTAssertTrue(minimized.isMinimized)
        XCTAssertTrue(hidden.isAppHidden)
        XCTAssertTrue(WindowAdmission.admits(minimized))
        XCTAssertTrue(WindowAdmission.admits(hidden))
        XCTAssertFalse(WindowAdmission.admits(minimized, options: .init(includeMinimized: false)))
        XCTAssertFalse(WindowAdmission.admits(hidden, options: .init(includeHidden: false)))
    }

    func testWithoutFlagsFallsBackToTitledWindows() {
        XCTAssertTrue(WindowAdmission.admits(window(3, 800, 600, tags: 0, attrs: 0, title: "Doc"), haveFlags: false))
        XCTAssertFalse(WindowAdmission.admits(window(4, 800, 600, tags: 0, attrs: 0, title: ""), haveFlags: false))
    }

    func testTitlesLoseTheAppName() {
        XCTAssertEqual(WindowTitles.clean("Quest — Mozilla Firefox", appName: "Firefox"), "Quest")
        XCTAssertEqual(WindowTitles.clean("roblox game people - Discord", appName: "Discord"), "roblox game people")
        XCTAssertEqual(WindowTitles.clean("Inbox (3) – bryan@example.com – Gmail - Google Chrome", appName: "Google Chrome"),
                       "Inbox (3) – bryan@example.com – Gmail")
        XCTAssertEqual(WindowTitles.clean("Startup Cold Email Kit", appName: "Firefox"), "Startup Cold Email Kit")
        XCTAssertEqual(WindowTitles.clean("/Users/bryan/Documents/notes.txt", appName: "TextEdit"), "notes.txt")
        XCTAssertEqual(WindowTitles.clean("Big - Small", appName: "Notes"), "Big - Small")
        XCTAssertEqual(WindowTitles.clean("   ", appName: "Notes"), "")
    }

    func testOrderPutsRecentFirstAndDemotedLast() {
        let windows: [(id: CGWindowID, zIndex: Int, demoted: Bool)] = [
            (10, 0, false), (11, 1, false), (12, 2, true), (13, 3, false), (14, 4, false),
        ]
        XCTAssertEqual(SwitcherOrder.order(windows, recent: [13, 10, 12]), [13, 10, 11, 14, 12])
        XCTAssertEqual(SwitcherOrder.order(windows, recent: []), [10, 11, 13, 14, 12])
    }

    func testFirstPressGoesToThePreviousWindow() {
        XCTAssertEqual(SwitcherOrder.initialSelection(count: 5, firstIsCurrent: true, backward: false), 1)
        XCTAssertEqual(SwitcherOrder.initialSelection(count: 5, firstIsCurrent: false, backward: false), 0)
        XCTAssertEqual(SwitcherOrder.initialSelection(count: 1, firstIsCurrent: true, backward: false), 0)
        XCTAssertEqual(SwitcherOrder.initialSelection(count: 5, firstIsCurrent: true, backward: true), 4)
        XCTAssertEqual(SwitcherOrder.move(4, by: 1, count: 5), 0)
        XCTAssertEqual(SwitcherOrder.move(0, by: -1, count: 5), 4)
    }

    func testRecentWindowsStayBounded() {
        var recent = RecentWindows(limit: 3)
        for id: CGWindowID in [1, 2, 3, 2, 4] { recent.touch(id) }
        XCTAssertEqual(recent.ids, [4, 2, 3])
        recent.keep(only: [2, 3])
        XCTAssertEqual(recent.ids, [2, 3])
    }

    func testSearchRanksNamesThenTitlesThenApps() {
        let items = [
            WindowSearch.Item(name: nil, title: "Firefox Privacy Notice", app: "Firefox"),
            WindowSearch.Item(name: "School", title: "Quest", app: "Firefox"),
            WindowSearch.Item(name: nil, title: "Old school photos", app: "Photos"),
            WindowSearch.Item(name: nil, title: "general", app: "Discord"),
        ]
        XCTAssertEqual(WindowSearch.rank("school", in: items), [1, 2])
        XCTAssertEqual(WindowSearch.rank("fire", in: items), [0, 1])
        XCTAssertEqual(WindowSearch.rank("disc", in: items), [3])
        XCTAssertEqual(WindowSearch.rank("", in: items), [0, 1, 2, 3])
        XCTAssertEqual(WindowSearch.rank("zzz", in: items), [])
    }

    func testNamesFollowTheWindowAndComeBackAfterARestart() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 949)
        let stored = [WindowName(name: "School", bundleID: "org.mozilla.firefox", windowID: 44091, title: "Quest", frame: frame,
                                 lastSeen: now.addingTimeInterval(-60))]
        // Still open.
        var result = WindowNaming.assign(stored, to: [.init(id: 44091, bundleID: "org.mozilla.firefox", title: "Quest – Course", frame: frame)], now: now)
        XCTAssertEqual(result.names, [44091: "School"])
        XCTAssertEqual(result.updated.first?.title, "Quest – Course")
        // Firefox restarted: new window ids, same titles restored. Full-screen frames are all
        // identical, so only the title can tell them apart.
        result = WindowNaming.assign(result.updated, to: [
            .init(id: 50001, bundleID: "org.mozilla.firefox", title: "YouTube", frame: frame),
            .init(id: 50002, bundleID: "org.mozilla.firefox", title: "Quest – Course", frame: frame),
        ], now: now)
        XCTAssertEqual(result.names, [50002: "School"])
        XCTAssertEqual(result.updated.first?.windowID, 50002)
    }

    func testNamesDontJumpToAmbiguousWindowsAndAgeOut() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 949)
        let stored = [WindowName(name: "School", bundleID: "org.mozilla.firefox", windowID: 1, title: "Quest", frame: frame, lastSeen: now)]
        // Two candidates in the same place, neither with the title: leave the name unattached.
        let ambiguous = WindowNaming.assign(stored, to: [
            .init(id: 2, bundleID: "org.mozilla.firefox", title: "A", frame: frame),
            .init(id: 3, bundleID: "org.mozilla.firefox", title: "B", frame: frame),
        ], now: now)
        XCTAssertTrue(ambiguous.names.isEmpty)
        XCTAssertEqual(ambiguous.updated.count, 1)
        // One window in the same place: that's it.
        let single = WindowNaming.assign(stored, to: [.init(id: 4, bundleID: "org.mozilla.firefox", title: "New tab", frame: frame)], now: now)
        XCTAssertEqual(single.names, [4: "School"])
        // Not seen for over two weeks: forgotten.
        let old = WindowNaming.assign(stored, to: [], now: now.addingTimeInterval(15 * 86400))
        XCTAssertTrue(old.updated.isEmpty)
    }
}

final class SwitcherKeyTapTests: XCTestCase {
    private final class Box: @unchecked Sendable {
        var events: [SwitcherKeyTap.Event] = []
    }

    private func key(_ code: Int, down: Bool, _ flags: CGEventFlags) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down)!
        event.flags = flags
        return event
    }

    private func flags(_ flags: CGEventFlags) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Command), keyDown: true)!
        event.type = .flagsChanged
        event.flags = flags
        return event
    }

    func testCommandTabOpensAndIsSwallowed() {
        let box = Box()
        let tap = SwitcherKeyTap { box.events.append($0) }
        XCTAssertNil(tap.handle(type: .keyDown, event: key(kVK_Tab, down: true, .maskCommand)))
        XCTAssertEqual(tap.mode, .open)
        XCTAssertEqual(box.events, [.trigger(backward: false, appWindows: false, isRepeat: false)])
        // Its key-up is swallowed too.
        XCTAssertNil(tap.handle(type: .keyUp, event: key(kVK_Tab, down: false, .maskCommand)))
    }

    func testOrdinaryTypingPassesThrough() {
        let box = Box()
        let tap = SwitcherKeyTap { box.events.append($0) }
        XCTAssertNotNil(tap.handle(type: .keyDown, event: key(kVK_Tab, down: true, [])))
        XCTAssertNotNil(tap.handle(type: .keyDown, event: key(kVK_ANSI_W, down: true, .maskCommand)))
        XCTAssertNotNil(tap.handle(type: .keyUp, event: key(kVK_ANSI_W, down: false, .maskCommand)))
        // ⌘⌥Tab belongs to someone else.
        XCTAssertNotNil(tap.handle(type: .keyDown, event: key(kVK_Tab, down: true, [.maskCommand, .maskAlternate])))
        XCTAssertTrue(box.events.isEmpty)
        XCTAssertEqual(tap.mode, .idle)
    }

    func testWhileOpenKeysGoToTheSwitcherAndReleaseCommits() {
        let box = Box()
        let tap = SwitcherKeyTap { box.events.append($0) }
        _ = tap.handle(type: .keyDown, event: key(kVK_Tab, down: true, .maskCommand))
        XCTAssertNil(tap.handle(type: .keyDown, event: key(kVK_Tab, down: true, [.maskCommand, .maskShift])))
        XCTAssertNil(tap.handle(type: .keyDown, event: key(kVK_ANSI_W, down: true, .maskCommand)))
        XCTAssertTrue(tap.isTriggerHeld)
        XCTAssertNotNil(tap.handle(type: .flagsChanged, event: flags([])))
        XCTAssertFalse(tap.isTriggerHeld)
        XCTAssertEqual(box.events, [
            .trigger(backward: false, appWindows: false, isRepeat: false),
            .trigger(backward: true, appWindows: false, isRepeat: false),
            .key(code: kVK_ANSI_W, shift: false, isRepeat: false),
            .released,
        ])
    }

    func testKeyAboveTabOpensTheFrontAppsWindows() {
        let box = Box()
        let tap = SwitcherKeyTap { box.events.append($0) }
        XCTAssertNil(tap.handle(type: .keyDown, event: key(kVK_ANSI_Grave, down: true, .maskCommand)))
        XCTAssertEqual(box.events, [.trigger(backward: false, appWindows: true, isRepeat: false)])
        tap.mode = .idle
        tap.appWindowsKey = false
        XCTAssertNotNil(tap.handle(type: .keyDown, event: key(kVK_ANSI_Grave, down: true, .maskCommand)))
    }

    func testOptionTrigger() {
        let box = Box()
        let tap = SwitcherKeyTap { box.events.append($0) }
        tap.trigger = .option
        XCTAssertNotNil(tap.handle(type: .keyDown, event: key(kVK_Tab, down: true, .maskCommand)))
        XCTAssertNil(tap.handle(type: .keyDown, event: key(kVK_Tab, down: true, .maskAlternate)))
        XCTAssertEqual(box.events.count, 1)
    }

    func testTypingModeLetsKeysThrough() {
        let box = Box()
        let tap = SwitcherKeyTap { box.events.append($0) }
        tap.mode = .typing
        XCTAssertNotNil(tap.handle(type: .keyDown, event: key(kVK_ANSI_A, down: true, [])))
        XCTAssertTrue(box.events.isEmpty)
    }

    func testAStuckSwitcherLetsTheKeyboardGo() {
        let box = Box()
        let tap = SwitcherKeyTap { box.events.append($0) }
        _ = tap.handle(type: .keyDown, event: key(kVK_Tab, down: true, .maskCommand))
        // Pretend the switcher's last heartbeat was long ago.
        tap.setLastBeatForTesting(ProcessInfo.processInfo.systemUptime - SwitcherKeyTap.heartbeatTimeout - 1)
        XCTAssertNotNil(tap.handle(type: .keyDown, event: key(kVK_ANSI_A, down: true, [])))
        XCTAssertEqual(tap.mode, .idle)
    }
}

final class PointerIntentTests: XCTestCase {
    func testARestingPointerNeverPicksACard() {
        var pointer = PointerIntent(at: CGPoint(x: 500, y: 400))
        // The switcher opens under it, cards slide beneath it: same spot, nothing picked.
        XCTAssertFalse(pointer.moved(to: CGPoint(x: 500, y: 400)))
        XCTAssertFalse(pointer.moved(to: CGPoint(x: 501, y: 399)))  // a nudge
        XCTAssertFalse(pointer.moved(to: CGPoint(x: 500, y: 400)))
    }

    func testMovingItPicksTheCardUnderIt() {
        var pointer = PointerIntent(at: CGPoint(x: 500, y: 400))
        XCTAssertTrue(pointer.moved(to: CGPoint(x: 540, y: 400)))
        // Standing still again (while Tab moves the selection and cards slide): nothing.
        XCTAssertFalse(pointer.moved(to: CGPoint(x: 540, y: 400)))
        // Slow moves add up from where it last picked.
        XCTAssertFalse(pointer.moved(to: CGPoint(x: 541.5, y: 400)))
        XCTAssertTrue(pointer.moved(to: CGPoint(x: 543, y: 400)))
    }
}
