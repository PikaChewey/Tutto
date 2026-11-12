//
//  ChargeLimit.swift
//  Tutto
//
//  Charge limit: stop charging at a level you choose (80 % unless you pick another), for a
//  MacBook that's plugged in most of the time. While the charge is held, the Mac runs on the
//  adapter and the battery just sits. Charging starts again 5 % below the limit, and
//  "Charge to 100 % once" lifts it until the battery is full or the adapter comes out.
//
//  Only root can stop charging (an SMC write), so TuttoHelper does it, under a lease this
//  controller renews every minute. If Tutto hangs, crashes or quits, the helper lets the Mac
//  charge again by itself (`ChargeControlCore.swift`).
//
//  Off by default. Switched on, it listens to power-source changes (no polling); the only
//  timer is the lease renewal, and it runs only while charging is held off.
//

import AppKit
import IOKit.ps
import Observation
import os
import ServiceManagement
import SwiftUI
import TuttoKit

private let chargeLog = Logger(subsystem: "ca.bryanyao.Tutto", category: "charge-limit")

@MainActor
@Observable
final class ChargeLimitController {
    static let shared = ChargeLimitController()

    private enum Keys {
        static let enabled = "battery.chargeLimit.enabled"
        static let level = "battery.chargeLimit.level"
        static let topUp = "battery.chargeLimit.topUp"
    }

    private(set) var enabled = false
    private(set) var level = ChargeLimitRules.defaultLevel
    /// "Charge to 100 % once" is on.
    private(set) var topUp = false
    /// The latest power-source reading (only kept while the limit is on).
    private(set) var reading: ChargeReading?
    /// The helper confirmed it holds charging off.
    private(set) var inhibiting = false
    private(set) var helperStatus: SMAppService.Status = .notRegistered
    /// A failure worth telling (the helper refused or couldn't be reached).
    private(set) var notice: String?
    /// Nil when this Mac's SMC has no charging control key (read once, never written from here).
    private(set) var method: ChargeSMC.Method?

    @ObservationIgnored private var started = false
    @ObservationIgnored private var powerSource: CFRunLoopSource?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var renewTimer: DispatchSourceTimer?
    @ObservationIgnored private var connection: NSXPCConnection?
    /// The value of a request on its way to the helper.
    @ObservationIgnored private var pending: Bool?
    @ObservationIgnored private var reconnects = 0
    /// Snapshots only: shown as on, but nothing was ever sent to the helper.
    @ObservationIgnored private var previewing = false

    var supported: Bool { method != nil }

    /// A few words for the panel's battery card while the limit is holding the charge, else nil.
    var panelNote: String? {
        guard enabled, let reading else { return nil }
        return ChargeLimitRules.panelNote(percent: reading.percent, pluggedIn: reading.pluggedIn,
                                          topUp: topUp, inhibiting: inhibiting)
    }

    /// The Battery page's status line while the limit is on.
    var statusLine: String? {
        guard enabled, let reading else { return nil }
        return ChargeLimitRules.status(percent: reading.percent, pluggedIn: reading.pluggedIn, charging: reading.charging,
                                       limit: level, topUp: topUp, inhibiting: inhibiting)
    }

    // MARK: Lifetime

    func start(model: AppModel) {
        guard !started else { return }
        started = true
        let defaults = UserDefaults.standard
        enabled = defaults.bool(forKey: Keys.enabled)
        level = ChargeLimitRules.normalize(defaults.object(forKey: Keys.level) as? Int ?? ChargeLimitRules.defaultLevel)
        topUp = defaults.bool(forKey: Keys.topUp)
        method = ChargeControl.supportedMethod()
        refreshHelperStatus()
        if enabled { activate() }
    }

    /// At quit: charging always back on (waits up to 2 s for the helper; closing the connection
    /// makes it allow charging too, even if the answer never comes).
    func stop() {
        guard !previewing else { return }
        deactivate(waitForHelper: true)
        started = false
    }

