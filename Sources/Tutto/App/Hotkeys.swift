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
    case windowPalette
    case captureArea
    case captureScreen
    case captureAreaEdit
    case openTutto
    case toggleCornerClick
    case window(WindowAction)

    var id: String {
        switch self {
        case .clipboardHistory: "clipboard.history"
        case .windowPalette: "windows.palette"
        case .captureArea: "screenshot.area"
        case .captureScreen: "screenshot.screen"
        case .captureAreaEdit: "screenshot.edit"
        case .openTutto: "app.open"
        case .toggleCornerClick: "cornerclick.toggle"
        case .window(let action): "windows.\(action.rawValue)"
        }
    }

    var title: String {
        switch self {
        case .clipboardHistory: "Clipboard history"
        case .windowPalette: "Window palette"
        case .captureArea: "Capture area to clipboard"
        case .captureScreen: "Capture full screen to clipboard"
        case .captureAreaEdit: "Capture area and edit"
        case .openTutto: "Open Tutto"
        case .toggleCornerClick: "Pause or resume CornerClick"
        case .window(let action): action.title
        }
    }

    var module: ModuleID? {
        switch self {
        case .clipboardHistory: .clipboard
        case .windowPalette, .window: .windows
        case .captureArea, .captureScreen, .captureAreaEdit: .screenshots
        case .toggleCornerClick: .cornerClick
        case .openTutto: nil
        }
    }

    /// The shortcuts from the spec (Raycast's and Shottr's, as used on this Mac).
    var defaultShortcut: KeyShortcut? {
        switch self {
        case .clipboardHistory: .ctrlShift(kVK_ANSI_V)
        case .windowPalette: .cmdOption(kVK_ANSI_B)
        case .captureArea: .cmdShift(kVK_ANSI_2)
        case .captureScreen: .cmdShift(kVK_ANSI_1)
        case .captureAreaEdit: .cmdShift(kVK_ANSI_Grave)
        case .openTutto, .toggleCornerClick, .window: nil
        }
    }

    static var fixed: [ShortcutAction] {
        [.clipboardHistory, .windowPalette, .captureArea, .captureScreen, .captureAreaEdit, .openTutto, .toggleCornerClick]
    }

    static var all: [ShortcutAction] { fixed + WindowAction.allCases.map { .window($0) } }
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
    }

    private var registrations: [UInt32: Registration] = [:]
    private var ids: [String: UInt32] = [:]
    private var nextID: UInt32 = 1
    private var handlerRef: EventHandlerRef?
    private var suspended = false

    /// Shortcuts that macOS refused (another app or the system owns them).
    private(set) var failed: Set<String> = []

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let center = Unmanaged<HotkeyCenter>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { center.fire(hotKeyID.id) }
            return noErr
        }, 1, &spec, context, &handlerRef)
    }

    /// Registers (or replaces, or with nil removes) the shortcut for an id.
    func bind(_ id: String, to shortcut: KeyShortcut?, handler: @escaping () -> Void) {
        unbind(id)
        guard let shortcut else { return }
        let number = nextID
        nextID += 1
        ids[id] = number
        var registration = Registration(shortcut: shortcut, ref: nil, handler: handler)
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
        for (number, registration) in registrations {
            if let ref = registration.ref { UnregisterEventHotKey(ref) }
            registrations[number]?.ref = nil
        }
    }

    func resume() {
        guard suspended else { return }
        suspended = false
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
}

/// Apps that, when running, also respond to some of Tutto's default shortcuts. macOS delivers a
/// shared global shortcut to every app that registered it (verified with Shottr on macOS 26.5),
/// so both would react.
@MainActor
enum ExternalShortcuts {
    static func runningOwner(of shortcut: KeyShortcut?) -> String? {
        guard let shortcut else { return nil }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        if running.contains("cc.ffitch.shottr"),
           [KeyShortcut.cmdShift(kVK_ANSI_1), .cmdShift(kVK_ANSI_2)].contains(shortcut) {
            return "Shottr"
        }
        if running.contains("com.raycast.macos"),
           [KeyShortcut.ctrlShift(kVK_ANSI_V), .cmdOption(kVK_ANSI_B)].contains(shortcut) {
            return "Raycast"
        }
        return nil
    }
}
