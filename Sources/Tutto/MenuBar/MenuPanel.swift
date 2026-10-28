//
//  MenuPanel.swift
//  Tutto
//
//  The menu bar panel: what you open the menu bar for, in the order you look. Tutto's mark
//  and how the Mac is doing in plain words; the battery with its health and the apps using
//  the processor most; six tiles (CPU, memory, GPU, disk, network, temperature), each a
//  number, an engraved caption and the last minute as a line; the apps' sound; and the
//  tools with their keys, to click instead of pressing them. Settings live in the app.
//  Each part appears only if its module is on, and readings run only while the panel is
//  open (no process is started for them).
//
//  One grid: cards inset 10 pt from the panel, content 12 pt inside them (text from x = 22
//  to 298), 8 pt between blocks. Hover backgrounds reach outward, so nothing moves. One
//  accent (the system's) for what's live: the lines, meters, the playing badge, pressed
//  keys; red only for alarms.
//

import AppKit
import SwiftUI
import TuttoKit

private enum PanelGrid {
    static let width: CGFloat = 320
    static let outer: CGFloat = 10
    static let inset: CGFloat = 12
    static let gap: CGFloat = 8
    /// A tile: half the cards' width.
    static let tile: CGFloat = (width - 2 * outer - gap) / 2
}

struct MenuPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: PanelGrid.gap) {
            PanelHeader(model: model)
            if let system = model.system {
                if let battery = system.battery {
                    BatteryCard(battery: battery, system: system)
                } else {
                    BusyAppsList(apps: system.busyApps, measured: system.busyAppsMeasured).panelCard()
                }
                StatTiles(system: system, sensors: model.sensors)
            }
            if let sound = model.sound, SoundModule.isSupported {
                SoundCard(sound: sound)
            }
            if !ShortcutRows.rows(model).isEmpty {
                ToolsCard(model: model)
            }
            Notices(model: model)
            PanelFooter(model: model)
        }
        .padding(.horizontal, PanelGrid.outer)
        .padding(.top, PanelGrid.outer)
        .padding(.bottom, 6)
        .frame(width: PanelGrid.width)
        .fixedSize(horizontal: false, vertical: true)
        .watching(model.system, model.system?.panelFeeds ?? [])
        .background(PanelWindowReader())
    }
}

/// Remembers the panel's own window, so it's closed only while it's actually showing.
@MainActor
private enum PanelWindow {
    static weak var current: NSWindow?
}

private struct PanelWindowReader: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Reader() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Reader: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { MainActor.assumeIsolated { PanelWindow.current = window } }
        }
    }
}

// MARK: - Pieces

private extension View {
    /// A group on the panel: a soft rounded surface instead of rules and captions.
    func panelCard() -> some View {
        padding(PanelGrid.inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.055)))
    }

    /// A hover background that reaches `x` and `y` past the content, so the content stays on the grid.
    func hoverBackground(_ on: Bool, x: CGFloat = 8, y: CGFloat = 0) -> some View {
        padding(.horizontal, x)
            .padding(.vertical, y)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? Color.primary.opacity(0.08) : .clear))
            .padding(.horizontal, -x)
            .padding(.vertical, -y)
    }
}

/// Text button that brightens on hover, for the few quiet actions on the panel.
private struct QuietLink: View {
    var title: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? Color.ink : Color.ink3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A card's title row: the title, and something quiet on the right.
private struct CardTitle<Trailing: View>: View {
    var title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.ink)
            Spacer(minLength: 8)
            trailing
        }
        .lineLimit(1)
    }
}

/// Runs an action after the panel has closed, so it isn't in the picture or in the way, and
/// the app you were in is the front app again. The panel is closed through the menu bar icon's
/// own button, as a click on the icon closes it: closing its window directly left SwiftUI
/// thinking it was still open, so the next click on the icon did nothing.
@MainActor
private func afterPanelCloses(_ action: @escaping @MainActor () -> Void) {
    closePanel()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
        MainActor.assumeIsolated { action() }
    }
}

/// Closes the panel the way a click on the icon does. Opening Tutto's window doesn't close it by
/// itself (Tutto stays the active app), so anything that opens a page closes the panel first.
@MainActor
private func closePanel() {
    // A click on the icon toggles: only while the panel is up, or a late call would open it again.
    guard PanelWindow.current?.isVisible ?? true else { return }
    if let button = menuBarButton() { button.performClick(nil) } else { NSApp.keyWindow?.close() }
}

