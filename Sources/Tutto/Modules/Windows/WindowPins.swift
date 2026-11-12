//
//  WindowPins.swift
//  Tutto
//
//  Keep a window on top of the others. macOS has no public way to change another app's window
//  level, so a pinned window gets a live copy (PinMirror) floating exactly over it. The copy
//  shows while you're somewhere else and hides while you're in the window itself, so you
//  always type into the real one; clicking the copy takes you there. Up to three windows.
//
//  Nothing runs while nothing is pinned. While something is, Tutto listens for app switches,
//  Space changes and the pinned windows' own moves (an Accessibility observer per app), with
//  no timers; the capture runs only while a copy is on screen.
//

import AppKit
import ApplicationServices
import Observation
import ScreenCaptureKit
import TuttoKit

@MainActor
@Observable
final class WindowPins {
    struct Pin: Identifiable, Equatable {
        let id: CGWindowID
        let pid: pid_t
        var appName: String
        var title: String
        var label: String { PinRules.label(app: appName, title: title) }
    }

    /// The windows on top, oldest first.
    private(set) var pinned: [Pin] = []

    @ObservationIgnored private var elements: [CGWindowID: AXUIElement] = [:]
    @ObservationIgnored private var mirrors: [CGWindowID: PinMirror] = [:]
    @ObservationIgnored private var observers: [pid_t: PinObserver] = [:]
    @ObservationIgnored private var tokens: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    /// Windows being pinned (the window list is being read).
    @ObservationIgnored private var pending: Set<CGWindowID> = []
    /// A copy just clicked: its window counts as focused until its app says so itself.
    @ObservationIgnored private var raising: (id: CGWindowID, until: Date)?
    @ObservationIgnored private var settle: DispatchWorkItem?

    // MARK: Pinning

    /// Pins the front window on top, or unpins it if it's pinned.
    func toggleFrontWindow() {
        guard AXIsProcessTrusted() else {
            AppModel.shared.permissions.request(.accessibility)
            NSSound.beep()
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication, let window = WindowModule.focusedWindow(of: app) else {
            NSSound.beep()
            return
        }
        toggle(window: window, app: app)
    }

    func isPinned(_ window: AXUIElement) -> Bool {
        guard let id = WindowElements.windowID(of: window) else { return false }
        return pinned.contains { $0.id == id }
    }

    func toggle(window: AXUIElement, app: NSRunningApplication?) {
        guard let id = WindowElements.windowID(of: window) else {
            NSSound.beep()
            return
        }
        switch PinRules.toggle(id, pinned: pinned.map(\.id)) {
        case .unpin:
            let label = pinned.first { $0.id == id }?.label
            unpin(id)
            Toast.shared.show("Back to normal", detail: label)
        case .full:
            Toast.shared.show("Three windows are on top already", detail: "Unpin one first, on the Windows page", duration: 2.5)
        case .pin:
            pin(window, id: id, app: app)
        }
    }

    private func pin(_ window: AXUIElement, id: CGWindowID, app: NSRunningApplication?) {
        guard !pending.contains(id) else { return }
        guard let info = ServerInfo.of(id) else {
            NSSound.beep()
            return
        }
        switch PinRules.refusal(pid: info.pid, ownPID: getpid(), layer: info.layer, size: info.bounds.size,
                                fullScreen: WindowModule.isFullScreen(window)) {
        case .fullScreen:
            Toast.shared.show("Leave full screen first", detail: "A full-screen window has a Space of its own", duration: 2.5)
            return
        case .ownWindow, .notAWindow, .tooSmall:
            Toast.shared.show("That can't be kept on top", detail: "Only other apps' windows can", duration: 2.5)
            return
        case nil:
            break
        }
        guard CGPreflightScreenCaptureAccess() else {
            AppModel.shared.permissions.request(.screenRecording)
            Toast.shared.show("Screen Recording needed", detail: "Switch on Tutto in System Settings, then try again", duration: 3)
            return
        }
        pending.insert(id)
        let appName = (app?.processIdentifier == info.pid ? app : NSRunningApplication(processIdentifier: info.pid))?
            .localizedName ?? "Window"
        Task { @MainActor [weak self] in
            let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let self else { return }
            self.pending.remove(id)
            guard let captured = content?.windows.first(where: { $0.windowID == id }) else {
                Toast.shared.show("Couldn't keep that window on top", detail: "It may have closed", duration: 2.5)
                return
            }
            guard PinRules.toggle(id, pinned: self.pinned.map(\.id)) == .pin else { return }
            self.add(Pin(id: id, pid: info.pid, appName: appName, title: Self.title(of: window)),
                     element: window, filter: SCContentFilter(desktopIndependentWindow: captured))
            Toast.shared.show("Kept on top", detail: "\(appName) stays above other windows")
        }
    }

    private func add(_ pin: Pin, element: AXUIElement, filter: SCContentFilter) {
        if pinned.isEmpty { startWatching() }
        pinned.append(pin)
        elements[pin.id] = element
        mirrors[pin.id] = PinMirror(filter: filter,
                                    onClick: { [weak self] in self?.raise(pin.id) },
                                    onStop: { [weak self] in self?.update() })
        if observers[pin.pid] == nil {
            observers[pin.pid] = PinObserver(pid: pin.pid) { [weak self] name, element in
                self?.observed(name, element)
            }
        }
        observers[pin.pid]?.watch(element, as: pin.id)
        update()
    }

    /// Lets a window go back to normal (quietly: the list it's clicked in shows it).
    func unpin(_ id: CGWindowID) {
        guard let index = pinned.firstIndex(where: { $0.id == id }) else { return }
        let pin = pinned.remove(at: index)
        mirrors.removeValue(forKey: id)?.close()
        elements[id] = nil
        if let observer = observers[pin.pid] {
            observer.unwatch(id)
            if !pinned.contains(where: { $0.pid == pin.pid }) {
                observer.invalidate()
                observers[pin.pid] = nil
            }
        }
        if raising?.id == id { raising = nil }
        if pinned.isEmpty { stopWatching() }
    }

    func unpinAll() {
        for pin in pinned { unpin(pin.id) }
        pending.removeAll()
    }

    // MARK: Clicking a copy

    /// Hands you the real window: raised, its app in front, the copy out of the way.
    func raise(_ id: CGWindowID) {
        guard let pin = pinned.first(where: { $0.id == id }), let element = elements[id] else { return }
        raising = (id, Date().addingTimeInterval(0.8))
        mirrors[id]?.hide()
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: pin.pid)?.activate()
        settleLater(0.85)
    }

