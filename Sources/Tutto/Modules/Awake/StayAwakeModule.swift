//
//  StayAwakeModule.swift
//  Tutto
//
//  Stay Awake: keep the Mac running for a time you type, lid closed included, so agents keep
//  working, and go easy on the battery while the lid is shut.
//
//  Sleep itself is held by TuttoHelper (`pmset disablesleep`), which also keeps the session's end:
//  a hung or crashed Tutto can't keep the Mac awake past it. Everything else is done here and undone
//  when the lid opens or the session ends: the display (put to sleep; dimmed to 0 only when an app
//  holds it awake, then put back to the level sampled while the lid was open), sound, paused apps. Low Power
//  Mode goes through the helper. Without the helper, a power assertion keeps the Mac awake while
//  the lid is open, and the card says closing it will still sleep the Mac.
//
//  Nothing runs without a session. During one: the end timer, a once-a-minute tick for the menu
//  bar's time left (stopped while the lid is closed), and the lid, power and heat notifications.
//

import AppKit
import IOKit
import IOKit.pwr_mgt
import Observation
import ServiceManagement
import TuttoKit

@MainActor
@Observable
final class StayAwakeModule: ModuleController {
    struct Session: Codable, Equatable {
        var startedAt: Date
        var endsAt: Date
        /// Started by "While agents work": it moves its end along while they work.
        var agents: Bool? = nil
    }

    /// What the lid closing changed, to undo when it opens (kept on disk, so a relaunch can too).
    struct LidRecord: Codable, Equatable {
        /// The display was put to sleep.
        var darkened = false
        /// Set when the display wouldn't sleep and was dimmed instead: the levels to put back.
        var brightness: Float? = nil
        var keyboard: Float? = nil
        var mute: OutputMute.Saved?
        var paused: [PausedProcess] = []
        var pausedNames: [String] = []
        var muted: Bool { mute != nil }
    }

    private(set) var session: Session?
    /// The helper holds sleep, so the lid can close. False: only an assertion, lid open only.
    private(set) var lidSafe = false
    private(set) var lidClosed = false
    private(set) var lidRecord: LidRecord?
    /// What the last closed lid did, shown once it's open again.
    private(set) var lastClosed: LidRecord?
    /// Why Low Power Mode is on (nil: it's as you had it).
    private(set) var lowPowerReason: String?
    /// Something to tell: the helper isn't set up, a call failed.
    private(set) var notice: String?
    /// How the last session ended, until the next one starts.
    private(set) var lastEnded: String?
    private(set) var hotspotStatus: String?
    /// Time left beside the menu bar icon, in whole minutes.
    private(set) var menuBarText: String?
    private(set) var helperStatus: SMAppService.Status = .notRegistered

    private(set) var policy: AwakePolicy

    /// Changes a setting (the floors are kept in order).
    func update(_ change: (inout AwakePolicy) -> Void) {
        var changed = policy
        change(&changed)
        changed.normalize()
        guard changed != policy else { return }
        policy = changed
        save(policy, Keys.policy)
        agentGate.grace = TimeInterval(policy.agentQuietMinutes * 60)
        if policy.whileAgentsWork { agentWatcher.start() } else { agentWatcher.stop() }
        updateMenuBarText()
        evaluate()
    }
    /// Per app (bundle id): pause it while the lid is closed, or never. Absent: its category decides.
    var pauseChoices: [String: Bool] { didSet { save(pauseChoices, Keys.pauseChoices) } }
    var hotspotEnabled: Bool {
        didSet {
            defaults.set(hotspotEnabled, forKey: Keys.hotspotEnabled)
            if hotspotEnabled { locationAccess().request() }
            restartHotspot()
        }
    }
    var hotspotSSID: String {
        didSet {
            defaults.set(hotspotSSID, forKey: Keys.hotspotSSID)
            restartHotspot()
        }
    }

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var connection: NSXPCConnection?
    @ObservationIgnored private var assertion: IOPMAssertionID = 0
    @ObservationIgnored private var endTimer: DispatchSourceTimer?
    @ObservationIgnored private var minuteTimer: DispatchSourceTimer?
    @ObservationIgnored private let lid = LidObserver()
    @ObservationIgnored private var power: PowerSourceObserver?
    @ObservationIgnored private var thermal: NSObjectProtocol?
    @ObservationIgnored private var hotspot: HotspotWatcher?
    @ObservationIgnored private var location: LocationAccess?
    /// Asks the display to sleep again while the lid stays closed (macOS defers a request made
    /// soon after a wake).
    @ObservationIgnored private var darkTimer: DispatchSourceTimer?
    /// Brightness sampled while the lid was open and you were at the Mac (by the time the lid is
    /// shut, auto-brightness has dimmed the panel under it), for the fallback.
    @ObservationIgnored private var sampledBrightness: Float?
    @ObservationIgnored private var sampledKeyboard: Float?
    @ObservationIgnored private var lowPowerOn = false
    @ObservationIgnored private let agentWatcher = AgentWatcher()
    /// Plugins with Stay Awake triggers hear about sessions starting and ending.
    @ObservationIgnored var onPluginEvent: ((PluginEvent, String?) -> Void)?
    @ObservationIgnored private var agentGate = AgentGate(grace: 600)
    @ObservationIgnored private var toolsTimer: DispatchSourceTimer?
    @ObservationIgnored private var reconnects = 0
    @ObservationIgnored private var watchingDisplays = false
    @ObservationIgnored private var displayWork: DispatchWorkItem?
    @ObservationIgnored private var quitting = false

