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
    private(set) var corner: CornerModule?
    private(set) var wordCounter: WordCounterModule?
    private(set) var sound: SoundModule?
    private(set) var switcher: SwitcherModule?
    private(set) var strip: StripModule?

    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// On notched MacBooks a crowded menu bar puts new icons behind the notch, where they can't be clicked.
    private(set) var menuBarIconHidden = false
    private(set) var hasCompletedOnboarding: Bool

    private let defaults = UserDefaults.standard

    private init() {
        if let saved = defaults.array(forKey: Keys.enabled) as? [String] {
            // Tools added since the choice was saved start on, like everything does on a first run.
            let known = defaults.array(forKey: Keys.known) as? [String] ?? Self.originalModules
            let added = ModuleID.allCases.filter { !known.contains($0.rawValue) && $0.isOnByDefault }
            enabled = Set(saved.compactMap(ModuleID.init(rawValue:))).union(added)
        } else {
            enabled = Set(ModuleID.allCases.filter(\.isOnByDefault))  // everything on, the way the spec describes Tutto
        }
        #if DEBUG
        // Live tests of the strip with test windows only: nothing else of Tutto runs.
        if CommandLine.arguments.contains("--strip-only") { enabled = [.strip, .switcher] }
        #endif
        hasCompletedOnboarding = defaults.bool(forKey: Keys.onboarded)
    }

    // MARK: Lifecycle

    /// `quietly` (offscreen snapshots) starts modules without taking any global shortcuts.
    func launch(quietly: Bool = false) {
        hotkeys.onSuspendChange = { [weak self] suspended in self?.strip?.setShortcutsSuspended(suspended) }
        // A window left out of view by a strip that didn't get to stop (a crash) comes back, and so
        // does a Dock it hid.
        if !enabled.contains(.strip) && !quietly {
            StripModule.rescueParkedWindows()
            StripModule.restoreDock()
        }
        for id in ModuleID.allCases where enabled.contains(id) { start(id) }
        // Things that live outside Tutto's process must match the switch even if it was
        // turned off in an earlier session: Finder only loads the menu extension when Archives is on.
        if !enabled.contains(.archives) && !quietly { permissions.setFinderExtension(enabled: false) }
        if !quietly { bindShortcuts() }
        permissions.refresh()
    }

    /// Checks whether the menu bar icon landed under the camera notch (macOS hides it there).
    func checkMenuBarIconVisibility() {
        guard let item = NSApp.windows.first(where: { $0.className.contains("StatusBarWindow") }),
              let screen = item.screen ?? NSScreen.main,
              let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else {
            menuBarIconHidden = false
            return
        }
        // Between the two usable areas is the notch.
        let notch = CGRect(x: left.maxX, y: left.minY, width: right.minX - left.maxX, height: left.height)
        menuBarIconHidden = item.frame.width > 0 && notch.intersects(item.frame.insetBy(dx: 2, dy: 0))
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
            if id == .strip { strip?.announce() }
        } else {
            enabled.remove(id)
            stop(id)
        }
        #if DEBUG
        if CommandLine.arguments.contains("--strip-only") { return bindShortcuts() }
        #endif
        defaults.set(enabled.map(\.rawValue).sorted(), forKey: Keys.enabled)
        defaults.set(ModuleID.allCases.map(\.rawValue), forKey: Keys.known)
        bindShortcuts()
    }

    #if DEBUG
    /// Offscreen renders (`--snapshot`) run beside the real app and share its bundle id, files and
    /// system registrations. Only the readings start; every other module is made (so its views
    /// render) but never started or stopped: starting or stopping them would take over ⌘Tab, other
    /// apps' windows or trackpad clicks, write the clipboard history, or switch the installed
    /// Finder extension off.
    static var rendersOffscreen = false
    private static let readingsOnly: Set<ModuleID> = [.system, .sensors]
    #endif

    private func start(_ id: ModuleID) {
        #if DEBUG
        if Self.rendersOffscreen, !Self.readingsOnly.contains(id) {
            switch id {
            case .clipboard: if clipboard == nil { clipboard = ClipboardModule(model: self) }
            case .windows: if windows == nil { windows = WindowModule(model: self) }
            case .screenshots: if screenshots == nil { screenshots = ScreenshotModule(model: self) }
            case .archives: if archives == nil { archives = ArchiveModule(model: self) }
            case .corner: if corner == nil { corner = CornerModule() }
            case .wordCounter: if wordCounter == nil { wordCounter = WordCounterModule() }
            case .sound: if sound == nil { sound = SoundModule() }
            case .switcher, .strip, .system, .sensors: break
            }
            return
        }
        #endif
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
        case .corner:
            if corner == nil { corner = CornerModule() }
            corner?.start()
        case .wordCounter:
            if wordCounter == nil { wordCounter = WordCounterModule() }
            wordCounter?.start()
        case .sound:
            if sound == nil { sound = SoundModule() }
            sound?.start()
        case .switcher:
            if switcher == nil { switcher = SwitcherModule(model: self) }
            switcher?.start()
        case .strip:
            if strip == nil { strip = StripModule(model: self) }
            strip?.start()
        }
    }

    private func stop(_ id: ModuleID) {
        #if DEBUG
        if Self.rendersOffscreen, !Self.readingsOnly.contains(id) { return }
        #endif
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
        case .wordCounter:
            wordCounter?.stop()
            wordCounter = nil
        case .sound:
            sound?.stop()
            sound = nil
        case .switcher:
            switcher?.stop()
            switcher = nil
        case .strip:
            strip?.stop()
            strip = nil
        case .corner:
            corner?.stop()
            corner = nil
        }
    }

    // MARK: Shortcuts

    /// Registers every shortcut whose module is on; releases the rest.
    func bindShortcuts() {
        var stripKeys: [KeyShortcut: StripCommand] = [:]
        for action in ShortcutAction.all {
            let active = action.module.map { enabled.contains($0) } ?? true
            let shortcut = active ? shortcuts.shortcut(for: action) : nil
            hotkeys.bind(action.id, to: shortcut) { [weak self] in
                self?.perform(action)
            }
            if case .strip(let command) = action, let shortcut { stripKeys[shortcut] = command }
        }
        // The strip's keys win even where another app registered the same ones first.
        strip?.setShortcuts(stripKeys)
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
        case .wordCounter: wordCounter?.togglePanel()
        case .muteFrontApp:
            if let result = sound?.toggleFrontmost() {
                Toast.shared.show(result.muted ? "Muted" : "Unmuted", detail: result.name)
            }
        case .openTutto: MainWindowController.shared.show()
        case .toggleCorner:
            if let corner { corner.isEnabled.toggle() }
        case .window(let windowAction): windows?.perform(windowAction)
        case .strip(let command): strip?.perform(command)
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

    /// The tools in the first release, for choices saved before `modules.known` existed.
    private static let originalModules = ["system", "sensors", "clipboard", "windows", "screenshots", "archives", "corner"]

    private enum Keys {
        static let enabled = "modules.enabled"
        /// The tools that existed when `enabled` was saved.
        static let known = "modules.known"
        static let onboarded = "hasCompletedOnboarding"
    }
}