    // MARK: Showing and hiding the copies

    /// Decides for every pinned window whether its copy shows, and where.
    func update() {
        guard !pinned.isEmpty else { return }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        if let raising, raising.until < Date() { self.raising = nil }
        var focusedByPID: [pid_t: CGWindowID?] = [:]
        for pin in pinned {
            // Gone from the window server: closed, or its app quit.
            guard let info = ServerInfo.of(pin.id) else {
                unpin(pin.id)
                continue
            }
            var focused: CGWindowID?
            if front == pin.pid {
                if let raising, raising.id == pin.id {
                    focused = pin.id
                } else if let known = focusedByPID[pin.pid] {
                    focused = known
                } else {
                    focused = Self.focusedWindow(of: pin.pid)
                    focusedByPID[pin.pid] = focused
                }
            }
            let shows = PinRules.showsCopy(pinned: pin.id, pinnedPID: pin.pid, frontmostPID: front,
                                           focusedWindow: focused, windowOnScreen: info.onScreen)
            guard let mirror = mirrors[pin.id] else { continue }
            if shows {
                let frame = PinRules.panelFrame(windowBounds: info.bounds, primaryHeight: primaryHeight)
                mirror.show(frame: frame, scale: Self.scale(at: frame))
            } else {
                mirror.hide()
            }
        }
    }