    // MARK: Settings

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        UserDefaults.standard.set(on, forKey: Keys.enabled)
        if on {
            notice = nil
            reconnects = 0
            refreshHelperStatus()
            activate()
        } else {
            setTopUp(false)
            deactivate(waitForHelper: false)
        }
    }

    func setLevel(_ value: Int) {
        let value = ChargeLimitRules.normalize(value)
        guard value != level else { return }
        level = value
        UserDefaults.standard.set(value, forKey: Keys.level)
        evaluate()
    }

    /// "Charge to 100 % once", or cancels it.
    func chargeFullOnce(_ on: Bool = true) {
        setTopUp(on)
        evaluate()
    }

    private func setTopUp(_ on: Bool) {
        guard on != topUp else { return }
        topUp = on
        UserDefaults.standard.set(on, forKey: Keys.topUp)
    }

    // MARK: Helper set-up (the same approval fans and Stay Awake use)

    func refreshHelperStatus() {
        helperStatus = SMAppService.daemon(plistName: TuttoFanHelper.plistName).status
    }

    func setUpHelper() {
        refreshHelperStatus()
        if helperStatus == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        } else {
            AppModel.shared.permissions.request(.fanHelper)
            refreshHelperStatus()
        }
        evaluate()
    }

    // MARK: Events

    private func activate() {
        guard started, powerSource == nil else { return evaluate() }
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let controller = Unmanaged<ChargeLimitController>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { controller.evaluate() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            powerSource = source
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.willSleep() }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        })
        // Coming back from System Settings after approving the helper.
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.helperStatus != .enabled else { return }
                self.refreshHelperStatus()
                self.evaluate()
            }
        })
        evaluate()
    }

    private func deactivate(waitForHelper: Bool) {
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        powerSource = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        stopRenewing()
        if inhibiting || pending == true {
            if waitForHelper {
                let done = DispatchSemaphore(value: 0)
                helperProxy { _ in done.signal() }?.setChargingInhibited(false, lease: 0) { _, _ in done.signal() }
                _ = done.wait(timeout: .now() + 2)
                inhibiting = false
                pending = nil
                closeConnection()
            } else {
                send(false)
            }
        } else {
            closeConnection()
        }
        reading = nil
    }

    /// Before sleep: below the limit, let it charge (nothing can watch the charge while the Mac
    /// sleeps); at or above it, keep holding.
    private func willSleep() {
        guard enabled, inhibiting, let now = ChargeReading.read(), now.percent < level else { return }
        chargeLog.notice("sleeping at \(now.percent)% below the \(self.level)% limit: charging allowed")
        stopRenewing()
        send(false)
    }

    /// Reads the power source and does what the rules say.
    func evaluate() {
        guard started, enabled else { return }
        reading = ChargeReading.read()
        guard let reading, supported else { return apply(false) }
        let decision = ChargeLimitRules.decide(.init(percent: reading.percent, pluggedIn: reading.pluggedIn, limit: level,
                                                     topUp: topUp, inhibiting: inhibiting || pending == true))
        setTopUp(decision.topUp)
        apply(decision.inhibit)
    }

    private func apply(_ inhibit: Bool) {
        if inhibit {
            guard !inhibiting, pending != true else { return }
            refreshHelperStatus()
            guard helperStatus == .enabled else { return }
            send(true)
        } else {
            stopRenewing()
            guard inhibiting || pending == true else {
                if pending == nil { closeConnection() }
                return
            }
            send(false)
        }
    }

    // MARK: Talking to the helper

    private func send(_ inhibit: Bool) {
        pending = inhibit
        let proxy = helperProxy { [weak self] error in
            guard let self, self.pending == inhibit else { return }
            self.pending = nil
            self.inhibiting = false
            if inhibit { self.notice = "Couldn't reach Tutto's helper (\(error.localizedDescription)), so the Mac keeps charging." }
            self.closeConnection()
        }
        proxy?.setChargingInhibited(inhibit, lease: ChargeLease.duration) { [weak self] status, message in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.answered(inhibit, status: status, message: message) }
            }
        }
    }

    private func answered(_ inhibit: Bool, status: Int32, message: String?) {
        guard pending == inhibit else { return }
        pending = nil
        chargeLog.notice("helper: \(inhibit ? "hold" : "allow") -> \(FanStatus.describe(status), privacy: .public) \(message ?? "", privacy: .public)")
        if inhibit {
            if status == FanStatus.success {
                inhibiting = true
                notice = nil
                reconnects = 0
                startRenewing()
            } else {
                inhibiting = false
                notice = (message ?? FanStatus.describe(status)) + " The Mac keeps charging."
                closeConnection()
                return
            }
        } else {
            inhibiting = false
            if status != FanStatus.success {
                notice = "The helper couldn't restart charging just now; it will within two minutes."
            }
            // Closing the connection makes the helper allow charging too.
            closeConnection()
        }
        // Things may have moved on while the request was out (switched off, unplugged).
        if enabled { evaluate() } else if inhibiting { apply(false) }
    }

    /// The only timer: while charging is held off, renew the lease every minute.
    private func startRenewing() {
        guard renewTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + ChargeLease.renewInterval, repeating: ChargeLease.renewInterval, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.renew() }
        }
        renewTimer = timer
        timer.resume()
    }

    private func stopRenewing() {
        renewTimer?.cancel()
        renewTimer = nil
    }

    private func renew() {
        guard inhibiting, pending == nil else { return }
        helperProxy { _ in }?.setChargingInhibited(true, lease: ChargeLease.duration) { [weak self] status, message in
            guard status != FanStatus.success else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.inhibiting else { return }
                    self.inhibiting = false
                    self.stopRenewing()
                    self.notice = (message ?? FanStatus.describe(status)) + " The Mac keeps charging."
                    self.closeConnection()
                }
            }
        }
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
            chargeLog.error("helper: \(error.localizedDescription, privacy: .public)")
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

    /// The helper went away (updated, crashed). It lets the Mac charge when that happens, so
    /// the honest state is "charging allowed"; ask again a few times.
    private func connectionEnded() {
        connection = nil
        let wasHolding = inhibiting || pending == true
        inhibiting = false
        pending = nil
        stopRenewing()
        guard wasHolding, enabled else { return }
        reconnects += 1
        guard reconnects <= 5 else {
            notice = "Lost touch with Tutto's helper, so the Mac keeps charging. Switch the limit off and on to retry."
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + pow(2, Double(reconnects))) { [weak self] in
            MainActor.assumeIsolated { self?.evaluate() }
        }
    }

    #if DEBUG
    /// Snapshots: the limit on and holding, with nothing started.
    func previewHolding(percent: Int = 80, helper: SMAppService.Status = .enabled) {
        previewing = true
        enabled = true
        level = 80
        method = method ?? .flag32
        reading = ChargeReading(percent: percent, pluggedIn: true, charging: false)
        inhibiting = helper == .enabled
        helperStatus = helper
    }
    #endif
}

