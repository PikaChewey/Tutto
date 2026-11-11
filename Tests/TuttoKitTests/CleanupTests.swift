import Foundation
import XCTest
@testable import TuttoKit

final class CleanupRulesTests: XCTestCase {
    func testBundleIDsFromNames() {
        XCTAssertEqual(CleanupRules.bundleID(fromName: "com.foo.Bar.plist"), "com.foo.Bar")
        XCTAssertEqual(CleanupRules.bundleID(fromName: "com.foo.Bar.savedState"), "com.foo.Bar")
        XCTAssertEqual(CleanupRules.bundleID(fromName: "group.com.foo.shared"), "com.foo.shared")
        XCTAssertEqual(CleanupRules.bundleID(fromName: "ABCDE12345.com.foo.shared"), "com.foo.shared")
        // As they're really named in ~/Library/Application Scripts: a team ID, then "group." or "groups.".
        XCTAssertEqual(CleanupRules.bundleID(fromName: "3TH5R7YS88.group.com.anchorfree.hss-mac"), "com.anchorfree.hss-mac")
        XCTAssertEqual(CleanupRules.bundleID(fromName: "243LU875E5.groups.com.apple.podcasts"), "com.apple.podcasts")
        XCTAssertEqual(CleanupRules.bundleID(fromName: "org.videolan.vlc"), "org.videolan.vlc")
        XCTAssertNil(CleanupRules.bundleID(fromName: "Discord"))
        XCTAssertNil(CleanupRules.bundleID(fromName: "com.foo"))
        XCTAssertNil(CleanupRules.bundleID(fromName: "My App 2.0 Backup"))
        XCTAssertNil(CleanupRules.bundleID(fromName: "Google Chrome.app"))
    }

    func testAppleIsNeverTouched() {
        XCTAssertTrue(CleanupRules.isApple("com.apple.Safari"))
        XCTAssertTrue(CleanupRules.isApple("COM.APPLE.dt.Xcode"))
        XCTAssertTrue(CleanupRules.isApple("GeoServices"))      // Maps' cache, under a plain name
        XCTAssertTrue(CleanupRules.isApple("is.workflow.my.app")) // Shortcuts, under its maker's old ID
        XCTAssertTrue(CleanupRules.isApple("org.cups.printingprefs"))
        XCTAssertFalse(CleanupRules.isApple("com.applesauce.app"))
        XCTAssertFalse(CleanupRules.isApple("Steam"))
    }

    /// A removed app's caches start ticked; its data only when untouched for a month and with no
    /// sign-in in it (a command-line tool's login looks like a leftover but isn't one to lose).
    func testLeftoverDataNeedsToBeOldAndHoldNoSignIn() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recently = now.addingTimeInterval(-8 * 24 * 3600)
        let longAgo = now.addingTimeInterval(-90 * 24 * 3600)
        XCTAssertTrue(CleanupRules.suggestsRemoving(places: ["Caches", "HTTPStorages"], lastChange: recently, hasSignIn: false, now: now))
        XCTAssertFalse(CleanupRules.suggestsRemoving(places: ["Application Support", "Caches"], lastChange: recently, hasSignIn: false, now: now))
        XCTAssertTrue(CleanupRules.suggestsRemoving(places: ["Application Support", "Preferences"], lastChange: longAgo, hasSignIn: false, now: now))
        XCTAssertFalse(CleanupRules.suggestsRemoving(places: ["Application Support"], lastChange: longAgo, hasSignIn: true, now: now))
        XCTAssertTrue(CleanupRules.looksLikeSignIn("auth.json"))
        XCTAssertTrue(CleanupRules.looksLikeSignIn("Login Data"))
        XCTAssertFalse(CleanupRules.looksLikeSignIn("config.json"))
        XCTAssertEqual(CleanupRules.vendor(of: "com.Roblox.RobloxStudio"), "com.roblox")
    }

    func testOwnershipLeansSafe() {
        let installed = CleanupRules.normalized(["com.google.Chrome", "org.mozilla.firefox", "com.anthropic.claudefordesktop"])
        XCTAssertTrue(CleanupRules.isOwned("com.google.Chrome", installed: installed))
        XCTAssertTrue(CleanupRules.isOwned("com.google.Chrome.helper", installed: installed))
        XCTAssertTrue(CleanupRules.isOwned("com.google.Keystone", installed: installed))     // same vendor: Chrome's updater
        XCTAssertTrue(CleanupRules.isOwned("ORG.MOZILLA.FIREFOX", installed: installed))
        XCTAssertFalse(CleanupRules.isOwned("com.spotify.client", installed: installed))     // nothing from Spotify is here
        XCTAssertFalse(CleanupRules.isOwned("com.tinyspeck.slackmacgap", installed: installed))
    }

    func testOnlyPlainPathsInsideTheRootMayGo() {
        let root = "/Users/me/Library/Caches"
        XCTAssertTrue(CleanupRules.isSafeToRemove("/Users/me/Library/Caches/com.spotify.client", root: root))
        XCTAssertFalse(CleanupRules.isSafeToRemove(root, root: root))
        XCTAssertFalse(CleanupRules.isSafeToRemove("/Users/me/Library/Caches/../Mail", root: root))
        XCTAssertFalse(CleanupRules.isSafeToRemove("/Users/me/Library/CachesX/thing", root: root))
        XCTAssertFalse(CleanupRules.isSafeToRemove("Library/Caches/thing", root: root))
        XCTAssertFalse(CleanupRules.isSafeToRemove("/Users/me/Library/Caches/bad\u{07}name", root: root))
        // A link inside the root that points elsewhere.
        XCTAssertFalse(CleanupRules.isSafeToRemove("/Users/me/Library/Caches/link", root: root, resolved: "/Users/me/Documents"))
        XCTAssertTrue(CleanupRules.isSafeToRemove("/Users/me/Library/Caches/link", root: root, resolved: "/Users/me/Library/Caches/real"))
        XCTAssertFalse(CleanupRules.isSafeToRemove("/System/Library/Caches/x", root: "/System/Library/Caches"))
    }

    func testDeveloperCachesAreKnown() {
        XCTAssertTrue(CleanupRules.isDeveloperCache("Library/Caches/Homebrew"))
        XCTAssertTrue(CleanupRules.isDeveloperCache("Library/Caches/pip/http"))
        XCTAssertTrue(CleanupRules.isDeveloperCache("Library/Caches/org.swift.swiftpm"))
        XCTAssertFalse(CleanupRules.isDeveloperCache("Library/Caches/com.spotify.client"))
        XCTAssertFalse(CleanupCategory.developer.selectedByDefault)
        XCTAssertFalse(CleanupCategory.probableLeftover.selectedByDefault)
        XCTAssertTrue(CleanupCategory.leftover.selectedByDefault)
    }
}
