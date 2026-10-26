//
//  SystemMonitor.swift
//  Tutto
//
//  Live system readings for whatever is on screen right now. Views register what they
//  show (`SystemFeed`) while visible; with no viewers there is no timer, no `top`,
//  nothing. That is the whole battery story of the System module.
//

import Foundation
import Observation
import SwiftUI
import TuttoKit

enum SystemFeed: Hashable, CaseIterable {
    /// CPU, GPU, memory, disk, network, battery numbers (1 Hz).
    case load
    /// Every mounted volume (refreshed every 10 s).
    case volumes
    /// Top processes by energy impact (a streaming `top`).
    case energyProcesses
    case cpuProcesses
    case memoryProcesses
}

@MainActor
@Observable
final class SystemMonitor {
    static let historyLength = 60

    private(set) var cpu: CPUUsage = .zero
    private(set) var cpuHistory: [Double] = []
    private(set) var gpu: GPUStats?
    private(set) var gpuHistory: [Double] = []
    private(set) var memory: MemoryStats?
    private(set) var memoryHistory: [Double] = []
    private(set) var rootVolume: VolumeStats?
    private(set) var volumes: [VolumeStats] = []
    private(set) var diskRead: Double?
    private(set) var diskWrite: Double?
    private(set) var networkIn: Double?
    private(set) var networkOut: Double?
    private(set) var networkHistory: [Double] = []
    private(set) var networkInterface: NetworkInterfaceInfo?
    private(set) var battery: BatteryInfo?
    private(set) var loadAverage: [Double] = []
    private(set) var energyProcesses: [ProcessSample] = []
    private(set) var cpuProcesses: [ProcessSample] = []
    private(set) var memoryProcesses: [ProcessSample] = []

    private var watchers: [SystemFeed: Int] = [:]
    private var timer: DispatchSourceTimer?
    private var tick = 0
    private var lastTicks: [CPUTicks] = []
    private var diskReadMeter = RateMeter()
    private var diskWriteMeter = RateMeter()
    private var netInMeter = RateMeter()
    private var netOutMeter = RateMeter()
    private var streams: [SystemFeed: TopProcessStream] = [:]

    var isSampling: Bool { timer != nil }

    /// Desktops have no battery; decided once.
    let hasBattery: Bool

    init() {
        // One cheap read up front so views lay out at their final size the first time they
        // appear (the menu bar window doesn't grow later).
        let initial = BatteryReader.read()
        hasBattery = initial != nil
        battery = initial
        memory = MemoryReader.read()
        gpu = GPUReader.read().first
        rootVolume = DiskReader.rootVolume()
    }

    /// What the menu bar panel needs while it's open: the 1 Hz numbers, no process list (that
    /// runs `top`, and lives on the Battery, CPU and Memory pages).
    var panelFeeds: Set<SystemFeed> { [.load] }

    // MARK: Watching

    func begin(_ feeds: Set<SystemFeed>) {
        let wasWatchingVolumes = watching(.volumes)
        for feed in feeds { watchers[feed, default: 0] += 1 }
        update()
        // The slow readings otherwise wait for the 10th tick; a page that just opened shouldn't.
        if watching(.volumes) && !wasWatchingVolumes { sampleSlow() }
    }

    func end(_ feeds: Set<SystemFeed>) {
        for feed in feeds { watchers[feed] = max(0, (watchers[feed] ?? 0) - 1) }
        update()
    }

    /// Module switched off: drop everything.
    func stopAll() {
        watchers.removeAll()
        update()
    }

    private func watching(_ feed: SystemFeed) -> Bool { (watchers[feed] ?? 0) > 0 }

