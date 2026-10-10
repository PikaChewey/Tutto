//
//  SystemPages.swift
//  Tutto
//
//  Battery, CPU, GPU, memory, disk and network in depth. Each page keeps only the
//  readings it shows alive, and only while it's on screen.
//

import SwiftUI
import TuttoKit

/// Shared wrapper: header, then either the page or the "module is off" card.
private struct SystemPage<Content: View>: View {
    var model: AppModel
    var title: String
    var subtitle: String
    var feeds: Set<SystemFeed>
    @ViewBuilder var content: (SystemMonitor) -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: title, subtitle: subtitle, module: .system)
            if let monitor = model.system {
                VStack(alignment: .leading, spacing: 22) {
                    content(monitor)
                }
                .watching(monitor, feeds)
            } else {
                ModuleOffView(module: .system, model: model)
            }
        }
    }
}

/// A large chart of the last minute.
struct HistoryChart: View {
    var values: [Double]
    var height: CGFloat = 64

    var body: some View {
        VStack(spacing: 4) {
            Sparkline(values: values, capacity: SystemMonitor.historyLength)
                .frame(height: height)
                .overlay(alignment: .top) { Hairline().opacity(0.6) }
                .overlay(alignment: .bottom) { Hairline() }
            HStack {
                Caption("60 s ago", uppercase: false)
                Spacer()
                Caption("now", uppercase: false)
            }
        }
    }
}

/// A row in a readout table: label left, monospaced value right.
struct ValueRow: View {
    var label: String
    var value: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.ink2)
            Spacer(minLength: 12)
            if let detail {
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.ink3)
            }
            Text(value)
                .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Color.ink)
        }
        .frame(minHeight: 28)
        .overlay(alignment: .bottom) { Hairline().opacity(0.6) }
        .accessibilityElement(children: .combine)
    }
}

struct ProcessTable: View {
    var title: String
    var processes: [ProcessSample]
    var value: (ProcessSample) -> String
    var valueCaption: String

    var body: some View {
        InkGroup(title, trailing: AnyView(Caption(valueCaption))) {
            if processes.isEmpty {
                Text("Measuring…")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.ink4)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            } else {
                ForEach(processes) { process in
                    ProcessRow(process: process, value: value(process))
                        .frame(height: 26)
                }
            }
        }
    }
}

// MARK: - Battery

struct BatteryPage: View {
    var model: AppModel