    init() {
        let defaults = UserDefaults.standard
        var policy = Self.load(AwakePolicy.self, Keys.policy) ?? AwakePolicy()
        policy.normalize()
        self.policy = policy
        pauseChoices = Self.load([String: Bool].self, Keys.pauseChoices) ?? [:]
        hotspotEnabled = defaults.bool(forKey: Keys.hotspotEnabled)
        hotspotSSID = defaults.string(forKey: Keys.hotspotSSID) ?? ""
        lid.onChange = { [weak self] closed in self?.lidChanged(closed) }
        agentGate.grace = TimeInterval(policy.agentQuietMinutes * 60)
        agentWatcher.onActivity = { [weak self] in self?.noteAgentWork() }
    }

    // MARK: ModuleController

    func start() {
        refreshHelperStatus()
        // A lid record left by a Tutto that stopped mid-session: put it back once the lid is open.
        if let record = Self.load(LidRecord.self, Keys.lidRecord) {
            lidRecord = record
            if LidObserver.read() == true { lid.start() } else { restoreLid() }
        }
        adoptSession()
        if policy.whileAgentsWork { agentWatcher.start() }
        if session?.agents == true { armToolsCheck() }
    }

    func stop() {
        agentWatcher.stop()
        toolsTimer?.cancel()
        toolsTimer = nil
        quitting = true
        if session != nil { end("Tutto quit", waitForHelper: true) }
        if lidRecord != nil && !lidClosed { restoreLid() }
        lid.stop()
        closeConnection()
    }

    // MARK: Starting and ending

    var isRunning: Bool { session != nil }

