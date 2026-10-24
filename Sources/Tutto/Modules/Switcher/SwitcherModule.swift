//
//  SwitcherModule.swift
//  Tutto
//
//  ⌘Tab shows every window instead of every app: three Firefox windows are three cards,
//  each with its own title and picture, wherever they are (other Spaces, full screen,
//  minimized, hidden apps). Hold ⌘, press Tab to move, let go to switch.
//
//  How it stays light:
//  - Nothing is resident but a key filter on its own thread that looks at each key press's
//    code and modifiers and lets everything except the trigger through.
//  - The window list is built when you press ⌘Tab (a few milliseconds) and dropped after.
//  - Recent-window order comes from macOS's app-activation notifications, not polling.
//  - Pictures are taken only while the switcher is open, only for cards in view, and the
//    cache is emptied 30 seconds after it closes.
//

import AppKit
import Carbon.HIToolbox
import Observation
import os
import SwiftUI
import TuttoKit

private let log = Logger(subsystem: "ca.bryanyao.Tutto", category: "switcher")

/// One card: a window, or an app with no windows open.
struct SwitcherItem: Identifiable, Equatable {
    let id: String
    let windowID: CGWindowID?
    let pid: pid_t
    let bundleID: String
    let appName: String
    let icon: NSImage
    /// The window's title with the app's name trimmed off.
    let title: String
    /// The title as the window reports it.
    let rawTitle: String
    var customName: String?
    var isMinimized: Bool
    var isHidden: Bool
    /// "Desktop 2" for a window on another desktop; nil when it's here or in full screen.
    let place: String?
    let frame: CGRect
    let zIndex: Int

    var isWindowless: Bool { windowID == nil }

    var displayTitle: String {
        if let customName, !customName.isEmpty { return customName }
        if isWindowless { return appName }
        return title.isEmpty ? appName : title
    }

    var subtitle: String {
        var parts = [appName]
        if customName?.isEmpty == false, !title.isEmpty { parts.append(title) }
        if isWindowless { parts.append("No windows open") }
        return parts.joined(separator: " · ")
    }
}

/// What the switcher overlay shows. Lives only while it's open.
@MainActor
@Observable
final class SwitcherSession {
    var all: [SwitcherItem] = []
    var visible: [SwitcherItem] = []
    var selection = 0
    /// Typing to filter (nil = not searching).
    var query: String?
    /// Only this app's windows (bundle id), toggled with the key above Tab.
    var appFilter: String?
    var renaming: String?
    var renameText = ""
    var thumbnails: [CGWindowID: NSImage] = [:]
    var closing: Set<String> = []
    var showPreviews = true
    var showHints = true
    /// Stays open without the modifier held (searching, renaming).
    var pinned = false
    /// Changes with every opening, so the overlay draws fresh cards instead of animating
    /// from the previous opening's order.
    var generation = 0
    /// Hovering picks a card only once the pointer has moved since the switcher opened.
    @ObservationIgnored var pointer = PointerIntent(at: .zero)
    /// Where each card is in the panel, for pointer and click handling.
    @ObservationIgnored var cardFrames: [Int: CGRect] = [:]

    var selected: SwitcherItem? { visible.indices.contains(selection) ? visible[selection] : nil }

    func refilter(keepSelection: Bool = true) {
        let previous = keepSelection ? selected?.id : nil
        var items = all
        if let appFilter { items = items.filter { $0.bundleID == appFilter } }
        if let query, !query.trimmingCharacters(in: .whitespaces).isEmpty {
            let ranked = WindowSearch.rank(query, in: items.map { .init(name: $0.customName, title: $0.title, app: $0.appName) })
            items = ranked.map { items[$0] }
        }
        visible = items
        if let previous, let index = items.firstIndex(where: { $0.id == previous }) {
            selection = index
        } else {
            selection = min(selection, max(items.count - 1, 0))
            if query != nil { selection = 0 }
        }
    }
}

@MainActor
@Observable
final class SwitcherModule: ModuleController {
    enum Scope: String, CaseIterable { case allSpaces, currentSpace }

    // MARK: Settings

