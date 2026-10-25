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

    /// Roblox Studio keeps an untitled helper surface (57193) above its window (56955): the card
    /// for the window you're in is still Studio's own window, so the first press goes back. Only
    /// windows on screen count, and an app in front with no card there (Finder at the desktop)
    /// has none: the first press goes to the window used last.
    func testTheWindowYoureInIsTheFrontAppsCardUnderItsHelpers() {
        let firefox: pid_t = 5723, studio: pid_t = 23927, discord: pid_t = 97080, finder: pid_t = 679
        let cards: [(id: CGWindowID, pid: pid_t)] = [(44094, firefox), (44095, firefox), (56955, studio), (55343, discord)]
        XCTAssertEqual(SwitcherOrder.current(onScreen: [57193, 56955], frontApp: studio, cards: cards), 56955)
        // Firefox's window on another Space (44094) isn't the one you're in, wherever it stacks.
        XCTAssertEqual(SwitcherOrder.current(onScreen: [55343, 44095], frontApp: firefox, cards: cards), 44095)
        XCTAssertNil(SwitcherOrder.current(onScreen: [55343, 44095], frontApp: finder, cards: cards))
        XCTAssertEqual(SwitcherOrder.current(onScreen: [57193, 56955], frontApp: nil, cards: cards), 56955)
    }

    /// "This Space" from a full-screen app (Roblox Studio on its own Space) shows every window;
    /// from a desktop it keeps to that desktop.
    func testThisSpaceFromAFullScreenAppShowsEverySpace() {
        let desktop = SpaceInfo(id: 1, isFullScreen: false, desktopNumber: 1, isCurrent: true)
        let studio = SpaceInfo(id: 3925, isFullScreen: true, desktopNumber: 0, isCurrent: true)
        let otherDisplayDesktop = SpaceInfo(id: 7, isFullScreen: false, desktopNumber: 1, isCurrent: true)
        XCTAssertTrue(SpaceScope.showsEverySpace(current: [studio], frontSpace: 3925))
        XCTAssertTrue(SpaceScope.showsEverySpace(current: [studio], frontSpace: nil))
        XCTAssertFalse(SpaceScope.showsEverySpace(current: [desktop], frontSpace: 1))
        XCTAssertFalse(SpaceScope.showsEverySpace(current: [desktop], frontSpace: nil))
        // Two displays: the Space of the window you're in decides.
        XCTAssertTrue(SpaceScope.showsEverySpace(current: [studio, otherDisplayDesktop], frontSpace: 3925))
        XCTAssertFalse(SpaceScope.showsEverySpace(current: [studio, otherDisplayDesktop], frontSpace: 7))
        XCTAssertFalse(SpaceScope.showsEverySpace(current: [studio, otherDisplayDesktop], frontSpace: nil))
    }

    /// "This Space" from Desktop 1: other desktops' windows go, except minimized ones and hidden
    /// apps'; an app with nothing to see here is away, even with a window minimized here. A game
    /// in full screen stays, a window with its picture: it has its Space to itself (reported: from
    /// Desktop 1, ⌘Tab showed Roblox in full screen as an icon).
    func testThisSpaceKeepsTuckedWindowsAndNamesTheAppsAway() {
        let firefox: pid_t = 5723, discord: pid_t = 97080, roblox: pid_t = 40860, notes: pid_t = 900
        let split = SpaceScope.split([
            (44094, firefox, 2, false),     // Firefox on Desktop 2
            (44095, firefox, 1, true),      // and one minimized
            (55343, discord, 1, false),     // here
            (58225, roblox, 3979, false),   // a game in full screen
            (70000, notes, 2, true),        // a hidden app's window on Desktop 2
            (71000, discord, nil, false),   // Space not known: stays
        ], here: [1], fullScreen: [3979])
        XCTAssertEqual(split.kept, [44095, 55343, 58225, 70000, 71000])
        XCTAssertEqual(split.away, [firefox: [44094]])
    }

    /// Apps without a card come most recently used first, not in the order they were launched.
    func testAppsWithoutCardsGoMostRecentFirst() {
        let finder: pid_t = 679, chatGPT: pid_t = 85868, firefox: pid_t = 5723, discord: pid_t = 97080
        let order = SwitcherOrder.apps([finder, chatGPT, firefox, discord], lastUsed: [discord: 500, firefox: 300])
        XCTAssertEqual(order, [discord, firefox, finder, chatGPT])
    }

    func testAnAppOnAnotherDesktopYouJustLeftIsOnePressAwayFromThisSpace() {
        // Desktop 1: Discord in front, Firefox behind it. Roblox's only window (56684) is on
        // Desktop 2, and you came to Discord from it.
        let discord: CGWindowID = 55343, firefox: CGWindowID = 54100, roblox: CGWindowID = 56684, studio: CGWindowID = 56955
        let robloxApp: pid_t = 32635, studioApp: pid_t = 23927
        let cards = SwitcherOrder.order([(discord, 0, false), (firefox, 1, false)],
                                        away: [robloxApp: [roblox], studioApp: [studio]], recent: [discord, roblox, firefox, studio])
        XCTAssertEqual(cards, [.window(discord), .app(robloxApp), .window(firefox), .app(studioApp)])
        XCTAssertEqual(SwitcherOrder.initialSelection(count: cards.count, firstIsCurrent: true, backward: false), 1)
        // An app with windows on several Spaces goes where the one you used last would.
        XCTAssertEqual(SwitcherOrder.order([(discord, 0, false), (firefox, 1, false)], away: [studioApp: [700, studio]],
                                           recent: [discord, 700, firefox, studio]),
                       [.window(discord), .app(studioApp), .window(firefox)])
        // None of its windows used since Tutto started: not placed (it goes after the windows).
        XCTAssertEqual(SwitcherOrder.order([(discord, 0, false), (firefox, 1, false)], away: [robloxApp: [roblox]], recent: [discord]),
                       [.window(discord), .window(firefox)])
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

    /// A hand on the mouse (playing a game, the pointer mid-screen where the switcher opens)
    /// jiggles it a few points: that's not pointing at a card.
    func testAJiggleUnderTenPointsPicksNothing() {
        var pointer = PointerIntent(at: CGPoint(x: 756, y: 491))
        for jiggle in [CGPoint(x: 760, y: 494), CGPoint(x: 750, y: 488), CGPoint(x: 764, y: 499), CGPoint(x: 757, y: 485)] {
            XCTAssertFalse(pointer.moved(to: jiggle), "\(jiggle)")
        }
        XCTAssertTrue(pointer.moved(to: CGPoint(x: 780, y: 491)))
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
