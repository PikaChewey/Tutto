//
//  MenuPanel.swift
//  Tutto
//
//  The menu bar panel: a glance at the battery and the machine, CornerClick's corner,
//  and one-click access to every tool. Each part appears only if its module is on.
//  Readings run only while this panel is open.
//

import AppKit
import SwiftUI
import TuttoKit

struct MenuPanel: View {
    @Bindable var model: AppModel
    @AppStorage("panel.cornerClickExpanded") private var cornerExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 10)

            if let system = model.system {
                if let battery = system.battery {
                    BatterySummary(battery: battery, monitor: system)
                        .padding(.bottom, 12)
                    Hairline().padding(.bottom, 10)
                }
                StatsStrip(monitor: system)
                    .padding(.bottom, model.sensors == nil ? 10 : 4)
                    .watching(system, system.panelFeeds)
            }
            if let sensors = model.sensors {
                if model.system == nil { Hairline().padding(.bottom, 6) }
                SensorsLine(sensors: sensors)
                    .padding(.bottom, 8)
            }

            if let cornerClick = model.cornerClick {
                Hairline().padding(.bottom, 8)
                CornerClickSection(module: cornerClick, expanded: $cornerExpanded)
                    .padding(.bottom, 10)
            }

            if hasQuickActions {
                Hairline().padding(.bottom, 8)
                QuickActions(model: model)
                    .padding(.bottom, 8)
            }

            Notices(model: model)

            Hairline().padding(.bottom, 6)
            footer
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(width: 320)
        .animation(Motion.smooth, value: cornerExpanded)
    }

    private var hasQuickActions: Bool {
        model.screenshots != nil || model.clipboard != nil || model.windows != nil
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(nsImage: MenuBarGlyph.image())
                .renderingMode(.template)
                .foregroundStyle(Color.ink)
                .accessibilityHidden(true)
            Text("Tutto")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.ink)
            Spacer()
        }
        .frame(height: 22)
    }

    private var footer: some View {
        HStack {
            Button("Open Tutto") { MainWindowController.shared.show() }
                .buttonStyle(FooterButtonStyle())
            Spacer()
            Menu {
                Toggle("Open at Login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                Button("Shortcuts…") { MainWindowController.shared.show(page: .shortcuts) }
                Button("Permissions…") { MainWindowController.shared.show(page: .permissions) }
                Divider()
                Button("Quit Tutto") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.ink2)
                    .frame(width: 28, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
            .accessibilityLabel("More")
        }
    }
}

private struct FooterButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(hovering ? Color.ink : Color.ink2)
            .padding(.vertical, 3)
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: - Battery

private struct BatterySummary: View {
    var battery: BatteryInfo
    var monitor: SystemMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                MainWindowController.shared.show(page: .battery)
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    BatteryGlyph(level: Double(battery.percent) / 100, charging: battery.isCharging,
                                 alert: battery.percent <= 10 && !battery.isPluggedIn)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(alignment: .firstTextBaseline, spacing: 1) {
                            Text("\(battery.percent)")
                                .font(.system(size: 24, weight: .semibold).monospacedDigit())
                                .contentTransition(.numericText(value: Double(battery.percent)))
                            Text("%")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.ink3)
                        }
                        Text(stateLine)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.ink3)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 1) {
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text(Format.watts(battery.powerDraw))
                                .font(.system(size: 17, weight: .medium).monospacedDigit())
                                .contentTransition(.numericText())
                            Text("W")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.ink3)
                        }
                        Caption(battery.isPluggedIn ? "system power" : "drain")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Battery \(battery.percent) percent, \(stateLine)")
            .help("Battery details")

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 0) {
                GridRow {
                    Readout(caption: "Health", value: Format.percent(battery.health), unit: "%")
                    Readout(caption: "Cycles", value: Format.number(battery.cycleCount))
                    VStack(alignment: .leading, spacing: 3) {
                        Caption("Max · Design")
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text("\(Format.number(battery.maxCapacity))")
                                .font(.system(size: 15, weight: .medium).monospacedDigit())
                            Text("/ \(Format.number(battery.designCapacity)) mAh")
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                .foregroundStyle(Color.ink3)
                        }
                        .lineLimit(1)
                    }
                    .gridCellColumns(1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Maximum capacity \(battery.maxCapacity) of \(battery.designCapacity) milliamp hours designed")
                }
            }

            EnergyList(processes: monitor.energyProcesses)
        }
    }

    private var stateLine: String {
        var parts = [battery.stateText]
        if let minutes = Format.minutes(battery.minutesToEmpty) { parts.append("\(minutes) left") }
        if let minutes = Format.minutes(battery.minutesToFull) { parts.append("full in \(minutes)") }
        return parts.joined(separator: " · ")
    }
}