    var trigger: SwitcherKeyTap.Trigger {
        didSet { save(trigger.rawValue, Keys.trigger); tap?.trigger = trigger }
    }
    var scope: Scope { didSet { save(scope.rawValue, Keys.scope) } }
    var appWindowsKey: Bool { didSet { save(appWindowsKey, Keys.appWindowsKey); tap?.appWindowsKey = appWindowsKey } }
    var showPreviews: Bool { didSet { save(showPreviews, Keys.previews) } }
    var includeMinimized: Bool { didSet { save(includeMinimized, Keys.minimized) } }
    var includeHidden: Bool { didSet { save(includeHidden, Keys.hidden) } }
    var includeWindowless: Bool { didSet { save(includeWindowless, Keys.windowless) } }
    var showHints: Bool { didSet { save(showHints, Keys.hints) } }
    private(set) var excluded: [String]
    private(set) var names: [WindowName]

    /// False when macOS refused the key filter (Accessibility not allowed yet).
    private(set) var isListening = false

    let session = SwitcherSession()
    private(set) var isOpen = false

    weak var model: AppModel?
    private var tap: SwitcherKeyTap?
    private var recent = RecentWindows()
    private var overlay: SwitcherOverlay?
    private var revealWork: DispatchWorkItem?
    private var heartbeat: Timer?
    private var observers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private let thumbnails = ThumbnailStore()
    private var icons: [pid_t: NSImage] = [:]
    private var openedAt = Date.distantPast
    private var lastInteraction = Date()
    private let defaults = UserDefaults.standard

    init(model: AppModel) {
        self.model = model
        let d = UserDefaults.standard
        trigger = SwitcherKeyTap.Trigger(rawValue: d.string(forKey: Keys.trigger) ?? "") ?? .command
        scope = Scope(rawValue: d.string(forKey: Keys.scope) ?? "") ?? .allSpaces
        appWindowsKey = d.object(forKey: Keys.appWindowsKey) as? Bool ?? true
        showPreviews = d.object(forKey: Keys.previews) as? Bool ?? true
        includeMinimized = d.object(forKey: Keys.minimized) as? Bool ?? true
        includeHidden = d.object(forKey: Keys.hidden) as? Bool ?? true
        includeWindowless = d.object(forKey: Keys.windowless) as? Bool ?? true
        showHints = d.object(forKey: Keys.hints) as? Bool ?? true
        excluded = d.stringArray(forKey: Keys.excluded) ?? []
        if let data = d.data(forKey: Keys.names), let saved = try? JSONDecoder().decode([WindowName].self, from: data) {
            names = saved
        } else {
            names = []
        }
    }

    // MARK: Lifecycle