/// Opens a page of the app (or the app where you left it) and closes the panel.
@MainActor
private func showInApp(_ page: MainPage? = nil) {
    closePanel()
    if let page { MainWindowController.shared.show(page: page) } else { MainWindowController.shared.show() }
}

/// The button SwiftUI makes for the menu bar icon.
@MainActor
private func menuBarButton() -> NSStatusBarButton? {
    func find(_ view: NSView) -> NSStatusBarButton? {
        (view as? NSStatusBarButton) ?? view.subviews.lazy.compactMap(find).first
    }
    return NSApp.windows.lazy
        .filter { $0.className.contains("StatusBarWindow") }
        .compactMap { $0.contentView.flatMap(find) }
        .first
}

// MARK: - Header

/// Tutto's mark and how the Mac is doing in plain words: a problem first, else the battery.
private struct PanelHeader: View {
    var model: AppModel

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(nsImage: MenuBarGlyph.image())
                .renderingMode(.template)
                .foregroundStyle(Color.ink)
                .accessibilityHidden(true)
            if let system = model.system {
                VerdictLine(glance: Glance.make(battery: system.battery, cpu: system.cpu.total, memoryPressure: system.memory?.pressure,
                                                hottest: model.sensors?.summary?.hottest, diskFree: system.rootVolume?.available,
                                                diskUsed: system.rootVolume?.usedFraction))
            } else {
                Text("Tutto")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.ink)
                Spacer()
            }
        }
        .frame(height: 22)
        .padding(.horizontal, PanelGrid.inset)
    }
}

/// The verdict: its title on the left, the detail on the right. A problem gets a ⚠︎ ahead of
/// it (red when it's an alarm); a calm Mac gets nothing.
struct VerdictLine: View {
    var glance: Glance

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if glance.level != .calm {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(glance.level == .alert ? Color.alert : Color.ink2)
            }
            Text(glance.title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.ink)
            Spacer(minLength: 8)
            if let detail = glance.detail {
                Text(detail)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(glance.level == .alert ? Color.alert : Color.ink3)
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Battery

/// The battery: how full, what the Mac is drawing, how healthy it is, and the apps using the
/// processor most right now.
private struct BatteryCard: View {
    var battery: BatteryInfo
    var system: SystemMonitor
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                showInApp(.battery)
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    BatteryGlyph(level: Double(battery.percent) / 100, charging: battery.isCharging, alert: low)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(alignment: .firstTextBaseline, spacing: 1) {
                            Text("\(battery.percent)")
                                .font(.system(size: 24, weight: .semibold).monospacedDigit())
                                .foregroundStyle(low ? Color.alert : Color.ink)
                            Text("%")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.ink3)
                        }
                        Text(healthLine)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.ink3)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text(Format.watts(battery.powerDraw))
                                .font(.system(size: 17, weight: .medium).monospacedDigit())
                                .foregroundStyle(Color.ink)
                            Text("W")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.ink3)
                        }
                        Caption(powerCaption)
                    }
                }
                .hoverBackground(hovering, x: 6, y: 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("Battery details")
            .accessibilityLabel("Battery")
            .accessibilityValue("\(battery.percent) percent, \(battery.stateText), \(Format.watts(battery.powerDraw)) watts \(powerCaption), \(healthLine)")
            .accessibilityHint("Shows details")
            // A battery that needs attention says so on a line of its own (it's rare, and it matters).
            if let condition = unusualCondition {
                Label(condition, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.alert)
                    .lineLimit(1)
            }
            BusyAppsList(apps: system.busyApps, measured: system.busyAppsMeasured)
        }
        .panelCard()
    }

    private var unusualCondition: String? {
        guard let condition = battery.condition, !condition.isEmpty, condition.lowercased() != "normal" else { return nil }
        return condition
    }

    private var low: Bool { battery.percent <= 10 && !battery.isPluggedIn }

    /// "Health 94 % · 148 cycles" (a condition other than Normal gets its own line).
    private var healthLine: String {
        "Health \(battery.healthPercent) % · \(Format.number(battery.cycleCount)) cycles"
    }

    /// The figure is what the Mac is using: from the adapter when plugged in, from the battery when not.
    private var powerCaption: String {
        battery.isPluggedIn ? "system" : "drain"
    }
}

