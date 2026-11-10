//
//  LidActions.swift
//  Tutto
//
//  What Stay Awake does to the Mac while the lid is closed, and undoes when it opens: the
//  built-in display asleep (with sleep disabled macOS no longer does this itself; the keyboard
//  light goes out with it), or dimmed to 0 if an app holds it awake, the sound muted, and the
//  apps you chose paused. Plus the lid itself:
//  an IOKit notification from the power manager, so nothing runs between lid changes.
//
//  The brightness fallback goes through private frameworks (DisplayServices, CoreBrightness) with no
//  contract, so each is checked before its first use: DisplayServices only on the macOS versions it
//  was measured on, the keyboard client only while its methods have the types measured on macOS 26.
//

import AppKit
import CoreAudio
import IOKit
import IOKit.pwr_mgt
import ObjectiveC.runtime
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

/// The built-in display's sleep: what the lid closing asks for first, since it leaves your brightness
/// alone. Only when an app holds the display awake does Stay Awake dim it instead (`DisplayBrightness`).
enum DisplayPower {
    /// Puts the display to sleep now, through `pmset displaysleepnow` (no root needed). Setting
    /// IODisplayWrangler's IORequestIdle from an app does nothing on this Mac (measured: the display
    /// stayed awake with nothing holding it); pmset slept it within 3 s. macOS may still keep it on
    /// while an app holds it awake, which is when the dimming fallback steps in. Like closing the
    /// lid, display sleep locks the screen when a password is required after sleep.
    static func requestSleep() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { awakeLog.error("displaysleepnow: \(error.localizedDescription, privacy: .public)") }
    }

    /// Wakes a sleeping display, as a key press would.
    static func wake() {
        var id: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("Tutto: lid opened" as CFString, kIOPMUserActiveLocal, &id)
    }

    static var isAsleep: Bool { Displays.builtIn().map { CGDisplayIsAsleep($0) != 0 } ?? false }
}

/// The built-in display's brightness, through DisplayServices: the fallback when the display
/// can't be put to sleep (an app holds it awake, a sound playing for one).
enum DisplayBrightness {
    /// macOS versions the DisplayServices calls were measured on. A C symbol carries no types, so
    /// on any other version the display is left alone.
    static let measuredMajors: Set<Int> = [26]

    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set_ = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let symbols: (get: Get, set: Set_)? = {
        guard measuredMajors.contains(ProcessInfo.processInfo.operatingSystemVersion.majorVersion),
              let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let get = dlsym(handle, "DisplayServicesGetBrightness"),
              let set = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
        return (unsafeBitCast(get, to: Get.self), unsafeBitCast(set, to: Set_.self))
    }()

    /// Why the display is left alone, or nil.
    static var refusal: String? {
        guard symbols == nil else { return nil }
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        return measuredMajors.contains(major) ? "macOS's brightness controls couldn't be loaded." : "Not yet checked on macOS \(major), so the display is left on."
    }

    static func read() -> Float? {
        guard let symbols, let display = Displays.builtIn() else { return nil }
        var value: Float = 0
        return symbols.get(display, &value) == 0 ? value : nil
    }

    @discardableResult
    static func set(_ value: Float) -> Bool {
        guard let symbols, let display = Displays.builtIn() else { return false }
        return symbols.set(display, min(max(value, 0), 1)) == 0
    }
}

/// The built-in keyboard's backlight, through CoreBrightness's KeyboardBrightnessClient.
enum KeyboardLight {
    /// Type encodings measured on macOS 26 (offsets removed). A changed one refuses the client.
    static let measured: [String: String] = [
        "copyKeyboardBacklightIDs": "@@:",
        "isKeyboardBuiltIn:": "B@:Q",
        "brightnessForKeyboard:": "f@:Q",
        "setBrightness:forKeyboard:": "B@:fQ",
    ]

    private static let client: (object: NSObject, cls: AnyClass)? = {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY) != nil,
              let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return nil }
        for (name, encoding) in measured {
            guard let method = class_getInstanceMethod(cls, NSSelectorFromString(name)),
                  let raw = method_getTypeEncoding(method) else { return nil }
            guard String(cString: raw).filter({ !$0.isNumber }) == encoding else { return nil }
        }
        return (cls.init(), cls)
    }()

    static var refusal: String? { client == nil ? "macOS's keyboard light controls didn't look as expected, so it's left on." : nil }

    private static func imp<T>(_ name: String, as type: T.Type) -> T? {
        guard let client, let method = class_getInstanceMethod(client.cls, NSSelectorFromString(name)) else { return nil }
        return unsafeBitCast(method_getImplementation(method), to: type)
    }

    private static func builtInIDs() -> [UInt64] {
        typealias Copy = @convention(c) (NSObject, Selector) -> Unmanaged<NSArray>?
        typealias BuiltIn = @convention(c) (NSObject, Selector, UInt64) -> Bool
        guard let client, let copy = imp("copyKeyboardBacklightIDs", as: Copy.self),
              let isBuiltIn = imp("isKeyboardBuiltIn:", as: BuiltIn.self),
              let ids = copy(client.object, NSSelectorFromString("copyKeyboardBacklightIDs"))?.takeRetainedValue() as? [NSNumber]
        else { return [] }
        return ids.map(\.uint64Value).filter { isBuiltIn(client.object, NSSelectorFromString("isKeyboardBuiltIn:"), $0) }
    }

    static func read() -> Float? {
        typealias Get = @convention(c) (NSObject, Selector, UInt64) -> Float
        guard let client, let id = builtInIDs().first, let get = imp("brightnessForKeyboard:", as: Get.self) else { return nil }
        return get(client.object, NSSelectorFromString("brightnessForKeyboard:"), id)
    }

    @discardableResult
    static func set(_ value: Float) -> Bool {
        typealias Set_ = @convention(c) (NSObject, Selector, Float, UInt64) -> Bool
        guard let client, let set = imp("setBrightness:forKeyboard:", as: Set_.self) else { return false }
        let ids = builtInIDs()
        return !ids.isEmpty && ids.allSatisfy { set(client.object, NSSelectorFromString("setBrightness:forKeyboard:"), min(max(value, 0), 1), $0) }
    }
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
