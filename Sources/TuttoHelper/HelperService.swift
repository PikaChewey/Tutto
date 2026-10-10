//
//  HelperService.swift
//  TuttoHelper
//
//  The XPC side of the fan helper: accepts only Tutto.app, runs every SMC write on one
//  serial queue, and puts the fans back on automatic when the app goes away, on
//  SIGTERM and before sleep.
//

import Foundation
import IOKit
import IOKit.pwr_mgt
import os

let log = Logger(subsystem: TuttoFanHelper.machServiceName, category: "helper")

final class HelperService: NSObject, NSXPCListenerDelegate, TuttoFanHelperProtocol {
    /// Every SMC access and all state below happen on this queue.
    let queue = DispatchQueue(label: "ca.bryanyao.Tutto.helper.fans")

    private let controller: FanController
    private let requirement: String?
    private let exitsWhenIdle: Bool

    private var clients = Set<ObjectIdentifier>()
    private var idleTimer: DispatchSourceTimer?
    private var idleAttempts = 0
    private var signalSources: [DispatchSourceSignal] = []
    private var power: PowerObserver?

    /// `requirement` is the code-signing requirement every client must meet (nil only in
    /// the self-test's control case).
    init(smc: SMCAccess, requirement: String? = TuttoFanHelper.clientRequirement, exitsWhenIdle: Bool = true) {
        controller = FanController(smc: smc)
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
        queue.async { self.scheduleIdleExit() }
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

    // MARK: Lifetime (on queue)

    private func clientEnded(_ id: ObjectIdentifier) {
        guard clients.remove(id) != nil else { return }
        log.info("client disconnected; \(self.clients.count, privacy: .public) left")
        guard clients.isEmpty else { return }
        let status = controller.resetAll()
        log.notice("last client gone: fans to automatic (\(FanStatus.describe(status), privacy: .public))")
        scheduleIdleExit()
    }

    private func scheduleIdleExit() {
        guard exitsWhenIdle, clients.isEmpty, idleTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + TuttoFanHelper.idleExitDelay)
        timer.setEventHandler { [unowned self] in
            self.idleTimer = nil
            guard self.clients.isEmpty else { return }
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
