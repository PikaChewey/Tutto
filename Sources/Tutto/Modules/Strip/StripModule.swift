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
    private(set) var disabledDisplays: [String]
    private(set) var floatingApps: [String]

    // MARK: Status

    private(set) var isTrusted = AXIsProcessTrusted()
    /// False while stopped with ⌃⌥Q (the module stays on, its shortcuts too).
    private(set) var isRunning = false
    private(set) var windowCount = 0
    private(set) var displayList: [StripDisplay] = []
    private(set) var setupChecks: [MacSetupCheck] = []

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
    /// `--strip-only <bundle id>`: manage only that app's windows (live tests with test windows).
    @ObservationIgnored private let onlyBundle: String? = {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--strip-only"), args.count > index + 1 else { return nil }
        return args[index + 1]
    }()
    @ObservationIgnored private var commandStarted: TimeInterval?
    @ObservationIgnored private var frames = 0
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
        disabledDisplays = d.stringArray(forKey: Keys.disabledDisplays) ?? []
        floatingApps = d.stringArray(forKey: Keys.floatingApps) ?? []
        if let data = d.data(forKey: Keys.layouts), let saved = try? JSONDecoder().decode([String: [StripColumn]].self, from: data) {
            savedLayouts = saved
        } else {
            savedLayouts = [:]
        }
        indicator.onSelect = { [weak self] column in self?.indicatorSelected(column) }
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
        rebuild()
        if let state = activeState() { showIndicator(state, message: "Tiled every window", refused: false) }
    }

    func refreshSetupChecks() {
        let reading = Self.readMacSetup()
        let tiling = ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))
        setupChecks = MacSetup.checks(reading, swipeFingers: swipeFingers > 0 ? swipeFingers : nil, hasEdgeTiling: tiling)
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

    /// Finds each display's current Space, builds or refreshes its strip, and lays it out.
    private func rebuild() {
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
            if fresh.contains(where: { $0 === state }) {
                state.strip.offset = geometry(for: state).offset(revealing: state.strip.focusColumn, from: 0, centring: centring)
                state.offset.snap(to: state.strip.offset)
            }
            apply(state, animated: false)
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
            let arrivals = found[state.key] ?? []
            guard !arrivals.isEmpty else { continue }
            var strip = state.strip
            if restoring.contains(state.key), let saved = savedLayouts[state.key.storageKey] {
                let live = Set(arrivals.map(\.0.id))
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
            for (w, _) in arrivals.sorted(by: { $0.0.shown.minX != $1.0.shown.minX ? $0.0.shown.minX < $1.0.shown.minX : $0.1 < $1.1 })
            where !strip.contains(w.id) {
                strip.insert(w.id, width: initialWidth(w.shown, metrics: metrics), besideFocused: false, focus: false)
            }
            if let front = arrivals.min(by: { $0.1 < $1.1 })?.0, restoring.contains(state.key) { strip.focus(front.id) }
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
        if let onlyBundle, bundleID != onlyBundle { return nil }
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
            if let id = StripAX.windowID(element), windows[id] != nil || floating.contains(id) { continue }
            adopt(element, pid: pid)
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
            apply(state, animated: true)
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
        guard isRunning else { return }
        switch event {
        case .created(let element):
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                MainActor.assumeIsolated { self?.adopt(element, pid: pid) }
            }
        case .focusChanged:
            syncFocus()
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
            guard let id = StripAX.windowID(element) else { return }
            windowChanged(id, element: element, pid: pid)
        case .minimized(let element):
            guard let id = observers[pid]?.window(for: element), let w = windows[id], let state = strips[w.key] else { return }
            sendAway(w, from: state, reason: .minimized)
        case .deminimized(let element):
            guard let id = StripAX.windowID(element) else { return }
            // After the window has finished growing back out of the Dock.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                MainActor.assumeIsolated { self?.comeBack(id, element: element, pid: pid, focus: true) }
            }
        case .titleChanged(let element):
            guard let id = StripAX.windowID(element), let w = windows[id], let state = strips[w.key],
                  state.strip.location(of: id).map({ state.strip.columns[$0.column].tabbed }) == true else { return }
            updateTabBars()
        }
    }

    /// A window the strip hasn't met: tile it beside the focused window (or at the end, quietly,
    /// when its app is in the background).
    private func adopt(_ element: AXUIElement, pid: pid_t, focus: Bool? = nil) {
        guard isRunning, let id = StripAX.windowID(element), windows[id] == nil, !floating.contains(id), !userFloated.contains(id) else { return }
        if takeOverNativeTab(id, element: element, pid: pid) { return }
        guard let frame = StripAX.frame(element), let state = state(for: frame) else { return }
        let app = NSRunningApplication(processIdentifier: pid)
        guard let w = admit(element, pid: pid, bundleID: app?.bundleIdentifier, into: state) else { return }
        let front = focus ?? (NSWorkspace.shared.frontmostApplication?.processIdentifier == pid)
        state.strip.insert(w.id, width: defaultWidth, besideFocused: front, focus: front)
        if front { reveal(state) }
        apply(state, animated: true)
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
        apply(state, animated: true)
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
        if StripAX.isFullScreen(element) { return sendAway(w, from: state, reason: .fullScreen) }
        let now = ProcessInfo.processInfo.systemUptime
        if animating.contains(id) || now - w.lastMove < 0.5 || w.held || state.swiping { return }
        guard let frame = StripAX.frame(element), !Self.sameFrame(frame, w.shown) else { return }
        if NSEvent.pressedMouseButtons & 1 != 0 {
            w.held = true
            watchMouseUp()
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
        apply(state, animated: true)
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
        apply(state, animated: true)
        windowCount = windows.count
    }

    // MARK: Focus

    /// The strip follows focus: a window you click or ⌘Tab to scrolls into view.
    private func syncFocus() {
        guard isRunning, let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ownPID,
              let element = StripAX.focusedWindow(of: app.processIdentifier), let id = StripAX.windowID(element) else {
            return updateDecor()
        }
        guard let w = windows[id] else {
            if !floating.contains(id), !userFloated.contains(id), away[id] == nil {
                adopt(element, pid: app.processIdentifier, focus: true)
            }
            return updateDecor()
        }
        guard let state = strips[w.key], isCurrent(w.key), !w.held else { return updateDecor() }
        guard state.strip.focusedWindow != id else { return updateDecor() }
        state.strip.focus(id)
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
        let element = w.element
        let pid = w.pid
        nonisolated(unsafe) let unsafeElement = element
        mover.run(pid: pid) { _ = WindowFocus.focus(window: id, pid: pid, element: unsafeElement) }
    }

    // MARK: Commands

    func perform(_ command: StripCommand) {
        if command == .toggleRunning { return toggleRunning() }
        guard isRunning else {
            Toast.shared.show("The strip is stopped", detail: isTrusted ? "⌃⌥Q starts it again." : "Allow Accessibility for Tutto first.")
            return
        }
        // A full-screen app's Space (or a display the strip is off for) has no strip: the key
        // quietly does nothing there.
        guard let state = activeState() else {
            log.notice("\(command.id, privacy: .public): no strip here")
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
        guard let app = NSWorkspace.shared.frontmostApplication, let element = StripAX.focusedWindow(of: app.processIdentifier),
              let id = StripAX.windowID(element) else { return NSSound.beep() }
        if let w = windows[id], let owner = strips[w.key] {
            owner.strip.remove(id)
            let visible = owner.display.visible
            let size = CGSize(width: min(w.target.width, visible.width * 0.7).rounded(), height: min(w.target.height, visible.height * 0.8).rounded())
            let frame = CGRect(x: (visible.midX - size.width / 2).rounded(), y: (visible.midY - size.height / 2).rounded(),
                               width: size.width, height: size.height)
            mover.move(id, pid: w.pid, element: w.element, to: frame, setSize: true)
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
            // A window that gets taller goes to its new top at once: macOS clamps a new height to
            // the room below a window's current top.
            if abs(spring.height.value - placement.frame.height) > 0.5 { spring.y.snap(to: placement.frame.minY) }
            spring.width.snap(to: placement.frame.width)
            spring.height.snap(to: placement.frame.height)
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
        for id in Array(animating) {
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
            place(w, at: done ? w.target : spring.roundedRect, state: state, geometry: geometry)
        }
        #if DEBUG
        if dt > 0 { frames += 1 }
        #endif
        followWithOverlays()
        if !moving, dt > 0 || animating.isEmpty {
            link.stop()
            didSettle(settled)
        }
    }

    private func place(_ w: StripManagedWindow, at rect: CGRect, state: StripState, geometry: StripGeometry) {
        let inView = geometry.isInView(rect, column: w.column) && !overhangsAnotherDisplay(rect, state.display)
        if inView {
            guard w.parked || rect != w.shown else { return }
            let resize = w.parked || abs(rect.width - w.shown.width) > 0.5 || abs(rect.height - w.shown.height) > 0.5
            send(w, rect, resize: resize)
            if w.parked {
                w.parked = false
                parkedChanged()
            }
        } else if !w.parked {
            park(w, in: state, side: rect.midX < state.display.visible.midX ? .left : .right)
        }
    }

    private func park(_ w: StripManagedWindow, in state: StripState, side: StripSide) {
        guard !w.parked else { return }
        let others = displayList.filter { $0.uuid != state.display.uuid }.map(\.frame)
        let frame = StripParking.frame(size: w.target.size, side: side, display: state.display.visible, others: others)
        send(w, frame, resize: abs(frame.width - w.shown.width) > 0.5 || abs(frame.height - w.shown.height) > 0.5)
        w.parked = true
        parkedChanged()
    }

    private func send(_ w: StripManagedWindow, _ frame: CGRect, resize: Bool) {
        mover.move(w.id, pid: w.pid, element: w.element, to: frame, setSize: resize)
        w.shown = frame
        w.lastMove = ProcessInfo.processInfo.systemUptime
        if resize { w.resized = true }
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
        #if DEBUG
        if frames > 0 { log.notice("settled after \(self.frames) frames") }
        frames = 0
        #endif
        updateDecor()
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
        if preferPointer, let state = pointerState() { return state }
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

    private func showIndicator(_ state: StripState, message: String?, refused: Bool, force: Bool = false, duration: TimeInterval = 1.1) {
        guard showsIndicator || force else { return }
        indicatorKey = state.key
        indicator.show(tiles: tiles(for: state), message: message, refused: refused, display: state.display, duration: duration)
    }

    private func updateIndicatorTiles() {
        guard indicator.isVisible, let key = indicatorKey, let state = strips[key] else { return }
        indicator.update(tiles: tiles(for: state))
    }

    private func tiles(for state: StripState) -> [StripIndicatorState.Tile] {
        let geometry = geometry(for: state)
        return state.strip.columns.enumerated().map { c, column in
            StripIndicatorState.Tile(id: c, icons: column.windows.compactMap { windows[$0].flatMap { icon(for: $0.pid) } },
                                     focused: c == state.strip.focusColumn,
                                     visible: geometry.visibleFraction(of: c, offset: state.strip.offset),
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
