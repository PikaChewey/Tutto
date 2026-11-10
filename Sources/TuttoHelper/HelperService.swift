//
//  HelperService.swift
//  TuttoHelper
//
//  The XPC side of the helper: accepts only Tutto.app, runs every SMC write and power
//  command on one serial queue, and puts the fans back on automatic when the app goes away,
//  on SIGTERM and before sleep.
//
//  Stay Awake: the helper holds the session's end itself, so a hung or crashed app can't keep
//  the Mac awake past it. When the app goes away mid-session, paused apps are resumed at once
//  and the session runs on to its end (the lid may be closed with agents working), unless the
//  battery runs nearly flat or the Mac gets critically hot first. A journal left by a helper
//  that was killed is picked up at the next start.
//

import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import os

let log = Logger(subsystem: TuttoFanHelper.machServiceName, category: "helper")

final class HelperService: NSObject, NSXPCListenerDelegate, TuttoFanHelperProtocol {
    /// Every SMC access and all state below happen on this queue.
    let queue = DispatchQueue(label: "ca.bryanyao.Tutto.helper.fans")

    private let controller: FanController
    /// Nil in the self-test, which must not touch the Mac's power settings.
    private let awake: AwakeController?
    private let requirement: String?
    private let exitsWhenIdle: Bool

    private var clients = Set<ObjectIdentifier>()
    private var awakeTimer: DispatchSourceTimer?
    private var idleTimer: DispatchSourceTimer?
    private var idleAttempts = 0
    private var signalSources: [DispatchSourceSignal] = []
    private var power: PowerObserver?

    /// `requirement` is the code-signing requirement every client must meet (nil only in
    /// the self-test's control case).
    init(smc: SMCAccess, requirement: String? = TuttoFanHelper.clientRequirement, exitsWhenIdle: Bool = true,
         awakeJournal: URL? = URL(fileURLWithPath: TuttoFanHelper.awakeJournalPath)) {
        controller = FanController(smc: smc)
        awake = awakeJournal.map { AwakeController(commands: SystemPMSet(), processes: SystemProcesses(), journalURL: $0) }
        self.requirement = requirement
        self.exitsWhenIdle = exitsWhenIdle
    }

    /// Rejects non-matching peers before the delegate sees them (macOS 13+), and sets the
    /// same requirement on each accepted connection.
    func attach(to listener: NSXPCListener) {
        if let requirement { listener.setConnectionCodeSigningRequirement(requirement) }
        listener.delegate = self
    }

    /// Daemon-only duties: restore automatic on SIGTERM/SIGINT/SIGHUP and before sleep,
    /// and exit when idle.
    func startDaemonDuties() {
        for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
            source.setEventHandler { [unowned self] in
                let status = self.controller.resetAll()
                log.notice("signal \(signalNumber, privacy: .public): fans to automatic (\(FanStatus.describe(status), privacy: .public)); exiting")
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
        power = PowerObserver(queue: queue) { [unowned self] in
            let status = self.controller.resetAll()
            log.notice("system will sleep: fans to automatic (\(FanStatus.describe(status), privacy: .public))")
        }
        if power == nil { log.error("could not register for sleep notifications") }
        queue.async {
            // A session journaled by a helper that was stopped: resume what it paused (the app that
            // paused it may be gone) and keep it to its end, or end it if that has passed.
            if let awake = self.awake, awake.isActive {
                let resumed = awake.resumePaused()
                log.notice("found a Stay Awake journal (ends \(awake.deadline?.description ?? "?", privacy: .public)); resumed \(resumed, privacy: .public)")
                self.armAwakeTimer()
            }
            self.scheduleIdleExit()
        }
    }

    // MARK: NSXPCListenerDelegate

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        if let requirement { connection.setCodeSigningRequirement(requirement) }
        connection.exportedInterface = TuttoFanHelper.makeInterface()
        connection.exportedObject = self
        let id = ObjectIdentifier(connection)
        let ended: () -> Void = { [weak self] in
            guard let self else { return }
            self.queue.async { self.clientEnded(id) }
        }
        connection.invalidationHandler = ended
        connection.interruptionHandler = ended
        queue.sync {
            clients.insert(id)
            idleTimer?.cancel()
            idleTimer = nil
            idleAttempts = 0
        }
        log.info("client connected (pid \(connection.processIdentifier, privacy: .public))")
        connection.resume()
        return true
    }

