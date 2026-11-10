//
//  FanHelperProtocol.swift
//  Tutto
//
//  The XPC contract between Tutto.app and TuttoHelper, the root LaunchDaemon that
//  writes fan speeds to the SMC and keeps the Mac awake for Stay Awake (`AwakeCore.swift`).
//
//  This file is compiled into BOTH TuttoKit and TuttoHelper. Sources/TuttoHelper/Shared/
//  holds a symlink to it, so the helper does not have to link all of TuttoKit. Keep it
//  Foundation-only. The explicit @objc name keeps the wire name identical in both modules.
//

import Foundation

/// Names, versions and code-signing requirements shared by the app and the helper.
public enum TuttoFanHelper {
    /// launchd label and Mach service name of the helper.
    public static let machServiceName = "ca.bryanyao.Tutto.helper"
    /// File name passed to `SMAppService.daemon(plistName:)`. The file lives in
    /// `Tutto.app/Contents/Library/LaunchDaemons/`.
    public static let plistName = "ca.bryanyao.Tutto.helper.plist"
    /// Bump this whenever the protocol or the helper's behaviour changes. The app
    /// compares it with `version(reply:)` and re-registers the daemon on a mismatch.
    public static let version = "1.1.0"

    public static let appBundleIdentifier = "ca.bryanyao.Tutto"
    public static let helperIdentifier = "ca.bryanyao.Tutto.helper"
    public static let teamIdentifier = "8WA5T6YMPK"

    /// The helper accepts connections only from a process that satisfies this requirement.
    public static let clientRequirement =
        "anchor apple generic and identifier \"\(appBundleIdentifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""

    /// The app should only talk to a helper that satisfies this requirement
    /// (`NSXPCConnection.setCodeSigningRequirement` on the client side).
    public static let helperRequirement =
        "anchor apple generic and identifier \"\(helperIdentifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""

    /// Where the helper journals a Stay Awake session (root-owned).
    public static let awakeJournalPath = "/Library/Application Support/Tutto/awake.json"

    /// The helper exits after this long with no clients, every fan on automatic and no session.
    /// launchd starts it again the next time the app connects.
    public static let idleExitDelay: TimeInterval = 15

    /// Values for the `mode` argument of `setFan`.
    public static let modeAutomatic = 0
    public static let modeManual = 1

    /// The interface for both ends of the connection.
    public static func makeInterface() -> NSXPCInterface {
        NSXPCInterface(with: TuttoFanHelperProtocol.self)
    }
}

/// Methods TuttoHelper exports over XPC. Every status is an IOKit `IOReturn`
/// (0 = success; see `FanStatus`). Non-root callers of the SMC get
/// `FanStatus.notPrivileged` (0xe00002c1).
@objc(TuttoFanHelperProtocol)
public protocol TuttoFanHelperProtocol {
    /// The helper's `TuttoFanHelper.version`.
    func version(reply: @escaping (String) -> Void)

    /// `mode` 0 = automatic (rpm ignored), 1 = manual at `rpm`. The helper clamps
    /// `rpm` to the fan's [min, max] from the SMC. The string explains a failure.
    func setFan(_ index: Int, mode: Int, rpm: Double, reply: @escaping (Int32, String?) -> Void)

    /// Puts every fan back on automatic control.
    func resetAllFans(reply: @escaping (Int32) -> Void)

    // MARK: Stay Awake (helper 1.1.0)

    /// Keeps the Mac awake, lid closed included (`pmset -a disablesleep 1`), until `deadline`
    /// (seconds since 1970), or moves the end of the session running. The helper ends it by
    /// itself `AwakeLimits.grace` after the deadline, and caps it at `AwakeLimits.longest`.
    func beginAwake(until deadline: Double, reply: @escaping (Int32, String?) -> Void)

    /// Ends the session: paused processes resumed, Low Power Mode and sleep put back. With
    /// `sleepIfLidClosed`, a Mac whose lid is still closed is then put to sleep.
    func endAwake(sleepIfLidClosed: Bool, reply: @escaping (Int32, String?) -> Void)

    /// Low Power Mode for the battery, on or back to what it was before the session.
    func setAwakeLowPower(_ on: Bool, reply: @escaping (Int32, String?) -> Void)

    /// The processes the app paused (JSON `[PausedProcess]`), resumed by the helper if the app
    /// goes away. Only the caller's own processes are kept.
    func setAwakePaused(_ json: Data, reply: @escaping (Int32) -> Void)

    /// The session running, if any: its end (0 = none) and whether Low Power Mode is claimed.
    func awakeState(reply: @escaping (Double, Bool) -> Void)
}
