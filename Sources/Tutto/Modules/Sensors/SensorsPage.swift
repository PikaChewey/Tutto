//
//  SensorsPage.swift
//  Tutto
//

import AppKit
import ServiceManagement
import SwiftUI
import TuttoKit

struct SensorsPage: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Sensors & Fans", subtitle: "Every temperature sensor macOS exposes, and your fans — with control for heavy work.",
                       module: .sensors)
            if let sensors = model.sensors {
                SensorsContent(sensors: sensors)
                    .background(VisibilityReader { visible in visible ? sensors.begin() : sensors.end() })
            } else {
                ModuleOffView(module: .sensors, model: model)
            }
        }
    }
}

private struct SensorsContent: View {
    @Bindable var sensors: SensorsModule

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let summary = sensors.summary {
                HStack(alignment: .bottom, spacing: 28) {
                    temperature("CPU", summary.cpuAverage, hottest: summary.cpuHottest)
                    temperature("GPU", summary.gpuAverage, hottest: summary.gpuHottest)
                    temperature("SoC die", summary.socAverage, hottest: summary.socHottest)
                    temperature("Battery", summary.batteryAverage, hottest: nil)
                    temperature("SSD", summary.ssd, hottest: nil)
                    Spacer()
                }
            }
            if sensors.hasFans {
                ForEach(sensors.fans) { fan in
                    FanControlView(sensors: sensors, fan: fan)
                }
            } else {
                InkGroup("Fans") {
                    Text("This Mac has no fans (it's cooled passively), so there's nothing to control.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.ink2)
                        .padding(.vertical, 8)
                }
            }
            SensorList(readings: sensors.temperatures)
            Text(TemperatureSensors.mappingDescription + " Sensors macOS reports with impossible values are hidden.")
                .font(.system(size: 11))
                .foregroundStyle(Color.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func temperature(_ caption: String, _ average: Double?, hottest: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Readout(caption: caption, value: average.map { String(format: "%.0f", $0) } ?? "—", unit: average == nil ? nil : "°C", large: true)
            if let hottest {
                Text("hottest \(Format.temperature(hottest))")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Color.ink3)
            }
        }
    }
}

private struct FanControlView: View {
    @Bindable var sensors: SensorsModule
    var fan: FanReading
    @State private var customRPM: Double = 0

    private enum Choice: Hashable { case auto, custom, maximum }

    private var choice: Choice {
        switch sensors.commands[fan.index] {
        case .none, .auto?: .auto
        case .rpm?: .custom
        case .maximum?: .maximum
        }
    }

    var body: some View {
        InkGroup(sensors.fanCount > 1 ? "Fan \(fan.index + 1)" : "Fan") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 24) {
                    FanGlyph(spinning: !fan.isStopped)
                    Readout(caption: "Speed", value: fan.isStopped ? "Off" : Format.number(Int(fan.currentRPM)),
                            unit: fan.isStopped ? nil : "rpm", large: true)
                    Readout(caption: "Range", value: "\(Format.number(Int(fan.minRPM)))–\(Format.number(Int(fan.maxRPM)))", unit: "rpm")
                    Readout(caption: "Control", value: fan.mode == .manual ? "Manual" : "Automatic")
                    Spacer()
                    InkSegmented(selection: Binding(get: { choice }, set: { select($0) }),
                                 options: [(Choice.auto, "Auto"), (.custom, "Custom"), (.maximum, "Max")],
                                 help: { option in
                                     switch option {
                                     case .auto: "macOS controls the fan (recommended)"
                                     case .custom: "Hold a speed you choose"
                                     case .maximum: "Full speed, for long renders or games"
                                     }
                                 })
                }
                if choice == .custom {
                    HStack(spacing: 12) {
                        Caption("\(Format.number(Int(fan.minRPM)))", uppercase: false)
                        Slider(value: $customRPM, in: fan.minRPM...fan.maxRPM, step: 100) { editing in
                            if !editing { sensors.set(.rpm(customRPM), for: fan) }
                        }
                        .controlSize(.small)
                        Caption("\(Format.number(Int(fan.maxRPM)))", uppercase: false)
                        Text("\(Format.number(Int(customRPM))) rpm")
                            .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                            .frame(width: 80, alignment: .trailing)
                    }
                    .transition(.opacity)
                }
                helperStatus
                Text("Fans return to automatic when you quit Tutto, when the Mac sleeps, when Sensors is turned off, or if Tutto stops unexpectedly.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 10)
            .animation(Motion.snappy, value: choice)
        }
        .onAppear { customRPM = fan.minRPM + (fan.maxRPM - fan.minRPM) / 2 }
    }

    private func select(_ choice: Choice) {
        switch choice {
        case .auto: sensors.set(.auto, for: fan)
        case .custom: sensors.set(.rpm(customRPM), for: fan)
        case .maximum: sensors.set(.maximum, for: fan)
        }
    }

    @ViewBuilder
    private var helperStatus: some View {
        if sensors.helperStatus != .enabled {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "lock").foregroundStyle(Color.ink2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(sensors.helperStatus == .requiresApproval ? "Approve the fan helper" : "Fan control needs a small helper")
                        .font(.system(size: 12.5, weight: .medium))
                    Text(sensors.helperMessage ?? "Only root can change fan speeds on a Mac. Tutto installs a 200 KB helper that does just that and runs only while you control a fan. Reading speeds and temperatures never needs it.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(sensors.helperStatus == .requiresApproval ? "Open Settings" : "Install Helper") {
                    if sensors.helperStatus == .requiresApproval {
                        SMAppService.openSystemSettingsLoginItems()
                    } else {
                        sensors.installHelper()
                    }
                }
                .buttonStyle(InkButtonStyle(compact: true))
            }
            .padding(12)
            .background(Color.wash, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else if let message = sensors.helperMessage {
            Text(message).font(.system(size: 11.5)).foregroundStyle(Color.ink2)
        }
    }
}