    // MARK: TuttoFanHelperProtocol

    func version(reply: @escaping (String) -> Void) {
        reply(TuttoFanHelper.version)
    }

    func setFan(_ index: Int, mode: Int, rpm: Double, reply: @escaping (Int32, String?) -> Void) {
        queue.async {
            let result = self.controller.setFan(index, mode: mode, rpm: rpm)
            log.notice("setFan \(index, privacy: .public) mode \(mode, privacy: .public) rpm \(rpm, privacy: .public): \(FanStatus.describe(result.status), privacy: .public)")
            reply(result.status, result.message)
        }
    }

    func resetAllFans(reply: @escaping (Int32) -> Void) {
        queue.async {
            let status = self.controller.resetAll()
            log.notice("resetAllFans: \(FanStatus.describe(status), privacy: .public)")
            reply(status)
        }
    }

    // MARK: Stay Awake

    func beginAwake(until deadline: Double, reply: @escaping (Int32, String?) -> Void) {
        queue.async {
            guard let awake = self.awake else { return reply(FanStatus.unsupported, "Stay Awake is off in this helper.") }
            let result = awake.begin(until: Date(timeIntervalSince1970: deadline))
            log.notice("beginAwake until \(Date(timeIntervalSince1970: deadline).description, privacy: .public): \(result.message ?? "ok", privacy: .public)")
            self.armAwakeTimer()
            reply(result.status, result.message)
        }
    }

    func endAwake(sleepIfLidClosed: Bool, reply: @escaping (Int32, String?) -> Void) {
        queue.async {
            let result = self.endAwakeSession(reason: "asked", sleepIfLidClosed: sleepIfLidClosed)
            reply(result.status, result.message)
        }
    }

    func setAwakeLowPower(_ on: Bool, reply: @escaping (Int32, String?) -> Void) {
        queue.async {
            guard let awake = self.awake else { return reply(FanStatus.unsupported, "Stay Awake is off in this helper.") }
            let result = awake.setLowPower(on)
            log.notice("setAwakeLowPower \(on, privacy: .public): \(result.message ?? "ok", privacy: .public)")
            reply(result.status, result.message)
        }
    }

    func setAwakePaused(_ json: Data, reply: @escaping (Int32) -> Void) {
        guard let connection = NSXPCConnection.current() else { return reply(FanStatus.notPermitted) }
        let uid = UInt32(connection.effectiveUserIdentifier)
        queue.async {
            guard let awake = self.awake,
                  let list = try? JSONDecoder().decode([PausedProcess].self, from: json) else { return reply(FanStatus.badArgument) }
            let result = awake.setPaused(list, ownedBy: uid)
            log.info("setAwakePaused: \(list.count, privacy: .public) processes")
            reply(result.status)
        }
    }

    func awakeState(reply: @escaping (Double, Bool) -> Void) {
        queue.async {
            reply(self.awake?.deadline?.timeIntervalSince1970 ?? 0, self.awake?.lowPowerClaimed ?? false)
        }
    }

    /// Ends the session and, if asked and the lid is still closed, puts the Mac to sleep.
    @discardableResult
    private func endAwakeSession(reason: String, sleepIfLidClosed: Bool) -> AwakeResult {
        guard let awake, awake.isActive else { return .ok }
        let result = awake.end()
        log.notice("Stay Awake ended (\(reason, privacy: .public)): \(result.message ?? "ok", privacy: .public)")
        if result.succeeded {
            awakeTimer?.cancel()
            awakeTimer = nil
            if sleepIfLidClosed && Self.lidIsClosed() {
                // Give powerd a moment with sleep allowed again, then make sure the closed Mac sleeps.
                queue.asyncAfter(deadline: .now() + 1) {
                    guard Self.lidIsClosed(), !awake.isActive else { return }
                    let sleep = SystemPMSet().pmset(["sleepnow"])
                    log.notice("lid closed after the session: sleepnow (\(sleep.status, privacy: .public))")
                }
            }
            scheduleIdleExit()
        } else {
            armAwakeTimer(retry: true)
        }
        return result
    }

