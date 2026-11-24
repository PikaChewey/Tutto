import AppKit
import XCTest
@testable import TuttoKit

/// Live only (`FULLSCREEN_LIVE=1`): the windows of regular apps that sit in native full screen, as
/// Strip finds them to bring back. Skipped otherwise.
final class FullScreenLiveTests: XCTestCase {
    func testListsFullScreenWindows() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FULLSCREEN_LIVE"] == "1")
        let spaces = WindowServer.spaces()
        let pids = Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map(\.processIdentifier))
        for window in WindowServer.windows(of: pids) where WindowAdmission.admits(window) {
            let space = WindowServer.space(of: window.id)
            let full = space.flatMap { spaces[$0]?.isFullScreen } ?? false
            print("live-window", window.pid, window.id, full ? "FULL" : "-", NSRunningApplication(processIdentifier: window.pid)?.localizedName ?? "?")
        }
    }
}
