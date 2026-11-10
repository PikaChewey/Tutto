//
//  LidActions.swift
//  Tutto
//
//  What Stay Awake does to the Mac while the lid is closed, and undoes when it opens: the
//  built-in display asleep (with sleep disabled macOS no longer does this itself; the keyboard
//  light goes out with it), the sound muted, and the apps you chose paused. Plus the lid itself:
//  an IOKit notification from the power manager, so nothing runs between lid changes.
//

import AppKit
import CoreAudio
import IOKit
import IOKit.pwr_mgt
import os
import TuttoKit

let awakeLog = Logger(subsystem: "ca.bryanyao.Tutto", category: "awake")

// MARK: - Lid

/// Watches the lid. `onChange` gets `true` for closed, once the lid has stayed that way for 2 s
/// (opening and closing it quickly does nothing). Runs only while a session needs it.
@MainActor
final class LidObserver {
    static let debounce: TimeInterval = 2

    var onChange: ((Bool) -> Void)?
    private(set) var isClosed = false

    private var port: IONotificationPortRef?
    private var service: io_service_t = 0
    private var notification: io_object_t = 0
    private var pending: DispatchWorkItem?
    /// A simulated close holds until a simulated open; the real lid is ignored meanwhile.
    private var simulating = false

    /// True = closed, false = open, nil = no lid (a desktop Mac).
    nonisolated static func read() -> Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        guard let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() else { return nil }
        return (value as? Bool) ?? (value as? NSNumber)?.boolValue
    }

    func start() {
        guard port == nil else { return }
        isClosed = Self.read() ?? false
        service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0, let port = IONotificationPortCreate(kIOMainPortDefault) else {
            awakeLog.error("lid: no power manager to watch")
            return
        }
        self.port = port
        IONotificationPortSetDispatchQueue(port, .main)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let result = IOServiceAddInterestNotification(port, service, kIOGeneralInterest, { refcon, _, _, _ in
            guard let refcon else { return }
            let observer = Unmanaged<LidObserver>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { observer.changed() }
        }, refcon, &notification)
        if result != KERN_SUCCESS {
            awakeLog.error("lid: interest notification failed (\(result))")
            stop()
        }
    }

    func stop() {
        pending?.cancel()
        pending = nil
        simulating = false
        if notification != 0 { IOObjectRelease(notification); notification = 0 }
        if let port { IONotificationPortDestroy(port); self.port = nil }
        if service != 0 { IOObjectRelease(service); service = 0 }
    }

    var isSimulating: Bool { simulating }

    /// Drops a simulated close and goes back to the real lid (no `onChange`).
    func endSimulation() {
        simulating = false
        isClosed = Self.read() ?? false
    }

    /// For tests of the lid actions without closing the lid (`tutto://do/lid-closed`).
    func simulate(closed: Bool) {
        pending?.cancel()
        pending = nil
        simulating = closed
        guard closed != isClosed else { return }
        isClosed = closed
        onChange?(closed)
    }

    private func changed() {
        guard !simulating, let now = Self.read() else { return }
        pending?.cancel()
        pending = nil
        guard now != isClosed else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.simulating, Self.read() == now, now != self.isClosed else { return }
                self.isClosed = now
                awakeLog.notice("lid \(now ? "closed" : "open", privacy: .public)")
                self.onChange?(now)
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce, execute: work)
    }
}

enum Displays {
    /// Another display is on: closing the lid is then an ordinary desk set-up.
    static func externalIsActive() -> Bool {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return false }
        return ids.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
    }

    static func builtIn() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }
}

// MARK: - Display

/// The built-in display's sleep. Stay Awake never writes the brightness: with auto-brightness on,
/// a written level is taken as your preference and the screen can come back at another level.
enum DisplayPower {
    /// Asks the display to sleep now (what `pmset displaysleepnow` does). macOS defers it for a
    /// while after a wake, and ignores it while an app holds a display assertion (a video playing).
    static func requestSleep() {
        let wrangler = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources/IODisplayWrangler")
        guard wrangler != 0 else { return }
        defer { IOObjectRelease(wrangler) }
        IORegistryEntrySetCFProperty(wrangler, "IORequestIdle" as CFString, kCFBooleanTrue)
    }

    /// Wakes a sleeping display, as a key press would.
    static func wake() {
        var id: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("Tutto: lid opened" as CFString, kIOPMUserActiveLocal, &id)
    }

    static var isAsleep: Bool { Displays.builtIn().map { CGDisplayIsAsleep($0) != 0 } ?? false }
}

// MARK: - Sound

/// The default output's mute switch.
enum OutputMute {
    struct Saved: Codable, Equatable {
        var deviceUID: String
        var wasMuted: Bool
    }

    private static var muteAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                                                mScope: kAudioDevicePropertyScopeOutput,
                                                                mElement: kAudioObjectPropertyElementMain)

    /// Mutes the default output; returns what to put back, or nil when it can't be muted.
    static func mute() -> Saved? {
        guard let device = AudioDevices.defaultOutputID(), let uid = AudioDevices.defaultOutputUID(),
              let muted = isMuted(device) else { return nil }
        if !muted { setMuted(device, true) }
        return Saved(deviceUID: uid, wasMuted: muted)
    }

    static func restore(_ saved: Saved) {
        guard let device = device(uid: saved.deviceUID), isMuted(device) == true, !saved.wasMuted else { return }
        setMuted(device, false)
    }

    private static func isMuted(_ device: AudioObjectID) -> Bool? {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectHasProperty(device, &muteAddress),
              AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    private static func setMuted(_ device: AudioObjectID, _ muted: Bool) {
        var value: UInt32 = muted ? 1 : 0
        let status = AudioObjectSetPropertyData(device, &muteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        if status != noErr { awakeLog.error("mute \(muted): \(status)") }
    }

    private static func device(uid: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { pointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), pointer, &size, &device)
        }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }
}

// MARK: - Pausing apps

enum AppPauser {
    /// The regular apps open now, as Stay Awake sees them.
    static func openApps() -> [(app: AwakeApp, running: NSRunningApplication)] {
        NSWorkspace.shared.runningApplications.compactMap { running in
            guard running.activationPolicy == .regular, let id = running.bundleIdentifier, !running.isTerminated else { return nil }
            let category = running.bundleURL.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String }
            return (AwakeApp(bundleID: id, name: running.localizedName ?? id, category: category), running)
        }
    }

    /// SIGSTOP for each app and everything it started (parent first, so it can't react to its
    /// children stopping). Returns what was paused, for `resume`.
    static func pause(_ apps: [NSRunningApplication]) -> [PausedProcess] {
        let parents = ProcessTree.parents()
        var paused: [PausedProcess] = []
        let uid = getuid()
        for app in apps {
            for pid in ProcessTree.family(of: app.processIdentifier, parents: parents).reversed() {
                guard let identity = SystemProcesses.identity(of: pid), identity.uid == uid else { continue }
                if kill(pid, SIGSTOP) == 0 { paused.append(PausedProcess(pid: pid, startTime: identity.startTime, uid: uid)) }
            }
        }
        return paused
    }

    /// SIGCONT, children first, for each paused process that is still the one that was paused.
    static func resume(_ paused: [PausedProcess]) {
        for process in paused.reversed() {
            guard let identity = SystemProcesses.identity(of: process.pid), identity.uid == process.uid,
                  abs(identity.startTime - process.startTime) < 0.001 else { continue }
            kill(process.pid, SIGCONT)
        }
    }
}