/// The three apps using the processor most right now, helpers counted as their app (read
/// from the kernel every 2 s while the panel is open). Always three rows tall, so the panel
/// doesn't jump as apps come and go.
private struct BusyAppsList: View {
    var apps: [AppActivity]
    /// False until the first reading since the panel opened.
    var measured: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Caption("Busiest apps")
                Spacer()
                Caption("CPU")
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    if index < apps.count {
                        BusyAppRow(app: apps[index])
                    } else if index == 0 {
                        Text(measured ? "All quiet" : "Measuring…")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.ink3)
                            .frame(height: 18)
                    } else {
                        Color.clear.frame(height: 18)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Busiest apps")
    }
}

private struct BusyAppRow: View {
    var app: AppActivity

    var body: some View {
        HStack(spacing: 7) {
            AppIcon(pid: app.pid)
                .frame(width: 15, height: 15)
            Text(app.name)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            Text(app.cpu >= 10 ? "\(Int(app.cpu.rounded())) %" : String(format: "%.1f %%", app.cpu))
                .font(.geist(11, weight: .medium))
                .foregroundStyle(Color.ink2)
        }
        .frame(height: 18)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Tiles

/// Six tiles in two columns: CPU, memory, GPU, disk, network and temperature, each a number,
/// an engraved caption, a detail and the last minute as a line (or a meter). Each opens its page.
/// With Sensors & Fans off there's no temperature, and the network tile takes the row.
private struct StatTiles: View {
    var system: SystemMonitor
    var sensors: SensorsModule?

    var body: some View {
        VStack(spacing: PanelGrid.gap) {
            HStack(spacing: PanelGrid.gap) {
                StatTile(caption: "CPU", value: Format.percent(system.cpu.total), unit: "%", detail: loadText,
                         page: .cpu, help: "Processor load · load average \(loadValue)",
                         spokenName: "CPU", spokenValue: "\(Format.percent(system.cpu.total)) percent, load average \(loadValue)") {
                    Sparkline(values: system.cpuHistory, color: .accentColor, stretch: true)
                }
                StatTile(caption: "Memory", value: Format.percent(system.memory?.usedFraction ?? 0), unit: "%", detail: memoryUsed,
                         alert: system.memory?.pressure == .critical, page: .memory,
                         help: "Memory used · pressure \(system.memory?.pressure.label.lowercased() ?? "unknown")",
                         spokenName: "Memory", spokenValue: "\(Format.percent(system.memory?.usedFraction ?? 0)) percent, \(memoryUsed) used") {
                    Sparkline(values: system.memoryHistory, color: .accentColor, stretch: true)
                }
            }
            HStack(spacing: PanelGrid.gap) {
                StatTile(caption: "GPU", value: Format.percent(system.gpu?.utilization ?? 0), unit: "%", detail: gpuMemory,
                         page: .gpu, help: "Graphics load",
                         spokenName: "GPU", spokenValue: "\(Format.percent(system.gpu?.utilization ?? 0)) percent") {
                    Sparkline(values: system.gpuHistory, color: .accentColor, stretch: true)
                }
                let disk = system.rootVolume.map { Format.diskParts($0.available) } ?? ("—", "")
                let full = (system.rootVolume?.usedFraction ?? 0) >= 0.95
                StatTile(caption: "Disk", value: disk.0, unit: disk.1, detail: "free", alert: full, page: .disk,
                         help: "Free space on \(system.rootVolume?.name ?? "the startup disk")",
                         spokenName: "Disk", spokenValue: system.rootVolume == nil ? "unavailable" : "\(disk.0) \(disk.1) free") {
                    Meter(value: system.rootVolume?.usedFraction ?? 0, height: 4, alert: full, fill: .accentColor, track: Color.primary.opacity(0.1))
                        .frame(height: 4)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 4)
                }
            }
            HStack(spacing: PanelGrid.gap) {
                let down = Format.rateParts(system.networkIn)
                StatTile(caption: "Network", value: down.0, unit: down.1, detail: "↑ " + Format.rate(system.networkOut),
                         prefix: "↓", page: .network, help: "Downloading and uploading",
                         spokenName: "Network",
                         spokenValue: "download \(Format.spokenRate(system.networkIn)), upload \(Format.spokenRate(system.networkOut))",
                         wide: sensors == nil) {
                    Sparkline(values: system.networkHistory, color: .accentColor, stretch: true)
                }
                // Temperature belongs to Sensors & Fans: with that off, there's no tile.
                if sensors != nil {
                    let hot = (temperature ?? 0) >= 95
                    StatTile(caption: "Temp", value: temperature.map { "\(Int($0.rounded()))" } ?? "—", unit: temperature == nil ? "" : "°C",
                             detail: fanText, alert: hot, page: .sensors, help: temperatureHelp,
                             spokenName: "Temperature",
                             spokenValue: temperature.map { "\(Int($0.rounded())) degrees Celsius" + (fanText.isEmpty ? "" : ", \(fanText)") } ?? "unavailable") {
                        Meter(value: ((temperature ?? 30) - 30) / 70, height: 4, alert: hot, fill: .accentColor, track: Color.primary.opacity(0.1))
                            .frame(height: 4)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                            .padding(.bottom, 4)
                    }
                }
            }
        }
        .background(VisibilityReader { visible in
            guard let sensors else { return }
            visible ? sensors.begin() : sensors.end()
        })
    }

    private var loadValue: String {
        guard let load = system.loadAverage.first else { return "unknown" }
        return String(format: "%.1f", load)
    }

    private var loadText: String {
        system.loadAverage.first == nil ? "" : "load \(loadValue)"
    }

    private var memoryUsed: String {
        guard let memory = system.memory else { return "" }
        return String(format: "%.1f GB", Double(memory.used) / 1_073_741_824)
    }

    private var gpuMemory: String {
        guard let bytes = system.gpu?.memoryInUse, bytes > 0 else { return "" }
        return String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }

    private var temperature: Double? { sensors?.summary.flatMap { $0.cpuAverage ?? $0.socAverage } }

    private var fanText: String {
        guard let fan = sensors?.fans.first else { return "" }
        return fan.isStopped ? "fan off" : "\(Format.number(Int(fan.currentRPM))) rpm"
    }

    private var temperatureHelp: String {
        guard temperature != nil else { return "No temperature sensor could be read on this Mac" }
        return ["Processor temperature", fanText].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// One tile: an engraved caption and a detail on top, the number and its line beneath. The number
/// never shrinks or truncates: the line gives way instead (down to 26 pt) when it needs the room.
private struct StatTile<Graph: View>: View {
    var caption: String
    var value: String
    var unit: String
    var detail: String
    var alert = false
    /// A small mark ahead of the number (the network's ↓).
    var prefix: String?
    var page: MainPage
    var help: String
    var spokenName: String
    var spokenValue: String
    /// Spans both columns.
    var wide = false
    @ViewBuilder var graph: Graph
    @State private var hovering = false

    var body: some View {
        Button {
            showInApp(page)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Caption(caption)
                    Spacer(minLength: 4)
                    Text(detail)
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(Color.ink3)
                        .lineLimit(1)
                }
                HStack(alignment: .bottom, spacing: 6) {
                    // A word unit (GB, KB/s) gets a little air; % and °C sit close.
                    HStack(alignment: .firstTextBaseline, spacing: unit.first?.isLetter == true ? 2.5 : 1) {
                        if let prefix {
                            Text(prefix)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.ink3)
                        }
                        Text(value)
                            .font(.system(size: 21, weight: .medium).monospacedDigit())
                            .foregroundStyle(alert ? Color.alert : Color.ink)
                        if !unit.isEmpty {
                            Text(unit)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.ink3)
                        }
                    }
                    .lineLimit(1)
                    .fixedSize()
                    .layoutPriority(1)
                    Spacer(minLength: 2)
                    graph
                        .frame(minWidth: 26, maxWidth: wide ? 120 : 46)
                        .frame(height: 20)
                }
                .frame(height: 24)
            }
            .padding(.horizontal, PanelGrid.inset)
            .padding(.vertical, 9)
            .frame(width: wide ? PanelGrid.tile * 2 + PanelGrid.gap : PanelGrid.tile, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.085 : 0.055)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(spokenName)
        .accessibilityValue(spokenValue)
        .accessibilityHint("Shows details")
    }
}