    /// Starts a session this long, or adds this much to the one running.
    func start(for seconds: TimeInterval) {
        guard seconds >= 60 else { return }
        if let session {
            // Time added by hand: an agents' session becomes an ordinary one.
            return setEnd((session.agents == true ? Date() : session.endsAt).addingTimeInterval(seconds))
        }
        let now = Date()
        let ends = now.addingTimeInterval(min(seconds, AwakeLimits.longest))
        session = Session(startedAt: now, endsAt: ends)
        save(session, Keys.session)
        lastEnded = nil
        lastClosed = nil
        notice = nil
        reconnects = 0
        if assertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn), "Tutto Stay Awake" as CFString, &assertion)
        }
        awakeLog.notice("session started for \(Int(seconds / 60)) min")
        onPluginEvent?(.awakeStarted, String(Int(seconds / 60)))
        sampleBrightness()
        beginWatching()
        holdSleep(until: ends)
    }

    /// Moves the end of the session running (adding time, typed or from a chip).
    func setEnd(_ date: Date, byHand: Bool = true) {
        guard var session else { return }
        if byHand { session.agents = nil }
        session.endsAt = min(date, Date().addingTimeInterval(AwakeLimits.longest))
        self.session = session
        save(session, Keys.session)
        armEndTimer()
        updateMenuBarText()
        holdSleep(until: session.endsAt)
    }

    func endNow() {
        if session?.agents == true { agentGate.endedByHand() }
        end("Ended")
    }

    var isAgentSession: Bool { session?.agents == true }

    // MARK: While agents work

    /// A sign of agent work: a session-log write, a busy build, or `tutto://do/agent-busy`.
    func noteAgentWork() {
        guard policy.whileAgentsWork else { return }
        switch agentGate.activity(at: Date(), session: session != nil, ours: session?.agents == true) {
        case .nothing:
            break
        case .start:
            start(for: agentGate.grace)
            guard var session else { return }
            session.agents = true
            self.session = session
            save(session, Keys.session)
            updateMenuBarText()
            armToolsCheck()
            awakeLog.notice("agents working: staying awake")
        case .extend:
            // Moved in steps of a minute or more, not at every write.
            guard let session, agentGate.end(after: Date()).timeIntervalSince(session.endsAt) >= 60 else { return }
            setEnd(agentGate.end(after: Date()), byHand: false)
        }
    }

    /// Once a minute during an agents' session: commands they started keeping the processor busy
    /// count as work too.
    private func armToolsCheck() {
        toolsTimer?.cancel()
        _ = agentWatcher.toolsBusy()  // the starting reading
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.session?.agents == true else {
                    self?.toolsTimer?.cancel()
                    self?.toolsTimer = nil
                    return
                }
                if self.agentWatcher.toolsBusy() { self.noteAgentWork() }
            }
        }
        timer.resume()
        toolsTimer = timer
    }

    /// Ends the session. Paused apps resume at once; the display and sound wait
    /// for the lid to open if it's closed. A Mac whose lid is closed with no other display goes
    /// to sleep (unless that's switched off).
    private func end(_ reason: String, waitForHelper: Bool = false) {
        guard session != nil else { return }
        if lid.isSimulating {
            lid.endSimulation()
            lidClosed = lid.isClosed
        }
        let closedAlone = lidClosed && !Displays.externalIsActive()
        session = nil
        onPluginEvent?(.awakeEnded, reason)
        defaults.removeObject(forKey: Keys.session)
        endTimer?.cancel()
        endTimer = nil
        stopMinuteTick()
        menuBarText = nil
        power = nil
        watchDisplays(false)
        if let thermal { NotificationCenter.default.removeObserver(thermal) }
        thermal = nil
        hotspot?.stop()
        hotspot = nil
        hotspotStatus = nil
        lowPowerOn = false
        lowPowerReason = nil
        if var record = lidRecord, !record.paused.isEmpty {
            AppPauser.resume(record.paused)
            record.paused = []
            lidRecord = record
            save(record, Keys.lidRecord)
        }
        if lidClosed {
            lid.start()  // stays on to put the display and sound back when the lid opens
        } else {
            restoreLid()
            lid.stop()
        }
        if assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
        let sleep = policy.sleepWhenDoneClosed && closedAlone
        // Also when the helper hasn't answered yet: it ends only a session it holds.
        if lidSafe || helperStatus == .enabled {
            if waitForHelper {
                // Quitting: wait for the helper's answer, but never more than 3 s.
                let done = DispatchSemaphore(value: 0)
                helperProxy { _ in }?.endAwake(sleepIfLidClosed: sleep) { _, _ in done.signal() }
                _ = done.wait(timeout: .now() + 3)
            } else {
                helperProxy { _ in }?.endAwake(sleepIfLidClosed: sleep) { [weak self] _, message in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            if let message { self?.notice = message }
                            if self?.session == nil { self?.closeConnection() }
                        }
                    }
                }
            }
        }
        lidSafe = false
        lastEnded = "\(reason) at \(Date().formatted(date: .omitted, time: .shortened))"
        awakeLog.notice("session ended: \(reason, privacy: .public)")
        if !quitting && !lidClosed && reason != "Ended" {
            Toast.shared.show("Stay Awake ended", detail: reason)
        }
    }

    /// A session left running by a Tutto that quit or stopped, or one the helper still holds.
    private func adoptSession() {
        let saved = Self.load(Session.self, Keys.session)
        if let saved, saved.endsAt > Date().addingTimeInterval(30) {
            session = saved
            if assertion == 0 {
                IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                            IOPMAssertionLevel(kIOPMAssertionLevelOn), "Tutto Stay Awake" as CFString, &assertion)
            }
            beginWatching()
            holdSleep(until: saved.endsAt)
            return
        }
        defaults.removeObject(forKey: Keys.session)
        // Sleep still disabled from a session that's over (the helper ends it once it's asked
        // or its time is up, but the helper only runs when Tutto asks): ask now.
        if Self.sleepDisabledNow() && helperStatus == .enabled {
            helperProxy { _ in }?.awakeState { [weak self] deadline, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        // A session started meanwhile owns the helper now.
                        guard let self, self.session == nil else { return }
                        if deadline > Date().timeIntervalSince1970 + 30 {
                            self.session = Session(startedAt: Date(), endsAt: Date(timeIntervalSince1970: deadline))
                            self.save(self.session, Keys.session)
                            self.lidSafe = true
                            self.beginWatching()
                            self.resendState()
                        } else if deadline > 0 {
                            self.helperProxy { _ in }?.endAwake(sleepIfLidClosed: false) { _, _ in }
                        } else {
                            self.closeConnection()
                        }
                    }
                }
            }
        }
    }

    // MARK: The helper

    func refreshHelperStatus() {
        helperStatus = SMAppService.daemon(plistName: TuttoFanHelper.plistName).status
    }

    func setUpHelper() {
        AppModel.shared.permissions.request(.fanHelper)
        refreshHelperStatus()
    }

    private func holdSleep(until end: Date) {
        // `evaluate` can end a session as it starts (battery already below the floor).
        guard session != nil else { return }
        refreshHelperStatus()
        guard helperStatus == .enabled else {
            lidSafe = false
            notice = helperStatus == .requiresApproval
                ? "Approve Tutto's helper to keep the Mac on with the lid closed. Until then, closing it sleeps the Mac."
                : "Closing the lid sleeps the Mac until Tutto's helper is set up (one approval)."
            return
        }
        helperProxy { [weak self] error in
            self?.lidSafe = false
            self?.notice = "Couldn't reach Tutto's helper (\(error.localizedDescription)). Closing the lid sleeps the Mac."
        }?.beginAwake(until: end.timeIntervalSince1970) { [weak self] status, message in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.session != nil else { return }
                    if status == 0 {
                        let wasSafe = self.lidSafe
                        self.lidSafe = true
                        self.reconnects = 0
                        self.notice = nil
                        if !wasSafe { self.resendState() }
                    } else {
                        self.lidSafe = false
                        self.notice = (message ?? "The helper refused.") + " Closing the lid sleeps the Mac."
                    }
                }
            }
        }
    }

    /// After (re)connecting: Low Power Mode and paused apps, as they are now.
    private func resendState() {
        evaluate(force: true)
        if let record = lidRecord, !record.paused.isEmpty { sendPaused(record.paused) }
    }

    private func sendPaused(_ list: [PausedProcess]) {
        guard lidSafe, let data = try? JSONEncoder().encode(list) else { return }
        helperProxy { _ in }?.setAwakePaused(data) { _ in }
    }

    private func helperProxy(_ onError: @escaping @MainActor (Error) -> Void) -> TuttoFanHelperProtocol? {
        if connection == nil {
            let connection = NSXPCConnection(machServiceName: TuttoFanHelper.machServiceName, options: .privileged)
            connection.remoteObjectInterface = TuttoFanHelper.makeInterface()
            connection.setCodeSigningRequirement(TuttoFanHelper.helperRequirement)
            connection.invalidationHandler = { [weak self] in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.connectionEnded() } }
            }
            connection.interruptionHandler = { [weak self] in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.connectionEnded() } }
            }
            connection.resume()
            self.connection = connection
        }
        let handler: (Error) -> Void = { error in
            awakeLog.error("helper: \(error.localizedDescription, privacy: .public)")
            DispatchQueue.main.async { MainActor.assumeIsolated { onError(error) } }
        }
        return connection?.remoteObjectProxyWithErrorHandler(handler) as? TuttoFanHelperProtocol
    }

    private func closeConnection() {
        connection?.invalidationHandler = nil
        connection?.interruptionHandler = nil
        connection?.invalidate()
        connection = nil
    }

    /// The helper went away (updated, crashed). It keeps its journal, so asking again picks the
    /// session back up.
    private func connectionEnded() {
        connection = nil
        guard session != nil, !quitting else { return }
        lidSafe = false
        reconnects += 1
        guard reconnects <= 5 else {
            notice = "Lost touch with Tutto's helper, so closing the lid would sleep the Mac. End and start again to retry."
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + pow(2, Double(reconnects - 1))) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let session = self.session, self.connection == nil else { return }
                self.holdSleep(until: session.endsAt)
            }
        }
    }

    // MARK: Displays

    /// A display plugged in or out while the lid is closed: docking puts everything back (a desk
    /// set-up), undocking applies the closed-lid actions.
    private func watchDisplays(_ on: Bool) {
        let me = Unmanaged.passUnretained(self).toOpaque()
        if on, !watchingDisplays {
            watchingDisplays = CGDisplayRegisterReconfigurationCallback(Self.displayCallback, me) == .success
        } else if !on, watchingDisplays {
            CGDisplayRemoveReconfigurationCallback(Self.displayCallback, me)
            watchingDisplays = false
        }
    }

    private static let displayCallback: CGDisplayReconfigurationCallBack = { _, flags, me in
        guard !flags.contains(.beginConfigurationFlag), let me else { return }
        let module = Unmanaged<StayAwakeModule>.fromOpaque(me).takeUnretainedValue()
        DispatchQueue.main.async { MainActor.assumeIsolated { module.displaysChangedSoon() } }
    }

    private func displaysChangedSoon() {
        displayWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.displaysChanged() } }
        displayWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func displaysChanged() {
        guard session != nil, lidClosed else { return }
        if Displays.externalIsActive() {
            if lidRecord != nil { restoreLid() }
        } else if lidRecord == nil {
            applyClosed()
        }
        evaluate()
    }

    // MARK: While a session runs

    private func beginWatching() {
        armEndTimer()
        lid.start()
        lidClosed = lid.isClosed
        startMinuteTick()
        if power == nil { power = PowerSourceObserver { [weak self] in MainActor.assumeIsolated { self?.evaluate() } } }
        if thermal == nil {
            thermal = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluate() }
            }
        }
        watchDisplays(true)
        restartHotspot()
        evaluate()
    }

    private func armEndTimer() {
        endTimer?.cancel()
        guard let session else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(wallDeadline: .now() + max(0, session.endsAt.timeIntervalSinceNow), leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.end(self?.session?.agents == true ? "Agents went quiet" : "Time's up") }
        }
        timer.resume()
        endTimer = timer
    }

    /// Once a minute, as the time left in whole minutes changes; not while the lid is closed.
    private func startMinuteTick() {
        stopMinuteTick()
        updateMenuBarText()
        guard let session, !lidClosed else { return }
        let remaining = session.endsAt.timeIntervalSinceNow
        let first = remaining.truncatingRemainder(dividingBy: 60) + 0.05
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + max(0.05, first), repeating: 60, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.updateMenuBarText()
                self?.sampleBrightness()
            }
        }
        timer.resume()
        minuteTimer = timer
    }

    private func stopMinuteTick() {
        minuteTimer?.cancel()
        minuteTimer = nil
    }

    private func updateMenuBarText() {
        // An agents' session has no set end to count down to; the icon shows it instead.
        guard let session, policy.showTimeInMenuBar, session.agents != true else { return menuBarText = nil }
        let text = AwakeDuration.menuBar(session.endsAt.timeIntervalSinceNow)
        if text != menuBarText { menuBarText = text }
    }

    /// The display's and keyboard's levels, while you're at the Mac with the lid open (a reading
    /// only, never a write).
    private func sampleBrightness() {
        guard policy.darkenWhenClosed, !lidClosed, !DisplayPower.isAsleep else { return }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard idle < 30 else { return }  // idle-dimmed, not your setting
        if let value = DisplayBrightness.read() { sampledBrightness = value }
        if let value = KeyboardLight.read() { sampledKeyboard = value }
    }

    // MARK: The lid

    private func lidChanged(_ closed: Bool) {
        lidClosed = closed
        guard session != nil else {
            // Ended with the lid closed: what's left is putting things back.
            if !closed {
                restoreLid()
                lid.stop()
            }
            return
        }
        if closed {
            stopMinuteTick()
            applyClosed()
        } else {
            lastClosed = lidRecord
            restoreLid()
            startMinuteTick()
        }
        evaluate()
    }

    /// Lid closed with no other display: the display asleep (its keyboard light goes with it), sound
    /// muted, the chosen apps paused. Low Power Mode follows in `evaluate`.
    private func applyClosed() {
        guard lidSafe, !Displays.externalIsActive(), lidRecord == nil else { return }
        var record = LidRecord()
        if policy.darkenWhenClosed {
            record.darkened = true
            darkenUntilOpen()
        }
        if policy.muteWhenClosed { record.mute = OutputMute.mute() }
        if policy.pauseAppsWhenClosed {
            let chosen = AppPauser.openApps().filter { AwakePausing.pauses($0.app, choices: pauseChoices) }
            record.paused = AppPauser.pause(chosen.map(\.running))
            record.pausedNames = chosen.map(\.app.name)
            if !record.paused.isEmpty { sendPaused(record.paused) }
        }
        lidRecord = record
        save(record, Keys.lidRecord)
        awakeLog.notice("lid closed: display asleep \(record.darkened), muted \(record.muted), paused \(record.paused.count)")
    }

    /// Display sleep now, and again every 30 s (six times at most) while the lid is closed and the
    /// display is still awake. Still awake after the first 30 s means something holds it on (a sound
    /// playing, a video): then it's dimmed to 0 as well, and put back when the lid opens.
    private func darkenUntilOpen() {
        darkTimer?.cancel()
        DisplayPower.requestSleep()
        var tries = 0
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                tries += 1
                guard self.lidClosed, self.lidRecord?.darkened == true, tries <= 6, !DisplayPower.isAsleep else {
                    self.darkTimer?.cancel()
                    self.darkTimer = nil
                    return
                }
                DisplayPower.requestSleep()
                self.dimAsFallback()
            }
        }
        timer.resume()
        darkTimer = timer
    }

    /// The display wouldn't sleep: dim it and the keyboard light to 0, keeping the levels sampled
    /// while the lid was open.
    private func dimAsFallback() {
        guard var record = lidRecord, record.brightness == nil, record.keyboard == nil else { return }
        if DisplayBrightness.refusal == nil, let level = sampledBrightness ?? DisplayBrightness.read(), level > 0 {
            record.brightness = level
            DisplayBrightness.set(0)
        }
        if KeyboardLight.refusal == nil, let level = sampledKeyboard ?? KeyboardLight.read(), level > 0 {
            record.keyboard = level
            KeyboardLight.set(0)
        }
        lidRecord = record
        save(record, Keys.lidRecord)
        awakeLog.notice("display held awake under the lid: dimmed (display \(record.brightness ?? -1), keys \(record.keyboard ?? -1))")
    }

    private func restoreLid() {
        guard let record = lidRecord else { return }
        if !record.paused.isEmpty {
            AppPauser.resume(record.paused)
            if session != nil { sendPaused([]) }
        }
        if let mute = record.mute { OutputMute.restore(mute) }
        darkTimer?.cancel()
        darkTimer = nil
        if record.darkened { DisplayPower.wake() }
        if record.brightness != nil || record.keyboard != nil {
            Self.putLevels(record)
            // Waking runs the panel's own fade-in over what was set; set it once more after.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MainActor.assumeIsolated { Self.putLevels(record) } }
        }
        lidRecord = nil
        defaults.removeObject(forKey: Keys.lidRecord)
        awakeLog.notice("lid open: put back")
    }

    private static func putLevels(_ record: LidRecord) {
        if let level = record.brightness { DisplayBrightness.set(level) }
        if let level = record.keyboard { KeyboardLight.set(level) }
    }

    /// `tutto://do/lid-closed` / `lid-open`: runs the lid actions without moving the lid. Only with
    /// `awake.lidSimulation` set, and only during a session.
    func simulateLid(closed: Bool) {
        guard defaults.bool(forKey: Keys.lidSimulation), session != nil else { return }
        awakeLog.notice("simulated lid \(closed ? "closed" : "open", privacy: .public)")
        lid.simulate(closed: closed)
    }

    // MARK: Battery and heat

    private func conditions() -> AwakeConditions {
        // The light read: the full battery reader also parses the registry and, hourly, a health report.
        let power = PowerSourceNow.read()
        return AwakeConditions(onBattery: power.onBattery, charge: power.charge,
                               heat: Heat(ProcessInfo.processInfo.thermalState),
                               lidClosed: lidClosed, externalDisplay: lidClosed && Displays.externalIsActive())
    }

    private func evaluate(force: Bool = false) {
        guard session != nil else { return }
        let now = conditions()
        if let reason = AwakeRules.endReason(policy, now) {
            return end(reason)
        }
        let reason = lidSafe ? AwakeRules.lowPowerReason(policy, now) : nil
        lowPowerReason = reason
        let wanted = reason != nil
        guard wanted != lowPowerOn || force, lidSafe else { return }
        lowPowerOn = wanted
        helperProxy { _ in }?.setAwakeLowPower(wanted) { status, message in
            if status != 0 { awakeLog.error("low power \(wanted): \(message ?? "", privacy: .public)") }
        }
    }

    // MARK: Hotspot

    func locationAccess() -> LocationAccess {
        if let location { return location }
        let made = LocationAccess()
        location = made
        return made
    }

    private func restartHotspot() {
        hotspot?.stop()
        hotspot = nil
        hotspotStatus = nil
        let ssid = hotspotSSID.trimmingCharacters(in: .whitespaces)
        guard session != nil, hotspotEnabled, !ssid.isEmpty else { return }
        let watcher = HotspotWatcher(ssid: ssid)
        watcher.onStatus = { [weak self] status in self?.hotspotStatus = status }
        watcher.start()
        hotspot = watcher
    }

    // MARK: Apps to pause

    /// The open apps, with whether each would be paused, for the page.
    func pauseList() -> [(app: AwakeApp, pauses: Bool, icon: NSImage?)] {
        AppPauser.openApps()
            .filter { AwakePausing.canPause($0.app) }
            .map { ($0.app, AwakePausing.pauses($0.app, choices: pauseChoices), $0.running.icon) }
            .sorted { $0.app.name.localizedCaseInsensitiveCompare($1.app.name) == .orderedAscending }
    }

    func setPauses(_ app: AwakeApp, _ on: Bool) {
        if on == AwakePausing.pausesByDefault(category: app.category) { pauseChoices[app.bundleID] = nil } else { pauseChoices[app.bundleID] = on }
    }

    #if DEBUG
    /// Offscreen renders only: a session as the card shows it, without touching the Mac.
    func previewSession(remaining: TimeInterval, lidSafe: Bool, lastClosed: LidRecord? = nil) {
        session = Session(startedAt: Date(), endsAt: Date().addingTimeInterval(remaining))
        self.lidSafe = lidSafe
        self.lastClosed = lastClosed
        notice = lidSafe ? nil : "Closing the lid sleeps the Mac until Tutto's helper is set up (one approval)."
        helperStatus = lidSafe ? .enabled : .notRegistered
        menuBarText = AwakeDuration.menuBar(remaining)
    }
    #endif

    // MARK: Storage

    private static func sleepDisabledNow() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let value = IORegistryEntryCreateCFProperty(root, "SleepDisabled" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (value as? Bool) ?? false
    }

    private func save<T: Encodable>(_ value: T?, _ key: String) {
        if let value, let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    private enum Keys {
        static let session = "awake.session"
        static let lidRecord = "awake.lidRecord"
        static let policy = "awake.policy"
        static let pauseChoices = "awake.pauseChoices"
        static let hotspotEnabled = "awake.hotspot.enabled"
        static let hotspotSSID = "awake.hotspot.ssid"
        static let lidSimulation = "awake.lidSimulation"
    }
}