    func start() {
        let tap = SwitcherKeyTap { [weak self] event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(event) } }
        }
        tap.trigger = trigger
        tap.appWindowsKey = appWindowsKey
        self.tap = tap
        startListening()
        // Load the window server calls now so the first ⌘Tab doesn't pay for it.
        DispatchQueue.global(qos: .utility).async {
            _ = WindowServer.canClassify
            _ = WindowServer.spaces()
            _ = WindowServer.frontWindow()
        }

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.appActivated(app) }
        })
        // Swiping to another full-screen Space of the same app doesn't announce an app change.
        observers.append(center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.spaceChanged() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.appTerminated(app) }
        })
        // Taps can be switched off across sleep and screen lock: set up again after.
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.startListening() }
            })
        }
        // Accessibility switched on later: start then, without a relaunch.
        distributedObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated { if self?.isListening == false { self?.startListening() } }
            }
        })
    }

    func stop() {
        cancel()
        stopObservingFocus()
        tap?.stop()
        tap = nil
        isListening = false
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        distributedObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        distributedObservers.removeAll()
        overlay?.close()
        overlay = nil
        thumbnails.removeAll()
        icons.removeAll()
    }

    private func startListening() {
        guard let tap else { return }
        if tap.isRunning, tap.isEnabled {
            isListening = true
            return
        }
        isListening = tap.start()
    }

    // MARK: Events

    private func handle(_ event: SwitcherKeyTap.Event) {
        switch event {
        case .trigger(let backward, let appWindows, _):
            if isOpen {
                step(backward ? -1 : 1)
            } else {
                open(backward: backward, appWindows: appWindows)
            }
        case .key(let code, let shift, _):
            guard isOpen else {
                tap?.mode = .idle
                return
            }
            handleKey(code, shift: shift)
        case .released:
            if isOpen, !session.pinned { commit() }
        }
    }

    private func handleKey(_ code: Int, shift: Bool) {
        lastInteraction = Date()
        switch code {
        case kVK_Escape: escape()
        case kVK_Return, kVK_ANSI_KeypadEnter: commit()
        case kVK_LeftArrow, kVK_UpArrow: step(-1)
        case kVK_RightArrow, kVK_DownArrow: step(1)
        case kVK_ANSI_Grave: toggleAppFilter()
        case kVK_ANSI_W: closeSelected()
        case kVK_ANSI_Q: quitSelected()
        case kVK_ANSI_M: minimizeSelected()
        case kVK_ANSI_H: hideSelected()
        case kVK_ANSI_F: arrangeSelected(.maximize)
        case kVK_ANSI_C: arrangeSelected(.center)
        case kVK_ANSI_N: arrangeSelected(.nextDisplay)
        case kVK_ANSI_R: beginRename()
        case kVK_ANSI_Slash, kVK_ANSI_S: beginSearch()
        default:
            if let number = Self.numberKeys.firstIndex(of: code) {
                guard session.visible.indices.contains(number) else { return }
                session.selection = number
                commit()
            }
        }
    }

    private static let numberKeys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                                     kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]

    // MARK: Open / move / switch

    private func open(backward: Bool, appWindows: Bool) {
        openedAt = Date()
        let started = ProcessInfo.processInfo.systemUptime
        lastInteraction = Date()
        let front = WindowServer.frontWindow()
        if let front { recent.touch(front.id) }
        let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        var items = buildItems()
        if appWindows, let frontBundle { items = items.filter { $0.bundleID == frontBundle && !$0.isWindowless } }
        guard !items.isEmpty else {
            tap?.mode = .idle
            return NSSound.beep()
        }
        // The window you're in first, the one before it second and selected: set all at once,
        // with no animation, so the switcher opens already in that state.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            session.generation += 1
            session.pointer = PointerIntent(at: NSEvent.mouseLocation)
            session.cardFrames = [:]
            session.all = items
            session.query = nil
            session.appFilter = appWindows ? frontBundle : nil
            session.renaming = nil
            session.closing = []
            session.pinned = false
            session.showPreviews = showPreviews && CGPreflightScreenCaptureAccess()
            session.showHints = showHints
            session.thumbnails = thumbnails.cachedImages(for: items.compactMap(\.windowID)).merging(stripPictures(for: items)) { _, strip in strip }
            session.refilter(keepSelection: false)
            session.selection = SwitcherOrder.initialSelection(count: session.visible.count,
                                                               firstIsCurrent: session.visible.first?.windowID == front?.id,
                                                               backward: backward)
        }
        isOpen = true
        startHeartbeat()
        log.notice("open: \(self.session.visible.count) cards in \(Int((ProcessInfo.processInfo.systemUptime - started) * 1000)) ms, selected \(self.session.selection)")

        // A quick tap (⌘ already up): switch straight away, no flash of UI.
        if !modifierHeld() { return commit() }

        if session.showPreviews { requestThumbnails() }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.reveal() }
        }
        revealWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    private func reveal() {
        guard isOpen else { return }
        log.notice("reveal at +\(Int(Date().timeIntervalSince(self.openedAt) * 1000)) ms")
        if overlay == nil {
            overlay = SwitcherOverlay(session: session, actions: SwitcherActions(
                select: { [weak self] in self?.session.selection = $0 },
                commit: { [weak self] index in
                    guard let self else { return }
                    self.session.selection = index
                    self.commit()
                },
                saveRename: { [weak self] in self?.saveRename() },
                cancelRename: { [weak self] in self?.endTyping() },
                searchCommit: { [weak self] in self?.commit() },
                searchCancel: { [weak self] in self?.escape() },
                searchStep: { [weak self] in self?.step($0) },
                clickedOutside: { [weak self] in self?.cancel() }
            ))
        }
        overlay?.show(near: frontWindowScreen())
    }

    private func step(_ delta: Int) {
        lastInteraction = Date()
        session.selection = SwitcherOrder.move(session.selection, by: delta, count: session.visible.count)
        if session.showPreviews { requestThumbnails() }
    }

    private func commit() {
        guard isOpen else { return }
        let item = session.selected
        close()
        guard let item else { return }
        focus(item)
    }

    private func escape() {
        if session.renaming != nil { return endTyping() }
        if session.query != nil {
            session.query = nil
            session.refilter()
            return endTyping()
        }
        cancel()
    }

    func cancel() {
        guard isOpen else { return }
        close()
    }

    private func close() {
        isOpen = false
        revealWork?.cancel()
        revealWork = nil
        heartbeat?.invalidate()
        heartbeat = nil
        tap?.mode = .idle
        overlay?.hide()
        session.renaming = nil
        session.query = nil
        thumbnails.forgetSoon()
    }

    private func startHeartbeat() {
        tap?.heartbeat()
        heartbeat?.invalidate()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.beat() }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer
    }

    /// Keeps the key filter routing keys to the switcher, and catches a let-go the filter
    /// didn't see (macOS hid it behind Secure Input, or the event was dropped).
    private func beat() {
        guard isOpen else { return }
        tap?.heartbeat()
        if !session.pinned, !modifierHeld(), Date().timeIntervalSince(openedAt) > 0.05 { return commit() }
        // A pinned switcher nobody touches for a minute goes away by itself.
        if session.pinned, Date().timeIntervalSince(lastInteraction) > 60 { cancel() }
    }

    /// From the key events the filter sees (the hardware state misses software-posted keys).
    private func modifierHeld() -> Bool {
        if let tap, tap.isRunning { return tap.isTriggerHeld }
        let flags = CGEventSource.flagsState(.combinedSessionState)
        return flags.contains(trigger == .command ? .maskCommand : .maskAlternate)
    }

    // MARK: Focusing

    private func focus(_ item: SwitcherItem) {
        guard let app = NSRunningApplication(processIdentifier: item.pid) else { return }
        guard let window = item.windowID else {
            if app.isHidden { app.unhide() }
            app.activate()
            return
        }
        recent.touch(window)
        if app.isHidden { app.unhide() }
        if let own = ownWindow(item) {
            log.notice("switch to Tutto's own window \(window)")
            if own.isMiniaturized { own.deminiaturize(nil) }
            AppActivation.present(own)
            return
        }
        let pid = item.pid
        let title = item.rawTitle
        let opened = openedAt
        log.notice("switch to window \(window) (\(item.appName, privacy: .public)) at +\(Int(Date().timeIntervalSince(opened) * 1000)) ms")
        DispatchQueue.global(qos: .userInteractive).async {
            var element = WindowElements.element(for: window, pid: pid)
            if element == nil, WindowElements.chooseFromWindowMenu(title: title, pid: pid) {
                // The app is bringing the window forward; once it's on this Space its element exists.
                Thread.sleep(forTimeInterval: 0.3)
                element = WindowElements.element(for: window, pid: pid, budget: 0.15)
                log.notice("window \(window) chosen from its app's Window menu")
            }
            WindowFocus.focus(window: window, pid: pid, element: element)
            // Some apps hand focus back to another of their windows a moment later; check and insist once.
            Thread.sleep(forTimeInterval: 0.15)
            let landed = WindowServer.frontWindow()?.id == window
            if !landed {
                WindowFocus.focus(window: window, pid: pid, element: element)
            }
            log.notice("focus \(window): \(landed ? "in front" : "raised again", privacy: .public) at +\(Int(Date().timeIntervalSince(opened) * 1000)) ms")
        }
    }

    private func appActivated(_ app: NSRunningApplication?) {
        guard let pid = app?.processIdentifier, pid != getpid() else { return }
        observeFocus(of: pid)
        // The window comes forward a moment after its app is announced.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            MainActor.assumeIsolated {
                if let id = WindowServer.frontWindow(of: pid) { self?.recent.touch(id) }
            }
            // Remember its window's element while it's on this Space (cheap here, sometimes
            // impossible later from another Space).
            DispatchQueue.global(qos: .utility).async { WindowElements.rememberFocusedWindow(of: pid) }
        }
    }

    private func spaceChanged() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let front = WindowServer.frontWindow() else { return }
                self.recent.touch(front.id)
                let pid = front.pid
                DispatchQueue.global(qos: .utility).async { WindowElements.rememberFocusedWindow(of: pid) }
            }
        }
    }

    // MARK: Focus inside the front app

    private var focusObserver: AXObserver?
    private var observedPID: pid_t = 0

    /// Follows which of the front app's windows has focus (another Firefox window clicked,
    /// macOS's own window cycling), so "the window you were just in" stays exact. Only the
    /// front app is observed, and only focus changes are delivered.
    private func observeFocus(of pid: pid_t) {
        guard pid != observedPID else { return }
        stopObservingFocus()
        var created: AXObserver?
        let callback: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            let module = Unmanaged<SwitcherModule>.fromOpaque(refcon).takeUnretainedValue()
            WindowElements.remember(element)
            guard let id = WindowElements.windowID(of: element) else { return }
            MainActor.assumeIsolated { module.recent.touch(id) }
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let observer = created else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, app, kAXFocusedWindowChangedNotification as CFString, refcon)
        AXObserverAddNotification(observer, app, kAXMainWindowChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        focusObserver = observer
        observedPID = pid
    }

    private func stopObservingFocus() {
        if let focusObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(focusObserver), .defaultMode)
        }
        focusObserver = nil
        observedPID = 0
    }

    private func appTerminated(_ app: NSRunningApplication?) {
        guard let pid = app?.processIdentifier else { return }
        icons[pid] = nil
        guard isOpen else { return }
        session.all.removeAll { $0.pid == pid }
        session.refilter()
        if session.visible.isEmpty { cancel() }
    }

    // MARK: Actions on the selected card

    private func toggleAppFilter() {
        guard let item = session.selected else { return }
        session.appFilter = session.appFilter == nil ? item.bundleID : nil
        session.refilter()
    }

    private func closeSelected() {
        guard let item = session.selected, let window = item.windowID else { return quitSelected() }
        session.closing.insert(item.id)
        let pid = item.pid
        if let own = ownWindow(item) {
            own.performClose(nil)
        } else {
            DispatchQueue.global(qos: .userInitiated).async {
            guard let element = WindowElements.element(for: window, pid: pid) else { return }
                var button: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &button) == .success, let button {
                    AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)  // swiftlint:disable:this force_cast
                }
            }
        }
        // The card goes when the window really closes (an app asking to save keeps it open).
        for delay in [0.35, 1.2, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.dropIfClosed(item) }
            }
        }
    }

    private func dropIfClosed(_ item: SwitcherItem) {
        guard isOpen, let window = item.windowID, !WindowServer.exists(window) else { return }
        session.closing.remove(item.id)
        session.all.removeAll { $0.id == item.id }
        session.refilter()
        if session.visible.isEmpty { cancel() }
    }

    private func quitSelected() {
        guard let item = session.selected else { return }
        NSRunningApplication(processIdentifier: item.pid)?.terminate()
        for index in session.all.indices where session.all[index].pid == item.pid { session.closing.insert(session.all[index].id) }
    }

    private func minimizeSelected() {
        guard let item = session.selected, let window = item.windowID, !item.isMinimized else { return }
        mark(item.id) { $0.isMinimized = true }
        if let own = ownWindow(item) { return own.miniaturize(nil) }
        let pid = item.pid
        DispatchQueue.global(qos: .userInitiated).async {
            guard let element = WindowElements.element(for: window, pid: pid) else { return }
            AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        }
    }

    private func hideSelected() {
        guard let item = session.selected, let app = NSRunningApplication(processIdentifier: item.pid) else { return }
        app.hide()
        for index in session.all.indices where session.all[index].pid == item.pid { session.all[index].isHidden = true }
        session.refilter()
    }

    /// Places the selected window (fill the screen, centre it, move it to the next display)
    /// and switches to it.
    private func arrangeSelected(_ action: WindowAction) {
        guard let item = session.selected, let window = item.windowID, let windows = model?.windows else { return NSSound.beep() }
        close()
        focus(item)
        let pid = item.pid
        if ownWindow(item) != nil {
            // Tutto's own window answers Accessibility in-process: ask on the main thread.
            if let element = WindowElements.element(for: window, pid: pid) {
                windows.perform(action, on: element, app: NSRunningApplication.current)
            }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            guard let element = WindowElements.element(for: window, pid: pid) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                MainActor.assumeIsolated {
                    windows.perform(action, on: element, app: NSRunningApplication(processIdentifier: pid))
                }
            }
        }
    }

    /// Tutto's own window (its main or welcome window). An Accessibility call on it is answered
    /// inside Tutto, on whatever thread made it, and AppKit windows only work on the main
    /// thread: a raise from the background crashed Tutto. These are handled directly instead.
    private func ownWindow(_ item: SwitcherItem) -> NSWindow? {
        guard item.pid == getpid(), let id = item.windowID else { return nil }
        return NSApp.windows.first { $0.windowNumber == Int(id) }
    }

    private func mark(_ id: String, _ change: (inout SwitcherItem) -> Void) {
        if let index = session.all.firstIndex(where: { $0.id == id }) { change(&session.all[index]) }
        session.refilter()
    }

    // MARK: Search and rename

    private func beginSearch() {
        session.pinned = true
        session.query = session.query ?? ""
        session.refilter()
        tap?.mode = .typing
        overlay?.focusText()
    }

    private func beginRename() {
        guard let item = session.selected, !item.isWindowless else { return }
        session.pinned = true
        session.renaming = item.id
        session.renameText = item.customName ?? ""
        tap?.mode = .typing
        overlay?.focusText()
    }

    private func endTyping() {
        session.renaming = nil
        tap?.mode = isOpen ? .open : .idle
        overlay?.endTextFocus()
    }

    private func saveRename() {
        guard let id = session.renaming, let item = session.all.first(where: { $0.id == id }), let window = item.windowID else {
            return endTyping()
        }
        let text = session.renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        setName(text.isEmpty ? nil : text, for: item, window: window)
        mark(id) { $0.customName = text.isEmpty ? nil : text }
        endTyping()
    }

    private func setName(_ name: String?, for item: SwitcherItem, window: CGWindowID) {
        names.removeAll { $0.windowID == window && $0.bundleID == item.bundleID }
        if let name {
            names.append(WindowName(name: name, bundleID: item.bundleID, windowID: window, title: item.rawTitle,
                                    frame: item.frame, lastSeen: Date()))
        }
        saveNames()
    }

    func forgetName(_ name: WindowName) {
        names.removeAll { $0 == name }
        saveNames()
    }

    private func saveNames() {
        if let data = try? JSONEncoder().encode(names) { defaults.set(data, forKey: Keys.names) }
    }

    // MARK: Excluded apps

    func exclude(_ bundleID: String) {
        guard !excluded.contains(bundleID) else { return }
        excluded.append(bundleID)
        defaults.set(excluded, forKey: Keys.excluded)
    }

    func include(_ bundleID: String) {
        excluded.removeAll { $0 == bundleID }
        defaults.set(excluded, forKey: Keys.excluded)
    }

    // MARK: Building the list

    /// Every window (and windowless app) that belongs on a card, in switching order.
    func buildItems() -> [SwitcherItem] {
        let mine = getpid()
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && !excluded.contains($0.bundleIdentifier ?? "")
                && ($0.processIdentifier != mine || NSApp.activationPolicy() == .regular)
        }
        let byPID = Dictionary(apps.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
        let options = WindowAdmission.Options(includeMinimized: includeMinimized, includeHidden: includeHidden)
        let haveFlags = WindowServer.canClassify
        var windows = WindowServer.windows(of: Set(byPID.keys)).filter { WindowAdmission.admits($0, options: options, haveFlags: haveFlags) }
        // Tutto's own floating panels aren't windows to switch to.
        windows.removeAll { $0.pid == mine && $0.title.isEmpty }

        let spaces = WindowServer.spaces()
        let currentSpaces = Set(spaces.values.filter(\.isCurrent).map(\.id))
        var spaceOf: [CGWindowID: UInt64] = [:]
        for window in windows { spaceOf[window.id] = WindowServer.space(of: window.id) }
        if scope == .currentSpace {
            windows.removeAll { window in
                guard let space = spaceOf[window.id] else { return false }
                return !currentSpaces.contains(space) && !window.isMinimized && !window.isAppHidden
            }
        }

        // Names you gave windows find their windows (and follow them across app restarts).
        let live = windows.compactMap { w -> WindowNaming.Live? in
            guard let bundle = byPID[w.pid]?.bundleIdentifier else { return nil }
            return .init(id: w.id, bundleID: bundle, title: w.title, frame: w.frame)
        }
        let naming = WindowNaming.assign(names, to: live)
        if naming.updated != names {
            names = naming.updated
            saveNames()
        }

        var untitled: [pid_t: Int] = [:]
        var items: [SwitcherItem] = windows.compactMap { w in
            guard let app = byPID[w.pid] else { return nil }
            let appName = app.localizedName ?? app.bundleIdentifier ?? "App"
            var title = WindowTitles.clean(w.title, appName: appName)
            if title.isEmpty {
                untitled[w.pid, default: 0] += 1
                if untitled[w.pid]! > 1 { title = "\(appName) \(untitled[w.pid]!)" }
            }
            let place: String? = spaceOf[w.id].flatMap { spaces[$0] }.flatMap { info in
                info.isCurrent || info.isFullScreen ? nil : "Desktop \(info.desktopNumber)"
            }
            return SwitcherItem(id: "w\(w.id)", windowID: w.id, pid: w.pid, bundleID: app.bundleIdentifier ?? "", appName: appName,
                                icon: icon(for: app), title: title, rawTitle: w.title, customName: naming.names[w.id],
                                isMinimized: w.isMinimized, isHidden: w.isAppHidden || app.isHidden, place: place,
                                frame: w.frame, zIndex: w.zIndex)
        }
        let order = SwitcherOrder.order(items.map { ($0.windowID ?? 0, $0.zIndex, $0.isMinimized || $0.isHidden) }, recent: recent.ids)
        let position = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        items.sort { (position[$0.windowID ?? 0] ?? .max) < (position[$1.windowID ?? 0] ?? .max) }
        recent.keep(only: Set(items.compactMap(\.windowID)))
        WindowElements.prune(keeping: Set(windows.map(\.id)))

        // Apps with no window open stay reachable, after the windows (like Finder with none open).
        if includeWindowless {
            let withWindows = Set(items.map(\.pid))
            for app in apps where !withWindows.contains(app.processIdentifier) && app.processIdentifier != mine {
                items.append(SwitcherItem(id: "a\(app.processIdentifier)", windowID: nil, pid: app.processIdentifier,
                                          bundleID: app.bundleIdentifier ?? "", appName: app.localizedName ?? "App",
                                          icon: icon(for: app), title: "", rawTitle: "", customName: nil, isMinimized: false,
                                          isHidden: app.isHidden, place: nil, frame: .zero, zIndex: .max))
            }
        }
        return items
    }

    private func icon(for app: NSRunningApplication) -> NSImage {
        if let cached = icons[app.processIdentifier] { return cached }
        let image = app.icon ?? NSWorkspace.shared.icon(for: .application)
        icons[app.processIdentifier] = image
        return image
    }

    // MARK: Pictures

    private func requestThumbnails() {
        // The selection and its neighbours first, then the rest that fit on screen.
        let items = session.visible
        guard !items.isEmpty else { return }
        let around = (0..<min(items.count, 14)).map { offset -> Int in
            let side = offset % 2 == 0 ? offset / 2 : -(offset + 1) / 2
            return SwitcherOrder.move(session.selection, by: side, count: items.count)
        }
        // Windows the scrolling strip keeps out of view don't draw; show the picture it took
        // before tucking them away instead of capturing a blank one.
        let fromStrip = stripPictures(for: around.map { items[$0] })
        for (id, picture) in fromStrip { session.thumbnails[id] = picture }
        let ids = around.compactMap { items[$0].windowID }.filter { fromStrip[$0] == nil }
        thumbnails.capture(ids) { [weak self] id, image in
            guard let self, self.isOpen else { return }
            self.session.thumbnails[id] = image
        }
    }

    private func stripPictures(for items: [SwitcherItem]) -> [CGWindowID: NSImage] {
        guard let strip = model?.strip else { return [:] }
        var pictures: [CGWindowID: NSImage] = [:]
        for item in items {
            guard let id = item.windowID, strip.isParked(id), let picture = WindowPictures.shared.picture(for: id) else { continue }
            pictures[id] = picture
        }
        return pictures
    }

    private func frontWindowScreen() -> NSScreen? {
        if let front = WindowServer.frontWindow(),
           let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], front.id) as? [[String: Any]])?.first,
           let bounds = info[kCGWindowBounds as String] as? [String: Double] {
            // CoreGraphics measures from the top of the main screen; AppKit from the bottom.
            let mainHeight = NSScreen.screens.first?.frame.height ?? 0
            let center = CGPoint(x: (bounds["X"] ?? 0) + (bounds["Width"] ?? 0) / 2,
                                 y: mainHeight - (bounds["Y"] ?? 0) - (bounds["Height"] ?? 0) / 2)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) { return screen }
        }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    // MARK: Settings storage

    private func save(_ value: Any, _ key: String) { defaults.set(value, forKey: key) }

    private enum Keys {
        static let trigger = "switcher.trigger"
        static let scope = "switcher.scope"
        static let appWindowsKey = "switcher.appWindowsKey"
        static let previews = "switcher.previews"
        static let minimized = "switcher.includeMinimized"
        static let hidden = "switcher.includeHidden"
        static let windowless = "switcher.includeWindowless"
        static let hints = "switcher.hints"
        static let excluded = "switcher.excluded"
        static let names = "switcher.names"
    }
}