// MARK: - Sound

/// The apps on the Mac as icons: click one to mute it at the speakers. Muted apps first, then
/// the ones playing, then the rest in the order they opened.
private struct SoundCard: View {
    @Bindable var sound: SoundModule
    @State private var order: [String] = []

    /// Icons that fit across the card before the rest go into a menu.
    private static let capacity = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardTitle(title: "Sound") {
                // Only for an app you can see muted here; apps muted while closed stay muted.
                if sound.apps.contains(where: { sound.isMuted($0.bundleID) }) {
                    QuietLink(title: "Unmute All") { withAnimation(Motion.micro) { sound.unmuteOpen() } }
                }
            }
            if sound.apps.isEmpty {
                Text("No apps open")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.ink3)
                    .frame(height: 34)
            } else {
                HStack(spacing: 0) {
                    ForEach(visible) { app in
                        SoundAppButton(app: app, muted: sound.isMuted(app.bundleID), usingAudio: sound.usingAudio.contains(app.bundleID),
                                       size: 30) {
                            withAnimation(Motion.micro) { sound.toggle(app) }
                        }
                        .frame(width: 34.5, alignment: .leading)
                    }
                    if !overflow.isEmpty { overflowMenu }
                    Spacer(minLength: 0)
                }
                // Each button is 2 pt wider than its icon, and an app icon's artwork sits about 3 pt
                // inside its square at this size: pull the row left so the artwork lines up with the text.
                .padding(.leading, -5)
            }
            if let problem = sound.problem {
                HStack(spacing: 8) {
                    Text(problem)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    if sound.access == .denied {
                        Button("Allow") { AppModel.shared.permissions.request(.systemAudio) }
                            .buttonStyle(OutlineButtonStyle(compact: true))
                    }
                }
            }
        }
        .panelCard()
        .background(VisibilityReader { visible in
            if visible { sound.begin(); fixOrder(reset: true) } else { sound.end() }
        })
        .onAppear { fixOrder(reset: true) }
        .onChange(of: sound.apps.map(\.bundleID)) { fixOrder(reset: false) }
    }

    private var ordered: [SoundApp] {
        let byID = Dictionary(sound.apps.map { ($0.bundleID, $0) }, uniquingKeysWith: { a, _ in a })
        return order.compactMap { byID[$0] }
    }

    private var visible: [SoundApp] {
        let all = ordered
        return all.count <= Self.capacity ? all : Array(all.prefix(Self.capacity - 1))
    }

    private var overflow: [SoundApp] {
        let all = ordered
        return all.count <= Self.capacity ? [] : Array(all.dropFirst(Self.capacity - 1))
    }

    /// On open: muted first, then apps using audio, then launch order. Later launches go last.
    private func fixOrder(reset: Bool) {
        let ids = sound.apps.map(\.bundleID)
        if reset || order.isEmpty {
            func rank(_ id: String) -> Int { sound.isMuted(id) ? 0 : (sound.usingAudio.contains(id) ? 1 : 2) }
            order = ids.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
        } else {
            order = order.filter(ids.contains) + ids.filter { !order.contains($0) }
        }
    }

    private var overflowMenu: some View {
        Menu {
            Section("Click to mute or unmute") {
                ForEach(overflow) { app in
                    Toggle(isOn: Binding(get: { sound.isMuted(app.bundleID) }, set: { sound.setMuted(app.bundleID, $0) })) {
                        Label { Text(app.name) } icon: { Image(nsImage: app.icon) }
                    }
                }
            }
        } label: {
            Text("+\(overflow.count)")
                .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(overflow.contains { sound.isMuted($0.bundleID) } ? Color.ink : Color.ink2)
                .frame(width: 25, height: 25)   // the size of an icon's artwork, not its square
                .background(Circle().fill(Color.primary.opacity(0.08)))
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("\(overflow.count) more apps")
        .accessibilityLabel("\(overflow.count) more apps")
    }
}