// MARK: - Battery page

/// The Battery page's charge limit settings.
struct ChargeLimitSection: View {
    var model: AppModel
    @State private var draft: Double?
    private var limit: ChargeLimitController { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            InkGroup("Charge limit") {
                LabeledRow("Stop charging at a set level", detail: mainDetail) {
                    InkSwitch(isOn: Binding(get: { limit.enabled }, set: { limit.setEnabled($0) }),
                              label: "Stop charging at a set level",
                              active: !limit.enabled || limit.helperStatus == .enabled)
                        .disabled(!limit.supported)
                }
                if limit.enabled && limit.supported {
                    if limit.helperStatus != .enabled {
                        Hairline().opacity(0.6)
                        LabeledRow(limit.helperStatus == .requiresApproval ? "Approve Tutto's helper" : "Needs Tutto's helper",
                                   detail: "Only the system can stop charging, so Tutto's helper does it (the same one fans and Stay Awake use). Approve it once.") {
                            Button(limit.helperStatus == .requiresApproval ? "Approve" : "Set Up") { limit.setUpHelper() }
                                .buttonStyle(InkButtonStyle(compact: true))
                        }
                    }
                    Hairline().opacity(0.6)
                    LabeledRow("Stop at", detail: "Charging starts again below \(shownLevel - ChargeLimitRules.resumeGap) %.") {
                        HStack(spacing: 10) {
                            Slider(value: Binding(get: { draft ?? Double(limit.level) }, set: { draft = $0 }),
                                   in: 50...100, step: 5) { editing in
                                if !editing, let draft {
                                    limit.setLevel(Int(draft))
                                    self.draft = nil
                                }
                            }
                            .controlSize(.small)
                            .frame(width: 150)
                            .accessibilityLabel("Stop charging at")
                            .accessibilityValue("\(shownLevel) percent")
                            Text("\(shownLevel) %")
                                .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                                .foregroundStyle(Color.ink)
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                    Hairline().opacity(0.6)
                    LabeledRow("Full charge once", detail: limit.topUp
                               ? "Charging to 100 %. The limit comes back once it's full or unplugged."
                               : "For a day away from the desk: charges to 100 %, then the limit comes back.") {
                        Button(limit.topUp ? "Cancel" : "Charge to 100 %") { limit.chargeFullOnce(!limit.topUp) }
                            .buttonStyle(OutlineButtonStyle(compact: true))
                    }
                }
            }
            if limit.enabled && limit.supported {
                Text("macOS's Optimized Battery Charging may also hold the charge for a while. While it's held, the Mac runs on the adapter.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(Motion.snappy, value: limit.enabled)
        .onAppear { limit.refreshHelperStatus() }
    }

    private var shownLevel: Int { draft.map { Int($0) } ?? limit.level }

    /// What it does while off; while on, what it's doing (or what went wrong).
    private var mainDetail: String {
        guard limit.supported else { return "This Mac doesn't let apps stop charging." }
        guard limit.enabled else {
            return "For a Mac that's plugged in most of the time: it stops charging at \(limit.level) %, which is easier on the battery."
        }
        if let notice = limit.notice { return notice }
        if limit.helperStatus != .enabled { return "Waiting for Tutto's helper. Until then, the Mac charges as usual." }
        return limit.statusLine ?? "Reading the battery…"
    }
}
