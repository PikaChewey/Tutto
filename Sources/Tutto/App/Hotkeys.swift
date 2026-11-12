//
//  Hotkeys.swift
//  Tutto
//
//  Global shortcuts through Carbon's RegisterEventHotKey: the system delivers the key
//  press to Tutto, so nothing listens to the keyboard and no permission is needed.
//  Costs nothing between presses.
//

import AppKit
import Carbon.HIToolbox
import Observation
import TuttoKit

/// Everything that can have a global shortcut.
enum ShortcutAction: Hashable, Identifiable {
    case clipboardHistory
    case pastePlainText
    case pinWindow
    case cleanKeyboard
    case showMenuBarIcons
    case windowPalette
    case captureArea
    case captureScreen
    case captureAreaEdit
    case recordScreen
    case scrollingCapture
    case convertFiles
    case cleanUp
    case wordCounter
    case muteFrontApp
    case openTutto
    case toggleCorner
    case toggleClicker
    case window(WindowAction)
    /// One of your plugins (Plugins page).
    case plugin(UUID)
    case strip(StripCommand)

    var id: String {
        switch self {
        case .clipboardHistory: "clipboard.history"
        case .pastePlainText: "clipboard.pastePlain"
        case .pinWindow: "windows.pin"
        case .cleanKeyboard: "keyboard.clean"
        case .showMenuBarIcons: "menubar.toggle"
        case .windowPalette: "windows.palette"
        case .captureArea: "screenshot.area"
        case .captureScreen: "screenshot.screen"
        case .captureAreaEdit: "screenshot.edit"
        case .recordScreen: "screenshot.record"
        case .scrollingCapture: "screenshot.scrolling"
        case .convertFiles: "convert.window"
        case .cleanUp: "cleanup.open"
        case .wordCounter: "wordcounter.open"
        case .muteFrontApp: "sound.muteFront"
        case .openTutto: "app.open"
        case .toggleCorner: "corner.toggle"
        case .toggleClicker: "clicker.toggle"
        case .plugin(let id): ScriptPlugin.toolPrefix + id.uuidString
        case .window(let action): "windows.\(action.rawValue)"
        case .strip(let command): command.id
        }
    }

    var title: String {
        switch self {
        case .clipboardHistory: "Clipboard history"
        case .pastePlainText: "Paste as plain text"
        case .pinWindow: "Keep the front window on top (again to stop)"
        case .cleanKeyboard: "Clean the keyboard (locks keys and trackpad)"
        case .showMenuBarIcons: "Show or hide tucked-away menu bar icons"
        case .windowPalette: "Window palette"
        case .captureArea: "Capture area to clipboard"
        case .captureScreen: "Capture full screen to clipboard"
        case .captureAreaEdit: "Capture area and edit"
        case .recordScreen: "Record the screen (again to stop)"
        case .scrollingCapture: "Scrolling capture"
        case .convertFiles: "Open the Convert window"
        case .cleanUp: "Clean up (scan for leftovers, caches and logs)"
        case .wordCounter: "Word counter"
        case .muteFrontApp: "Mute or unmute the front app"
        case .openTutto: "Open Tutto"
        case .toggleCorner: "Pause or resume Trackpad Corner"
        case .toggleClicker: "Start or stop the auto clicker"
        case .plugin(let id): PluginShortcuts.names[id] ?? "Plugin"
        case .window(let action): action.title
        case .strip(let command): command.title
        }
    }

    var module: ModuleID? {
        switch self {
        case .clipboardHistory, .pastePlainText: .clipboard
        case .windowPalette, .window, .pinWindow: .windows
        case .showMenuBarIcons: .menuBarItems
        case .cleanKeyboard: nil
        case .captureArea, .captureScreen, .captureAreaEdit, .recordScreen, .scrollingCapture: .screenshots
        case .convertFiles: .converter
        case .cleanUp: .cleaner
        case .wordCounter: .wordCounter
        case .muteFrontApp: .sound
        case .toggleCorner: .corner
        case .toggleClicker: .clicker
        case .plugin: nil
        case .strip: .strip
        case .openTutto: nil
        }
    }

    /// The shortcuts Tutto starts with.
    var defaultShortcut: KeyShortcut? {
        switch self {
        case .clipboardHistory: DefaultShortcuts.clipboardHistory
        case .pastePlainText: DefaultShortcuts.pastePlainText
        case .windowPalette: DefaultShortcuts.windowPalette
        case .captureArea: DefaultShortcuts.captureArea
        case .captureScreen: DefaultShortcuts.captureScreen
        case .captureAreaEdit: DefaultShortcuts.captureAreaEdit
        case .recordScreen: DefaultShortcuts.recordScreen
        case .scrollingCapture: DefaultShortcuts.scrollingCapture
        case .convertFiles: DefaultShortcuts.convertFiles
        case .cleanUp: nil
        case .wordCounter: DefaultShortcuts.wordCounter
        case .toggleClicker: DefaultShortcuts.toggleClicker
        case .strip(let command): command.defaultShortcut
        case .openTutto, .toggleCorner, .muteFrontApp, .window, .plugin, .pinWindow, .cleanKeyboard, .showMenuBarIcons: nil
        }
    }