// MARK: - Pictures of windows

/// Card-sized pictures, taken on a background queue (two at a time) only while the switcher
/// is open, and forgotten 30 s after it closes so nothing stays in memory between uses.
@MainActor
final class ThumbnailStore {
    private var images: [CGWindowID: (image: NSImage, taken: Date)] = [:]
    private var inFlight = Set<CGWindowID>()
    private var forgetWork: DispatchWorkItem?
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        queue.name = "Window switcher pictures"
        return queue
    }()
    /// Card picture size in pixels (2x of 208 × 130 points).
    static let pixelSize = CGSize(width: 416, height: 260)

    func cachedImages(for ids: [CGWindowID]) -> [CGWindowID: NSImage] {
        forgetWork?.cancel()
        var result: [CGWindowID: NSImage] = [:]
        for id in ids { if let entry = images[id] { result[id] = entry.image } }
        return result
    }

    func capture(_ ids: [CGWindowID], completion: @escaping @MainActor (CGWindowID, NSImage) -> Void) {
        forgetWork?.cancel()
        for id in ids {
            if inFlight.contains(id) { continue }
            if let entry = images[id], Date().timeIntervalSince(entry.taken) < 2 { continue }
            inFlight.insert(id)
            queue.addOperation {
                // The whole window, or nothing (the card keeps its icon): never a clipped sliver.
                let picture = WindowPictures.capture(id, fitting: Self.pixelSize)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.inFlight.remove(id)
                        guard let picture else { return }
                        self.images[id] = (picture, Date())
                        completion(id, picture)
                    }
                }
            }
        }
    }

    func forgetSoon() {
        forgetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.removeAll() }
        }
        forgetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    func removeAll() {
        queue.cancelAllOperations()
        images.removeAll()
        inFlight.removeAll()
    }

    /// Shrinks a full-size window picture to fit `size`, keeping its shape.
    nonisolated static func scaled(_ image: CGImage, to size: CGSize) -> CGImage? {
        let scale = min(size.width / CGFloat(image.width), size.height / CGFloat(image.height), 1)
        let width = max(Int(CGFloat(image.width) * scale), 1), height = max(Int(CGFloat(image.height) * scale), 1)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