// MARK: - Tools

/// The tools, each with its keys: click one to do the same as pressing them.
@MainActor
enum ShortcutRows {
    struct Row: Identifiable {
        var action: ShortcutAction
        var title: String
        /// The tile's label.
        var short: String
        var symbol: String
        var id: String { action.id }
    }

    static func rows(_ model: AppModel) -> [Row] {
        var rows: [Row] = []
        if model.screenshots != nil {
            rows.append(Row(action: .captureArea, title: "Capture Area", short: "Area", symbol: "rectangle.dashed"))
            rows.append(Row(action: .captureAreaEdit, title: "Capture and Edit", short: "Edit", symbol: "pencil.and.scribble"))
            rows.append(Row(action: .captureScreen, title: "Capture Screen", short: "Screen", symbol: "laptopcomputer"))
        }
        if model.clipboard != nil {
            rows.append(Row(action: .clipboardHistory, title: "Clipboard History", short: "History", symbol: "list.clipboard"))
        }
        if model.windows != nil { rows.append(Row(action: .windowPalette, title: "Snap Window", short: "Snap", symbol: "rectangle.split.2x1")) }
        if model.wordCounter != nil {
            rows.append(Row(action: .wordCounter, title: "Count Words", short: "Words", symbol: ModuleID.wordCounter.symbol))
        }
        return rows
    }
}

