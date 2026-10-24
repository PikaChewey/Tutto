//
//  SoundModule.swift
//  Tutto
//
//  Mutes chosen apps at the speakers and headphones. The apps keep playing (and anything
//  that records them, like a screen recording or an assistant listening in, still hears
//  them); their sound just never reaches the output device.
//
//  How (see MuteRig): one private Core Audio tap over every sound process of the muted
//  apps, inside a private device that Core Audio starts only when one of them plays.
//  Half a second after they go quiet the device is stopped and re-armed, so a muted app
//  that is silent costs nothing and never keeps the Mac awake.
//
//  Nothing polls while the panel is closed. Core Audio announces new sound processes
//  (Discord opening a call helper), output changes (headphones), and restarts; muted
//  apps stay muted when they relaunch and after Tutto restarts.
//

import AppKit
import CoreAudio
import Observation
import TuttoKit

/// One app in the ⌘Tab switcher.
struct SoundApp: Identifiable, Equatable {
    let bundleID: String
    let name: String
    let pid: pid_t
    let icon: NSImage
    var id: String { bundleID }
}

@MainActor
@Observable
final class SoundModule: ModuleController {
    /// Bundle IDs, remembered across launches.
    private(set) var muted: Set<String>
    /// Running ⌘Tab apps, refreshed while something shows them.
    private(set) var apps: [SoundApp] = []
    /// Bundle IDs of apps with an output stream running right now.
    private(set) var usingAudio: Set<String> = []
    /// Shown in the panel and on the page when muting can't happen.
    private(set) var problem: String?
    private(set) var access: SystemAudioAccess.Status = SystemAudioAccess.status()

    static var isSupported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    private let defaults = UserDefaults.standard
    private static let mutedKey = "sound.muted"
    private static let excluded: Set<String> = ["com.apple.finder", Bundle.main.bundleIdentifier ?? "ca.bryanyao.Tutto"]

    private var rig: AnyObject?
    private var rigTargets: [AudioObjectID] = []
    private var watchers = 0
    private var timer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    private var systemListeners: [(AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)] = []
    private var outputListeners: [(AudioObjectID, AudioObjectPropertyListenerBlock)] = []
    private var rearmWork: DispatchWorkItem?
    private var refreshWork: DispatchWorkItem?
    private let lookups = DispatchQueue(label: "ca.bryanyao.Tutto.sound.lookups", qos: .userInitiated)

    init() {
        muted = Set(UserDefaults.standard.stringArray(forKey: Self.mutedKey) ?? [])
    }

    // MARK: Lifecycle

