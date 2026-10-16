//
//  WindowModule.swift
//  Tutto
//
//  Window management through the Accessibility API: ⌃⇧B opens a palette, type
//  "left half", press ↩, and the window you were in snaps there. Every action can
//  also have its own shortcut. Nothing runs between uses.
//

import AppKit
import ApplicationServices
import Observation
import TuttoKit

@MainActor
@Observable
final class WindowModule: ModuleController {
    /// Space between tiled windows and screen edges, in points.
    var gap: Double { didSet { defaults.set(gap, forKey: Keys.gap) } }
    private(set) var usage: [String: Int]

    private weak var model: AppModel?
    private let defaults = UserDefaults.standard
    private var palette: WindowPaletteController?
    /// Frames before Tutto moved them, for Restore.
    private var history: [(window: AXUIElement, frame: CGRect)] = []

    init(model: AppModel) {
        self.model = model
        gap = defaults.double(forKey: Keys.gap)
        usage = defaults.dictionary(forKey: Keys.usage) as? [String: Int] ?? [:]
    }

    func start() {}

    func stop() {
        palette?.close()
        palette = nil
        history.removeAll()
    }

    // MARK: Palette

    func showPalette() {
        let app = NSWorkspace.shared.frontmostApplication
        let target = app.flatMap { Self.focusedWindow(of: $0) }
        if palette == nil { palette = WindowPaletteController(module: self) }
        palette?.show(app: app, window: target)
    }

    func paletteDidClose() { palette = nil }

    /// Actions in palette order: most used first when there's no query.
    func rankedActions(for query: String) -> [WindowAction] {
        let multipleDisplays = NSScreen.screens.count > 1
        let available = WindowAction.allCases.filter { !$0.movesBetweenDisplays || multipleDisplays }
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            return available.enumerated().sorted { a, b in
                let ua = usage[a.element.rawValue] ?? 0, ub = usage[b.element.rawValue] ?? 0
                return ua != ub ? ua > ub : a.offset < b.offset
            }.map(\.element)
        }
        // Best match first; ties go to what you use most, then to the natural order (left before top).
        return available.enumerated().compactMap { index, action -> (WindowAction, Int, Int)? in
            guard let score = FuzzyMatcher.score(query, title: action.title, aliases: action.aliases) else { return nil }
            return (action, score * 100 + min(usage[action.rawValue] ?? 0, 99), index)
        }
        .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }
        .map(\.0)
    }

    // MARK: Performing

    /// From a shortcut: acts on the frontmost app's focused window.
    func perform(_ action: WindowAction) {
        guard let app = NSWorkspace.shared.frontmostApplication, let window = Self.focusedWindow(of: app) else {
            if !AXIsProcessTrusted() { model?.permissions.request(.accessibility) }
            NSSound.beep()
            return
        }
        perform(action, on: window, app: app)
    }

    func perform(_ action: WindowAction, on window: AXUIElement, app: NSRunningApplication?) {
        // macOS won't move or resize a window in native full screen (each sits on its own Space).
        // Take it out of full screen first, wait for the animation to finish, then place it.
        if Self.isFullScreen(window), action != .restore {
            exitFullScreen(window) { [weak self] in self?.place(action, window: window, app: app) }
            return
        }
        place(action, window: window, app: app)
    }

    /// Ends native full screen and calls `then` once the window has left it (or after 2 s).
    private func exitFullScreen(_ window: AXUIElement, then: @escaping () -> Void) {
        AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanFalse)
        let deadline = Date().addingTimeInterval(2)
        var settledSince: Date?
        var lastFrame: CGRect?
        func poll() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                MainActor.assumeIsolated {
                    let frame = Self.frame(of: window)
                    // Done when it's no longer full screen and its frame has stopped animating.
                    if !Self.isFullScreen(window), frame == lastFrame {
                        if let since = settledSince, Date().timeIntervalSince(since) >= 0.15 { return then() }
                        if settledSince == nil { settledSince = Date() }
                    } else {
                        settledSince = nil
                    }
                    lastFrame = frame
                    if Date() > deadline { return then() }
                    poll()
                }
            }
        }
        poll()
    }

    private func place(_ action: WindowAction, window: AXUIElement, app: NSRunningApplication?) {
        guard let current = Self.frame(of: window) else { return }
        usage[action.rawValue, default: 0] += 1
        defaults.set(usage, forKey: Keys.usage)

        if action == .restore {
            if let index = history.lastIndex(where: { CFEqual($0.window, window) }) {
                Self.setFrame(history.remove(at: index).frame, of: window, app: app)
            }
            return
        }
        let screens = Self.screensInAXSpace()
        guard let currentScreen = Self.screen(containing: current, in: screens) else { return }

        let target: CGRect
        switch action {
        case .nextDisplay, .previousDisplay:
            guard screens.count > 1, let index = screens.firstIndex(where: { $0.frame == currentScreen.frame }) else { return }
            let next = screens[(index + (action == .nextDisplay ? 1 : screens.count - 1)) % screens.count]
            target = WindowLayout.move(current, from: currentScreen.visible, to: next.visible)
        default:
            target = WindowLayout.frame(for: action, visible: currentScreen.visible, current: current, gap: gap)
        }
        guard target != current else { return }
        history.removeAll { CFEqual($0.window, window) }
        history.append((window, current))
        if history.count > 40 { history.removeFirst() }
        Self.setFrame(target, of: window, app: app)
    }

    // MARK: Accessibility helpers

    static func isFullScreen(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &value) == .success && (value as? Bool) == true
    }

    static func focusedWindow(of app: NSRunningApplication) -> AXUIElement? {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value,
               CFGetTypeID(value) == AXUIElementGetTypeID() {
                return (value as! AXUIElement)
            }
        }
        return nil
    }

    static func frame(of window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: position, size: size)
    }

    /// Size, position, size again: some apps clamp the size to the screen they're on before moving.
    static func setFrame(_ frame: CGRect, of window: AXUIElement, app: NSRunningApplication?) {
        // Apps with "enhanced user interface" on (set by assistive tools) animate every
        // AX resize slowly; switch it off for the move.
        let appElement = app.map { AXUIElementCreateApplication($0.processIdentifier) }
        var enhanced: CFTypeRef?
        let wasEnhanced = appElement.map {
            AXUIElementCopyAttributeValue($0, "AXEnhancedUserInterface" as CFString, &enhanced) == .success
                && (enhanced as? Bool) == true
        } ?? false
        if wasEnhanced, let appElement {
            AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
        }
        var size = frame.size
        var origin = frame.origin
        if let sizeValue = AXValueCreate(.cgSize, &size), let originValue = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, originValue)
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        }
        if wasEnhanced, let appElement {
            AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    struct ScreenArea {
        var frame: CGRect
        var visible: CGRect
        var name: String
    }

    /// Every screen's full and usable frame in Accessibility coordinates, left to right.
    static func screensInAXSpace() -> [ScreenArea] {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSScreen.screens.map {
            ScreenArea(frame: WindowLayout.flip($0.frame, primaryHeight: primaryHeight),
                       visible: WindowLayout.flip($0.visibleFrame, primaryHeight: primaryHeight),
                       name: $0.localizedName)
        }
        .sorted { $0.frame.minX < $1.frame.minX }
    }

    static func screen(containing frame: CGRect, in screens: [ScreenArea]) -> ScreenArea? {
        screens.max { a, b in
            a.frame.intersection(frame).area < b.frame.intersection(frame).area
        }
    }

    private enum Keys {
        static let gap = "windows.gap"
        static let usage = "windows.usage"
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