private struct ToolsCard: View {
    var model: AppModel
    /// A tool is on its way (keys lighting, panel closing): the row ignores further clicks, so a
    /// quick double click can't run it twice or bring the panel back.
    @State private var launching = false
    private static let inset: CGFloat = 6
    private static let gap: CGFloat = 2

    var body: some View {
        let rows = ShortcutRows.rows(model)
        let count = CGFloat(max(rows.count, 1))
        // Each tile an equal share of the card, so a long shortcut can't widen it.
        let tile = (PanelGrid.width - 2 * PanelGrid.outer - 2 * Self.inset - Self.gap * (count - 1)) / count
        HStack(spacing: Self.gap) {
            ForEach(rows) { row in
                ToolTile(row: row, shortcut: model.shortcuts.shortcut(for: row.action), launching: $launching) {
                    afterPanelCloses { model.perform(row.action) }
                }
                .frame(width: tile)
            }
        }
        .padding(.horizontal, Self.inset)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.055)))
    }
}

/// A tool: its symbol, a short name and its keys. Clicking it presses the keys you'd press:
/// they light up one after another, then the panel closes and the tool runs.
private struct ToolTile: View {
    var row: ShortcutRows.Row
    var shortcut: KeyShortcut?
    @Binding var launching: Bool
    var action: () -> Void
    @State private var hovering = false
    @State private var lit = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: press) {
            VStack(spacing: 4) {
                Image(systemName: row.symbol)
                    .font(.system(size: 14.5))
                    .foregroundStyle(Color.ink)
                    .frame(height: 18)
                Text(row.short)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.ink2)
                    .lineLimit(1)
                if let shortcut {
                    keys(shortcut)
                } else {
                    Text("—").font(.system(size: 9.5)).foregroundStyle(Color.ink4).frame(height: 14)
                }
            }
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Color.primary.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .help(shortcut.map { "\(row.title) (\($0.displayString))" } ?? row.title)
        .accessibilityLabel(row.title)
        .accessibilityValue(shortcut?.spokenDescription ?? "")
    }

    /// Keycaps when they fit the tile; a longer custom shortcut falls back to one line of text.
    private func keys(_ shortcut: KeyShortcut) -> some View {
        ViewThatFits(in: .horizontal) {
            keycaps(shortcut.symbols)
            Text(shortcut.displayString)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(lit > 0 ? Color.accentColor : Color.ink2)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(height: 13)
        }
    }

    /// Small keycaps; while pressed, each fills in turn with the accent.
    private func keycaps(_ symbols: [String]) -> some View {
        HStack(spacing: 1.5) {
            ForEach(Array(symbols.enumerated()), id: \.offset) { index, symbol in
                Text(symbol)
                    .font(.system(size: 8.5, weight: .medium, design: .rounded))
                    .foregroundStyle(lit > index ? Color.white : Color.ink2)
                    .frame(minWidth: 11, minHeight: 13)
                    .padding(.horizontal, symbol.count > 1 ? 2 : 0)
                    .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(lit > index ? Color.accentColor : Color.wash))
                    .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(lit > index ? Color.clear : Color.hairline))
            }
        }
        .fixedSize()
    }

    /// Keys light 30 ms apart (all at once under Reduce Motion), the tool runs 80 ms after the last,
    /// and the keys go dark once the panel has faded. One launch at a time for the whole row.
    private func press() {
        guard !launching else { return }
        launching = true
        let count = shortcut?.symbols.count ?? 0
        let step = reduceMotion ? 0 : 0.03
        for index in 0..<count {
            DispatchQueue.main.asyncAfter(deadline: .now() + step * Double(index)) {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.05)) { lit = index + 1 }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + step * Double(count) + 0.08) {
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                lit = 0
                launching = false
            }
        }
    }
}