/// Apps using the most energy right now (Activity Monitor's Energy Impact).
private struct EnergyList: View {
    var processes: [ProcessSample]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Caption("Using energy")
                Spacer()
                Caption("impact")
            }
            if processes.isEmpty {
                Text("Measuring…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.ink4)
                    .frame(height: 18 * 4, alignment: .topLeading)
            } else {
                ForEach(processes.prefix(4)) { process in
                    ProcessRow(process: process, value: String(format: "%.1f", process.energyImpact))
                }
            }
        }
        .animation(Motion.snappy, value: processes.map(\.pid))
    }
}

struct ProcessRow: View {
    var process: ProcessSample
    var value: String

    var body: some View {
        HStack(spacing: 7) {
            AppIcon(pid: process.pid)
                .frame(width: 14, height: 14)
            Text(process.name)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            Text(value)
                .font(.mono(11, weight: .medium))
                .foregroundStyle(Color.ink2)
                .contentTransition(.numericText())
        }
        .frame(height: 18)
        .accessibilityElement(children: .combine)
    }
}

/// The app's icon, or a quiet placeholder for background processes.
struct AppIcon: View {
    var pid: Int32

    var body: some View {
        if let icon = NSRunningApplication(processIdentifier: pid)?.icon {
            Image(nsImage: icon).resizable().interpolation(.high)
        } else {
            Image(systemName: "gearshape")
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color.ink4)
                .padding(1.5)
        }
    }
}

/// A battery drawn in hairlines, filled to its level.
struct BatteryGlyph: View {
    var level: Double
    var charging: Bool
    var alert = false

    var body: some View {
        HStack(spacing: 1.5) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.ink.opacity(0.55), lineWidth: 1.2)
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(alert ? Color.alert : Color.ink)
                        .frame(width: max(2, (geo.size.width) * min(max(level, 0), 1)))
                        .animation(Motion.snappy, value: level)
                }
                .padding(2.5)
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.paper)
                        .frame(maxWidth: .infinity)
                        .shadow(color: .black.opacity(0.25), radius: 0.5)
                }
            }
            .frame(width: 34, height: 17)
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(Color.ink.opacity(0.55))
                .frame(width: 2, height: 6)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - CPU / GPU / Memory / Disk

private struct StatsStrip: View {
    var monitor: SystemMonitor

    var body: some View {
        HStack(spacing: 0) {
            tile("CPU", value: monitor.cpu.total, history: monitor.cpuHistory, page: .cpu)
            divider
            tile("GPU", value: monitor.gpu?.utilization ?? 0, history: monitor.gpuHistory, page: .gpu)
            divider
            tile("Memory", value: monitor.memory?.usedFraction ?? 0, history: monitor.memoryHistory, page: .memory,
                 alert: monitor.memory?.pressure == .critical)
            divider
            diskTile
        }
        .frame(height: 50)
    }

    private var divider: some View {
        Hairline(vertical: true).padding(.vertical, 6)
    }

    private func tile(_ caption: String, value: Double, history: [Double], page: MainPage, alert: Bool = false) -> some View {
        Button {
            MainWindowController.shared.show(page: page)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Caption(caption)
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(Format.percent(value))
                        .font(.system(size: 15, weight: .medium).monospacedDigit())
                        .foregroundStyle(alert ? Color.alert : Color.ink)
                        .contentTransition(.numericText(value: value))
                    Text("%")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.ink3)
                }
                Meter(value: value, height: 2, alert: alert)
                    .padding(.top, 4)
                    .frame(height: 10, alignment: .top)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(caption) details")
        .accessibilityLabel("\(caption) \(Format.percent(value)) percent")
    }

    private var diskTile: some View {
        Button {
            MainWindowController.shared.show(page: .disk)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Caption("Disk")
                if let volume = monitor.rootVolume {
                    let parts = Format.diskParts(volume.available)
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(parts.0)
                            .font(.system(size: 15, weight: .medium).monospacedDigit())
                        Text(parts.1)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Color.ink3)
                    }
                    Meter(value: volume.usedFraction, height: 2, alert: volume.usedFraction > 0.95)
                        .padding(.top, 4)
                        .frame(height: 10, alignment: .top)
                } else {
                    Text("—").font(.system(size: 15, weight: .medium))
                }
            }
            .padding(.leading, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Free space on \(monitor.rootVolume?.name ?? "the startup disk")")
        .accessibilityLabel("Disk, \(monitor.rootVolume.map { Format.bytes($0.available, style: .file) } ?? "unknown") free")
    }
}

// MARK: - CornerClick

