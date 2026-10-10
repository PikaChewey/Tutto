//
//  CornerClickModule.swift
//  Tutto
//
//  CornerClick, folded into Tutto: click or tap a bottom corner of the trackpad to
//  right-click while two-finger secondary click keeps working. The engine is the
//  original one (TuttoKit/CornerClick); this is its settings and live state.
//

import AppKit
import CBridges
import Observation
import TuttoKit

@MainActor
@Observable
final class CornerClickModule: ModuleController {
    // MARK: Settings (persisted)

    /// Paused from the menu bar = false. Independent of the module switch in General.
    var isEnabled: Bool { didSet { save(); applyEnabled() } }
    var clickEnabled: Bool { didSet { save(); pushRules() } }
    var tapEnabled: Bool { didSet { save(); pushRules() } }
    var zone: CornerZone { didSet { save(); pushRules() } }
    /// The user chose their own width and height instead of S, M or L.
    var zoneIsCustom: Bool { didSet { defaults.set(zoneIsCustom, forKey: Keys.custom) } }
    var diagnostics: Bool {
        didSet {
            defaults.set(diagnostics, forKey: Keys.diagnostics)
            applyDiagnostics()
        }
    }

    // MARK: Live state

    private(set) var status: EngineStatus = .off
    private(set) var contacts: [Contact] = []
    private(set) var trackpadSize: TrackpadSize = .macBookPro14
    /// Bumps every time a corner click/tap becomes a right-click (drives the zone flash).
    private(set) var pulse = 0
    private(set) var lastTrigger: Trigger?

    let engine = Engine()
    private let defaults = UserDefaults.standard
    private var watchers = 0
    private var observers: [NSObjectProtocol] = []

    var isTrusted: Bool { engine.isTrusted }

    init() {
        Self.migrateFromCornerClickApp()
        defaults.register(defaults: [Keys.enabled: true, Keys.click: true, Keys.tap: true])
        isEnabled = defaults.bool(forKey: Keys.enabled)
        clickEnabled = defaults.bool(forKey: Keys.click)
        tapEnabled = defaults.bool(forKey: Keys.tap)
        if let data = defaults.data(forKey: Keys.zone),
           let saved = try? JSONDecoder().decode(CornerZone.self, from: data) {
            zone = saved.clamped
        } else {
            zone = .standard
        }
        zoneIsCustom = defaults.bool(forKey: Keys.custom)
        diagnostics = defaults.bool(forKey: Keys.diagnostics)

        engine.onStatusChange = { [weak self] status in
            guard let self else { return }
            self.status = status
            if case .running = status, let size = Self.primaryTrackpadSize() {
                self.trackpadSize = size
            }
        }
        engine.onRightClick = { [weak self] trigger in
            self?.lastTrigger = trigger
            self?.pulse &+= 1
        }
        engine.onFrame = { [weak self] frame in self?.contacts = frame.contacts }
    }

    // MARK: ModuleController

    func start() {
        observePermissionChanges()
        applyDiagnostics()
        pushRules()
        applyEnabled()
    }

    func stop() {
        engine.stop()
        status = .off
        contacts = []
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        observers.removeAll()
    }

    // MARK: Actions

    /// Views showing the live trackpad call this on appear/disappear.
    /// Finger positions are only streamed while at least one is visible.
    func beginWatching() {
        watchers += 1
        pushRules()
        engine.setObserving(true)
        engine.refresh()
    }

    func endWatching() {
        watchers = max(0, watchers - 1)
        if watchers == 0 {
            engine.setObserving(false)
            contacts = []
        }
    }

    func resetZone() {
        zone = CornerZone(corner: zone.corner, width: CornerZone.standard.width, height: CornerZone.standard.height)
    }

    // MARK: Private

    private func pushRules() {
        let window = SystemTrackpad.tapToDragEnabled()
            ? ClickDecider.dragDelayedTapClickWindow
            : ClickDecider.standardTapClickWindow
        engine.setRules(RuleSet(zone: zone, clickEnabled: clickEnabled, tapEnabled: tapEnabled, tapClickWindow: window))
    }

    private func applyEnabled() {
        if isEnabled { engine.start() } else { engine.stop() }
        status = engine.status
    }

    private func applyDiagnostics() {
        engine.setDiagnostics(diagnostics)
        engine.onDiagnostic = diagnostics ? { line in CornerClickDiagnostics.write(line) } : nil
    }

