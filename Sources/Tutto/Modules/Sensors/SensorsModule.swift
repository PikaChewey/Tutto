//
//  SensorsModule.swift
//  Tutto
//
//  Temperatures and fans (Macs Fan Control's job). Reading needs no privileges and
//  happens only while a view shows it. Setting a fan speed goes through TuttoHelper,
//  a tiny root LaunchDaemon the user approves once. Tutto keeps one connection to it
//  open while any fan is under manual control; when that connection ends (quit,
//  crash, module off) the helper puts every fan back on automatic.
//

import AppKit
import Observation
import ServiceManagement
import TuttoKit

@MainActor
@Observable
final class SensorsModule {
    private(set) var temperatures: [TemperatureReading] = []
    private(set) var summary: TemperatureSummary?
    private(set) var fans: [FanReading] = []
    /// What the user asked each fan to do (nil = automatic).
    private(set) var commands: [Int: FanCommand] = [:]
    private(set) var helperStatus: SMAppService.Status = .notRegistered
    private(set) var helperMessage: String?
    private(set) var isApplying = false
    let fanCount = Fans.count

    private var watchers = 0
    private var timer: DispatchSourceTimer?
    private var connection: NSXPCConnection?
    private var observers: [NSObjectProtocol] = []

    var hasFans: Bool { fanCount > 0 }
    var isManual: Bool { commands.values.contains { $0 != .auto } }

    init() {
        refreshHelperStatus()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resetAll(reason: nil) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshHelperStatus() }
        })
    }

    /// Module switched off or app quitting: fans back to automatic, release everything.
    func stop() {
        resetAll(reason: nil)
        timer?.cancel()
        timer = nil
        watchers = 0
        TemperatureSensors.release()
        observers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
    }

    // MARK: Readings

    func begin() {
        watchers += 1
        guard timer == nil else { return }
        sample()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(300))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer.resume()
        self.timer = timer
    }

    func end() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        timer?.cancel()
        timer = nil
        TemperatureSensors.release()
    }

    private func sample() {
        temperatures = TemperatureSensors.read()
        summary = TemperatureSummary(temperatures)
        fans = Fans.read()
    }

    // MARK: Helper

    func refreshHelperStatus() {
        helperStatus = SMAppService.daemon(plistName: TuttoFanHelper.plistName).status
    }

    func installHelper() {
        AppModel.shared.permissions.request(.fanHelper)
        refreshHelperStatus()
        switch helperStatus {
        case .requiresApproval:
            helperMessage = "Switch on Tutto under System Settings › General › Login Items & Extensions › App Background Activity."
        case .enabled:
            helperMessage = nil
        default:
            helperMessage = "macOS didn't register the helper. Make sure Tutto is in Applications, then try again."
        }
    }

    // MARK: Fan control

    func set(_ command: FanCommand, for fan: FanReading) {
        let clamped = command.clamped(for: fan)
        commands[fan.index] = clamped == .auto ? nil : clamped
        apply(clamped, to: fan)
    }

    private func apply(_ command: FanCommand, to fan: FanReading) {
        refreshHelperStatus()
        guard helperStatus == .enabled else {
            commands[fan.index] = nil
            helperMessage = helperStatus == .requiresApproval
                ? "Approve the helper first: System Settings › General › Login Items & Extensions › App Background Activity."
                : "Install the fan helper to change fan speeds."
            return
        }
        let arguments = command.helperArguments(for: fan)
        isApplying = true
        helper { [weak self] error in
            MainActor.assumeIsolated {
                self?.isApplying = false
                self?.commands[fan.index] = nil
                self?.helperMessage = "Couldn't reach the fan helper: \(error.localizedDescription)"
            }
        }?.setFan(fan.index, mode: arguments.mode, rpm: arguments.rpm) { [weak self] status, message in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isApplying = false
                    if status == 0 {
                        self.helperMessage = nil
                    } else {
                        self.commands[fan.index] = nil
                        self.helperMessage = message ?? String(format: "The helper reported error 0x%08x.", UInt32(bitPattern: status))
                    }
                    self.sample()
                    if !self.isManual { self.closeConnection() }
                }
            }
        }
    }

    /// Everything back to automatic.
    func resetAll(reason: String?) {
        let wasManual = isManual
        commands.removeAll()
        guard wasManual, let proxy = helper(nil) else {
            closeConnection()
            return
        }
        proxy.resetAllFans { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.closeConnection() }
            }
        }
        // Closing the connection makes the helper reset on its own as well, so this is safe
        // even if the reply never arrives (e.g. during quit).
        if reason != nil { helperMessage = reason }
    }

    private func helper(_ onError: ((Error) -> Void)?) -> TuttoFanHelperProtocol? {
        if connection == nil {
            let connection = NSXPCConnection(machServiceName: TuttoFanHelper.machServiceName, options: .privileged)
            connection.remoteObjectInterface = TuttoFanHelper.makeInterface()
            connection.setCodeSigningRequirement(TuttoFanHelper.helperRequirement)
            connection.invalidationHandler = { [weak self] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.connectionEnded() }
                }
            }
            connection.interruptionHandler = { [weak self] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.connectionEnded() }
                }
            }
            connection.resume()
            self.connection = connection
        }
        return connection?.remoteObjectProxyWithErrorHandler { error in
            DispatchQueue.main.async { onError?(error) }
        } as? TuttoFanHelperProtocol
    }

    private func closeConnection() {
        connection?.invalidationHandler = nil
        connection?.interruptionHandler = nil
        connection?.invalidate()
        connection = nil
    }

    /// The helper went away (crashed, was updated). It resets fans when that happens,
    /// so the honest state is "automatic".
    private func connectionEnded() {
        connection = nil
        if isManual {
            commands.removeAll()
            helperMessage = "The fan helper stopped, so fans are back on automatic."
        }
        sample()
    }
}