    /// While a session runs: a check every minute (and at its end) for the end, and, with no app
    /// connected, for a nearly flat battery or critical heat.
    private func armAwakeTimer(retry: Bool = false) {
        guard let awake, awake.isActive else {
            awakeTimer?.cancel()
            awakeTimer = nil
            return
        }
        awakeTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let untilEnd = (awake.deadline?.addingTimeInterval(AwakeLimits.grace).timeIntervalSinceNow ?? 0)
        let first = retry ? 30 : max(1, min(60, untilEnd))
        timer.schedule(wallDeadline: .now() + first, repeating: 60, leeway: .seconds(2))
        timer.setEventHandler { [unowned self] in self.checkAwake() }
        awakeTimer = timer
        timer.resume()
    }

    private func checkAwake() {
        guard let awake, awake.isActive else { return armAwakeTimer() }
        if awake.isOverdue() {
            // Unattended, it can't know whether a display is plugged in; on battery it's a laptop
            // on its own, which should sleep.
            endAwakeSession(reason: "time is up", sleepIfLidClosed: clients.isEmpty ? Self.onBattery() : true)
            return
        }
        guard clients.isEmpty else { return armAwakeTimer() }
        if ProcessInfo.processInfo.thermalState == .critical {
            endAwakeSession(reason: "critical heat, no app", sleepIfLidClosed: true)
        } else if let charge = Self.batteryCharge(), Self.onBattery(), charge < AwakeLimits.unattendedBatteryFloor {
            endAwakeSession(reason: "battery at \(charge)%, no app", sleepIfLidClosed: true)
        } else {
            armAwakeTimer()
        }
    }

    static func lidIsClosed() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (value as? Bool) ?? false
    }

    static func onBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return false }
        return type == kIOPSBatteryPowerValue
    }

    static func batteryCharge() -> Int? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            return current * 100 / maximum
        }
        return nil
    }

    // MARK: Lifetime (on queue)

    private func clientEnded(_ id: ObjectIdentifier) {
        guard clients.remove(id) != nil else { return }
        log.info("client disconnected; \(self.clients.count, privacy: .public) left")
        guard clients.isEmpty else { return }
        let status = controller.resetAll()
        log.notice("last client gone: fans to automatic (\(FanStatus.describe(status), privacy: .public))")
        if let awake, awake.isActive {
            // Nothing is left to resume them when the lid opens.
            let resumed = awake.resumePaused()
            log.notice("last client gone mid-session: resumed \(resumed, privacy: .public) paused processes; session runs to its end")
            armAwakeTimer()
        }
        scheduleIdleExit()
    }

    private func scheduleIdleExit() {
        guard exitsWhenIdle, clients.isEmpty, idleTimer == nil, !(awake?.isActive ?? false) else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + TuttoFanHelper.idleExitDelay)
        timer.setEventHandler { [unowned self] in
            self.idleTimer = nil
            guard self.clients.isEmpty, !(self.awake?.isActive ?? false) else { return }
            if !self.controller.allAutomatic { self.controller.resetAll() }
            self.idleAttempts += 1
            // If something else keeps a fan manual, do not fight it forever.
            if self.controller.allAutomatic || self.idleAttempts >= 3 {
                log.notice("idle: exiting (all automatic: \(self.controller.allAutomatic, privacy: .public))")
                exit(0)
            }
            self.scheduleIdleExit()
        }
        idleTimer = timer
        timer.resume()
    }
}

// MARK: - Sleep notifications

/// Calls `willSleep` on `queue` before the system sleeps, then allows the sleep.
final class PowerObserver {
    // IOMessage.h constants (function-like macros, not imported into Swift).
    private static let canSystemSleep: UInt32 = 0xe000_0270
    private static let systemWillSleep: UInt32 = 0xe000_0280

    private let willSleep: () -> Void
    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0

    init?(queue: DispatchQueue, willSleep: @escaping () -> Void) {
        self.willSleep = willSleep
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(refcon, &notifyPort, { refcon, _, messageType, argument in
            guard let refcon else { return }
            Unmanaged<PowerObserver>.fromOpaque(refcon).takeUnretainedValue().handle(messageType, argument)
        }, &notifier)
        guard rootPort != 0, let notifyPort else { return nil }
        IONotificationPortSetDispatchQueue(notifyPort, queue)
    }

    private func handle(_ messageType: UInt32, _ argument: UnsafeMutableRawPointer?) {
        switch messageType {
        case Self.canSystemSleep:
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        case Self.systemWillSleep:
            willSleep()
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        default:
            break
        }
    }
}
