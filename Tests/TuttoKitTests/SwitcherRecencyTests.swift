import CoreGraphics
import Foundation
import XCTest
@testable import TuttoKit

/// The order ⌘Tab remembers ("the window you were just in is one press away") has to survive
/// Tutto restarting and windows dropping out of one listing. Window numbers and stacking values
/// are from a real session: four apps, each in full screen on its own Space, where the window
/// server's full list orders windows by their Space, not by use, and the app whose Space is
/// last (`chat`, z 145) sorted after everything whenever its use was forgotten.
final class SwitcherRecencyTests: XCTestCase {
    private let chat: CGWindowID = 104_473, browser: CGWindowID = 104_319, web: CGWindowID = 107_022, notes: CGWindowID = 39065
    private let chatApp = "com.example.chat", browserApp = "com.example.browser", webApp = "com.example.web", notesApp = "com.example.notes"
    private var windows: [(id: CGWindowID, zIndex: Int, demoted: Bool)] {
        [(web, 46, false), (browser, 59, false), (notes, 110, false), (chat, 145, false)]
    }
    private var apps: [CGWindowID: String] { [chat: chatApp, browser: browserApp, web: webApp, notes: notesApp] }

    /// You were in chat, went to the browser, and Tutto restarted: the next ⌘Tab still has chat
    /// one press away instead of last.
    func testTheOrderSurvivesARestart() throws {
        var before = RecentWindows()
        before.touch(notes, app: notesApp)
        before.touch(chat, app: chatApp)
        before.touch(browser, app: browserApp)
        let saved = try JSONDecoder().decode(SwitcherMemory.self,
                                             from: JSONEncoder().encode(SwitcherMemory(session: "login-1", recent: before, apps: [:])))

        // What a restart used to leave: nothing remembered, so the Space order decides.
        XCTAssertEqual(SwitcherOrder.order(windows, recent: RecentWindows().ids).last, chat)

        var after = RecentWindows()
        after.restore(saved, session: "login-1", windows: apps)
        XCTAssertEqual(SwitcherOrder.order(windows, recent: after.ids), [browser, chat, notes, web])
    }

    /// Windows used since the restart are newer than anything saved before it.
    func testWindowsUsedSinceTheRestartComeFirst() {
        var before = RecentWindows()
        before.touch(chat, app: chatApp)
        before.touch(browser, app: browserApp)
        var after = RecentWindows()
        after.touch(notes, app: notesApp)
        after.restore(SwitcherMemory(session: "s", recent: before, apps: [:]), session: "s", windows: apps)
        XCTAssertEqual(after.ids, [notes, browser, chat])
    }

    /// A saved order only applies in the same login (window numbers start over after logging
    /// out) and only to windows that still belong to the same app.
    func testASavedOrderNeedsTheSameLoginAndApp() {
        var before = RecentWindows()
        before.touch(chat, app: chatApp)
        before.touch(browser, app: browserApp)
        let saved = SwitcherMemory(session: "login-1", recent: before, apps: [:])

        var otherLogin = RecentWindows()
        otherLogin.restore(saved, session: "login-2", windows: apps)
        XCTAssertEqual(otherLogin.ids, [])

        // The chat window's number now belongs to another app's window; the browser's is gone.
        var reused = RecentWindows()
        reused.restore(saved, session: "login-1", windows: [chat: webApp])
        XCTAssertEqual(reused.ids, [])
    }

    /// A window that drops out of one listing (between Spaces, mid-animation, briefly not shown)
    /// keeps its place; only quitting its app forgets it.
    func testAWindowMissingFromOneListingKeepsItsPlace() {
        var recent = RecentWindows()
        recent.touch(notes, app: notesApp)
        recent.touch(chat, app: chatApp)
        recent.touch(browser, app: browserApp)
        // This listing has no chat window, but the app is still running.
        recent.keep(appsRunning: [browserApp, notesApp, chatApp, webApp])
        XCTAssertEqual(SwitcherOrder.order(windows, recent: recent.ids), [browser, chat, notes, web])

        recent.keep(appsRunning: [browserApp, notesApp, webApp])
        XCTAssertEqual(recent.ids, [browser, notes])
    }

    /// When each app was last in front (for app cards) comes back the same way, by app.
    func testAppTimesSurviveARestart() {
        let saved = SwitcherMemory(session: "s", recent: RecentWindows(), apps: [chatApp: 120, browserApp: 300])
        XCTAssertEqual(saved.apps(session: "s", running: [chatApp: 11, browserApp: 12, webApp: 13]), [11: 120, 12: 300])
        XCTAssertEqual(saved.apps(session: "other", running: [chatApp: 11]), [:])
    }

    /// An entry touched without knowing its app keeps the app it was first seen with.
    func testTouchKeepsAKnownApp() {
        var recent = RecentWindows()
        recent.touch(chat, app: chatApp)
        recent.touch(browser, app: browserApp)
        recent.touch(chat, app: "")
        XCTAssertEqual(recent.entries, [.init(id: chat, app: chatApp), .init(id: browser, app: browserApp)])
    }
}
