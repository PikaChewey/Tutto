//
//  AppModel.swift
//  Tutto
//
//  Owns the modules. A module that is switched off is released entirely: its object
//  is gone, so are its timers, taps, hotkeys and memory.
//

import AppKit
import Observation
import ServiceManagement
import TuttoKit

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let shortcuts = ShortcutStore()
    let hotkeys = HotkeyCenter()
    let permissions = Permissions()

    private(set) var enabled: Set<ModuleID>
    private(set) var system: SystemMonitor?
    private(set) var sensors: SensorsModule?
    private(set) var clipboard: ClipboardModule?
    private(set) var windows: WindowModule?
    private(set) var screenshots: ScreenshotModule?
    private(set) var archives: ArchiveModule?
    private(set) var cornerClick: CornerClickModule?

    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    private(set) var hasCompletedOnboarding: Bool

    private let defaults = UserDefaults.standard

    private init() {
        if let saved = defaults.array(forKey: Keys.enabled) as? [String] {
            enabled = Set(saved.compactMap(ModuleID.init(rawValue:)))
        } else {
            enabled = Set(ModuleID.allCases)  // everything on, the way the spec describes Tutto
        }
        hasCompletedOnboarding = defaults.bool(forKey: Keys.onboarded)
    }

    // MARK: Lifecycle

    /// `quietly` (offscreen snapshots) starts modules without taking any global shortcuts.
    func launch(quietly: Bool = false) {
        for id in ModuleID.allCases where enabled.contains(id) { start(id) }
        if !quietly { bindShortcuts() }
        permissions.refresh()
    }

    func shutdown() {
        for id in ModuleID.allCases { stop(id) }
    }

    func isEnabled(_ id: ModuleID) -> Bool { enabled.contains(id) }

    func setEnabled(_ id: ModuleID, _ on: Bool) {
        guard on != enabled.contains(id) else { return }
        if on {
            enabled.insert(id)
            start(id)
        } else {
            enabled.remove(id)
            stop(id)
        }
        defaults.set(enabled.map(\.rawValue).sorted(), forKey: Keys.enabled)
        bindShortcuts()
    }

    private func start(_ id: ModuleID) {
        switch id {
        case .system:
            if system == nil { system = SystemMonitor() }
        case .sensors:
            if sensors == nil { sensors = SensorsModule() }
        case .clipboard:
            if clipboard == nil { clipboard = ClipboardModule(model: self) }
            clipboard?.start()
        case .windows:
            if windows == nil { windows = WindowModule(model: self) }
            windows?.start()
        case .screenshots:
            if screenshots == nil { screenshots = ScreenshotModule(model: self) }
            screenshots?.start()
        case .archives:
            if archives == nil { archives = ArchiveModule(model: self) }
            archives?.start()
        case .cornerClick:
            if cornerClick == nil { cornerClick = CornerClickModule() }
            cornerClick?.start()
        }
    }

    private func stop(_ id: ModuleID) {
        switch id {
        case .system:
            system?.stopAll()
            system = nil
        case .sensors:
            sensors?.stop()
            sensors = nil
        case .clipboard:
            clipboard?.stop()
            clipboard = nil
        case .windows:
            windows?.stop()
            windows = nil
        case .screenshots:
            screenshots?.stop()
            screenshots = nil
        case .archives:
            archives?.stop()
            archives = nil
        case .cornerClick:
            cornerClick?.stop()
            cornerClick = nil
        }
    }

    // MARK: Shortcuts

    /// Registers every shortcut whose module is on; releases the rest.
    func bindShortcuts() {
        for action in ShortcutAction.all {
            let active = action.module.map { enabled.contains($0) } ?? true
            hotkeys.bind(action.id, to: active ? shortcuts.shortcut(for: action) : nil) { [weak self] in
                self?.perform(action)
            }
        }
    }

    func setShortcut(_ shortcut: KeyShortcut?, for action: ShortcutAction) {
        shortcuts.set(shortcut, for: action)
        bindShortcuts()
    }

    func resetShortcuts() {
        shortcuts.resetAll()
        bindShortcuts()
    }

    func perform(_ action: ShortcutAction) {
        switch action {
        case .clipboardHistory: clipboard?.showPalette()
        case .windowPalette: windows?.showPalette()
        case .captureArea: screenshots?.capture(.areaToClipboard)
        case .captureScreen: screenshots?.capture(.screenToClipboard)
        case .captureAreaEdit: screenshots?.capture(.areaToEditor)
        case .openTutto: MainWindowController.shared.show()
        case .toggleCornerClick:
            if let cornerClick { cornerClick.isEnabled.toggle() }
        case .window(let windowAction): windows?.perform(windowAction)
        }
    }

    // MARK: App settings

    func setLaunchAtLogin(_ on: Bool) {
        launchAtLogin = on
        Task.detached {
            do {
                if on { try SMAppService.mainApp.register() } else { try await SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Tutto: launch at login change failed: \(error.localizedDescription)")
            }
            await MainActor.run { AppModel.shared.launchAtLogin = SMAppService.mainApp.status == .enabled }
        }
    }

    func completeOnboarding() {
        hasCompletedOnboarding = true
        defaults.set(true, forKey: Keys.onboarded)
    }

    // MARK: Apps Tutto replaces

    struct ReplacedApp: Identifiable {
        var id: String { bundleID }
        var bundleID: String
        var name: String
        var module: ModuleID
        var advice: String
        var canQuit: Bool
    }

    static let replacedApps: [ReplacedApp] = [
        ReplacedApp(bundleID: "eu.exelban.Stats", name: "Stats", module: .system,
                    advice: "Samples continuously to update its menu bar. Tutto reads only while you look.", canQuit: true),
        ReplacedApp(bundleID: "com.crystalidea.macsfancontrol", name: "Macs Fan Control", module: .sensors,
                    advice: "Two apps controlling one fan will fight. Quit it before setting speeds here.", canQuit: true),
        ReplacedApp(bundleID: "com.raycast.macos", name: "Raycast", module: .clipboard,
                    advice: "Keep it as your launcher, but clear its ⌃⇧V and ⌘⌥B hotkeys in Raycast Settings › Extensions so Tutto gets them.",
                    canQuit: false),
        ReplacedApp(bundleID: "cc.ffitch.shottr", name: "Shottr", module: .screenshots,
                    advice: "Also listens for ⌘⇧1 and ⌘⇧2, so only one app would take the screenshot.", canQuit: true),
        ReplacedApp(bundleID: "com.macpaw.site.theunarchiver", name: "The Unarchiver", module: .archives,
                    advice: "Fine to keep, but you no longer need it.", canQuit: true),
        ReplacedApp(bundleID: "ca.bryanyao.CornerClick", name: "CornerClick", module: .cornerClick,
                    advice: "Running both turns some corner taps into two right-clicks. Quit it; Tutto has everything it did.",
                    canQuit: true),
    ]

    /// Replaced apps that are running right now and clash with a module that's on.
    func runningReplacedApps() -> [ReplacedApp] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return Self.replacedApps.filter { running.contains($0.bundleID) && enabled.contains($0.module) }
    }

    func quit(_ app: ReplacedApp) {
        for running in NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID) {
            running.terminate()
        }
    }

    private enum Keys {
        static let enabled = "modules.enabled"
        static let onboarded = "hasCompletedOnboarding"
    }
}