    var body: some View {
        SystemPage(model: model, title: "Battery", subtitle: "Health, charge and power, read straight from the battery.",
                   feeds: [.stats, .energyProcesses]) { monitor in
            if let battery = monitor.battery {
                hero(battery)
                HStack(alignment: .top, spacing: 18) {
                    InkGroup("Health") {
                        ValueRow(label: "Maximum capacity", value: "\(Format.percent(battery.health, digits: 1))%",
                                 detail: "of when it was new")
                        ValueRow(label: "Full charge holds", value: "\(Format.number(battery.maxCapacity)) mAh")
                        ValueRow(label: "Designed to hold", value: "\(Format.number(battery.designCapacity)) mAh")
                        if let raw = battery.rawMaxCapacity {
                            ValueRow(label: "Gas gauge reading", value: "\(Format.number(raw)) mAh")
                        }
                        ValueRow(label: "Cycle count", value: Format.number(battery.cycleCount),
                                 detail: battery.designCycleCount.map { "rated for \(Format.number($0))" })
                        ValueRow(label: "Condition", value: battery.condition ?? "—")
                    }
                    InkGroup("Power") {
                        ValueRow(label: battery.isPluggedIn ? "Mac is using" : "Draining at",
                                 value: "\(Format.watts(battery.powerDraw)) W")
                        if let power = battery.batteryPower {
                            ValueRow(label: power >= 0 ? "Into the battery" : "From the battery",
                                     value: "\(Format.watts(abs(power))) W")
                        }
                        ValueRow(label: "Voltage", value: battery.voltage.map { String(format: "%.2f V", $0) } ?? "—")
                        ValueRow(label: "Current", value: battery.amperage.map { String(format: "%.2f A", $0) } ?? "—")
                        ValueRow(label: "Temperature", value: battery.temperature.map { String(format: "%.1f °C", $0) } ?? "—")
                        if let name = battery.adapterName {
                            ValueRow(label: "Adapter", value: battery.adapterWatts.map { "\($0) W" } ?? "—", detail: name)
                        }
                    }
                }
                ProcessTable(title: "Using energy now", processes: monitor.energyProcesses,
                             value: { String(format: "%.1f", $0.energyImpact) }, valueCaption: "energy impact")
                Text("Energy impact is Activity Monitor's measure of how much power an app is using right now, including CPU, GPU, disk and wake-ups.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ink3)
            } else {
                Text("This Mac has no battery.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.ink2)
            }
        }
    }

    private func hero(_ battery: BatteryInfo) -> some View {
        HStack(alignment: .center, spacing: 18) {
            BatteryGlyph(level: Double(battery.percent) / 100, charging: battery.isCharging,
                         alert: battery.percent <= 10 && !battery.isPluggedIn)
                .scaleEffect(1.6)
                .frame(width: 64)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(battery.percent)")
                        .font(.system(size: 40, weight: .semibold).monospacedDigit())
                        .contentTransition(.numericText(value: Double(battery.percent)))
                    Text("%").font(.system(size: 18, weight: .medium)).foregroundStyle(Color.ink3)
                }
                Text([battery.stateText, Format.minutes(battery.minutesToEmpty).map { "\($0) left" },
                      Format.minutes(battery.minutesToFull).map { "full in \($0)" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.ink3)
            }
            Spacer()
            HStack(spacing: 28) {
                Readout(caption: "Health", value: Format.percent(battery.health, digits: 1), unit: "%", large: true)
                Readout(caption: "Cycles", value: Format.number(battery.cycleCount), large: true)
                Readout(caption: "Power", value: Format.watts(battery.powerDraw), unit: "W", large: true)
            }
        }
    }
}

// MARK: - CPU

struct CPUPage: View {
    var model: AppModel

    var body: some View {
        SystemPage(model: model, title: "CPU", subtitle: CPUReader.topology.brand, feeds: [.stats, .cpuProcesses]) { monitor in
            HStack(alignment: .bottom, spacing: 28) {
                Readout(caption: "Total", value: Format.percent(monitor.cpu.total), unit: "%", large: true)
                Readout(caption: "User", value: Format.percent(monitor.cpu.user), unit: "%", large: true)
                Readout(caption: "System", value: Format.percent(monitor.cpu.system), unit: "%", large: true)
                Readout(caption: "Load (1 min)", value: monitor.loadAverage.first.map { String(format: "%.2f", $0) } ?? "—", large: true)
                Spacer()
            }
            HistoryChart(values: monitor.cpuHistory)
            CoreGrid(usage: monitor.cpu.perCore)
            ProcessTable(title: "Using the CPU", processes: monitor.cpuProcesses,
                         value: { String(format: "%.1f%%", $0.cpu) }, valueCaption: "% of one core")
        }
    }
}

private struct CoreGrid: View {
    var usage: [Double]

    var body: some View {
        let topology = CPUReader.topology
        HStack(alignment: .top, spacing: 18) {
            cluster("\(topology.performanceName) cores", kind: .performance, topology: topology)
            cluster("\(topology.efficiencyName) cores", kind: .efficiency, topology: topology)
        }
    }

    private func cluster(_ title: String, kind: CoreKind, topology: CPUTopology) -> some View {
        let indices = topology.kinds.indices.filter { topology.kinds[$0] == kind }
        return InkGroup("\(title) · \(indices.count)") {
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(indices, id: \.self) { index in
                    let value = index < usage.count ? usage[index] : 0
                    VStack(spacing: 4) {
                        GeometryReader { geo in
                            ZStack(alignment: .bottom) {
                                RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(Color.wash)
                                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                    .fill(Color.ink)
                                    .frame(height: max(2, geo.size.height * value))
                            }
                        }
                        .frame(height: 54)
                        Text(Format.percent(value))
                            .font(.mono(9.5))
                            .foregroundStyle(Color.ink3)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Core \(index + 1)")
                    .accessibilityValue("\(Format.percent(value)) percent")
                }
            }
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - GPU

struct GPUPage: View {
    var model: AppModel

    var body: some View {
        SystemPage(model: model, title: "GPU",
                   subtitle: model.system?.gpu.map { "\($0.model)\($0.cores.map { " · \($0) cores" } ?? "")" } ?? "Graphics",
                   feeds: [.stats]) { monitor in
            let gpu = monitor.gpu
            HStack(alignment: .bottom, spacing: 28) {
                Readout(caption: "Utilization", value: Format.percent(gpu?.utilization ?? 0), unit: "%", large: true)
                Readout(caption: "Renderer", value: Format.percent(gpu?.renderer ?? 0), unit: "%", large: true)
                Readout(caption: "Tiler", value: Format.percent(gpu?.tiler ?? 0), unit: "%", large: true)
                if let memory = gpu?.memoryInUse {
                    let parts = Format.bytesParts(Int64(memory), style: .memory)
                    Readout(caption: "Memory in use", value: parts.0, unit: parts.1, large: true)
                }
                Spacer()
            }
            HistoryChart(values: monitor.gpuHistory)
            Text("Apple silicon shares memory between the CPU and GPU, so GPU memory comes out of the same pool shown on the Memory page.")
                .font(.system(size: 11))
                .foregroundStyle(Color.ink3)
        }
    }
}

// MARK: - Memory

struct MemoryPage: View {
    var model: AppModel

    var body: some View {
        SystemPage(model: model, title: "Memory", subtitle: "Unified memory, as Activity Monitor counts it.",
                   feeds: [.stats, .memoryProcesses]) { monitor in
            if let memory = monitor.memory {
                HStack(alignment: .bottom, spacing: 28) {
                    let used = Format.bytesParts(Int64(memory.used), style: .memory)
                    Readout(caption: "Used", value: used.0, unit: used.1, large: true)
                    let total = Format.bytesParts(Int64(memory.total), style: .memory)
                    Readout(caption: "Installed", value: total.0, unit: total.1, large: true)
                    Readout(caption: "Pressure", value: memory.pressure.label, large: true)
                    let swap = Format.bytesParts(Int64(memory.swapUsed), style: .memory)
                    Readout(caption: "Swap", value: swap.0, unit: swap.1, large: true)
                    Spacer()
                }
                MemoryBar(memory: memory)
                HistoryChart(values: monitor.memoryHistory)
                ProcessTable(title: "Using memory", processes: monitor.memoryProcesses,
                             value: { Format.bytes($0.memory) }, valueCaption: "memory")
            }
        }
    }
}

private struct MemoryBar: View {
    var memory: MemoryStats

    var body: some View {
        let parts: [(String, UInt64, Double)] = [
            ("App", memory.app, 1), ("Wired", memory.wired, 0.7), ("Compressed", memory.compressed, 0.45),
            ("Cached files", memory.cached, 0.2),
        ]
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 1.5) {
                    ForEach(parts, id: \.0) { part in
                        Rectangle()
                            .fill(Color.ink.opacity(part.2))
                            .frame(width: max(0, geo.size.width * Double(part.1) / Double(max(memory.total, 1)) - 1.5))
                    }
                    Spacer(minLength: 0)
                }
                .background(Color.wash)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .frame(height: 12)
            HStack(spacing: 18) {
                ForEach(parts, id: \.0) { part in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.ink.opacity(part.2)).frame(width: 8, height: 8)
                        Text(part.0).font(.system(size: 11.5)).foregroundStyle(Color.ink2)
                        Text(Format.bytes(part.1)).font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    }
                }
            }
        }
    }
}

// MARK: - Disk

struct DiskPage: View {
    var model: AppModel