    private func save() {
        defaults.set(isEnabled, forKey: Keys.enabled)
        defaults.set(clickEnabled, forKey: Keys.click)
        defaults.set(tapEnabled, forKey: Keys.tap)
        if let data = try? JSONEncoder().encode(zone) {
            defaults.set(data, forKey: Keys.zone)
        }
    }

    /// macOS broadcasts this whenever the Accessibility list changes. No polling needed.
    private func observePermissionChanges() {
        guard observers.isEmpty else { return }
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            // The trust database settles a moment after the notification.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                MainActor.assumeIsolated { self?.engine.refresh() }
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pushRules()  // picks up trackpad setting changes made in System Settings
                self?.engine.refresh()
            }
        })
    }

    private static func primaryTrackpadSize() -> TrackpadSize? {
        var info = CCDeviceInfo()
        guard CCMultitouchDeviceInfo(0, &info), info.surfaceWidth > 1000, info.surfaceHeight > 1000 else { return nil }
        return TrackpadSize(width: Double(info.surfaceWidth) / 100, height: Double(info.surfaceHeight) / 100)
    }

    /// First run: carry over the corner, size and triggers chosen in the standalone CornerClick app.
    private static func migrateFromCornerClickApp() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Keys.migrated) else { return }
        defaults.set(true, forKey: Keys.migrated)
        guard let old = UserDefaults(suiteName: "ca.bryanyao.CornerClick"), old.object(forKey: "zone.v4") != nil else { return }
        if let zone = old.data(forKey: "zone.v4") { defaults.set(zone, forKey: Keys.zone) }
        for (from, to) in [("clickEnabled", Keys.click), ("tapEnabled", Keys.tap), ("zoneIsCustom", Keys.custom)]
        where old.object(forKey: from) != nil {
            defaults.set(old.bool(forKey: from), forKey: to)
        }
    }

    #if DEBUG
    /// Fake live state for offscreen renders (`--snapshot`). Never used in release builds.
    func applyPreview(contacts: [Contact], running: Bool = true) {
        self.contacts = contacts
        status = running ? .running(trackpads: 1) : .needsPermission
    }
    #endif

    private enum Keys {
        static let enabled = "cornerclick.enabled"
        static let click = "cornerclick.clickEnabled"
        static let tap = "cornerclick.tapEnabled"
        static let zone = "cornerclick.zone.v4"
        static let custom = "cornerclick.zoneIsCustom"
        static let diagnostics = "cornerclick.diagnostics"
        static let migrated = "cornerclick.migrated"
    }
}

// MARK: - Status text

extension EngineStatus {
    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

extension CornerClickModule {
    var statusText: String {
        switch status {
        case .off: return "Paused"
        case .needsPermission: return "Needs access"
        case .running(let count): return count > 1 ? "\(count) trackpads" : "On"
        case .noTrackpad: return "No trackpad"
        case .multitouchUnavailable: return "Unavailable"
        case .eventTapFailed: return "Couldn't start"
        }
    }

    var problem: CornerClickProblem? {
        switch status {
        case .eventTapFailed: .couldNotStart
        case .noTrackpad: .noTrackpad
        case .multitouchUnavailable: .unavailable
        default: nil
        }
    }

    var cornerName: String { zone.corner == .bottomRight ? "bottom-right" : "bottom-left" }
}

enum CornerClickProblem: Equatable {
    case couldNotStart
    case noTrackpad
    case unavailable

    var message: String {
        switch self {
        case .couldNotStart: "CornerClick couldn't start."
        case .noTrackpad: "No trackpad found. Connect one and it'll start on its own."
        case .unavailable: "This macOS version blocks reading the trackpad."
        }
    }
}

// MARK: - Diagnostics

/// Troubleshooting only, off by default. Appends one line per trackpad click to
/// ~/Library/Logs/CornerClick/clicks.log (trackpad positions and decisions, nothing else).
@MainActor
enum CornerClickDiagnostics {
    private static var handle: FileHandle?
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/CornerClick/clicks.log")
    }

    static func write(_ line: String) {
        if handle == nil {
            let url = fileURL
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
        }
        try? handle?.write(contentsOf: Data("\(formatter.string(from: Date())) \(line)\n".utf8))
    }
}