private struct CornerClickSection: View {
    @Bindable var module: CornerClickModule
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    expanded.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Caption("CornerClick")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color.ink3)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "Hide CornerClick settings" : "Show CornerClick settings")
                if !module.status.isRunning || !expanded {
                    Text(summary)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.ink3)
                        .lineLimit(1)
                        .transition(.opacity)
                }
                Spacer()
                InkSwitch(isOn: $module.isEnabled, label: "CornerClick",
                          active: module.status.isRunning || !module.isEnabled)
            }
            if module.status == .needsPermission {
                AccessibilityCard(purpose: "CornerClick needs Accessibility access to turn a corner click into a right-click. It never reads what you type, and nothing leaves your Mac.")
            } else if expanded {
                CornerClickEditor(module: module, compact: true)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(Motion.snappy, value: module.status)
    }

    private var summary: String {
        if !module.status.isRunning { return module.statusText }
        let size = module.zoneIsCustom ? "Custom" : (ZonePreset.matching(module.zone, on: module.trackpadSize)?.rawValue ?? "Custom")
        let triggers = [module.clickEnabled ? "click" : nil, module.tapEnabled ? "tap" : nil].compactMap { $0 }.joined(separator: " + ")
        return "\(module.zone.corner == .bottomRight ? "Right" : "Left") · \(size) · \(triggers)"
    }
}

// MARK: - Quick actions

private struct QuickActions: View {
    var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                if model.screenshots != nil {
                    action("Area", symbol: "rectangle.dashed", .captureArea)
                    action("Screen", symbol: "macbook", .captureScreen)
                    action("Edit", symbol: "pencil.and.scribble", .captureAreaEdit)
                }
                if model.clipboard != nil {
                    action("Clipboard", symbol: "list.clipboard", .clipboardHistory)
                }
                if model.windows != nil {
                    action("Windows", symbol: "rectangle.split.2x1", .windowPalette)
                }
            }
            if let clipboard = model.clipboard {
                ClipboardLine(clipboard: clipboard)
            }
        }
    }

    private func action(_ title: String, symbol: String, _ shortcut: ShortcutAction) -> some View {
        QuickActionButton(title: title, symbol: symbol, shortcut: model.shortcuts.shortcut(for: shortcut)) {
            // Let the panel close first so it isn't in the screenshot or in the way.
            NSApp.keyWindow?.close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                MainActor.assumeIsolated { model.perform(shortcut) }
            }
        }
    }
}

private struct QuickActionButton: View {
    var title: String
    var symbol: String
    var shortcut: KeyShortcut?
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Color.ink)
                    .frame(height: 18)
                Text(title)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.ink2)
                    .lineLimit(1)
                KeyCaps(shortcut: shortcut, compact: true)
                    .scaleEffect(0.86)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Color.wash : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .help(shortcut.map { "\(title) (\($0.displayString))" } ?? title)
        .accessibilityLabel(title)
    }
}

private struct ClipboardLine: View {
    @Bindable var clipboard: ClipboardModule

    var body: some View {
        HStack(spacing: 8) {
            Caption("Clipboard")
            Text(clipboard.isPaused ? "Paused" : "\(clipboard.itemCount.formatted()) item\(clipboard.itemCount == 1 ? "" : "s")")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Color.ink3)
            Spacer()
            InkSwitch(isOn: Binding(get: { !clipboard.isPaused }, set: { clipboard.isPaused = !$0 }),
                      label: "Record clipboard history")
                .help(clipboard.isPaused ? "Resume recording" : "Pause recording (for sensitive work)")
        }
        .padding(.top, 2)
    }
}

// MARK: - Notices

/// Only things that need the user: a missing permission for a module that's on, and running
/// apps that actually clash (same shortcuts, double right-clicks). One line each.
private struct Notices: View {
    var model: AppModel

    var body: some View {
        let missing = Permission.allCases.filter { permission in
            guard permission == .accessibility || permission == .screenRecording else { return false }
            guard permission.modules.contains(where: { model.isEnabled($0) }) else { return false }
            return model.permissions.isGranted(permission) == false
        }
        let clashes = model.runningReplacedApps().filter { ["cc.ffitch.shottr", "ca.bryanyao.CornerClick"].contains($0.bundleID) }
        if !missing.isEmpty || !clashes.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(missing) { permission in
                    NoticeRow(symbol: "lock", text: "\(permission.title) needed", help: permission.powers, button: "Allow") {
                        model.permissions.request(permission)
                    }
                }
                ForEach(clashes) { app in
                    NoticeRow(symbol: "exclamationmark.triangle", text: "\(app.name) is also running", help: app.advice, button: "Quit") {
                        model.quit(app)
                    }
                }
            }
            .padding(.bottom, 8)
        }
    }
}

private struct NoticeRow: View {
    var symbol: String
    var text: String
    var help: String
    var button: String
    var action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.ink2)
                .frame(width: 14)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.ink)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button(button, action: action)
                .buttonStyle(InkButtonStyle(compact: true))
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(Color.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .help(help)
    }
}

extension String {
    var lowercasedFirst: String {
        guard let first else { return self }
        return first.lowercased() + dropFirst()
    }
}