    static var fixed: [ShortcutAction] {
        [.clipboardHistory, .pastePlainText, .windowPalette, .captureArea, .captureScreen, .captureAreaEdit, .recordScreen, .scrollingCapture, .convertFiles,
         .cleanUp, .wordCounter, .pinWindow, .showMenuBarIcons, .cleanKeyboard,
         .toggleClicker,
         .muteFrontApp, .openTutto, .toggleCorner]
    }

    static var all: [ShortcutAction] {
        fixed + WindowAction.allCases.map { .window($0) } + StripCommand.allCases.map { .strip($0) }
            + PluginShortcuts.ids.map { .plugin($0) }
    }

    var isPlugin: Bool {
        if case .plugin = self { return true }
        return false
    }

    /// Whether its shortcut is live: its tool is on (a plugin: it's switched on).
    func isActive(_ enabled: Set<ModuleID>) -> Bool {
        if case .plugin(let id) = self { return PluginShortcuts.enabled.contains(id) }
        return module.map { enabled.contains($0) } ?? true
    }
}

/// The user's shortcut choices, persisted. `nil` means "no shortcut".
@MainActor
@Observable
final class ShortcutStore {
    private(set) var custom: [String: KeyShortcut?] = [:]
    private let defaults = UserDefaults.standard
    private static let key = "shortcuts.v1"

    init() {
        if let data = defaults.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([String: KeyShortcut?].self, from: data) {
            custom = saved
        }
    }

    func shortcut(for action: ShortcutAction) -> KeyShortcut? {
        if let chosen = custom[action.id] { return chosen }
        return action.defaultShortcut
    }

    func set(_ shortcut: KeyShortcut?, for action: ShortcutAction) {
        custom[action.id] = .some(shortcut)
        save()
    }

    func reset(_ action: ShortcutAction) {
        custom.removeValue(forKey: action.id)
        save()
    }

    func resetAll() {
        custom.removeAll()
        save()
    }

    var isCustomized: Bool { !custom.isEmpty }

    /// Another action already using this shortcut.
    func conflict(for shortcut: KeyShortcut, excluding action: ShortcutAction) -> ShortcutAction? {
        ShortcutAction.all.first { $0 != action && self.shortcut(for: $0) == shortcut }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(custom) { defaults.set(data, forKey: Self.key) }
    }
}

/// Registers shortcuts with the system and calls back on the main thread when one is pressed.
@MainActor
final class HotkeyCenter {
    private struct Registration {
        var shortcut: KeyShortcut
        var ref: EventHotKeyRef?
        var handler: () -> Void
        /// Called when the keys are let go (the auto clicker's hold mode).
        var release: (() -> Void)?
    }

    private var registrations: [UInt32: Registration] = [:]
    private var ids: [String: UInt32] = [:]
    private var nextID: UInt32 = 1
    private var handlerRef: EventHandlerRef?
    private var suspended = false

    /// Shortcuts that macOS refused (another app or the system owns them).
    private(set) var failed: Set<String> = []
    /// Told when recording a shortcut starts (true) and ends, for key filters that sit in
    /// front of these registrations.
    var onSuspendChange: ((Bool) -> Void)?

    init() {
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let released = GetEventKind(event) == UInt32(kEventHotKeyReleased)
            let center = Unmanaged<HotkeyCenter>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { released ? center.fireRelease(hotKeyID.id) : center.fire(hotKeyID.id) }
            return noErr
        }, specs.count, &specs, context, &handlerRef)
    }

    /// Registers (or replaces, or with nil removes) the shortcut for an id.
    func bind(_ id: String, to shortcut: KeyShortcut?, handler: @escaping () -> Void, release: (() -> Void)? = nil) {
        unbind(id)
        guard let shortcut else { return }
        let number = nextID
        nextID += 1
        ids[id] = number
        var registration = Registration(shortcut: shortcut, ref: nil, handler: handler, release: release)
        if !suspended {
            registration.ref = register(shortcut, number: number, id: id)
        }
        registrations[number] = registration
    }

    func unbind(_ id: String) {
        guard let number = ids.removeValue(forKey: id) else { return }
        if let ref = registrations.removeValue(forKey: number)?.ref { UnregisterEventHotKey(ref) }
        failed.remove(id)
    }

    func isBound(_ id: String) -> Bool { ids[id] != nil }

    /// While a shortcut recorder is listening, every shortcut is released so the keys reach it.
    func suspend() {
        guard !suspended else { return }
        suspended = true
        onSuspendChange?(true)
        for (number, registration) in registrations {
            if let ref = registration.ref { UnregisterEventHotKey(ref) }
            registrations[number]?.ref = nil
        }
    }

    func resume() {
        guard suspended else { return }
        suspended = false
        onSuspendChange?(false)
        for (id, number) in ids {
            guard let registration = registrations[number] else { continue }
            registrations[number]?.ref = register(registration.shortcut, number: number, id: id)
        }
    }

    private func register(_ shortcut: KeyShortcut, number: UInt32, id: String) -> EventHotKeyRef? {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5455_5454), id: number)  // "TUTT"
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.carbonModifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr { failed.remove(id) } else { failed.insert(id) }
        return status == noErr ? ref : nil
    }

    private func fire(_ number: UInt32) {
        registrations[number]?.handler()
    }

    private func fireRelease(_ number: UInt32) {
        registrations[number]?.release?()
    }
}
