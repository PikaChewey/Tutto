//
//  ClickerModule.swift
//  Tutto
//
//  The auto clicker: clicks at the pointer (or a spot you pick) at the speed you set, until you
//  stop it with its shortcut (⌃⇧A to start with), the switch in the menu bar panel, a screen
//  corner, or its own limit of clicks or time. Started from the panel, it waits two seconds after
//  the panel closes so the first click lands where you put the pointer, not on the panel.
//
//  Nothing runs while it's off but the shortcut. While clicking: its own thread (ClickerEngine)
//  and a pill at the top of the screen with the count and how to stop it.
//

import AppKit
import Observation
import TuttoKit

@MainActor
@Observable
final class ClickerModule: ModuleController {
    enum State: Equatable {
        case idle
        /// Seconds left before the first click.
        case countdown(Int)
        case clicking
    }

    private(set) var state: State = .idle
    private(set) var clicks = 0
    private(set) var clickingSince: Date?
    /// How the last run went, until the next one: "340 clicks in 34 s".
    private(set) var lastRun: String?
    /// Why it couldn't start (Accessibility not allowed).
    private(set) var notice: String?
    private(set) var settings: ClickerSettings
    /// Waiting for a click that sets the spot to click at.
    private(set) var isPicking = false

    @ObservationIgnored private var engine: ClickerEngine?
    /// Clicks made by engines replaced mid-run (a setting changed while clicking), and which run
    /// is current, so a replaced engine's ending is ignored.
    @ObservationIgnored private var carriedClicks = 0
    @ObservationIgnored private var runID = 0
    @ObservationIgnored private var retuneWork: DispatchWorkItem?
    @ObservationIgnored private var countdownTimer: DispatchSourceTimer?
    @ObservationIgnored private var progressTimer: DispatchSourceTimer?
    @ObservationIgnored private var pickMonitor: Any?
    @ObservationIgnored private let hud = ClickerHUD()
    @ObservationIgnored private let defaults = UserDefaults.standard

    var isOn: Bool { state != .idle }

    init() {
        settings = UserDefaults.standard.data(forKey: Keys.settings)
            .flatMap { try? JSONDecoder().decode(ClickerSettings.self, from: $0) } ?? ClickerSettings()
    }

    func start() {}

    func stop() {
        end(nil)
        endPicking()
    }

