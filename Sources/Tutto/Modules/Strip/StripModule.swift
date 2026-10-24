//
//  StripModule.swift
//  Tutto (scrolling strip)
//
//  Every window on a display sits side by side on one strip, full height between the menu
//  bar and the Dock, and the screen scrolls along it. ⌃⌥← → moves between windows, ⌃⌥R
//  cycles a window's width, ⌃⌥] stacks it into its neighbour, and so on; every key can be
//  changed on the Shortcuts page. Off until you turn it on.
//
//  How it stays calm and light:
//  - Nothing polls. Each app reports its window changes through an Accessibility observer,
//    and a display link runs only while windows are moving.
//  - Windows move on one queue per app, newest frame first, so a slow app never holds up
//    the rest of the strip.
//  - A window out of view waits in a bottom corner of its display with one point showing.
//  - Native full screen, dialogs, Quick Look and fixed-size windows are left alone.
//  - Stopping the strip (⌃⌥Q, switching it off, quitting Tutto) puts every window back on
//    screen where you can see it.
//

import AppKit
import ApplicationServices
import Observation
import os
import TuttoKit

private let log = Logger(subsystem: "ca.bryanyao.Tutto", category: "strip")

/// One display's current Space.
struct StripKey: Hashable, Codable {
    let display: String
    let space: UInt64
    var storageKey: String { "\(display)|\(space)" }
}

/// A window the strip moves.
@MainActor
final class StripManagedWindow {
    let id: CGWindowID
    let pid: pid_t
    var element: AXUIElement
    let bundleID: String?
    var key: StripKey
    /// The height it opened with, for Keep original height.
    var naturalHeight: Double
    /// A width the app insists on after refusing the one it was given.
    var enforcedWidth: Double?
    var refusals = 0
    /// Where the layout wants it.
    var target: CGRect
    var column = 0
    var isBackgroundTab = false
    /// The last frame sent to it (or read from it).
    var shown: CGRect
    var parked = false
    var spring: SpringFrame?
    var lastMove: TimeInterval = 0
    /// Resized in this move, so worth checking that the app took the size.
    var resized = false
    /// Being dragged or resized by hand: the strip keeps its hands off until the mouse is up.
    var held = false

    init(id: CGWindowID, pid: pid_t, element: AXUIElement, bundleID: String?, key: StripKey, frame: CGRect) {
        self.id = id
        self.pid = pid
        self.element = element
        self.bundleID = bundleID
        self.key = key
        naturalHeight = frame.height
        target = frame
        shown = frame
    }
}

/// The strip on one display's current Space.
@MainActor
final class StripState {
    let key: StripKey
    var display: StripDisplay
    var strip = Strip()
    /// The viewport offset as it moves (the model's `offset` is where it's going).
    var offset = SpringValue(0)
    /// Centred on purpose (⌃⌥C): keep the offset even past the strip's ends until the next move.
    var centred = false
    var swiping = false
    var swipe = SwipeTracker()

    init(key: StripKey, display: StripDisplay) {
        self.key = key
        self.display = display
    }
}

@MainActor
@Observable
final class StripModule: ModuleController {
    // MARK: Settings

    var gap: Double { didSet { save(gap, Keys.gap); relayoutAll() } }
    var presets: [Double] { didSet { save(presets, Keys.presets) } }
    var defaultWidth: Double { didSet { save(defaultWidth, Keys.defaultWidth) } }
    var fullHeight: Bool { didSet { save(fullHeight, Keys.fullHeight); relayoutAll() } }
    var centring: StripCentring { didSet { save(centring.rawValue, Keys.centring); relayoutAll(reveal: true) } }
    var animation: StripAnimation { didSet { save(animation.rawValue, Keys.animation) } }
    var showsIndicator: Bool { didSet { save(showsIndicator, Keys.indicator); if !showsIndicator { indicator.hide() } } }
    var focusBorder: Bool { didSet { save(focusBorder, Keys.border); updateDecor() } }
    var dimInactive: Bool { didSet { save(dimInactive, Keys.dim); updateDecor() } }
    /// 0 (off), 3 or 4 fingers.
    var swipeFingers: Int { didSet { save(swipeFingers, Keys.swipe); configureInput(); refreshSetupChecks() } }
    var swipeSnaps: Bool { didSet { save(swipeSnaps, Keys.swipeSnaps) } }
    var modifierScroll: Bool { didSet { save(modifierScroll, Keys.scroll); configureInput() } }
    var focusFollowsMouse: Bool { didSet { save(focusFollowsMouse, Keys.focusFollowsMouse); configureInput() } }
    var mouseFollowsFocus: Bool { didSet { save(mouseFollowsFocus, Keys.mouseFollowsFocus) } }
    /// When windows are put in their places: only on a strip key (and when you switch to a
    /// window that's out of view), or all the time.
    var arrangeMode: ArrangeMode { didSet { save(arrangeMode.rawValue, Keys.arrange) } }
    /// Window pictures in the strip bar instead of app icons.
    var barPreviews: Bool { didSet { save(barPreviews, Keys.barPreviews); if barPreviews { refreshBarPictures() } } }

    enum ArrangeMode: String, CaseIterable { case onCommand, always }
    private var arrangesAlways: Bool { arrangeMode == .always }
    private(set) var disabledDisplays: [String]
    private(set) var floatingApps: [String]

    // MARK: Status

    private(set) var isTrusted = AXIsProcessTrusted()
    /// False while stopped with ⌃⌥Q (the module stays on, its shortcuts too).
    private(set) var isRunning = false
    private(set) var windowCount = 0
    private(set) var displayList: [StripDisplay] = []
    private(set) var setupChecks: [MacSetupCheck] = []
    /// Windows in native full screen, each on a Space of its own, which the strip leaves alone.
    private(set) var fullScreenWindowCount = 0
    private(set) var isBringingHome = false

    weak var model: AppModel?

    // MARK: Engine

