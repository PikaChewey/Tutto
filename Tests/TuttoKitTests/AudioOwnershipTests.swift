import XCTest
@testable import TuttoKit

final class AudioOwnershipTests: XCTestCase {
    private let discord = AudioOwnership.App(pid: 100, bundleID: "com.hnc.Discord", bundlePath: "/Applications/Discord.app")
    private let opera = AudioOwnership.App(pid: 200, bundleID: "com.operasoftware.OperaGX", bundlePath: "/Applications/Opera GX.app")
    private let safari = AudioOwnership.App(pid: 300, bundleID: "com.apple.Safari", bundlePath: "/Applications/Safari.app")
    private let studio = AudioOwnership.App(pid: 400, bundleID: "com.Roblox.RobloxStudio", bundlePath: "/Applications/RobloxStudio.app")

    private func system(responsible: [pid_t: pid_t] = [:], paths: [pid_t: String] = [:], parents: [pid_t: pid_t] = [:])
        -> AudioOwnership.System {
        AudioOwnership.System(responsible: { responsible[$0] }, path: { paths[$0] }, parent: { parents[$0] })
    }

    func testAppPlayingFromItsOwnProcess() {
        XCTAssertEqual(AudioOwnership.owner(of: 400, among: [discord, studio], system: system())?.bundleID, "com.Roblox.RobloxStudio")
    }

    func testHelperInsideTheBundleBelongsToTheApp() {
        // Opera GX's audio comes from "Opera Helper", bundle ID com.operasoftware.Opera.helper: no shared prefix.
        let helperPath = "/Applications/Opera GX.app/Contents/Frameworks/Opera Framework.framework/Versions/1/Helpers/Opera Helper.app/Contents/MacOS/Opera Helper"
        let owner = AudioOwnership.owner(of: 201, among: [discord, opera], system: system(paths: [201: helperPath]))
        XCTAssertEqual(owner?.bundleID, "com.operasoftware.OperaGX")
    }

    func testXPCServiceGoesToItsResponsibleApp() {
        // Safari plays through WebKit's GPU service, which lives in /System, not in Safari.app.
        let owner = AudioOwnership.owner(of: 301, among: [safari, discord], system: system(
            responsible: [301: 300], paths: [301: "/System/Library/Frameworks/WebKit.framework/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU"]))
        XCTAssertEqual(owner?.bundleID, "com.apple.Safari")
    }

    func testParentChainAsLastResort() {
        let owner = AudioOwnership.owner(of: 999, among: [discord], system: system(parents: [999: 998, 998: 100]))
        XCTAssertEqual(owner?.bundleID, "com.hnc.Discord")
    }

    func testLookAlikePathIsNotInsideTheBundle() {
        let owner = AudioOwnership.owner(of: 500, among: [discord], system: system(paths: [500: "/Applications/Discord.app2/Contents/MacOS/x"]))
        XCTAssertNil(owner)
    }

    func testNestedAppWinsOverTheAppAroundIt() {
        let inner = AudioOwnership.App(pid: 600, bundleID: "com.example.Inner", bundlePath: "/Applications/Outer.app/Contents/Inner.app")
        let outer = AudioOwnership.App(pid: 601, bundleID: "com.example.Outer", bundlePath: "/Applications/Outer.app")
        let owner = AudioOwnership.owner(of: 602, among: [outer, inner],
                                         system: system(paths: [602: "/Applications/Outer.app/Contents/Inner.app/Contents/MacOS/Inner"]))
        XCTAssertEqual(owner?.bundleID, "com.example.Inner")
    }

    func testUnknownProcessIsNobodys() {
        XCTAssertNil(AudioOwnership.owner(of: 700, among: [discord, opera], system: system(
            responsible: [700: 700], paths: [700: "/usr/bin/afplay"], parents: [700: 1])))
    }

    func testLiveProcessListIsReadable() {
        let processes = AudioProcessList.read()
        XCTAssertTrue(processes.allSatisfy { $0.pid > 0 && $0.objectID != 0 })
        // The responsible-process lookup exists on this macOS.
        XCTAssertNotNil(ProcessInfoLookup.responsiblePID(getpid()))
        XCTAssertNotNil(ProcessInfoLookup.executablePath(getpid()))
    }
}