// MARK: - Footer

private struct PanelFooter: View {
    @Bindable var model: AppModel
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                showInApp()
            } label: {
                Text("Open Tutto")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.ink)
                    .frame(height: 26)
                    .hoverBackground(hovering)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .onHover { hovering = $0 }
            Spacer()
            if let system = model.system, let footprint = system.ownFootprint {
                // What Tutto itself costs, right now: never a guess.
                Text(ownCost(footprint, system.ownCPU))
                    .font(.geist(10.5, weight: .medium))
                    .foregroundStyle(Color.ink3)
                    .help("What Tutto itself is using right now")
                    .accessibilityLabel("Tutto is using \(ownCost(footprint, system.ownCPU))")
            }
            Menu {
                if let clipboard = model.clipboard {
                    Toggle("Pause Clipboard History", isOn: Binding(get: { clipboard.isPaused }, set: { clipboard.isPaused = $0 }))
                }
                if let corner = model.corner {
                    Toggle("Pause Trackpad Corner", isOn: Binding(get: { !corner.isEnabled }, set: { corner.isEnabled = !$0 }))
                }
                if model.clipboard != nil || model.corner != nil { Divider() }
                Toggle("Open at Login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                Button("Shortcuts…") { showInApp(.shortcuts) }
                Button("Permissions…") { showInApp(.permissions) }
                Divider()
                Button("Quit Tutto") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.ink2)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
            .accessibilityLabel("More")
        }
        .padding(.leading, PanelGrid.inset)
        .padding(.trailing, PanelGrid.inset - 6)
    }

    private func ownCost(_ footprint: Double, _ cpu: Double?) -> String {
        let memory = "\(Int(footprint.rounded())) MB"
        guard let cpu else { return memory }
        return memory + " · " + String(format: "%.1f %% CPU", cpu)
    }
}

// MARK: - Notices

/// Only what needs the user: a permission missing for a module that's on. One line each.
private struct Notices: View {
    var model: AppModel

    var body: some View {
        let missing = Permission.allCases.filter { permission in
            guard permission == .accessibility || permission == .screenRecording else { return false }
            guard permission.modules.contains(where: { model.isEnabled($0) }) else { return false }
            return model.permissions.isGranted(permission) == false
        }
        if !missing.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(missing) { permission in
                    NoticeRow(symbol: "lock", text: "\(permission.title) needed", help: permission.powers, button: "Allow") {
                        model.permissions.request(permission)
                    }
                }
            }
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
        .padding(.vertical, 6)
        .padding(.horizontal, PanelGrid.inset)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .help(help)
    }
}

// MARK: - Shared with the app's pages

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
                .font(.geist(11, weight: .medium))
                .foregroundStyle(Color.ink2)
        }
        .frame(height: 18)
        .accessibilityElement(children: .combine)
    }
}

/// The app's icon, or a quiet placeholder for background processes.
struct AppIcon: View {
    var pid: Int32

    var body: some View {
        Group {
            if let icon = AppIconCache.icon(for: pid) {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                Image(systemName: "gearshape")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Color.ink4)
                    .padding(1.5)
            }
        }
        .accessibilityHidden(true)  // the row's name already says what it is
    }
}

/// App icons for process rows, looked up once per process while a list is visible.
@MainActor
enum AppIconCache {
    private static var icons: [Int32: NSImage] = [:]
    private static var misses: Set<Int32> = []

    static func icon(for pid: Int32) -> NSImage? {
        if let icon = icons[pid] { return icon }
        if misses.contains(pid) { return nil }
        if let icon = NSRunningApplication(processIdentifier: pid)?.icon {
            if icons.count > 64 { icons.removeAll() }
            icons[pid] = icon
            return icon
        }
        misses.insert(pid)
        return nil
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
                        .fill(alert ? Color.alert : Color.solidInk)
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