    var body: some View {
        SystemPage(model: model, title: "Disk", subtitle: "Free space and how fast your disks are working.",
                   feeds: [.stats, .volumes]) { monitor in
            HStack(alignment: .bottom, spacing: 28) {
                Readout(caption: "Reading", value: Format.rate(monitor.diskRead), large: true)
                Readout(caption: "Writing", value: Format.rate(monitor.diskWrite), large: true)
                Spacer()
            }
            InkGroup("Volumes") {
                ForEach(monitor.volumes) { volume in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: volume.isInternal ? "internaldrive" : "externaldrive")
                                .foregroundStyle(Color.ink2)
                            Text(volume.name).font(.system(size: 12.5, weight: .medium))
                            Spacer()
                            Text("\(Format.bytes(volume.available, style: .file)) free of \(Format.bytes(volume.total, style: .file))")
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(Color.ink2)
                        }
                        Meter(value: volume.usedFraction, height: 4, alert: volume.usedFraction > 0.95)
                    }
                    .padding(.vertical, 8)
                }
                if monitor.volumes.isEmpty {
                    Text("Reading volumes…").font(.system(size: 12)).foregroundStyle(Color.ink4).padding(.vertical, 8)
                }
            }
            Text("Free space includes purgeable files macOS clears on its own when it needs room, the same figure Finder shows.")
                .font(.system(size: 11))
                .foregroundStyle(Color.ink3)
        }
    }
}

// MARK: - Network

struct NetworkPage: View {
    var model: AppModel

    var body: some View {
        SystemPage(model: model, title: "Network", subtitle: "Throughput across Wi-Fi and Ethernet. Nothing is sent anywhere.",
                   feeds: [.stats]) { monitor in
            HStack(alignment: .bottom, spacing: 28) {
                Readout(caption: "Download", value: Format.rate(monitor.networkIn), large: true)
                Readout(caption: "Upload", value: Format.rate(monitor.networkOut), large: true)
                Spacer()
            }
            HistoryChart(values: monitor.networkHistory)
            InkGroup("Connection") {
                ValueRow(label: "Interface", value: monitor.networkInterface?.name ?? "Not connected")
                ValueRow(label: "Local address", value: monitor.networkInterface?.address ?? "—")
            }
        }
    }
}
