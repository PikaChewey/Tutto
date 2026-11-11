//
//  PluginHost.swift
//  Tutto
//
//  Runs plugins by themselves: their triggers and their cards. Nothing is watched that no plugin
//  asks for: each source (sleep and wake, the screen lock, apps, power, the clipboard, the network,
//  displays, schedules, agents) starts when the first plugin switched on needs it and stops with
//  the last. A card refreshes while it's on screen, or in the background only if it asks to;
//  schedules run on the wall clock, so a Mac that slept through one runs it once on waking, not
//  once per missed slot.
//

import AppKit
import IOKit.ps
import Network
import TuttoKit

@MainActor
final class PluginHost {
    private var plugins: PluginsModel { AppModel.shared.plugins }

    // Cards: how many places show each one (the panel, the Customize preview), and their timers.
    private var shown: [UUID: Int] = [:]
    private var cardTimers: [UUID: (interval: Double, timer: DispatchSourceTimer)] = [:]

    // Events
    private var watching: Set<PluginEvent> = []
    private var tokens: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var powerSource: CFRunLoopSource?
    private var lastPower: (onBattery: Bool, charge: Int?)?
    private var batteryWatches: [String: BatteryWatch] = [:]
    private var pathMonitor: NWPathMonitor?
    private var lastNetwork: String?
    private var networkDebounce: DispatchWorkItem?
    private var screenCount = 0
    private var clipboardTimer: DispatchSourceTimer?
    private var lastPasteboard = 0
    private var schedules: [String: DispatchSourceTimer] = [:]
    private var agentWatcher: AgentWatcher?
    private var agentsSince: Date?
    private var agentsQuiet: DispatchSourceTimer?
    private var launched = false

    /// Agents count as finished after this long without a sign of work (and no busy build).
    static let agentsQuietAfter: TimeInterval = 180

