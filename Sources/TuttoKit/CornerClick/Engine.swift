//
//  Engine.swift
//  Tutto (CornerClick engine)
//
//  Owns the event tap and the trackpad listeners, and keeps them alive across
//  sleep/wake, trackpad plug/unplug and permission changes. Main thread only.
//

import AppKit
import ApplicationServices
@preconcurrency import CoreGraphics
import IOKit
import CBridges

public enum EngineStatus: Equatable, Sendable {
    case off
    case needsPermission
    case running(trackpads: Int)
    case noTrackpad
    case multitouchUnavailable
    case eventTapFailed
}

@MainActor
public final class Engine {
    private(set) var status: EngineStatus = .off {
        didSet { if status != oldValue { onStatusChange?(status) } }
    }

    public var onStatusChange: ((EngineStatus) -> Void)?
    public var onRightClick: ((Trigger) -> Void)?
    public var onFrame: ((TouchFrame) -> Void)?
    public var onDiagnostic: ((String) -> Void)?

    private lazy var core = EngineCore { [weak self] event in
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let self else { return }
                switch event {
                case .rightClick(let trigger): self.onRightClick?(trigger)
                case .frame(let frame): self.onFrame?(frame)
                case .touchStreamStale:
                    self.onDiagnostic?("touch stream stale: restarting")
                    self.scheduleRestart(after: 0.05)
                case .diagnostic(let line): self.onDiagnostic?(line)
                }
            }
        }
    }

    private var wantsRunning = false
    private lazy var tapThread = EventTapThread(core: core)
    private var notificationPort: IONotificationPortRef?
    private var hotplugIterators: [io_iterator_t] = []
    private var restartWork: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private var trustWatchdog: DispatchSourceTimer?

    public init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification,
                     NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRestart(after: 2.0) }
            })
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopListening() }
            })
        }
    }

    // MARK: Public

    public var isTrusted: Bool { AXIsProcessTrusted() }

    public func setRules(_ rules: RuleSet) {
        core.setRules(rules)
    }

    /// Live finger positions are only produced while something is on screen to show them.
    public func setObserving(_ observing: Bool) {
        core.setObserving(observing)
    }

    public func setDiagnostics(_ on: Bool) {
        core.setDiagnostics(on)
    }

    public func start() {
        wantsRunning = true
        startListening()
    }

    public func stop() {
        wantsRunning = false
        stopListening()
        status = .off
    }

    /// Re-evaluates permission and restarts if needed (after the user grants access).
    public func refresh() {
        if wantsRunning, !isRunning || !isTrusted {
            startListening()
        }
    }

    // MARK: Lifecycle

    private var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    private func startListening() {
        stopListening()
        guard wantsRunning else { return }
        guard isTrusted else {
            status = .needsPermission
            return
        }

        let count = CCMultitouchStart({ context, deviceIndex, contacts, count in
            guard let context else { return }
            Unmanaged<EngineCore>.fromOpaque(context).takeUnretainedValue()
                .handleFrame(deviceIndex: Int(deviceIndex), contacts: contacts, count: Int(count))
        }, Unmanaged.passUnretained(core).toOpaque())

        guard count >= 0 else {
            status = .multitouchUnavailable
            return
        }
        core.resetTouches(sizes: (0..<max(count, 0)).map { index in
            var info = CCDeviceInfo()
            guard CCMultitouchDeviceInfo(index, &info), info.surfaceWidth > 1000, info.surfaceHeight > 1000 else {
                return .macBookPro14
            }
            return TrackpadSize(width: Double(info.surfaceWidth) / 100, height: Double(info.surfaceHeight) / 100)
        })
        armHotplugNotifications()
        guard count > 0 else {
            status = .noTrackpad
            return
        }
        guard tapThread.start() else {
            CCMultitouchStop()
            status = .eventTapFailed
            return
        }
        status = .running(trackpads: Int(count))
        startTrustWatchdog()
    }

    private func stopListening() {
        trustWatchdog?.cancel()
        trustWatchdog = nil
        restartWork?.cancel()
        restartWork = nil
        tapThread.stop()
        CCMultitouchStop()
        core.resetTouches(sizes: [])
    }

    private func scheduleRestart(after delay: TimeInterval) {
        guard wantsRunning else { return }
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.startListening() }
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// An active event tap left behind after Accessibility is revoked can freeze input
    /// system-wide on recent macOS. macOS usually announces the change, but not always,
    /// so double-check every few seconds while running and tear the tap down at once.
    private func startTrustWatchdog() {
        trustWatchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !AXIsProcessTrusted() else { return }
                self.stopListening()
                self.status = .needsPermission
            }
        }
        timer.resume()
        trustWatchdog = timer
    }

    // MARK: Trackpad plug / unplug

    private func armHotplugNotifications() {
        guard notificationPort == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notificationPort = port
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)

        let callback: IOServiceMatchingCallback = { context, iterator in
            while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
                IOObjectRelease(service)
            }
            guard let context else { return }
            let engine = Unmanaged<Engine>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { engine.scheduleRestart(after: 0.8) }
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            if IOServiceAddMatchingNotification(port, type, IOServiceMatching("AppleMultitouchDevice"),
                                                callback, context, &iterator) == KERN_SUCCESS {
                // Drain once to arm the notification (these are the devices already present).
                while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
                    IOObjectRelease(service)
                }
                hotplugIterators.append(iterator)
            }
        }
    }
}