    func start() {
        guard Self.isSupported else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            })
        }
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAccess() }
        })
        refreshApps()
        applyMutes()
    }

    func stop() {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0); NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        removeSystemListeners()
        removeOutputListeners()
        timer?.cancel()
        timer = nil
        watchers = 0
        tearDownRig()
    }

    // MARK: Watching (panel or page on screen)

    func begin() {
        watchers += 1
        refreshApps()
        refreshAccess()
        guard timer == nil else { return }
        // "Using audio" dots while something shows them; one cheap Core Audio read a second.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.refreshUsage() } }
        timer.resume()
        self.timer = timer
    }

    func end() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        timer?.cancel()
        timer = nil
    }

    // MARK: Muting

    func isMuted(_ bundleID: String) -> Bool { muted.contains(bundleID) }

    func toggle(_ app: SoundApp) { setMuted(app.bundleID, !muted.contains(app.bundleID)) }

    func setMuted(_ bundleID: String, _ on: Bool) {
        if on {
            guard !Self.excluded.contains(bundleID) else { return }
            muted.insert(bundleID)
        } else {
            muted.remove(bundleID)
        }
        defaults.set(muted.sorted(), forKey: Self.mutedKey)
        if on && access == .unknown {
            // The first mute asks macOS (System Audio Recording); mute once it answers.
            SystemAudioAccess.request { [weak self] _ in
                Task { @MainActor in
                    self?.refreshAccess()
                    self?.applyMutes()
                }
            }
        }
        applyMutes()
    }

    func unmuteAll() {
        muted.removeAll()
        defaults.set([String](), forKey: Self.mutedKey)
        applyMutes()
    }

    /// Mutes or unmutes the frontmost app (shortcut). Returns the app and its new state.
    func toggleFrontmost() -> (name: String, muted: Bool)? {
        guard let front = NSWorkspace.shared.frontmostApplication, front.activationPolicy == .regular,
              let id = front.bundleIdentifier, !Self.excluded.contains(id) else { return nil }
        let on = !muted.contains(id)
        setMuted(id, on)
        return (front.localizedName ?? id, on)
    }

    /// Muted apps that aren't running (they'll be muted when they open).
    var mutedClosed: [String] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return muted.subtracting(running).sorted()
    }

    // MARK: Engine

    private func applyMutes() {
        if muted.isEmpty {
            removeSystemListeners()
            removeOutputListeners()
            tearDownRig()
            problem = nil
            return
        }
        addSystemListeners()
        retarget()
    }

    /// Points the rig at every sound process that belongs to a muted app.
    private func retarget() {
        guard #available(macOS 14.2, *) else { return }
        lookUpTargets { [weak self] targets in self?.retarget(to: targets) }
    }

    @available(macOS 14.2, *)
    private func retarget(to targets: [AudioObjectID]) {
        let timing = PerfLog.begin("sound retarget"); defer { timing.end() }
        watchOutput(of: targets)
        if targets.isEmpty {
            tearDownRig()
            problem = nil
            return
        }
        if access == .denied {
            tearDownRig()
            problem = "Allow System Audio Recording to mute apps."
            return
        }
        if let rig = rig as? MuteRig {
            if targets == rigTargets { return }
            if rig.update(processes: targets) {
                rigTargets = targets
                return
            }
        }
        buildRig(targets)
    }

    /// Make before break: the new rig is running before the old one goes, so nothing slips out.
    @available(macOS 14.2, *)
    private func buildRig(_ targets: [AudioObjectID]) {
        do {
            let fresh = try MuteRig(processes: targets)
            (rig as? MuteRig)?.stop()
            rig = fresh
            rigTargets = targets
            problem = nil
        } catch {
            NSLog("Tutto: mute rig: \(error)")
            problem = "Couldn't mute: \(error)."
        }
        refreshAccess()
    }

    private func rebuild() {
        guard #available(macOS 14.2, *), !muted.isEmpty else { return }
        lookUpTargets { [weak self] targets in
            guard let self else { return }
            self.watchOutput(of: targets)
            guard !targets.isEmpty, self.access != .denied else { return }
            self.buildRig(targets)
        }
    }

    private func tearDownRig() {
        rearmWork?.cancel()
        if #available(macOS 14.2, *) { (rig as? MuteRig)?.stop() }
        rig = nil
        rigTargets = []
    }

    /// The sound processes of muted apps, looked up off the main thread (a Core Audio read per
    /// sound process and the kernel asked who owns each: 20-odd ms that landed on whatever was
    /// animating). `then` runs on the main thread, and only if the muted apps are still the same.
    private func lookUpTargets(then: @escaping @MainActor ([AudioObjectID]) -> Void) {
        let muted = self.muted
        let owners = runningOwners()
        lookups.async {
            let targets = Self.targetProcesses(muted: muted, owners: owners)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self, self.muted == muted else { return }
                    then(targets)
                }
            }
        }
    }

    nonisolated private static func targetProcesses(muted: Set<String>, owners: [AudioOwnership.App]) -> [AudioObjectID] {
        AudioProcessList.read().filter { process in
            if let id = process.bundleID, muted.contains(id) { return true }
            guard let owner = AudioOwnership.owner(of: process.pid, among: owners) else { return false }
            return muted.contains(owner.bundleID)
        }
        .map(\.objectID)
        .sorted()
    }

    /// Only ⌘Tab apps can own sound: helpers are running "apps" too (Discord Helper (Renderer)),
    /// and would otherwise claim their own sound instead of handing it to their app.
    private func runningOwners() -> [AudioOwnership.App] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier, let url = app.bundleURL else { return nil }
            return AudioOwnership.App(pid: app.processIdentifier, bundleID: id, bundlePath: url.path)
        }
    }

    // MARK: Core Audio notifications

    private func addSystemListeners() {
        guard systemListeners.isEmpty else { return }
        let system = AudioObjectID(kAudioObjectSystemObject)
        let selectors: [AudioObjectPropertySelector] = [
            kAudioHardwarePropertyProcessObjectList,     // an app opened a new sound process
            kAudioHardwarePropertyDefaultOutputDevice,   // headphones, AirPods, display speakers
            kAudioHardwarePropertyServiceRestarted,      // coreaudiod restarted
        ]
        for selector in selectors {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated {
                    if selector == kAudioHardwarePropertyProcessObjectList { self?.scheduleRefresh() } else { self?.rebuild() }
                }
            }
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            if AudioObjectAddPropertyListenerBlock(system, &address, .main, block) == noErr {
                systemListeners.append((selector, block))
            }
        }
    }

    private func removeSystemListeners() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        for (selector, block) in systemListeners {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(system, &address, .main, block)
        }
        systemListeners.removeAll()
    }

    /// Follows the muted processes' "playing" flag to re-arm the rig once they're all quiet.
    private func watchOutput(of targets: [AudioObjectID]) {
        guard Set(outputListeners.map(\.0)) != Set(targets) else { return }
        removeOutputListeners()
        for id in targets {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.outputChanged() }
            }
            var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            if AudioObjectAddPropertyListenerBlock(id, &address, .main, block) == noErr {
                outputListeners.append((id, block))
            }
        }
    }

    private func removeOutputListeners() {
        for (id, block) in outputListeners {
            var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(id, &address, .main, block)
        }
        outputListeners.removeAll()
        rearmWork?.cancel()
    }

    private func outputChanged() {
        rearmWork?.cancel()
        if watchers > 0 { refreshUsage() }
        guard #available(macOS 14.2, *), rig != nil else { return }
        guard !rigTargets.contains(where: AudioProcessList.isRunningOutput) else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let rig = self.rig as? MuteRig, rig.isRunning,
                      !self.rigTargets.contains(where: AudioProcessList.isRunningOutput) else { return }
                rig.rearm()
            }
        }
        rearmWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Coalesces bursts (an app launching several helpers at once).
    private func scheduleRefresh() {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.muted.isEmpty { self.retarget() }
                if self.watchers > 0 { self.refreshApps() }
            }
        }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    // MARK: App list

    private func refreshApps() {
        apps = NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier, !Self.excluded.contains(id),
                  !app.isTerminated else { return nil }
            return SoundApp(bundleID: id, name: app.localizedName ?? id, pid: app.processIdentifier,
                            icon: app.icon ?? NSWorkspace.shared.icon(for: .application))
        }
        refreshUsage()
    }

    private func refreshUsage() {
        let owners = runningOwners()
        var using: Set<String> = []
        for process in AudioProcessList.read() where process.isRunningOutput {
            if let owner = AudioOwnership.owner(of: process.pid, among: owners) { using.insert(owner.bundleID) }
        }
        if using != usingAudio { usingAudio = using }
    }

    private func refreshAccess() {
        let status = SystemAudioAccess.status()
        if status != access {
            access = status
            if !muted.isEmpty { retarget() }
        }
    }
}