    /// Follows the plugins: what's watched, what's scheduled, which cards refresh.
    func refresh() {
        let active = plugins.plugins.filter { plugins.isOn($0) }
        let triggered = active.filter(\.hasAction)
        let wanted = Set(triggered.flatMap { $0.triggers.map(\.event) })
        if wanted != watching { watch(wanted) }
        reschedule(triggered)
        refreshCardTimers(active)
        AppModel.shared.awake?.onPluginEvent = { [weak self] event, info in self?.fire(event, info: info) }
        if !launched {
            launched = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                MainActor.assumeIsolated { self?.fire(.launch) }
            }
        }
    }

    // MARK: Firing

    /// Runs every plugin switched on with a trigger for `event` that `match` accepts.
    func fire(_ event: PluginEvent, info: String? = nil, where match: (PluginTrigger) -> Bool = { _ in true }) {
        for plugin in plugins.plugins where plugins.isOn(plugin) && plugin.hasAction {
            guard plugin.triggers.contains(where: { $0.event == event && match($0) }) else { continue }
            plugins.run(plugin, reason: .trigger, event: event.rawValue, info: info)
        }
    }

    /// A custom event, from `tutto://do/event?name=…&info=…` (a script, a build, an agent's hook).
    func fireCustom(name: String, info: String?) {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return }
        var ran = 0
        for plugin in plugins.plugins where plugins.isOn(plugin) && plugin.hasAction {
            guard plugin.triggers.contains(where: { $0.event == .custom && ($0.name ?? "").caseInsensitiveCompare(wanted) == .orderedSame }) else { continue }
            plugins.run(plugin, reason: .trigger, event: wanted, info: info)
            ran += 1
        }
        pluginLog.notice("event \(wanted, privacy: .public): \(ran) plugin(s)")
    }

    // MARK: Cards

    /// A card came on screen or went away (the panel opening or closing, the preview).
    func card(_ id: UUID, shown isShown: Bool) {
        shown[id] = max(0, (shown[id] ?? 0) + (isShown ? 1 : -1))
        if shown[id] == 0 { shown[id] = nil }
        if isShown, let plugin = plugins.plugin(id), let widget = plugin.widget {
            let updated = plugins.cards[id]?.updated
            if updated.map({ Date().timeIntervalSince($0) >= widget.interval(background: false) }) ?? true {
                plugins.refreshCard(plugin)
            }
        }
        guard !plugins.quiet else { return }
        refreshCardTimers(plugins.plugins.filter { plugins.isOn($0) })
    }

    private func refreshCardTimers(_ active: [ScriptPlugin]) {
        var wanted: [UUID: Double] = [:]
        for plugin in active where plugin.hasWidget {
            guard let widget = plugin.widget else { continue }
            let onScreen = shown[plugin.id] != nil
            guard onScreen || widget.background else { continue }
            wanted[plugin.id] = widget.interval(background: !onScreen)
        }
        for (id, entry) in cardTimers where wanted[id] != entry.interval {
            entry.timer.cancel()
            cardTimers[id] = nil
        }
        for (id, interval) in wanted where cardTimers[id] == nil {
            if plugins.cards[id]?.updated == nil, let plugin = plugins.plugin(id) { plugins.refreshCard(plugin) }
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(Int(interval * 100)))
            timer.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let plugin = self.plugins.plugin(id) else { return }
                    self.plugins.refreshCard(plugin)
                }
            }
            timer.resume()
            cardTimers[id] = (interval, timer)
        }
    }

    // MARK: Sources

    private func watch(_ wanted: Set<PluginEvent>) {
        stopWatching()
        watching = wanted
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        func on(_ center: NotificationCenter, _ name: Notification.Name, _ handle: @escaping @MainActor () -> Void) {
            tokens.append((center, center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { handle() }
            }))
        }
        func onApp(_ name: Notification.Name, _ event: PluginEvent) {
            tokens.append((workspace, workspace.addObserver(forName: name, object: nil, queue: .main) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let bundle = app?.bundleIdentifier, appName = app?.localizedName
                MainActor.assumeIsolated { [weak self] in self?.appEvent(event, bundle: bundle, name: appName) }
            }))
        }
        if wanted.contains(.wake) {
            on(workspace, NSWorkspace.didWakeNotification) { [weak self] in self?.fire(.wake) }
        }
        if wanted.contains(.sleep) {
            on(workspace, NSWorkspace.willSleepNotification) { [weak self] in self?.fire(.sleep) }
        }
        if wanted.contains(.lock) {
            on(distributed, Notification.Name("com.apple.screenIsLocked")) { [weak self] in self?.fire(.lock) }
        }
        if wanted.contains(.unlock) {
            on(distributed, Notification.Name("com.apple.screenIsUnlocked")) { [weak self] in self?.fire(.unlock) }
        }
        if wanted.contains(.appLaunched) { onApp(NSWorkspace.didLaunchApplicationNotification, .appLaunched) }
        if wanted.contains(.appQuit) { onApp(NSWorkspace.didTerminateApplicationNotification, .appQuit) }
        if wanted.contains(.appActivated) { onApp(NSWorkspace.didActivateApplicationNotification, .appActivated) }
        if !wanted.isDisjoint(with: [.powerConnected, .powerDisconnected, .batteryBelow]) { startPower() }
        if wanted.contains(.clipboardChanged) { startClipboard() }
        if wanted.contains(.networkChanged) { startNetwork() }
        if wanted.contains(.displayChanged) {
            screenCount = NSScreen.screens.count
            on(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { [weak self] in self?.screensChanged() }
        }
        if !wanted.isDisjoint(with: [.agentsStarted, .agentsFinished]) { startAgents() }
        if !wanted.isEmpty {
            pluginLog.notice("watching \(wanted.map(\.rawValue).sorted().joined(separator: ", "), privacy: .public)")
        }
    }

    private func stopWatching() {
        for entry in tokens { entry.center.removeObserver(entry.token) }
        tokens.removeAll()
        if let powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes)
            self.powerSource = nil
        }
        lastPower = nil
        batteryWatches.removeAll()
        pathMonitor?.cancel()
        pathMonitor = nil
        lastNetwork = nil
        networkDebounce?.cancel()
        clipboardTimer?.cancel()
        clipboardTimer = nil
        agentWatcher?.stop()
        agentWatcher = nil
        agentsQuiet?.cancel()
        agentsQuiet = nil
        agentsSince = nil
        watching = []
    }

    private func appEvent(_ event: PluginEvent, bundle: String?, name: String?) {
        if event == .appActivated, bundle == Bundle.main.bundleIdentifier { return }
        fire(event, info: bundle ?? name) { $0.matches(bundleID: bundle, appName: name) }
    }

    // Power: the system says when a power source changes (plugged in, unplugged, charge moved).
    private func startPower() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let host = Unmanaged<PluginHost>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { host.powerChanged() }
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        powerSource = source
        powerChanged()
    }

    private func powerChanged() {
        let now = PowerSourceNow.read()
        defer { lastPower = now }
        if let last = lastPower, last.onBattery != now.onBattery {
            fire(now.onBattery ? .powerDisconnected : .powerConnected, info: now.charge.map(String.init))
        }
        guard let charge = now.charge else { return }
        for plugin in plugins.plugins where plugins.isOn(plugin) && plugin.hasAction {
            for (index, trigger) in plugin.triggers.enumerated() where trigger.event == .batteryBelow {
                let key = "\(plugin.id.uuidString)#\(index)"
                var watch = batteryWatches[key] ?? BatteryWatch()
                let fires = watch.update(charge: charge, onBattery: now.onBattery, below: trigger.percent ?? 20)
                batteryWatches[key] = watch
                if fires { plugins.run(plugin, reason: .trigger, event: PluginEvent.batteryBelow.rawValue, info: String(charge)) }
            }
        }
    }

    // The clipboard has no notification: its change count is read every 0.75 s, only while a
    // plugin asks. Tutto's own copies and private ones (passwords) are skipped.
    private func startClipboard() {
        lastPasteboard = NSPasteboard.general.changeCount
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.75, repeating: 0.75, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.checkClipboard() } }
        timer.resume()
        clipboardTimer = timer
    }

    private func checkClipboard() {
        let pasteboard = NSPasteboard.general
        let count = pasteboard.changeCount
        guard count != lastPasteboard else { return }
        lastPasteboard = count
        guard count != plugins.ownPasteboardChange else { return }
        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        guard types.isDisjoint(with: ClipboardModule.skipTypes) else { return }
        fire(.clipboardChanged)
    }

    private func startNetwork() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let kind = Self.kind(of: path)
            let signature = kind + "|" + path.gateways.map { "\($0)" }.joined(separator: ",")
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.networkChanged(kind: kind, signature: signature) } }
        }
        monitor.start(queue: DispatchQueue(label: "ca.bryanyao.Tutto.plugins.network", qos: .utility))
        pathMonitor = monitor
    }

    nonisolated private static func kind(of path: NWPath) -> String {
        guard path.status == .satisfied else { return "none" }
        if path.usesInterfaceType(.wifi) { return "wifi" }
        if path.usesInterfaceType(.wiredEthernet) { return "ethernet" }
        if path.usesInterfaceType(.cellular) { return "cellular" }
        return "other"
    }

    private func networkChanged(kind: String, signature: String) {
        defer { lastNetwork = signature }
        // The first report is how things are, not a change.
        guard let last = lastNetwork, last != signature else { return }
        networkDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.fire(.networkChanged, info: kind) } }
        networkDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func screensChanged() {
        let count = NSScreen.screens.count
        guard count != screenCount else { return }
        screenCount = count
        fire(.displayChanged, info: String(count))
    }

    // Agents: the same signs Stay Awake reads (writes to their session logs), with its own watcher.
    private func startAgents() {
        let watcher = AgentWatcher()
        watcher.onActivity = { [weak self] in self?.agentActivity() }
        watcher.start()
        agentWatcher = watcher
    }

    private func agentActivity() {
        if agentsSince == nil {
            agentsSince = Date()
            _ = agentWatcher?.toolsBusy()  // the starting reading
            fire(.agentsStarted)
        }
        armAgentsQuiet()
    }

    private func armAgentsQuiet() {
        agentsQuiet?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.agentsQuietAfter, leeway: .seconds(10))
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.agentsMaybeDone() } }
        timer.resume()
        agentsQuiet = timer
    }

    private func agentsMaybeDone() {
        guard let since = agentsSince else { return }
        // A build or test run they started counts as work, though it writes nothing to the log.
        if agentWatcher?.toolsBusy() == true { return armAgentsQuiet() }
        agentsSince = nil
        agentsQuiet = nil
        fire(.agentsFinished, info: String(max(1, Int(Date().timeIntervalSince(since) / 60))))
    }

    // MARK: Schedules

    private func reschedule(_ triggered: [ScriptPlugin]) {
        var wanted: [String: (plugin: UUID, trigger: PluginTrigger)] = [:]
        for plugin in triggered {
            for (index, trigger) in plugin.triggers.enumerated() where trigger.event == .every || trigger.event == .daily {
                wanted["\(plugin.id.uuidString)#\(index)#\(trigger.minutes ?? 0)#\(trigger.at ?? "")"] = (plugin.id, trigger)
            }
        }
        for key in schedules.keys where wanted[key] == nil {
            schedules.removeValue(forKey: key)?.cancel()
        }
        for (key, entry) in wanted where schedules[key] == nil {
            arm(key, plugin: entry.plugin, trigger: entry.trigger)
        }
    }

    private func arm(_ key: String, plugin id: UUID, trigger: PluginTrigger) {
        guard let next = PluginSchedule.next(trigger, after: Date()) else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(wallDeadline: .now() + max(next.timeIntervalSinceNow, 1),
                       leeway: .seconds(trigger.event == .every ? 15 : 5))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.schedules[key] != nil else { return }
                self.schedules[key]?.cancel()
                self.schedules[key] = nil
                if let plugin = self.plugins.plugin(id), self.plugins.isOn(plugin) {
                    self.plugins.run(plugin, reason: .trigger, event: trigger.event.rawValue)
                }
                self.arm(key, plugin: id, trigger: trigger)
            }
        }
        timer.resume()
        schedules[key] = timer
    }
}