/// A fan glyph: filled while it spins, hollow when stopped. Deliberately static —
/// nothing in Tutto animates continuously.
private struct FanGlyph: View {
    var spinning: Bool

    var body: some View {
        Image(systemName: spinning ? "fan.fill" : "fan")
            .font(.system(size: 26, weight: .light))
            .foregroundStyle(Color.ink)
            .frame(width: 34)
            .accessibilityHidden(true)
    }
}

private struct SensorList: View {
    var readings: [TemperatureReading]

    var body: some View {
        let groups = Dictionary(grouping: readings, by: \.group)
        let order = TemperatureGroup.allCases.filter { groups[$0] != nil }
        InkGroup("All sensors", trailing: AnyView(Caption("\(readings.count) sensors"))) {
            if readings.isEmpty {
                Text("Reading sensors…").font(.system(size: 12)).foregroundStyle(Color.ink4).padding(.vertical, 8)
            }
            ForEach(order, id: \.self) { group in
                VStack(alignment: .leading, spacing: 4) {
                    Caption(group.title).padding(.top, 8)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 24), GridItem(.flexible(), spacing: 24)], spacing: 0) {
                        ForEach(groups[group] ?? []) { reading in
                            HStack {
                                Text(reading.label).font(.system(size: 12)).foregroundStyle(Color.ink2).lineLimit(1)
                                Spacer()
                                Text(String(format: "%.1f °C", reading.celsius))
                                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                                    .foregroundStyle(reading.celsius >= 95 ? Color.alert : Color.ink)
                            }
                            .frame(height: 24)
                            .help(reading.name)
                        }
                    }
                }
            }
        }
    }
}

/// One line in the menu bar panel: the temperatures people check, and the fan.
struct SensorsLine: View {
    var sensors: SensorsModule

    var body: some View {
        Button {
            MainWindowController.shared.show(page: .sensors)
        } label: {
            HStack(spacing: 12) {
                Caption("Temp")
                if let summary = sensors.summary {
                    value("CPU", summary.cpuAverage ?? summary.socAverage)
                    value("GPU", summary.gpuAverage)
                    value("BAT", summary.batteryAverage)
                } else {
                    Text("Reading…").font(.system(size: 11.5)).foregroundStyle(Color.ink4)
                }
                Spacer()
                if let fan = sensors.fans.first {
                    Image(systemName: "fan").font(.system(size: 10.5)).foregroundStyle(Color.ink3)
                    Text(fan.isStopped ? "off" : "\(Format.number(Int(fan.currentRPM))) rpm")
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(sensors.isManual ? Color.ink : Color.ink2)
                }
            }
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Sensors & Fans")
        .background(VisibilityReader { visible in visible ? sensors.begin() : sensors.end() })
    }

    private func value(_ label: String, _ celsius: Double?) -> some View {
        HStack(spacing: 3) {
            Text(label).font(.mono(9.5)).foregroundStyle(Color.ink3)
            Text(Format.temperature(celsius))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle((celsius ?? 0) >= 95 ? Color.alert : Color.ink)
                .contentTransition(.numericText())
        }
    }
}