    private func update() {
        let wantsLoad = watching(.load) || watching(.volumes)
        if wantsLoad && timer == nil {
            startTimer()
        } else if !wantsLoad, let timer {
            timer.cancel()
            self.timer = nil
            lastTicks = []
            diskReadMeter.reset()
            diskWriteMeter.reset()
            netInMeter.reset()
            netOutMeter.reset()
        }
        for feed in [SystemFeed.energyProcesses, .cpuProcesses, .memoryProcesses] {
            if watching(feed), streams[feed] == nil {
                let sort: TopProcessStream.SortKey = feed == .energyProcesses ? .power : (feed == .cpuProcesses ? .cpu : .mem)
                let stream = TopProcessStream(sort: sort, count: feed == .energyProcesses ? 5 : 8, interval: 2) { [weak self] rows in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.receive(rows, for: feed) }
                    }
                }
                stream.start()
                streams[feed] = stream
            } else if !watching(feed), let stream = streams.removeValue(forKey: feed) {
                stream.stop()
            }
        }
    }

    private func receive(_ rows: [ProcessSample], for feed: SystemFeed) {
        guard streams[feed] != nil else { return }  // stopped meanwhile
        switch feed {
        case .energyProcesses: energyProcesses = rows.sorted { $0.energyImpact > $1.energyImpact }
        case .cpuProcesses: cpuProcesses = rows
        case .memoryProcesses: memoryProcesses = rows
        default: break
        }
    }

    private func startTimer() {
        lastTicks = CPUReader.ticks()
        tick = 0
        sampleSlow()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // First reading after a quarter second so numbers appear almost at once, then every second.
        timer.schedule(deadline: .now() + 0.25, repeating: 1.0, leeway: .milliseconds(150))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer.resume()
        self.timer = timer
    }

    // MARK: Sampling

    private func sample() {
        tick += 1
        let now = CPUReader.ticks()
        if !lastTicks.isEmpty {
            cpu = CPUReader.usage(from: lastTicks, to: now)
            push(cpu.total, into: &cpuHistory)
        }
        lastTicks = now

        if let gpu = GPUReader.read().first {
            self.gpu = gpu
            push(gpu.utilization ?? 0, into: &gpuHistory)
        }
        if let memory = MemoryReader.read() {
            self.memory = memory
            push(memory.usedFraction, into: &memoryHistory)
        }
        let time = ProcessInfo.processInfo.systemUptime
        let disk = DiskReader.counters()
        diskRead = diskReadMeter.rate(disk.bytesRead, at: time)
        diskWrite = diskWriteMeter.rate(disk.bytesWritten, at: time)
        let network = NetworkReader.counters()
        networkIn = netInMeter.rate(network.received, at: time)
        networkOut = netOutMeter.rate(network.sent, at: time)
        if let networkIn, let networkOut {
            // Log scale so a page load and a big download both read on the same little chart.
            let total = networkIn + networkOut
            push(total > 0 ? min(log10(total + 1) / 8, 1) : 0, into: &networkHistory)
        }
        // The battery gauge refreshes its registry entry every few seconds; reading faster gains nothing.
        if tick % 5 == 0 { battery = BatteryReader.read() }
        loadAverage = CPUReader.loadAverage()
        if tick % 10 == 0 { sampleSlow() }
    }

    /// Things that change slowly: battery, volumes, addresses.
    private func sampleSlow() {
        battery = BatteryReader.read()
        if watching(.volumes) {
            volumes = DiskReader.volumes()
            rootVolume = volumes.first(where: \.isRoot) ?? volumes.first
        } else {
            rootVolume = DiskReader.rootVolume()
        }
        networkInterface = NetworkReader.primaryInterface()
        loadAverage = CPUReader.loadAverage()
        if gpu == nil { gpu = GPUReader.read().first }
        if memory == nil { memory = MemoryReader.read() }
    }

    private func push(_ value: Double, into history: inout [Double]) {
        history.append(value)
        if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
    }
}

extension View {
    /// Keeps `feeds` live while this view is actually on screen.
    func watching(_ monitor: SystemMonitor?, _ feeds: Set<SystemFeed>) -> some View {
        background(VisibilityReader { visible in
            guard let monitor else { return }
            if visible { monitor.begin(feeds) } else { monitor.end(feeds) }
        })
    }
}