    /// One more look once an animation (minimizing, a Space sliding in) has finished.
    private func settleLater(_ delay: TimeInterval) {
        settle?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.update() } }
        settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func observed(_ name: String, _ element: AXUIElement) {
        switch name {
        case kAXTitleChangedNotification:
            guard let id = WindowElements.windowID(of: element),
                  let index = pinned.firstIndex(where: { $0.id == id }) else { return }
            let title = Self.title(of: element)
            if pinned[index].title != title { pinned[index].title = title }
        case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
            raising = nil
            update()
        case kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification, kAXUIElementDestroyedNotification:
            update()
            settleLater(0.45)
        default:  // moved, resized
            update()
        }
    }

    // MARK: Listening (only while something is pinned)

    private func startWatching() {
        guard tokens.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification] {
            tokens.append((workspace, workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }))
        }
        tokens.append((workspace, workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil,
                                                        queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.update()
                self?.settleLater(0.4)
            }
        }))
        tokens.append((workspace, workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil,
                                                        queue: .main) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                guard let self, let pid else { return }
                for pin in self.pinned where pin.pid == pid { self.unpin(pin.id) }
            }
        }))
        let app = NotificationCenter.default
        tokens.append((app, app.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }))
    }

    private func stopWatching() {
        for (center, token) in tokens { center.removeObserver(token) }
        tokens.removeAll()
        settle?.cancel()
        settle = nil
        raising = nil
    }

    // MARK: Lookups

    private struct ServerInfo {
        var bounds: CGRect
        var layer: Int
        var pid: pid_t
        var onScreen: Bool

        /// The window server's view of one window (no Accessibility call); nil once it's gone.
        static func of(_ id: CGWindowID) -> ServerInfo? {
            guard let list = CGWindowListCreateDescriptionFromArray([NSNumber(value: id)] as CFArray) as? [[String: Any]],
                  let first = list.first,
                  let boundsDictionary = first[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary) else { return nil }
            return ServerInfo(bounds: bounds, layer: first[kCGWindowLayer as String] as? Int ?? 0,
                              pid: pid_t(first[kCGWindowOwnerPID as String] as? Int ?? 0),
                              onScreen: first[kCGWindowIsOnscreen as String] as? Bool ?? false)
        }
    }

    private static func focusedWindow(of pid: pid_t) -> CGWindowID? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return WindowElements.windowID(of: value as! AXUIElement)
    }

    private static func title(of window: AXUIElement) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value) == .success else { return "" }
        return value as? String ?? ""
    }

    private static func scale(at frame: CGRect) -> CGFloat {
        let middle = CGPoint(x: frame.midX, y: frame.midY)
        return (NSScreen.screens.first { $0.frame.contains(middle) } ?? NSScreen.main)?.backingScaleFactor ?? 2
    }

    #if DEBUG
    /// Snapshots: windows listed as pinned, with no copies and nothing captured.
    func previewPins(_ labels: [(app: String, title: String)]) {
        pinned = labels.enumerated().map { Pin(id: CGWindowID(90_000 + $0.offset), pid: 0, appName: $0.element.app, title: $0.element.title) }
    }
    #endif
}

// MARK: - Accessibility observer

/// One app's notices about its pinned windows (moved, resized, minimized, closed, retitled) and
/// about which of its windows has focus.
@MainActor
private final class PinObserver {
    private var observer: AXObserver?
    private let application: AXUIElement
    private var watched: [CGWindowID: AXUIElement] = [:]
    private let handler: (String, AXUIElement) -> Void

    private static let appNotifications = [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification]
    private static let windowNotifications = [kAXWindowMovedNotification, kAXWindowResizedNotification, kAXWindowMiniaturizedNotification,
                                              kAXWindowDeminiaturizedNotification, kAXUIElementDestroyedNotification, kAXTitleChangedNotification]

    init?(pid: pid_t, handler: @escaping (String, AXUIElement) -> Void) {
        self.handler = handler
        application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.25)
        var created: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let observer = Unmanaged<PinObserver>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            MainActor.assumeIsolated { observer.handler(name, element) }
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let created else { return nil }
        observer = created
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.appNotifications {
            AXObserverAddNotification(created, application, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
    }

    func watch(_ element: AXUIElement, as window: CGWindowID) {
        guard let observer, watched[window] == nil else { return }
        watched[window] = element
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.windowNotifications {
            AXObserverAddNotification(observer, element, name as CFString, refcon)
        }
    }

    func unwatch(_ window: CGWindowID) {
        guard let observer, let element = watched.removeValue(forKey: window) else { return }
        for name in Self.windowNotifications {
            AXObserverRemoveNotification(observer, element, name as CFString)
        }
    }

    func invalidate() {
        guard let observer else { return }
        for id in Array(watched.keys) { unwatch(id) }
        for name in Self.appNotifications {
            AXObserverRemoveNotification(observer, application, name as CFString)
        }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        self.observer = nil
    }
}