    @ObservationIgnored private var strips: [StripKey: StripState] = [:]
    @ObservationIgnored private var currentKeys: [String: StripKey] = [:]
    @ObservationIgnored private var windows: [CGWindowID: StripManagedWindow] = [:]
    @ObservationIgnored private var away: [CGWindowID: AwayWindow] = [:]
    /// Windows that float on their own (dialogs, fixed size…), so they aren't asked again.
    @ObservationIgnored private var floating: Set<CGWindowID> = []
    /// Windows floated with ⌃⌥T.
    @ObservationIgnored private var userFloated: Set<CGWindowID> = []
    @ObservationIgnored private var observers: [pid_t: StripAppObserver] = [:]
    @ObservationIgnored private var animating: Set<CGWindowID> = []
    @ObservationIgnored private var geometries: [StripKey: StripGeometry] = [:]
    @ObservationIgnored private let mover = StripMover()
    @ObservationIgnored private lazy var link = StripDisplayLink { [weak self] dt in self?.step(dt: dt) }
    @ObservationIgnored private let indicator = StripIndicator()
    @ObservationIgnored private var indicatorKey: StripKey?
    @ObservationIgnored private let tabBars = StripTabBars()
    @ObservationIgnored private let decor = StripDecor()
    @ObservationIgnored private var input: StripInputTap?
    @ObservationIgnored private var keyTap: ShortcutTap?
    @ObservationIgnored private var keyCommands: [String: StripCommand] = [:]
    @ObservationIgnored private var keyBindings: [KeyShortcut: StripCommand] = [:]
    @ObservationIgnored private var notifications: [NSObjectProtocol] = []
    @ObservationIgnored private var distributed: [NSObjectProtocol] = []
    @ObservationIgnored private var mouseWatch: Timer?
    @ObservationIgnored private var revealOnMouseUp = false
    @ObservationIgnored private var hoverWork: DispatchWorkItem?
    @ObservationIgnored private var quietFocusUntil: TimeInterval = 0
    @ObservationIgnored private var decorWindow: CGWindowID?
    /// Windows coming out of full screen to join the strip: full width, in their Spaces' order.
    @ObservationIgnored private var arrivals: [CGWindowID: Int] = [:]
    @ObservationIgnored private var lastNoStripHint: TimeInterval = -1_000
    /// ⌃⌥ held right now, as the key filter reports it.
    @ObservationIgnored private var holdingModifiers = false
    @ObservationIgnored private var lastModifierEvent: TimeInterval = 0
    /// The window a strip key just gave focus to, and until when other reports are stale.
    @ObservationIgnored private var expectedFocus: (window: CGWindowID, until: TimeInterval)?
    @ObservationIgnored private var pictureTaken: [CGWindowID: TimeInterval] = [:]
    /// Set by a size key until the bar goes: the bar shows icons, so the window being sized
    /// isn't hidden behind pictures.
    @ObservationIgnored private var sizingBar = false
    /// Counts questions to apps about their focused window; only the latest answer counts.
    @ObservationIgnored private var focusQuestion = 0
    /// Windows gone out of view that still need their picture taken (once the strip is still).
    @ObservationIgnored private var unphotographed: Set<CGWindowID> = []
    @ObservationIgnored private var photographWork: DispatchWorkItem?
    @ObservationIgnored private let pictureQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        queue.name = "Strip pictures"
        return queue
    }()
    /// The strip a swipe started on keeps it until the fingers lift, wherever the pointer goes.
    @ObservationIgnored private var swipeKey: StripKey?
    @ObservationIgnored private var icons: [pid_t: NSImage] = [:]
    @ObservationIgnored private var savedLayouts: [String: [StripColumn]]
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private var parkedWork: DispatchWorkItem?
    @ObservationIgnored private var displayWork: DispatchWorkItem?
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let ownPID = ProcessInfo.processInfo.processIdentifier
    #if DEBUG
    /// `--strip-only <apps>`: manage only those apps' windows (live tests with test windows), as
    /// bundle ids or `pid:<n>` (a second copy of an app the user also runs), comma-separated.
    @ObservationIgnored private let onlyApps: [String]? = {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--strip-only"), args.count > index + 1 else { return nil }
        return args[index + 1].split(separator: ",").map(String.init)
    }()

    private func labAllows(pid: pid_t, bundleID: String?) -> Bool {
        guard let onlyApps else { return true }
        return onlyApps.contains("pid:\(pid)") || bundleID.map(onlyApps.contains) == true
    }
    @ObservationIgnored private var commandStarted: TimeInterval?
    @ObservationIgnored private var frames = 0
    @ObservationIgnored private var longestFrame = 0.0
    @ObservationIgnored private var lastFrameAt = 0.0
    #endif

    private struct AwayWindow {
        enum Reason { case minimized, hidden, fullScreen }
        var key: StripKey?
        var slot: StripSlot?
        var pid: pid_t
        var element: AXUIElement
        var reason: Reason
    }

    init(model: AppModel) {
        self.model = model
        let d = UserDefaults.standard
        gap = d.object(forKey: Keys.gap) as? Double ?? 8
        presets = (d.array(forKey: Keys.presets) as? [Double]).flatMap { $0.isEmpty ? nil : $0 } ?? Strip.defaultPresets
        defaultWidth = d.object(forKey: Keys.defaultWidth) as? Double ?? 0.5
        fullHeight = d.object(forKey: Keys.fullHeight) as? Bool ?? true
        centring = StripCentring(rawValue: d.string(forKey: Keys.centring) ?? "") ?? .never
        animation = StripAnimation(rawValue: d.string(forKey: Keys.animation) ?? "") ?? .smooth
        showsIndicator = d.object(forKey: Keys.indicator) as? Bool ?? true
        focusBorder = d.bool(forKey: Keys.border)
        dimInactive = d.bool(forKey: Keys.dim)
        swipeFingers = d.integer(forKey: Keys.swipe)
        swipeSnaps = d.object(forKey: Keys.swipeSnaps) as? Bool ?? true
        modifierScroll = d.object(forKey: Keys.scroll) as? Bool ?? true
        focusFollowsMouse = d.bool(forKey: Keys.focusFollowsMouse)
        mouseFollowsFocus = d.bool(forKey: Keys.mouseFollowsFocus)
        arrangeMode = ArrangeMode(rawValue: d.string(forKey: Keys.arrange) ?? "") ?? .onCommand
        barPreviews = d.object(forKey: Keys.barPreviews) as? Bool ?? true
        disabledDisplays = d.stringArray(forKey: Keys.disabledDisplays) ?? []
        floatingApps = d.stringArray(forKey: Keys.floatingApps) ?? []
        if let data = d.data(forKey: Keys.layouts), let saved = try? JSONDecoder().decode([String: [StripColumn]].self, from: data) {
            savedLayouts = saved
        } else {
            savedLayouts = [:]
        }
        indicator.onSelect = { [weak self] column in self?.indicatorSelected(column) }
        indicator.onHidden = { [weak self] in self?.sizingBar = false }
        // macOS's own modifier state misses keys posted by software (remote control, automation);
        // the key filter sees those. Either one saying ⌃⌥ are down keeps the bar.
        indicator.isHeld = { [weak self] in
            if StripIndicator.modifiersHeld() { return true }
            guard let self else { return false }
            return self.holdingModifiers && ProcessInfo.processInfo.systemUptime - self.lastModifierEvent < 10
        }
        indicator.onMove = { [weak self] from, to in self?.indicatorMoved(from, to) }
        tabBars.onSelect = { [weak self] window in self?.tabSelected(window) }
    }

    // MARK: Lifecycle

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        func on(_ name: Notification.Name, _ action: @escaping @MainActor (NSRunningApplication?) -> Void) {
            notifications.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated { action(app) }
            })
        }
        on(NSWorkspace.didLaunchApplicationNotification) { [weak self] app in self?.appLaunched(app) }
        on(NSWorkspace.didTerminateApplicationNotification) { [weak self] app in self?.appTerminated(app) }
        on(NSWorkspace.didActivateApplicationNotification) { [weak self] _ in self?.syncFocus() }
        on(NSWorkspace.didHideApplicationNotification) { [weak self] app in self?.appHidden(app) }
        on(NSWorkspace.didUnhideApplicationNotification) { [weak self] app in self?.appShown(app) }
        on(NSWorkspace.activeSpaceDidChangeNotification) { [weak self] _ in self?.spaceChanged() }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            on(name) { [weak self] _ in self?.scheduleRebuild(after: 1.2) }
        }
        notifications.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                    object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRebuild(after: 0.6) }
        })
        // Accessibility switched on later: start then, without a relaunch.
        distributed.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isTrusted = AXIsProcessTrusted()
                    if self.isTrusted, !self.isRunning { self.begin() }
                }
            }
        })
        refreshSetupChecks()
        startKeyTap()
        begin()
    }

    func stop() {
        end()
        keyTap?.stop()
        keyTap = nil
        notifications.forEach {
            NSWorkspace.shared.notificationCenter.removeObserver($0)
            NotificationCenter.default.removeObserver($0)
        }
        notifications.removeAll()
        distributed.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        distributed.removeAll()
        link.invalidate()
        indicator.close()
    }

    private func begin() {
        isTrusted = AXIsProcessTrusted()
        guard isTrusted, !isRunning else { return }
        if keyTap?.isRunning != true { startKeyTap() }
        isRunning = true
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            ensureObserver(app.processIdentifier)
        }
        rebuild()
        configureInput()
        log.notice("strip started: \(self.windows.count) windows on \(self.currentKeys.count) displays")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated { self?.prepareIndicator() }
        }
    }

    /// The bar is built before the first hold of ⌃⌥ needs it.
    private func prepareIndicator() {
        guard isRunning, showsIndicator, let state = activeState(), !state.strip.isEmpty else { return }
        indicator.prepare(tiles: tiles(for: state), display: state.display, previews: barPreviews && WindowPictures.canCapture)
    }

    /// Puts every window back on screen and lets go of everything; the settings stay.
    private func end() {
        guard isRunning else { return }
        saveLayoutsNow()
        releaseAllWindows()
        isRunning = false
        input?.stop()
        input = nil
        mouseWatch?.invalidate()
        mouseWatch = nil
        observers.values.forEach { $0.invalidate() }
        observers.removeAll()
        strips.removeAll()
        currentKeys.removeAll()
        windows.removeAll()
        away.removeAll()
        floating.removeAll()
        animating.removeAll()
        geometries.removeAll()
        link.stop()
        tabBars.removeAll()
        decor.removeAll()
        indicator.hide()
        windowCount = 0
        defaults.removeObject(forKey: Keys.parked)
    }

    // MARK: Keys

    /// The strip's shortcuts, caught by a key filter in front of the session (so they work
    /// even when another app registered the same keys first); the regular registrations
    /// underneath answer while a password field hides keys from filters.
    func setShortcuts(_ shortcuts: [KeyShortcut: StripCommand]) {
        keyBindings = shortcuts
        keyCommands = Dictionary(shortcuts.map { ($0.value.id, $0.value) }, uniquingKeysWith: { first, _ in first })
        keyTap?.bindings = shortcuts.mapValues(\.id)
    }

    func setShortcutsSuspended(_ suspended: Bool) {
        keyTap?.isSuspended = suspended
    }

    /// The strip bar is hold-to-see: it appears as soon as ⌃⌥ are both held, stays while they
    /// are (strip keys update it in place), and goes the moment they're let go.
    private func modifiersChanged(_ modifiers: KeyShortcut.Modifiers) {
        let timing = PerfLog.begin("strip modifiers"); defer { timing.end() }
        lastModifierEvent = ProcessInfo.processInfo.systemUptime
        let held = modifiers.contains(.control) && modifiers.contains(.option)
        guard held != holdingModifiers else { return }
        holdingModifiers = held
        guard held else { return indicator.hide() }
        guard isRunning, let state = activeState(), !state.strip.isEmpty else { return }
        if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier, front != ownPID { mover.expectMoves(of: front) }
        guard showsIndicator else { return }
        showIndicator(state, message: nil, refused: false)
    }

    private func startKeyTap() {
        guard AXIsProcessTrusted() else { return }
        let tap = keyTap ?? ShortcutTap { [weak self] id in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let command = self.keyCommands[id] else { return }
                    self.perform(command)
                }
            }
        }
        keyTap = tap
        tap.bindings = keyBindings.mapValues(\.id)
        tap.onModifiers = { [weak self] modifiers in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.modifiersChanged(modifiers) } }
        }
        if !tap.isRunning || !tap.isEnabled { tap.start(name: "Strip keys") }
    }

    // MARK: Settings actions

    func setDisplay(_ uuid: String, enabled: Bool) {
        disabledDisplays.removeAll { $0 == uuid }
        if !enabled { disabledDisplays.append(uuid) }
        defaults.set(disabledDisplays, forKey: Keys.disabledDisplays)
        guard isRunning else { return }
        if !enabled, let key = currentKeys[uuid], let state = strips[key] {
            release(state)
            for id in state.strip.allWindows { forget(id) }
            strips[key] = nil
        }
        rebuild()
    }

    func floatApp(_ bundleID: String) {
        guard !floatingApps.contains(bundleID) else { return }
        floatingApps.append(bundleID)
        defaults.set(floatingApps, forKey: Keys.floatingApps)
        for w in windows.values where w.bundleID == bundleID {
            guard let state = strips[w.key] else { continue }
            state.strip.remove(w.id)
            putOnScreen(w, in: state)
            forget(w.id)
            floating.insert(w.id)
            reveal(state)
            apply(state, animated: true)
        }
    }

    func tileApp(_ bundleID: String) {
        floatingApps.removeAll { $0 == bundleID }
        defaults.set(floatingApps, forKey: Keys.floatingApps)
        floating.removeAll()
        guard isRunning else { return }
        rebuild()
    }

    /// Lays the strip out again from the windows on screen now.
    func retileNow() {
        guard isRunning else { return begin() }
        rebuild(arrange: true)
        if let state = activeState() { showIndicator(state, message: "Tiled every window", refused: false) }
    }

    func refreshSetupChecks() {
        let reading = Self.readMacSetup()
        let tiling = ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))
        setupChecks = MacSetup.checks(reading, swipeFingers: swipeFingers > 0 ? swipeFingers : nil, hasEdgeTiling: tiling)
        fullScreenWindowCount = fullScreenWindows().count
    }

    /// Said when you switch the strip on: what it's doing, or why it has nothing to do yet.
    func announce() {
        refreshSetupChecks()
        if !isTrusted {
            Toast.shared.show("Scrolling Strip needs Accessibility", detail: "Allow Tutto in Privacy & Security › Accessibility. Click for details.",
                              duration: 4) { MainWindowController.shared.show(page: .strip) }
        } else if windowCount == 0, fullScreenWindowCount > 0 {
            Toast.shared.show("Scrolling Strip is on", detail: "Your apps are in full screen, each on its own Space, so there's nothing on the strip yet. Click to bring them onto it.",
                              duration: 6) { MainWindowController.shared.show(page: .strip) }
        } else {
            Toast.shared.show("Scrolling Strip is on", detail: "\(windowCount) \(windowCount == 1 ? "window" : "windows") side by side · ⌃⌥ ← → or ⌃⌥ + scroll to move along",
                              duration: 4) { MainWindowController.shared.show(page: .strip) }
        }
    }

    /// Real windows of regular apps that sit in native full screen, in Mission Control's order.
    private func fullScreenWindows() -> [ServerWindow] {
        let spaces = WindowServer.spaces()
        let order = WindowServer.spaceOrder()
        let pids = Set(NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ownPID && !floatingApps.contains($0.bundleIdentifier ?? "")
        }.map(\.processIdentifier))
        let found = WindowServer.windows(of: pids).compactMap { window -> (ServerWindow, Int)? in
            guard WindowAdmission.admits(window), !window.isMinimized, !window.isAppHidden,
                  let space = WindowServer.space(of: window.id), spaces[space]?.isFullScreen == true else { return nil }
            return (window, order.firstIndex(of: space) ?? Int.max)
        }
        return found.sorted { $0.1 < $1.1 }.map(\.0)
    }

    /// Takes every window out of native full screen so it lands on the desktop and joins the
    /// strip at full width: each one still fills the screen, and the strip slides between them
    /// (⌃⌥ ← →, ⌃⌥ + scroll) where macOS's Spaces used to.
    func bringFullScreenWindowsHere() {
        guard isRunning, !isBringingHome else { return }
        let windows = fullScreenWindows()
        guard !windows.isEmpty else { return refreshSetupChecks() }
        isBringingHome = true
        for (rank, window) in windows.enumerated() { arrivals[window.id] = rank }
        let targets = windows.map { (id: $0.id, pid: $0.pid, title: $0.title) }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var brought = 0
            for target in targets {
                var element = WindowElements.element(for: target.id, pid: target.pid, budget: 0.4)
                if element == nil, WindowElements.chooseFromWindowMenu(title: target.title, pid: target.pid) {
                    // The app brings the window forward; on its own Space it can be asked.
                    Thread.sleep(forTimeInterval: 0.7)
                    element = WindowElements.element(for: target.id, pid: target.pid, budget: 0.2)
                }
                guard let element else { continue }
                AXUIElementSetAttributeValue(element, "AXFullScreen" as CFString, kCFBooleanFalse)
                brought += 1
                // One at a time: macOS animates each window back out to the desktop.
                Thread.sleep(forTimeInterval: 1.1)
            }
            let count = brought
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isBringingHome = false
                    self.rebuild(arrange: true)
                    self.refreshSetupChecks()
                    let missed = targets.count - count
                    Toast.shared.show(count > 0 ? "\(count) \(count == 1 ? "window" : "windows") on the strip" : "Couldn't reach those windows",
                                      detail: missed > 0 ? "\(missed) didn't answer; open each once and try again." : "⌃⌥ ← → or ⌃⌥ + scroll slides between them.",
                                      duration: 4)
                }
            }
        }
    }

    private static func readMacSetup() -> MacSetupReading {
        func value(_ key: String, _ domain: String) -> NSNumber? {
            CFPreferencesAppSynchronize(domain as CFString)
            return CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? NSNumber
        }
        let wm = "com.apple.WindowManager"
        let trackpad = "com.apple.AppleMultitouchTrackpad"
        let edge = value("EnableTilingByEdgeDrag", wm)?.boolValue
        let top = value("EnableTopTilingByEdgeDrag", wm)?.boolValue
        return MacSetupReading(spansDisplays: value("spans-displays", "com.apple.spaces")?.boolValue,
                               rearrangesSpaces: value("mru-spaces", "com.apple.dock")?.boolValue,
                               stageManager: value("GloballyEnabled", wm)?.boolValue,
                               edgeTiling: edge == false && top == false ? false : (edge == nil && top == nil ? nil : true),
                               threeFingerSwipe: value("TrackpadThreeFingerHorizSwipeGesture", trackpad)?.intValue,
                               fourFingerSwipe: value("TrackpadFourFingerHorizSwipeGesture", trackpad)?.intValue,
                               threeFingerDrag: value("TrackpadThreeFingerDrag", trackpad)?.boolValue)
    }

    // MARK: Building strips

    private func scheduleRebuild(after delay: TimeInterval) {
        displayWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.keyTap?.isEnabled == false { self.startKeyTap() }
                guard self.isRunning else { return }
                self.rebuild()
                if self.input?.isEnabled == false { self.configureInput() }
            }
        }
        displayWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func spaceChanged() {
        guard isRunning else { return }
        indicator.hide()
        tabBars.removeAll()
        decor.removeAll()
        rebuild()
    }

    /// Finds each display's current Space and builds or refreshes its strip. Windows are laid
    /// out too when `arrange` is set or the strip keeps them in place all the time.
    private func rebuild(arrange: Bool = false) {
        guard isRunning else { return }
        let displays = StripDisplay.all()
        displayList = displays
        let spaces = WindowServer.currentSpaces()
        var keys: [String: StripKey] = [:]
        for display in displays where !disabledDisplays.contains(display.uuid) {
            guard let space = spaces[display.uuid] ?? spaces["Main"] ?? (spaces.count == 1 ? spaces.values.first : nil),
                  !space.isFullScreen else { continue }
            keys[display.uuid] = StripKey(display: display.uuid, space: space.id)
        }
        currentKeys = keys
        let existing = StripAX.existingWindowIDs()
        var fresh: [StripState] = []
        for key in keys.values {
            guard let display = displays.first(where: { $0.uuid == key.display }) else { continue }
            if let state = strips[key] {
                state.display = display
                prune(state, existing: existing)
            } else {
                let state = StripState(key: key, display: display)
                strips[key] = state
                fresh.append(state)
            }
        }
        // Windows that arrived while a strip wasn't looking, or never met it.
        let states = keys.values.compactMap { strips[$0] }
        collect(into: states, restoring: Set(fresh.map(\.key)))
        for state in states {
            let isFresh = fresh.contains { $0 === state }
            if isFresh {
                state.strip.offset = geometry(for: state).offset(revealing: state.strip.focusColumn, from: 0, centring: centring)
                state.offset.snap(to: state.strip.offset)
            }
            if arrange || arrangesAlways {
                apply(state, animated: !isFresh && arrange)
            } else if isFresh {
                // Arranged only on a strip key: windows stay where they are, except any left out of
                // view by an earlier run, which come back on screen.
                for id in state.strip.allWindows { if let w = windows[id], w.parked { putOnScreen(w, in: state) } }
            }
        }
        windowCount = windows.count
        updateDecor()
    }

    /// Adds every tileable window on the current Spaces to its display's strip: saved
    /// arrangements first (for strips being restored), the rest left to right.
    private func collect(into states: [StripState], restoring: Set<StripKey>) {
        guard !states.isEmpty else { return }
        let z = StripAX.zOrder()
        var found: [StripKey: [(StripManagedWindow, Int)]] = [:]
        var returning: [(CGWindowID, AXUIElement, pid_t)] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && !app.isHidden && app.processIdentifier != ownPID {
            ensureObserver(app.processIdentifier)
            for element in StripAX.windows(of: app.processIdentifier) {
                if let id = StripAX.windowID(element), away[id] != nil {
                    returning.append((id, element, app.processIdentifier))
                    continue
                }
                guard let frame = StripAX.frame(element), let state = state(for: frame), states.contains(where: { $0 === state }),
                      let w = admit(element, pid: app.processIdentifier, bundleID: app.bundleIdentifier, into: state) else { continue }
                found[state.key, default: []].append((w, z[w.id] ?? Int.max))
            }
        }
        for state in states {
            let incoming = found[state.key] ?? []
            guard !incoming.isEmpty else { continue }
            var strip = state.strip
            if restoring.contains(state.key), let saved = savedLayouts[state.key.storageKey] {
                let live = Set(incoming.map(\.0.id))
                strip.columns = saved.compactMap { column in
                    var column = column
                    let before = column.windows.count
                    column.windows = column.windows.filter { live.contains($0) }
                    guard !column.windows.isEmpty else { return nil }
                    if column.windows.count != before { column.heights = [] }
                    if column.windows.count < 2 { column.tabbed = false }
                    column.activeTab = min(column.activeTab, column.windows.count - 1)
                    return column
                }
            }
            let metrics = metrics(for: state)
            // Windows back from full screen keep their Spaces' order, after everything else.
            func rank(_ w: StripManagedWindow) -> Int { self.arrivals[w.id].map { 1_000 + $0 } ?? 0 }
            for (w, _) in incoming.sorted(by: { a, b in
                if rank(a.0) != rank(b.0) { return rank(a.0) < rank(b.0) }
                return a.0.shown.minX != b.0.shown.minX ? a.0.shown.minX < b.0.shown.minX : a.1 < b.1
            }) where !strip.contains(w.id) {
                let full = self.arrivals.removeValue(forKey: w.id) != nil
                strip.insert(w.id, width: full ? 1 : initialWidth(w.shown, metrics: metrics), besideFocused: false, focus: false)
            }
            if let front = incoming.min(by: { $0.1 < $1.1 })?.0, restoring.contains(state.key) { strip.focus(front.id) }
            state.strip = strip
        }
        // Back from full screen (or the Dock) while the strip was looking elsewhere.
        for (id, element, pid) in returning { comeBack(id, element: element, pid: pid, focus: false) }
    }

    /// The preset nearest a window's current width (a window wider than nine tenths of the
    /// screen keeps the full width).
    private func initialWidth(_ frame: CGRect, metrics: StripMetrics) -> Double {
        let fraction = metrics.fraction(for: frame.width)
        if fraction > 0.92 { return 1 }
        return presets.min { abs($0 - fraction) < abs($1 - fraction) } ?? defaultWidth
    }

    /// Takes windows that closed off a strip; `thorough` also those that left for another
    /// Space or display (one Accessibility call each, so only when Spaces or displays change).
    private func prune(_ state: StripState, existing: Set<CGWindowID>, thorough: Bool = true) {
        for id in state.strip.allWindows {
            guard let w = windows[id], existing.contains(id) else {
                forget(id)
                continue
            }
            guard thorough else { continue }
            if let space = WindowServer.space(of: id), space != state.key.space {
                forget(id)
            } else if !w.parked, let frame = StripAX.frame(w.element), let owner = self.state(for: frame), owner !== state {
                forget(id)
            }
        }
    }

    /// A tileable window becomes one the strip manages (not yet placed in a column).
    private func admit(_ element: AXUIElement, pid: pid_t, bundleID: String?, into state: StripState) -> StripManagedWindow? {
        guard let id = StripAX.windowID(element), !userFloated.contains(id), !floating.contains(id) else { return nil }
        if let known = windows[id] {
            // Still on a strip of a Space that isn't showing: it moved here.
            guard !isCurrent(known.key) else { return nil }
            strips[known.key]?.strip.remove(id)
            known.key = state.key
            known.element = element
            known.parked = true
            return known
        }
        #if DEBUG
        if !labAllows(pid: pid, bundleID: bundleID) { return nil }
        #endif
        let facts = StripAX.facts(element, bundleID: bundleID)
        switch StripRules.admission(facts, floatingApps: Set(floatingApps), ownBundleID: Bundle.main.bundleIdentifier) {
        case .ignore:
            if facts.isMinimized {
                away[id] = AwayWindow(key: nil, slot: nil, pid: pid, element: element, reason: .minimized)
                observers[pid]?.watch(element, as: id)
            }
            return nil
        case .float(let reason):
            floating.insert(id)
            log.debug("floats: \(id) \(bundleID ?? "?", privacy: .public) (\(reason, privacy: .public))")
            return nil
        case .tile:
            break
        }
        guard let frame = StripAX.frame(element) else { return nil }
        if let space = WindowServer.space(of: id), space != state.key.space { return nil }
        let w = StripManagedWindow(id: id, pid: pid, element: element, bundleID: bundleID, key: state.key, frame: frame)
        w.parked = StripParking.isParked(frame, display: state.display.visible)
        windows[id] = w
        observers[pid]?.watch(element, as: id)
        return w
    }

    private func forget(_ id: CGWindowID) {
        if let w = windows.removeValue(forKey: id) {
            strips[w.key]?.strip.remove(id)
            observers[w.pid]?.unwatch(id)
        }
        animating.remove(id)
        away[id] = nil
    }

    // MARK: Apps

    private func ensureObserver(_ pid: pid_t) {
        guard observers[pid] == nil, pid != ownPID else { return }
        if let observer = StripAppObserver(pid: pid, handler: { [weak self] pid, event in self?.handle(event, pid: pid) }) {
            observers[pid] = observer
        }
    }

    private func appLaunched(_ app: NSRunningApplication?) {
        guard isRunning, let app, app.activationPolicy == .regular else { return }
        let pid = app.processIdentifier
        // Apps take a moment to answer, and some open their first window late.
        for delay in [0.4, 1.2, 3.0, 8.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.adoptWindows(of: pid) }
            }
        }
    }

    private func adoptWindows(of pid: pid_t) {
        guard isRunning, NSRunningApplication(processIdentifier: pid)?.isHidden == false else { return }
        ensureObserver(pid)
        for element in StripAX.windows(of: pid) {
            guard let id = StripAX.windowID(element) else { continue }
            if windows[id] != nil || floating.contains(id) { continue }
            adopt(element, pid: pid, id: id)
        }
    }

    private func appTerminated(_ app: NSRunningApplication?) {
        guard let app else { return }
        let pid = app.processIdentifier
        observers.removeValue(forKey: pid)?.invalidate()
        mover.forget(pid: pid)
        icons[pid] = nil
        let gone = windows.values.filter { $0.pid == pid }
        let keys = Set(gone.map(\.key))
        gone.forEach { forget($0.id) }
        away = away.filter { $0.value.pid != pid }
        for key in keys where isCurrent(key) {
            guard let state = strips[key] else { continue }
            arrangeIfAlways(state)
        }
        windowCount = windows.count
    }

    private func appHidden(_ app: NSRunningApplication?) {
        guard isRunning, let app else { return }
        for w in windows.values where w.pid == app.processIdentifier {
            guard let state = strips[w.key] else { continue }
            sendAway(w, from: state, reason: .hidden)
        }
    }

    private func appShown(_ app: NSRunningApplication?) {
        guard isRunning, let app else { return }
        let pid = app.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                for (id, record) in self.away where record.pid == pid && record.reason == .hidden {
                    self.comeBack(id, element: record.element, pid: pid, focus: false)
                }
                self.adoptWindows(of: pid)
            }
        }
    }

    // MARK: Window events

    private func handle(_ event: StripAppObserver.Event, pid: pid_t) {
        let timing = PerfLog.begin("strip notice \(String(describing: event).prefix(14))", over: 0.004); defer { timing.end() }
        guard isRunning else { return }
        switch event {
        case .created(let element):
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                MainActor.assumeIsolated { self?.adopt(element, pid: pid) }
            }
        case .focusChanged(let element):
            focusNoticed(element, pid: pid)
        case .destroyed(let element):
            guard let id = observers[pid]?.window(for: element) else { return }
            if windows[id] == nil {
                away[id] = nil
                floating.remove(id)
                userFloated.remove(id)
                observers[pid]?.unwatch(id)
                return
            }
            // A closed native tab hands its column to the next tab in its group.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                MainActor.assumeIsolated { self?.windowClosed(id) }
            }
        case .moved(let element), .resized(let element):
            // Every frame the strip sends comes back as one of these.
            if let match = observers[pid]?.watchedWindow(for: element) {
                windowChanged(match.id, element: match.element, pid: pid)
            } else if let id = StripAX.windowID(element) {
                windowChanged(id, element: element, pid: pid)
            }
        case .minimized(let element):
            guard let id = observers[pid]?.window(for: element), let w = windows[id], let state = strips[w.key] else { return }
            sendAway(w, from: state, reason: .minimized)
        case .deminimized(let element):
            guard let id = observers[pid]?.window(for: element) else { return }
            // After the window has finished growing back out of the Dock.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                MainActor.assumeIsolated { self?.comeBack(id, element: element, pid: pid, focus: true) }
            }
        case .titleChanged(let element):
            guard let id = observers[pid]?.window(for: element), let w = windows[id], let state = strips[w.key],
                  state.strip.location(of: id).map({ state.strip.columns[$0.column].tabbed }) == true else { return }
            updateTabBars()
        }
    }

    /// A window the strip hasn't met: tile it beside the focused window (or at the end, quietly,
    /// when its app is in the background).
    private func adopt(_ element: AXUIElement, pid: pid_t, focus: Bool? = nil, id known: CGWindowID? = nil) {
        guard isRunning, let id = known ?? StripAX.windowID(element), windows[id] == nil, !floating.contains(id), !userFloated.contains(id) else { return }
        #if DEBUG
        if !labAllows(pid: pid, bundleID: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier) { return }
        #endif
        // A window on a Space without a strip (an app in full screen) is left alone before its
        // app is asked anything: busy apps keep the strip waiting.
        if let space = WindowServer.space(of: id), !currentKeys.values.contains(where: { $0.space == space }) { return }
        if takeOverNativeTab(id, element: element, pid: pid) { return }
        guard let frame = StripAX.frame(element), let state = state(for: frame) else { return }
        let app = NSRunningApplication(processIdentifier: pid)
        guard let w = admit(element, pid: pid, bundleID: app?.bundleIdentifier, into: state) else { return }
        let front = focus ?? (NSWorkspace.shared.frontmostApplication?.processIdentifier == pid)
        let width = arrivals.removeValue(forKey: w.id) != nil ? 1 : defaultWidth
        state.strip.insert(w.id, width: width, besideFocused: front, focus: front)
        if front { reveal(state) }
        arrangeIfAlways(state)
        windowCount = windows.count
        saveLayoutsSoon()
        log.debug("adopted \(id) into column \(state.strip.location(of: id)?.column ?? -1)")
    }

    /// Native window tabs are separate windows sharing one frame, only the front one on screen.
    /// A tab coming to the front takes over the column of the one it replaced, and tabs behind
    /// never get columns of their own.
    private func takeOverNativeTab(_ id: CGWindowID, element: AXUIElement, pid: pid_t) -> Bool {
        guard let frame = StripAX.frame(element) else { return false }
        let onScreen = StripAX.onScreenWindowIDs()
        let siblings = windows.values.filter { $0.pid == pid && Self.sameFrame($0.shown, frame) }
        if !onScreen.contains(id) { return !siblings.isEmpty }
        guard let old = siblings.first(where: { !onScreen.contains($0.id) }), let state = strips[old.key],
              let (c, r) = state.strip.location(of: old.id) else { return false }
        let wasFocused = state.strip.focusedWindow == old.id
        state.strip.columns[c].windows[r] = id
        let w = StripManagedWindow(id: id, pid: pid, element: element, bundleID: old.bundleID, key: old.key, frame: frame)
        w.target = old.target
        w.column = old.column
        w.naturalHeight = old.naturalHeight
        w.enforcedWidth = old.enforcedWidth
        windows[old.id] = nil
        observers[pid]?.unwatch(old.id)
        windows[id] = w
        observers[pid]?.watch(element, as: id)
        if wasFocused { state.strip.focus(id) }
        updateTabBars()
        updateDecor()
        return true
    }

    private static func sameFrame(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 3 && abs(a.minY - b.minY) < 3 && abs(a.width - b.width) < 3 && abs(a.height - b.height) < 3
    }

    private func windowClosed(_ id: CGWindowID) {
        guard let w = windows[id], let state = strips[w.key] else { return forget(id) }
        if let next = nextNativeTab(after: w), let (c, r) = state.strip.location(of: id) {
            state.strip.columns[c].windows[r] = next.id
            windows[id] = nil
            observers[w.pid]?.unwatch(id)
            let replacement = StripManagedWindow(id: next.id, pid: w.pid, element: next.element, bundleID: w.bundleID, key: w.key, frame: w.shown)
            replacement.target = w.target
            replacement.column = w.column
            windows[next.id] = replacement
            observers[w.pid]?.watch(next.element, as: next.id)
            updateTabBars()
            return
        }
        let wasFocused = state.strip.focusedWindow == id
        forget(id)
        guard isCurrent(state.key) else { return }
        if wasFocused { reveal(state) }
        arrangeIfAlways(state)
        windowCount = windows.count
        saveLayoutsSoon()
    }

    private func nextNativeTab(after w: StripManagedWindow) -> (id: CGWindowID, element: AXUIElement)? {
        let onScreen = StripAX.onScreenWindowIDs()
        for element in StripAX.windows(of: w.pid) {
            guard let id = StripAX.windowID(element), id != w.id, windows[id] == nil, onScreen.contains(id),
                  let frame = StripAX.frame(element), Self.sameFrame(frame, w.shown) else { continue }
            return (id, element)
        }
        return nil
    }

    /// Moved or resized by something other than the strip.
    private func windowChanged(_ id: CGWindowID, element: AXUIElement, pid: pid_t) {
        guard let w = windows[id] else {
            // Back from full screen.
            if let record = away[id], record.reason == .fullScreen, !StripAX.isFullScreen(element) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    MainActor.assumeIsolated { self?.comeBack(id, element: element, pid: pid, focus: true) }
                }
            }
            return
        }
        guard let state = strips[w.key] else { return }
        // The strip's own moves, and a drag in progress, need nothing from the app. (A window
        // gone full screen is also caught by the Space change.)
        let now = ProcessInfo.processInfo.systemUptime
        if animating.contains(id) || now - w.lastMove < 0.5 || w.held || state.swiping { return }
        if StripAX.isFullScreen(element) { return sendAway(w, from: state, reason: .fullScreen) }
        guard let frame = StripAX.frame(element), !Self.sameFrame(frame, w.shown) else { return }
        if NSEvent.pressedMouseButtons & 1 != 0 {
            w.held = true
            watchMouseUp()
            return
        }
        guard arrangesAlways else {
            // Moved or resized by something else (the window palette, the app itself): it stays
            // where it was put. A new width becomes its column's width at the next strip key.
            if abs(frame.width - w.shown.width) > 4, let (c, _) = state.strip.location(of: id), state.strip.columns[c].windows.count == 1 {
                state.strip.setWidth(metrics(for: state).fraction(for: frame.width), forColumnOf: id)
                w.enforcedWidth = nil
                w.refusals = 0
            }
            w.shown = frame
            w.parked = StripParking.isParked(frame, display: state.display.visible)
            w.spring = nil
            return
        }
        // The app moved or resized itself: put it back once; if it insists on its width,
        // it keeps that width and the strip lays out around it.
        if abs(frame.width - w.target.width) > 12, abs(frame.width - w.shown.width) > 2 {
            w.refusals += 1
            if w.refusals >= 2 { w.enforcedWidth = frame.width }
        }
        w.shown = frame
        w.spring = nil
        if isCurrent(state.key) { apply(state, animated: true) }
    }

    private func sendAway(_ w: StripManagedWindow, from state: StripState, reason: AwayWindow.Reason) {
        away[w.id] = AwayWindow(key: w.key, slot: state.strip.slot(of: w.id), pid: w.pid, element: w.element, reason: reason)
        state.strip.remove(w.id)
        windows[w.id] = nil
        animating.remove(w.id)
        guard isCurrent(state.key) else { return }
        reveal(state)
        arrangeIfAlways(state)
        windowCount = windows.count
    }

    /// A window back from the Dock, from hiding or from full screen goes back to its slot.
    private func comeBack(_ id: CGWindowID, element: AXUIElement, pid: pid_t, focus: Bool) {
        guard isRunning, windows[id] == nil else { return }
        let record = away.removeValue(forKey: id)
        // Some apps hand out a new element for a window after it's been minimized.
        let fresh = StripAX.windows(of: pid).first { StripAX.windowID($0) == id } ?? element
        guard !StripAX.isMinimized(fresh), !StripAX.isFullScreen(fresh), let frame = StripAX.frame(fresh) else { return }
        let state = record?.key.flatMap { isCurrent($0) ? strips[$0] : nil } ?? self.state(for: frame)
        guard let state, let w = admit(fresh, pid: pid, bundleID: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier, into: state) else { return }
        if let slot = record?.slot {
            state.strip.restore(w.id, to: slot)
        } else {
            state.strip.insert(w.id, width: defaultWidth, besideFocused: true, focus: focus)
        }
        if focus { state.strip.focus(w.id) }
        reveal(state)
        arrangeIfAlways(state)
        windowCount = windows.count
    }

    // MARK: Focus

    /// The strip follows focus: a window you click or ⌘Tab to scrolls into view.
    /// The app in front is asked which window has focus off the main thread: the app you just
    /// switched to is often busy drawing, and its answer took 30–70 ms, a stall in whatever was
    /// animating. A newer question makes an older answer moot.
    private func syncFocus() {
        guard isRunning, let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ownPID else { return updateDecor() }
        let pid = app.processIdentifier
        focusQuestion += 1
        let question = focusQuestion
        mover.run(pid: pid) { [weak self] in
            nonisolated(unsafe) let element = StripAX.focusedWindow(of: pid)
            let id = element.flatMap(StripAX.windowID)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, question == self.focusQuestion else { return }
                    self.focusMoved(to: element, id: id, pid: pid)
                }
            }
        }
    }

    /// An app's focus notice names its window: one the strip watches needs no question.
    private func focusNoticed(_ element: AXUIElement?, pid: pid_t) {
        guard let element, let match = observers[pid]?.watchedWindow(for: element) else { return syncFocus() }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
        focusQuestion += 1
        focusMoved(to: match.element, id: match.id, pid: pid)
    }

    private func focusMoved(to element: AXUIElement?, id: CGWindowID?, pid: pid_t) {
        let timing = PerfLog.begin("strip focus"); defer { timing.end() }
        guard isRunning, let element, let id else { return updateDecor() }
        guard let w = windows[id] else {
            if !floating.contains(id), !userFloated.contains(id), away[id] == nil {
                adopt(element, pid: pid, focus: true, id: id)
            }
            return updateDecor()
        }
        guard let state = strips[w.key], isCurrent(w.key), !w.held else { return updateDecor() }
        if let expected = expectedFocus {
            if expected.window == id || ProcessInfo.processInfo.systemUptime > expected.until {
                expectedFocus = nil
            } else {
                return updateDecor()  // a late report of the window the strip just moved focus away from
            }
        }
        guard state.strip.focusedWindow != id || (w.parked && !arrangesAlways) else { return updateDecor() }
        state.strip.focus(id)
        // Arranged only on strip keys: a window you can see stays put; one out of view (you
        // switched to it with ⌘Tab) slides into view.
        if !arrangesAlways, !w.parked {
            updateIndicatorTiles()
            return updateDecor()
        }
        // A click on a window can be the start of a drag: scroll once the mouse is up.
        if NSEvent.pressedMouseButtons & 1 != 0 {
            revealOnMouseUp = true
            watchMouseUp()
            return updateDecor()
        }
        if ProcessInfo.processInfo.systemUptime >= quietFocusUntil { reveal(state) }
        apply(state, animated: true)
        updateIndicatorTiles()
    }

    private func reveal(_ state: StripState) {
        state.centred = false
        state.strip.offset = geometry(for: state).offset(revealing: state.strip.focusColumn, from: state.strip.offset, centring: centring)
    }

    /// Gives the focused column's window the keyboard, after its first move is on its way.
    private func focusWindow(in state: StripState) {
        guard let id = state.strip.focusedWindow, let w = windows[id] else { return }
        // While macOS catches up it can still report the window that had focus before; those
        // reports mustn't send the strip back there.
        expectedFocus = (id, ProcessInfo.processInfo.systemUptime + 0.8)
        let element = w.element
        let pid = w.pid
        nonisolated(unsafe) let unsafeElement = element
        mover.run(pid: pid) { _ = WindowFocus.focus(window: id, pid: pid, element: unsafeElement) }
    }

    // MARK: Commands

    func perform(_ command: StripCommand) {
        let timing = PerfLog.begin("strip \(command.id)"); defer { timing.end() }
        if command == .toggleRunning { return toggleRunning() }
        guard isRunning else {
            Toast.shared.show("The strip is stopped", detail: isTrusted ? "⌃⌥Q starts it again." : "Allow Accessibility for Tutto first.")
            return
        }
        // A full-screen app's Space (or a display the strip is off for) has no strip: say why,
        // once in a while, instead of doing nothing silently.
        guard let state = activeState() else {
            log.notice("\(command.id, privacy: .public): no strip here")
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastNoStripHint > 60 {
                lastNoStripHint = now
                Toast.shared.show("Not on the strip", detail: "This app is in full screen, on a Space of its own. Click to bring your full-screen apps onto the strip.",
                                  duration: 4) { MainWindowController.shared.show(page: .strip) }
            }
            return
        }
        #if DEBUG
        commandStarted = ProcessInfo.processInfo.systemUptime
        frames = 0
        #endif
        prune(state, existing: StripAX.existingWindowIDs(), thorough: false)
        matchSystemFocus(state)
        let before = state.strip.focusedWindow
        var strip = state.strip
        var outcome: StripOutcome
        var resized = false
        switch command {
        case .focusLeft: outcome = strip.focusLeft()
        case .focusRight: outcome = strip.focusRight()
        case .focusUp: outcome = strip.focusUp()
        case .focusDown: outcome = strip.focusDown()
        case .focusFirst: outcome = strip.focusFirst()
        case .focusLast: outcome = strip.focusLast()
        case .focusNumber(let n): outcome = strip.focusNumber(n)
        case .moveLeft: outcome = strip.moveLeft()
        case .moveRight: outcome = strip.moveRight()
        case .moveUp: outcome = strip.moveUp()
        case .moveDown: outcome = strip.moveDown()
        case .moveToFirst: outcome = strip.moveToFirst()
        case .moveToLast: outcome = strip.moveToLast()
        case .moveToNumber(let n): outcome = strip.moveToNumber(n)
        case .cycleWidth:
            outcome = strip.cycleWidth(presets: presets)
            resized = true
        case .fullWidth:
            outcome = strip.toggleFullWidth(fallback: defaultWidth)
            resized = true
        case .wider:
            outcome = strip.adjustWidth(by: 0.1)
            resized = true
        case .narrower:
            outcome = strip.adjustWidth(by: -0.1)
            resized = true
        case .taller: outcome = strip.adjustHeight(by: 0.1)
        case .shorter: outcome = strip.adjustHeight(by: -0.1)
        case .equalizeHeights: outcome = strip.equalizeHeights()
        case .pinLeft: outcome = strip.togglePin(.left)
        case .pinRight: outcome = strip.togglePin(.right)
        case .stackLeft: outcome = strip.stack(into: .left)
        case .stackRight: outcome = strip.stack(into: .right)
        case .popOutRight: outcome = strip.popOut(to: .right)
        case .popOutLeft: outcome = strip.popOut(to: .left)
        case .toggleTabbed: outcome = strip.toggleTabbed()
        case .centre:
            outcome = strip.isEmpty ? .refused("The strip is empty.") : .done("Centre")
        case .showStrip:
            return showIndicator(state, message: nil, refused: false, force: true, duration: 2.5)
        case .nextDisplay:
            return sendToNextDisplay(from: state)
        case .toggleFloat:
            return toggleFloat(in: state)
        case .toggleRunning:
            return
        }
        if resized, strip.columns.indices.contains(strip.focusColumn) {
            for id in strip.columns[strip.focusColumn].windows {
                windows[id]?.enforcedWidth = nil
                windows[id]?.refusals = 0
            }
        }
        state.strip = strip
        // Sizing a window: the bar turns to icons until it goes, so the pictures don't cover the
        // bottom of the screen while you judge the size. It changes before anything moves, so its
        // one redraw doesn't land on the move.
        if [.cycleWidth, .fullWidth, .wider, .narrower, .taller, .shorter, .equalizeHeights].contains(command), !sizingBar {
            sizingBar = true
            if indicator.isVisible { showIndicator(state, message: outcome.message, refused: !outcome.changed) }
        }
        if outcome.changed {
            if command == .centre {
                state.centred = true
                state.strip.offset = geometry(for: state).centredOffset(for: state.strip.focusColumn)
            } else {
                reveal(state)
            }
            apply(state, animated: true)
            if state.strip.focusedWindow != before { focusWindow(in: state) }
            if mouseFollowsFocus { warpPointer(to: state) }
            saveLayoutsSoon()
        } else if !arrangesAlways {
            // A strip key arranges the strip even when its own move can't happen (already at
            // the end): windows moved by hand go back in place.
            apply(state, animated: true)
        }
        log.notice("\(command.id, privacy: .public): \(outcome.message, privacy: .public)")
        #if DEBUG
        if !outcome.changed { commandStarted = nil }
        #endif
        showIndicator(state, message: outcome.message, refused: !outcome.changed)
    }

    private func toggleRunning() {
        if isRunning {
            end()
            Toast.shared.show("Strip stopped", detail: "Every window is back on screen. ⌃⌥Q starts it again.")
        } else {
            begin()
            if isRunning {
                Toast.shared.show("Strip started", detail: "\(windowCount) windows on the strip")
            } else {
                Toast.shared.show("Accessibility needed", detail: "Allow Tutto in Privacy & Security › Accessibility.")
            }
        }
    }

    /// The model's focus follows the window you're actually in before a command acts on it.
    private func matchSystemFocus(_ state: StripState) {
        guard let app = NSWorkspace.shared.frontmostApplication, let element = StripAX.focusedWindow(of: app.processIdentifier),
              let id = StripAX.windowID(element), state.strip.contains(id), state.strip.focusedWindow != id else { return }
        state.strip.focus(id)
    }

    private func sendToNextDisplay(from state: StripState) {
        let order = displayList.filter { currentKeys[$0.uuid] != nil }
        guard order.count > 1, let index = order.firstIndex(where: { $0.uuid == state.key.display }),
              let id = state.strip.focusedWindow, let w = windows[id] else {
            return showIndicator(state, message: "There's no other display with a strip.", refused: true)
        }
        let next = order[(index + 1) % order.count]
        guard let key = currentKeys[next.uuid], let target = strips[key] else { return }
        let width = state.strip.columns[state.strip.focusColumn].width
        state.strip.remove(id)
        target.strip.insert(id, width: width, besideFocused: true, focus: true)
        w.key = target.key
        w.spring = nil
        w.parked = true  // comes in on the other display rather than sliding across both
        animating.remove(id)
        reveal(state)
        reveal(target)
        apply(state, animated: true)
        apply(target, animated: true)
        focusWindow(in: target)
        saveLayoutsSoon()
        showIndicator(target, message: "Sent to \(next.name)", refused: false)
    }

    private func toggleFloat(in state: StripState) {
        // Tutto's own windows never join the strip (they float above it, like dialogs).
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ownPID,
              let element = StripAX.focusedWindow(of: app.processIdentifier),
              let id = StripAX.windowID(element) else { return NSSound.beep() }
        if let w = windows[id], let owner = strips[w.key] {
            owner.strip.remove(id)
            let visible = owner.display.visible
            let size = CGSize(width: min(w.target.width, visible.width * 0.7).rounded(), height: min(w.target.height, visible.height * 0.8).rounded())
            let frame = CGRect(x: (visible.midX - size.width / 2).rounded(), y: (visible.midY - size.height / 2).rounded(),
                               width: size.width, height: size.height)
            mover.move(id, pid: w.pid, element: w.element, to: frame, order: .settle)
            forget(id)
            userFloated.insert(id)
            reveal(owner)
            apply(owner, animated: true)
            showIndicator(owner, message: "Floating · off the strip", refused: false)
        } else {
            userFloated.remove(id)
            floating.remove(id)
            guard let frame = StripAX.frame(element), let target = self.state(for: frame) ?? Optional(state) else { return }
            // Tiled because you asked, even if it's the kind of window that floats on its own.
            let w = StripManagedWindow(id: id, pid: app.processIdentifier, element: element, bundleID: app.bundleIdentifier,
                                       key: target.key, frame: frame)
            windows[id] = w
            observers[app.processIdentifier]?.watch(element, as: id)
            target.strip.insert(id, width: defaultWidth, besideFocused: true, focus: true)
            reveal(target)
            apply(target, animated: true)
            showIndicator(target, message: "Tiled · back on the strip", refused: false)
        }
        windowCount = windows.count
        saveLayoutsSoon()
    }

    // MARK: Layout and motion

    private func metrics(for state: StripState) -> StripMetrics {
        StripMetrics(area: state.display.visible, gap: gap, fullHeight: fullHeight)
    }

    private func geometry(for state: StripState) -> StripGeometry {
        var enforced: [StripWindow: Double] = [:]
        var natural: [StripWindow: Double] = [:]
        for id in state.strip.allWindows {
            guard let w = windows[id] else { continue }
            if let width = w.enforcedWidth { enforced[id] = width }
            natural[id] = w.naturalHeight
        }
        return StripGeometry(strip: state.strip, metrics: metrics(for: state), enforcedWidths: enforced, naturalHeights: natural)
    }

    private func relayoutAll(reveal revealing: Bool = false) {
        guard isRunning else { return }
        for key in currentKeys.values {
            guard let state = strips[key] else { continue }
            if revealing { reveal(state) }
            apply(state, animated: true)
        }
    }

    /// Sends every window of a strip toward its place: sizes change at once, positions glide.
    private func apply(_ state: StripState, animated: Bool) {
        let timing = PerfLog.begin("strip apply"); defer { timing.end() }
        guard isCurrent(state.key) else { return }
        let geometry = geometry(for: state)
        if !state.centred, centring != .always { state.strip.offset = geometry.clamped(state.strip.offset) }
        let instant = !animated || animation == .instant
        if instant { state.offset.snap(to: state.strip.offset) }
        let now = geometry.placements(offset: state.offset.value)
        let entry = Dictionary(now.map { ($0.window, $0.frame) }, uniquingKeysWith: { first, _ in first })
        for placement in geometry.placements(offset: state.strip.offset) {
            guard let w = windows[placement.window] else { continue }
            w.target = placement.frame
            w.column = placement.column
            w.isBackgroundTab = placement.isBackgroundTab
            if w.held { continue }
            if placement.isBackgroundTab {
                w.spring = nil
                animating.remove(w.id)
                park(w, in: state, side: .right)
                continue
            }
            var spring: SpringFrame
            if let moving = w.spring {
                spring = moving
            } else {
                // A window coming in from out of view starts where the strip would have it
                // right now, off the edge, and glides in with the rest.
                spring = SpringFrame(w.parked ? (entry[w.id] ?? placement.frame) : w.shown)
                if state.strip.columns[placement.column].pin == nil { spring.x.velocity = -state.offset.velocity }
            }
            // Position and size follow the same spring, so columns stay exactly a gap apart while
            // widths change (the order each frame is sent in keeps macOS from clamping a size).
            if instant { spring.snap(to: placement.frame) }
            w.spring = spring
            animating.insert(w.id)
        }
        geometries[state.key] = geometry
        step(dt: 0)
        if !animating.isEmpty || !state.offset.isSettled(at: state.strip.offset) { link.start() }
        updateTabBars()
        updateIndicatorTiles()
    }

    /// One display refresh: every moving window takes its next step.
    private func step(dt: Double) {
        let timing = PerfLog.begin("strip frame", over: 0.004); defer { timing.end() }
        let omega = animation.omega
        var moving = false
        for key in currentKeys.values {
            guard let state = strips[key], !state.swiping else { continue }
            if let omega, dt > 0 { state.offset.step(toward: state.strip.offset, omega: omega, dt: dt) }
            if omega == nil || state.offset.isSettled(at: state.strip.offset) {
                state.offset.snap(to: state.strip.offset)
            } else {
                moving = true
            }
        }
        var settled: [StripManagedWindow] = []
        for id in Self.sendingOrder(Array(animating), windows: windows) {
            guard let w = windows[id], var spring = w.spring, let state = strips[w.key], let geometry = geometries[w.key], !w.held else {
                animating.remove(id)
                windows[id]?.spring = nil
                continue
            }
            if let omega, dt > 0 { spring.step(toward: w.target, omega: omega, dt: dt) }
            let done = omega == nil || spring.isSettled(at: w.target)
            if done {
                w.spring = nil
                animating.remove(id)
                settled.append(w)
            } else {
                w.spring = spring
                moving = true
            }
            place(w, at: done ? w.target : spring.roundedRect, state: state, geometry: geometry, settling: done)
        }
        #if DEBUG
        if dt > 0 {
            frames += 1
            let now = CACurrentMediaTime()
            if lastFrameAt > 0 { longestFrame = max(longestFrame, now - lastFrameAt) }
            lastFrameAt = now
        }
        #endif
        followWithOverlays()
        if !moving, dt > 0 || animating.isEmpty {
            link.stop()
            didSettle(settled)
        }
    }

    /// The order a frame's moves are sent in, so neighbours never overlap on the way: windows
    /// heading right go first (the rightmost first, making room), then ones that only change
    /// size, then ones heading left (the leftmost first, filling in behind).
    private static func sendingOrder(_ ids: [CGWindowID], windows: [CGWindowID: StripManagedWindow]) -> [CGWindowID] {
        func heading(_ id: CGWindowID) -> Double {
            guard let w = windows[id] else { return 0 }
            return w.target.minX - w.shown.minX
        }
        func x(_ id: CGWindowID) -> Double { Double(windows[id]?.shown.minX ?? 0) }
        let right = ids.filter { heading($0) > 0.5 }.sorted { x($0) > x($1) }
        let still = ids.filter { abs(heading($0)) <= 0.5 }
        let left = ids.filter { heading($0) < -0.5 }.sorted { x($0) < x($1) }
        return right + still + left
    }

    private func place(_ w: StripManagedWindow, at rect: CGRect, state: StripState, geometry: StripGeometry, settling: Bool = false) {
        let inView = geometry.isInView(rect, column: w.column) && !overhangsAnotherDisplay(rect, state.display)
        if inView {
            guard w.parked || rect != w.shown || (settling && w.resized) else { return }
            let resize = w.parked || abs(rect.width - w.shown.width) > 0.5 || abs(rect.height - w.shown.height) > 0.5
            let grows = rect.width > w.shown.width + 0.5 || rect.height > w.shown.height + 0.5
            let order: StripAX.FrameOrder = settling && (resize || w.resized) ? .settle : (resize ? (grows ? .growing : .shrinking) : .positionOnly)
            send(w, rect, order: order)
            if w.parked {
                w.parked = false
                parkedChanged()
            }
        } else if !w.parked {
            park(w, in: state, side: rect.midX < state.display.visible.midX ? .left : .right)
        }
    }

    /// A window out of view waits in a corner at its own size: a window resized while out of
    /// view never redraws, and the switcher would show it blank. It's photographed once the
    /// strip is still, so the switcher and the strip bar can show what's in it (the picture is
    /// of the whole window wherever it is).
    private func park(_ w: StripManagedWindow, in state: StripState, side: StripSide) {
        guard !w.parked else { return }
        if WindowPictures.canCapture {
            unphotographed.insert(w.id)
            photographSoon()
        }
        let others = displayList.filter { $0.uuid != state.display.uuid }.map(\.frame)
        let frame = StripParking.frame(size: w.shown.size, side: side, display: state.display.visible, others: others)
        send(w, frame, order: .positionOnly)
        w.parked = true
        parkedChanged()
    }

    /// Whether the strip has a window waiting out of view (the switcher shows its picture).
    func isParked(_ window: CGWindowID) -> Bool { windows[window]?.parked == true }

    private func arrangeIfAlways(_ state: StripState) {
        if arrangesAlways { apply(state, animated: true) }
    }

    private func send(_ w: StripManagedWindow, _ frame: CGRect, order: StripAX.FrameOrder) {
        mover.move(w.id, pid: w.pid, element: w.element, to: frame, order: order)
        w.shown = frame
        w.lastMove = ProcessInfo.processInfo.systemUptime
        if order == .growing || order == .shrinking { w.resized = true }
        #if DEBUG
        if let started = commandStarted {
            log.notice("first move \(Int((ProcessInfo.processInfo.systemUptime - started) * 1000)) ms after the key")
            commandStarted = nil
        }
        #endif
    }

    private func overhangsAnotherDisplay(_ rect: CGRect, _ display: StripDisplay) -> Bool {
        displayList.contains { $0.uuid != display.uuid && $0.frame.intersects(rect.insetBy(dx: 2, dy: 2)) }
    }

    /// Checks that apps took the sizes they were given; one that insists on its own width
    /// keeps it, and the strip makes room.
    private func didSettle(_ settled: [StripManagedWindow]) {
        let timing = PerfLog.begin("strip settle"); defer { timing.end() }
        #if DEBUG
        if frames > 0 { log.notice("settled after \(self.frames) frames, longest \(Int(self.longestFrame * 1000)) ms") }
        frames = 0
        longestFrame = 0
        lastFrameAt = 0
        #endif
        updateDecor()
        // Pictures are taken of windows at rest: the bar's are refreshed once the strip is still.
        if !unphotographed.isEmpty || (indicator.isVisible && indicator.state.previews) { photographSoon() }
        for w in settled where w.resized && !w.parked {
            w.resized = false
            let id = w.id
            mover.readFrame(of: w.element, pid: w.pid, after: 0.15) { [weak self] frame in
                guard let self, let frame, let w = self.windows[id], !w.held, w.spring == nil, !w.parked,
                      let state = self.strips[w.key], self.isCurrent(w.key) else { return }
                if abs(frame.width - w.target.width) > 12 {
                    w.refusals += 1
                    w.shown = frame
                    if w.refusals >= 2 { w.enforcedWidth = frame.width }
                    self.apply(state, animated: true)
                } else if !Self.sameFrame(frame, w.shown) {
                    w.shown = frame
                }
            }
        }
    }

    private func putOnScreen(_ w: StripManagedWindow, in state: StripState) {
        let visible = state.display.visible
        var frame = w.parked || w.isBackgroundTab ? w.target : w.shown
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        guard !Self.sameFrame(frame, w.shown) || w.parked else { return }
        StripAX.setFrame(frame, of: w.element, size: !Self.sameFrame(CGRect(origin: .zero, size: frame.size), CGRect(origin: .zero, size: w.shown.size)))
        w.shown = frame
        w.parked = false
    }

    private func release(_ state: StripState) {
        for id in state.strip.allWindows {
            if let w = windows[id] { putOnScreen(w, in: state) }
        }
    }

    /// Every window the strip moved, on every Space, back where you can see it.
    private func releaseAllWindows() {
        link.stop()
        for w in windows.values {
            guard let state = strips[w.key] else { continue }
            putOnScreen(w, in: state)
        }
    }

    // MARK: Hand moves

    private func watchMouseUp() {
        guard mouseWatch == nil else { return }
        mouseWatch = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
                timer.invalidate()
                self.mouseWatch = nil
                self.mouseReleased()
            }
        }
    }

    private func mouseReleased() {
        let held = windows.values.filter(\.held)
        for w in held {
            w.held = false
            finishHandMove(w)
        }
        if revealOnMouseUp {
            revealOnMouseUp = false
            if held.isEmpty, let state = activeState() {
                reveal(state)
                apply(state, animated: true)
            }
        }
    }

    /// A window let go after a drag (reorder; another display) or a resize (new width).
    private func finishHandMove(_ w: StripManagedWindow) {
        guard let frame = StripAX.frame(w.element), let state = strips[w.key], let (c, r) = state.strip.location(of: w.id) else { return }
        let resized = abs(frame.width - w.shown.width) > 4 || abs(frame.height - w.shown.height) > 4
        w.shown = frame
        w.spring = nil
        w.parked = false
        guard arrangesAlways else {
            // Arranged only on strip keys: a window you moved stays there; a new width is kept
            // for its column at the next strip key.
            if resized, state.strip.columns[c].windows.count == 1 {
                state.strip.setWidth(metrics(for: state).fraction(for: frame.width), forColumnOf: w.id)
                w.enforcedWidth = nil
                w.refusals = 0
            }
            return saveLayoutsSoon()
        }
        if resized {
            let metrics = metrics(for: state)
            state.strip.setWidth(metrics.fraction(for: frame.width), forColumnOf: w.id)
            w.enforcedWidth = nil
            w.refusals = 0
            var column = state.strip.columns[c]
            if column.windows.count > 1, !column.tabbed {
                let available = metrics.inner.height - metrics.gap * Double(column.windows.count - 1)
                var heights = column.normalizedHeights
                let wanted = min(max(frame.height / available, Strip.minimumHeightFraction), 1 - Strip.minimumHeightFraction * Double(heights.count - 1))
                let rest = heights.indices.filter { $0 != r }.reduce(0) { $0 + heights[$1] }
                for index in heights.indices where index != r { heights[index] = rest > 0 ? heights[index] / rest * (1 - wanted) : 0 }
                heights[r] = wanted
                column.heights = heights
                state.strip.columns[c] = column
            }
            if !fullHeight, column.windows.count == 1 { w.naturalHeight = frame.height }
        } else {
            // Dropped on another display: it joins that display's strip.
            if let other = self.state(for: frame), other !== state {
                state.strip.remove(w.id)
                other.strip.insert(w.id, width: state.strip.columns.indices.contains(c) ? metrics(for: other).fraction(for: frame.width) : defaultWidth,
                                   besideFocused: true, focus: true)
                w.key = other.key
                reveal(state)
                apply(state, animated: true)
                reveal(other)
                apply(other, animated: true)
                saveLayoutsSoon()
                return
            }
            let geometry = geometry(for: state)
            if let target = geometry.column(atScreenX: frame.midX, offset: state.strip.offset), target != c {
                state.strip.moveColumn(from: c, to: target)
            }
            state.strip.focus(w.id)
        }
        reveal(state)
        apply(state, animated: true)
        saveLayoutsSoon()
    }

    // MARK: Trackpad and mouse

    private func configureInput() {
        guard isRunning else { return }
        let options = StripInputTap.Options(scroll: modifierScroll, swipeFingers: swipeFingers, pointer: focusFollowsMouse)
        if input == nil {
            input = StripInputTap { [weak self] event in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.handleInput(event) } }
            }
        }
        if !(input?.start(options) ?? false) { log.error("strip input taps refused") }
    }

    private func handleInput(_ event: StripInputTap.Event) {
        guard isRunning else { return }
        switch event {
        case .notch(let step): perform(step > 0 ? .focusRight : .focusLeft)
        case .scroll(let points, let ended): drag(by: points, ended: ended)
        case .swipe(let fraction):
            guard let state = activeState(pointer: true) else { return }
            drag(by: -fraction * geometry(for: state).viewportWidth * 1.6, ended: false)
        case .swipeEnded: drag(by: 0, ended: true)
        case .pointer(let point): pointerMoved(point)
        }
    }

    /// The strip follows the fingers one to one, then settles (on a column, or where it stops).
    private func drag(by points: Double, ended: Bool) {
        let owner = swipeKey.flatMap { isCurrent($0) ? strips[$0] : nil }
        guard let state = owner ?? activeState(pointer: true) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let geometry = geometry(for: state)
        if !state.swiping, points != 0 {
            swipeKey = state.key
            state.swiping = true
            state.swipe.reset()
            state.offset.snap(to: state.offset.value)
            for id in state.strip.allWindows {
                windows[id]?.spring = nil
                animating.remove(id)
            }
            geometries[state.key] = geometry
        }
        guard state.swiping else { return }
        if points != 0 {
            var next = state.offset.value + points
            // Past either end it stretches, then springs back.
            if next < 0 || next > geometry.maxOffset { next = state.offset.value + points * 0.3 }
            state.offset.snap(to: next)
            state.strip.offset = next
            state.swipe.record(offset: next, at: now)
            for placement in geometry.placements(offset: next) where !placement.isBackgroundTab {
                guard let w = windows[placement.window], !w.held else { continue }
                w.target = placement.frame
                place(w, at: placement.frame, state: state, geometry: geometry)
            }
            followWithOverlays()
            updateIndicatorTiles()
        }
        if ended {
            state.swiping = false
            swipeKey = nil
            let velocity = state.swipe.velocity
            let rest = geometry.settle(offset: state.offset.value, velocity: velocity, snap: swipeSnaps)
            state.offset.velocity = velocity
            state.strip.offset = rest
            state.centred = false
            if geometry.visibleFraction(of: state.strip.focusColumn, offset: rest) < 0.99,
               let best = geometry.mostVisibleColumn(offset: rest), let id = state.strip.columns[best].windows.first {
                state.strip.focus(state.strip.columns[best].tabbed ? state.strip.columns[best].windows[state.strip.columns[best].activeTab] : id)
                quietFocusUntil = now + 0.6
                focusWindow(in: state)
            }
            apply(state, animated: true)
            saveLayoutsSoon()
        }
    }

    private func pointerMoved(_ point: CGPoint) {
        guard focusFollowsMouse, NSEvent.pressedMouseButtons == 0 else { return }
        hoverWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.focusWindow(under: point) }
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func focusWindow(under point: CGPoint) {
        guard isRunning else { return }
        for key in currentKeys.values {
            guard let state = strips[key], state.display.frame.contains(point) else { continue }
            // Only the windows of this strip, front-most first among overlapping ones.
            guard let w = state.strip.allWindows.compactMap({ windows[$0] }).first(where: { !$0.parked && $0.shown.contains(point) }),
                  state.strip.focusedWindow != w.id else { return }
            state.strip.focus(w.id)
            quietFocusUntil = ProcessInfo.processInfo.systemUptime + 0.6
            focusWindow(in: state)
            updateIndicatorTiles()
            return
        }
    }

    private func warpPointer(to state: StripState) {
        guard let id = state.strip.focusedWindow, let w = windows[id], !w.target.contains(NSEvent.mouseLocationInAX) else { return }
        CGWarpMouseCursorPosition(CGPoint(x: w.target.midX, y: w.target.midY))
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    // MARK: Strips and displays

    private func isCurrent(_ key: StripKey) -> Bool { currentKeys[key.display] == key }

    /// The current strip of the display a frame is mostly on.
    private func state(for frame: CGRect) -> StripState? {
        let best = displayList.max { a, b in
            a.frame.intersection(frame).areaOrZero < b.frame.intersection(frame).areaOrZero
        }
        guard let best, best.frame.intersects(frame), let key = currentKeys[best.uuid] else { return nil }
        return strips[key]
    }

    /// The strip of the window you're in, else the one under the pointer.
    private func activeState(pointer preferPointer: Bool = false) -> StripState? {
        // With one display there's one current strip: no need to ask the frontmost app (which
        // can keep the bar waiting while it's busy).
        if preferPointer || displayList.count == 1, let state = pointerState() { return state }
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ownPID,
           let element = StripAX.focusedWindow(of: app.processIdentifier), let id = StripAX.windowID(element) {
            if let w = windows[id], isCurrent(w.key), let state = strips[w.key] { return state }
            if let frame = StripAX.frame(element), let state = state(for: frame) { return state }
        }
        return pointerState()
    }

    private func pointerState() -> StripState? {
        let point = NSEvent.mouseLocationInAX
        guard let display = displayList.first(where: { $0.frame.contains(point) }), let key = currentKeys[display.uuid] else {
            return currentKeys.values.first.flatMap { strips[$0] }
        }
        return strips[key]
    }

    // MARK: Overlays

    /// While ⌃⌥ are held the bar stays until they're let go; a move made without them (a swipe,
    /// a rebound key) shows it for a moment.
    private func showIndicator(_ state: StripState, message: String?, refused: Bool, force: Bool = false, duration: TimeInterval = 1) {
        let timing = PerfLog.begin("strip bar"); defer { timing.end() }
        guard showsIndicator || force else { return }
        indicatorKey = state.key
        let previews = barPreviews && !sizingBar && WindowPictures.canCapture
        let held = indicator.isHeld()
        indicator.show(tiles: tiles(for: state), message: message, refused: refused, display: state.display,
                       previews: previews, lifetime: held ? .whileHeld : .briefly(duration))
        if previews { animating.isEmpty ? refreshBarPictures() : photographSoon() }
    }

    /// Fresh pictures for the strip bar: windows in view now, and ones out of view the strip
    /// hasn't photographed yet. Two at a time, at most every 1.5 s per window.
    private func refreshBarPictures() {
        let timing = PerfLog.begin("strip bar pictures"); defer { timing.end() }
        guard barPreviews, !sizingBar, WindowPictures.canCapture, let key = indicatorKey, let state = strips[key] else { return }
        let now = ProcessInfo.processInfo.systemUptime
        for id in state.strip.allWindows {
            guard let w = windows[id] else { continue }
            if w.parked, WindowPictures.shared.picture(for: id) != nil { continue }
            if animating.contains(id) { continue }  // mid-move: photographed when it settles
            if let taken = pictureTaken[id], now - taken < 1.5 { continue }
            pictureTaken[id] = now
            photograph(id)
        }
    }

    private func photograph(_ id: CGWindowID) {
        pictureQueue.addOperation { [weak self] in
            let picture = WindowPictures.capture(id)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let picture else { return }
                    WindowPictures.shared.store(picture, for: id)
                    self?.updateIndicatorTiles()
                }
            }
        }
    }

    /// Pictures are taken once the strip has been still for a moment: one costs the window
    /// server and the GPU about as much as a frame of a move, so none are taken during one.
    private func photographSoon() {
        photographWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.photographWhenStill() }
        }
        photographWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    private func photographWhenStill() {
        let timing = PerfLog.begin("strip photographs"); defer { timing.end() }
        photographWork = nil
        guard animating.isEmpty else { return photographSoon() }
        let now = ProcessInfo.processInfo.systemUptime
        // Windows back in view since are taken with the bar's pictures, or live by the switcher.
        for id in unphotographed where windows[id]?.parked == true {
            pictureTaken[id] = now
            photograph(id)
        }
        unphotographed.removeAll()
        if indicator.isVisible, indicator.state.previews { refreshBarPictures() }
    }

    private func updateIndicatorTiles() {
        guard indicator.isVisible, let key = indicatorKey, let state = strips[key] else { return }
        indicator.update(tiles: tiles(for: state))
    }

    private func tiles(for state: StripState) -> [StripIndicatorState.Tile] {
        let geometry = geometry(for: state)
        return state.strip.columns.enumerated().map { c, column in
            let members = column.windows.compactMap { windows[$0] }
            // Faded when its windows wait out of view; partly cut off counts as in view.
            let outOfView = !members.isEmpty && members.allSatisfy(\.parked)
            let visible = outOfView ? 0 : (arrangesAlways ? max(geometry.visibleFraction(of: c, offset: state.strip.offset), 0.05) : 1)
            return StripIndicatorState.Tile(id: c, icons: members.compactMap { icon(for: $0.pid) },
                                            pictures: column.windows.map { WindowPictures.shared.picture(for: $0) },
                                            activeTab: column.activeTab,
                                            focused: c == state.strip.focusColumn, visible: visible,
                                            pin: column.pin, tabbed: column.tabbed)
        }
    }

    private func icon(for pid: pid_t) -> NSImage? {
        if let icon = icons[pid] { return icon }
        let icon = NSRunningApplication(processIdentifier: pid)?.icon
        icons[pid] = icon
        return icon
    }

    private func indicatorSelected(_ column: Int) {
        guard let key = indicatorKey, let state = strips[key], state.strip.columns.indices.contains(column) else { return }
        let target = state.strip.columns[column]
        state.strip.focus(target.tabbed ? target.windows[target.activeTab] : target.windows[0])
        reveal(state)
        apply(state, animated: true)
        focusWindow(in: state)
        showIndicator(state, message: nil, refused: false)
    }

    private func indicatorMoved(_ from: Int, _ to: Int) {
        guard let key = indicatorKey, let state = strips[key] else { return }
        state.strip.moveColumn(from: from, to: to)
        reveal(state)
        apply(state, animated: true)
        saveLayoutsSoon()
        showIndicator(state, message: nil, refused: false)
    }

    private func tabSelected(_ window: CGWindowID) {
        guard let w = windows[window], let state = strips[w.key] else { return }
        state.strip.focus(window)
        apply(state, animated: true)
        focusWindow(in: state)
    }

    private func updateTabBars() {
        var bars: [StripTabBars.Bar] = []
        for key in currentKeys.values {
            guard let state = strips[key], let geometry = geometries[key] else { continue }
            for bar in geometry.tabBars(offset: state.strip.offset) {
                let tabs = bar.windows.map { id in
                    StripTabBars.Tab(id: id, title: windows[id].map { StripAX.title($0.element) } ?? "",
                                     icon: windows[id].flatMap { icon(for: $0.pid) })
                }
                bars.append(StripTabBars.Bar(id: "\(key.storageKey)#\(bar.column)", frame: bar.frame, tabs: tabs, active: bar.active))
            }
        }
        tabBars.update(bars)
    }

    /// Tab bars and the focus border keep up with their windows while the strip moves.
    private func followWithOverlays() {
        var frames: [String: CGRect] = [:]
        for key in currentKeys.values {
            guard let state = strips[key], let geometry = geometries[key] else { continue }
            for bar in geometry.tabBars(offset: state.offset.value) {
                var frame = bar.frame
                if let active = windows[bar.windows[bar.active]] { frame.origin.x = (active.spring?.rect.minX ?? active.shown.minX).rounded() }
                frames["\(key.storageKey)#\(bar.column)"] = frame
            }
        }
        if !frames.isEmpty { tabBars.follow(frames) }
        if focusBorder, let id = decorWindow, let w = windows[id], let state = strips[w.key], w.spring != nil, !w.parked {
            decor.update(window: id, frame: w.spring?.roundedRect ?? w.shown, display: state.display, showBorder: true, dimOthers: dimInactive)
        }
    }

    /// The border and dimming follow the window in front.
    private func updateDecor() {
        guard isRunning, focusBorder || dimInactive else {
            decorWindow = nil
            return decor.removeAll()
        }
        guard let app = NSWorkspace.shared.frontmostApplication, let id = WindowServer.frontWindow(of: app.processIdentifier),
              let w = windows[id], let state = strips[w.key], isCurrent(w.key), !w.parked else {
            decorWindow = nil
            return decor.update(window: nil, frame: nil, display: nil, showBorder: false, dimOthers: false)
        }
        decorWindow = id
        decor.update(window: id, frame: w.spring?.roundedRect ?? w.shown, display: state.display, showBorder: focusBorder, dimOthers: dimInactive)
    }

    // MARK: Saving

    private func saveLayoutsSoon() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveLayoutsNow() }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// Column order, widths, stacks, tabs and pins, per display and Space, so they come back
    /// after Tutto restarts.
    private func saveLayoutsNow() {
        saveWork?.cancel()
        for (key, state) in strips where !state.strip.isEmpty {
            savedLayouts[key.storageKey] = state.strip.columns
        }
        if savedLayouts.count > 48 {
            let live = Set(strips.keys.map(\.storageKey))
            savedLayouts = savedLayouts.filter { live.contains($0.key) }
        }
        if let data = try? JSONEncoder().encode(savedLayouts) { defaults.set(data, forKey: Keys.layouts) }
    }

    /// Remembers which windows wait out of view, so a crash can't leave them there.
    private func parkedChanged() {
        guard parkedWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.parkedWork = nil
                let parked = self.windows.values.filter(\.parked).map { [Int($0.pid), Int($0.id)] }
                self.defaults.set(parked, forKey: Keys.parked)
            }
        }
        parkedWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// After a crash (or a force quit) windows can be left waiting out of view; on the next
    /// launch they're put back on screen. Run at launch whether the strip is on or not.
    static func rescueParkedWindows() {
        let defaults = UserDefaults.standard
        guard let parked = defaults.array(forKey: Keys.parked) as? [[Int]], !parked.isEmpty else { return }
        defaults.removeObject(forKey: Keys.parked)
        guard AXIsProcessTrusted() else { return }
        let displays = StripDisplay.all()
        for entry in parked where entry.count == 2 {
            let pid = pid_t(entry[0])
            let id = CGWindowID(entry[1])
            guard NSRunningApplication(processIdentifier: pid) != nil,
                  let element = WindowElements.element(for: id, pid: pid, budget: 0.2),
                  let frame = StripAX.frame(element),
                  let display = displays.first(where: { StripParking.isParked(frame, display: $0.visible) }) else { continue }
            let visible = display.visible
            let size = CGSize(width: min(frame.width, visible.width), height: min(frame.height, visible.height))
            StripAX.setFrame(CGRect(x: (visible.midX - size.width / 2).rounded(), y: (visible.midY - size.height / 2).rounded(),
                                    width: size.width, height: size.height), of: element, size: true)
            log.notice("rescued window \(id) left out of view")
        }
    }

    private func save(_ value: Any, _ key: String) { defaults.set(value, forKey: key) }

    enum Keys {
        static let gap = "strip.gap"
        static let presets = "strip.presets"
        static let defaultWidth = "strip.defaultWidth"
        static let fullHeight = "strip.fullHeight"
        static let centring = "strip.centring"
        static let animation = "strip.animation"
        static let indicator = "strip.indicator"
        static let border = "strip.focusBorder"
        static let dim = "strip.dimInactive"
        static let swipe = "strip.swipeFingers"
        static let swipeSnaps = "strip.swipeSnaps"
        static let scroll = "strip.modifierScroll"
        static let focusFollowsMouse = "strip.focusFollowsMouse"
        static let mouseFollowsFocus = "strip.mouseFollowsFocus"
        static let arrange = "strip.arrange"
        static let barPreviews = "strip.barPreviews"
        static let disabledDisplays = "strip.disabledDisplays"
        static let floatingApps = "strip.floatingApps"
        static let layouts = "strip.layouts"
        static let parked = "strip.parked"
    }
}

private extension CGRect {
    var areaOrZero: CGFloat { isNull ? 0 : width * height }
}

extension NSEvent {
    /// The pointer in Accessibility coordinates (top-left origin, y down).
    static var mouseLocationInAX: CGPoint {
        let location = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: location.x, y: primaryHeight - location.y)
    }
}