    func update(_ change: (inout ClickerSettings) -> Void) {
        var changed = settings
        change(&changed)
        changed.normalize()
        guard changed != settings else { return }
        settings = changed
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Keys.settings) }
        if state == .clicking { scheduleRetune() }
    }

    /// A change made while clicking takes effect at once: the engine is swapped for one with the new
    /// settings, carrying on the count and what's left of the limit. Held − or + changes the speed
    /// many times a second, so the swap waits for a quarter-second pause.
    private func scheduleRetune() {
        retuneWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.retune() } }
        retuneWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func retune() {
        retuneWork = nil
        guard state == .clicking, let old = engine else { return }
        old.stop()
        carriedClicks += old.progress.clicks
        engine = nil
        progressTimer?.cancel()
        progressTimer = nil
        run(continuing: true)
    }

    /// Settings from a `tutto://do/clicker?…` link (scripts, agents).
    func apply(_ items: [URLQueryItem]) {
        update { settings in
            for item in items {
                let value = item.value ?? ""
                switch item.name {
                case "cps": if let cps = Double(value) { settings.clicksPerSecond = cps }
                case "button": if let button = ClickButton(rawValue: value) { settings.button = button }
                case "double": settings.double = value == "1" || value == "true"
                case "at":
                    let parts = value.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                    settings.target = parts.count == 2 ? .point(x: parts[0], y: parts[1]) : .pointer
                case "for": if let seconds = Double(value) { settings.stop = seconds > 0 ? .afterSeconds(seconds) : .never }
                case "clicks": if let count = Int(value) { settings.stop = count > 0 ? .afterClicks(count) : .never }
                case "jitter": if let jitter = Double(value) { settings.jitter = jitter }
                case "delay": if let delay = Double(value) { settings.startDelay = delay }
                default: break
                }
            }
        }
    }

    // MARK: On and off

    /// The panel's switch and the shortcut (toggle mode).
    func toggle(fromPanel: Bool = false) {
        isOn ? end("Stopped") : begin(fromPanel: fromPanel)
    }

    /// Hold mode: the shortcut went down.
    func holdBegan() {
        guard settings.holdToClick, state == .idle else { return toggle() }
        begin(fromPanel: false, delay: 0)
    }

    /// Hold mode: the shortcut was let go.
    func holdEnded() {
        guard settings.holdToClick, isOn else { return }
        end("Let go")
    }

    func begin(fromPanel: Bool, delay: Double? = nil) {
        guard state == .idle else { return }
        guard AXIsProcessTrusted() else {
            notice = "Allow Tutto in Privacy & Security › Accessibility so it can click."
            AppModel.shared.permissions.request(.accessibility)
            return
        }
        notice = nil
        lastRun = nil
        // From the panel the pointer is on the panel: give it time to get where it's going.
        let wait = delay ?? (fromPanel ? max(settings.startDelay, 2) : settings.startDelay)
        guard wait > 0 else { return run() }
        var left = Int(wait.rounded(.up))
        state = .countdown(left)
        hud.show(countdown: left, settings: settings)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + wait - Double(left - 1), repeating: 1)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, case .countdown = self.state else { return }
                left -= 1
                if left <= 0 {
                    self.countdownTimer?.cancel()
                    self.countdownTimer = nil
                    self.run()
                } else {
                    self.state = .countdown(left)
                    self.hud.show(countdown: left, settings: self.settings)
                }
            }
        }
        timer.resume()
        countdownTimer = timer
    }

    /// `continuing`: settings changed mid-run; the count and the limit carry on.
    private func run(continuing: Bool = false) {
        if !continuing {
            carriedClicks = 0
            clicks = 0
            clickingSince = Date()
        }
        var current = settings
        let elapsed = clickingSince.map { Date().timeIntervalSince($0) } ?? 0
        guard let left = ClickerRules.remainingStop(settings, clicks: carriedClicks, elapsed: elapsed) else {
            clicks = carriedClicks
            return end("Done")
        }
        current.stop = left
        runID += 1
        let id = runID
        let engine = ClickerEngine(settings: current) { [weak self] ending in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.runID == id else { return }
                    switch ending {
                    case .asked: break
                    case .done: self.end("Done")
                    case .corner: self.end("Stopped at a corner")
                    }
                }
            }
        }
        self.engine = engine
        state = .clicking
        engine.start()
        hud.show(clicks: carriedClicks, settings: settings, shortcut: AppModel.shared.shortcuts.shortcut(for: .toggleClicker))
        // The count, a few times a second, only while clicking.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.2, repeating: 0.2, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let engine = self.engine else { return }
                let count = self.carriedClicks + engine.progress.clicks
                if count != self.clicks { self.clicks = count }
                self.hud.show(clicks: count, settings: self.settings,
                              shortcut: AppModel.shared.shortcuts.shortcut(for: .toggleClicker))
            }
        }
        timer.resume()
        progressTimer = timer
    }

    /// Stops a countdown or a run. `reason` nil: quietly (module off, quit).
    func end(_ reason: String?) {
        guard state != .idle else { return }
        countdownTimer?.cancel()
        countdownTimer = nil
        progressTimer?.cancel()
        progressTimer = nil
        retuneWork?.cancel()
        retuneWork = nil
        if let engine {
            engine.stop()
            clicks = carriedClicks + engine.progress.clicks
        }
        engine = nil
        runID += 1
        let ran = clickingSince.map { Date().timeIntervalSince($0) } ?? 0
        if state == .clicking, let reason {
            lastRun = "\(reason): \(clicks.formatted()) click\(clicks == 1 ? "" : "s") in \(ClickerRules.duration(max(ran, 1)))"
        }
        state = .idle
        clickingSince = nil
        hud.hide()
    }

    // MARK: Picking the spot

    /// The next click anywhere sets the spot (and isn't passed on as a click to the app under it,
    /// since it lands on a clear overlay); Esc cancels.
    func pickPoint() {
        guard !isPicking else { return }
        isPicking = true
        hud.showPicking()
        ClickerPicker.shared.pick { [weak self] point in
            guard let self else { return }
            self.endPicking()
            if let point { self.update { $0.target = .point(x: point.x, y: point.y) } }
        }
    }

    private func endPicking() {
        isPicking = false
        if state == .idle { hud.hide() }
    }

    #if DEBUG
    /// Offscreen renders only: the clicker as the panel shows it mid-run, without clicking.
    func previewClicking(_ clicks: Int, since: TimeInterval = 0) {
        state = .clicking
        self.clicks = clicks
        clickingSince = Date().addingTimeInterval(-since)
    }

    /// Offscreen renders only: settings shown without saving them.
    func previewSettings(_ change: (inout ClickerSettings) -> Void) {
        change(&settings)
    }
    #endif

    private enum Keys {
        static let settings = "clicker.settings"
    }
}
