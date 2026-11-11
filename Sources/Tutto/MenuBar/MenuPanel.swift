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

/// The grid, its spacing scaled by the theme's density (the panel's width never changes).
@MainActor
private enum PanelGrid {
    static let width: CGFloat = 320
    static var outer: CGFloat { (10 * ThemeStore.shared.tokens.densityScale).rounded() }
    static var inset: CGFloat { (12 * ThemeStore.shared.tokens.densityScale).rounded() }
    static var gap: CGFloat { (8 * ThemeStore.shared.tokens.densityScale).rounded() }
    /// A tile: half the cards' width.
    static var tile: CGFloat { (width - 2 * outer - gap) / 2 }
}

/// The Customize page's preview while you arrange it: which card is selected, which is being
/// dragged and over which, and what a drop does.
@MainActor
@Observable
final class PanelEditing {
    var selected: String?
    var dragging: String?
    var target: String?
    /// Moves the first card to where the second is.
    @ObservationIgnored var move: (String, String) -> Void = { _, _ in }
}

struct MenuPanel: View {
    @Bindable var model: AppModel
    /// Drawn on the Customize page: shown, not used (and not the menu bar's own window).
    var preview = false
    /// On the Customize page: cards can be picked up, moved and selected.
    var editing: PanelEditing?

    var body: some View {
        VStack(alignment: .leading, spacing: PanelGrid.gap) {
            PanelHeader(model: model)
            // The cards in the order and sizes set on the Customize page.
            WidgetGrid(model: model, editing: editing)
            Notices(model: model)
            PanelFooter(model: model)
        }
        .padding(.horizontal, PanelGrid.outer)
        .padding(.top, PanelGrid.outer)
        .padding(.bottom, 6)
        .frame(width: PanelGrid.width)
        .fixedSize(horizontal: false, vertical: true)
        .background { PanelBackdrop() }
        .watching(model.system, model.system?.panelFeeds ?? [])
        .background { if !preview { PanelWindowReader() } }
        .tint(Color.themeAccent)
    }
}

/// Over the panel's glass: the theme's tint, or its solid background instead of glass.
private struct PanelBackdrop: View {
    var body: some View {
        let tokens = ThemeStore.shared.tokens
        Rectangle()
            .fill(tokens.solidBackground ? tokens.canvas : tokens.tint)
            .ignoresSafeArea()
    }
}

/// The cards in lines: two small ones side by side, a wide one (or a small one alone) across,
/// one-line controls together in one card.
private struct WidgetGrid: View {
    var model: AppModel
    var editing: PanelEditing?

    var body: some View {
        let lines = PanelLayout.lines(model.layout.slots(model))
        VStack(spacing: PanelGrid.gap) {
            ForEach(lines, id: \.self) { line in
                switch line {
                case .cards(let ids):
                    HStack(spacing: PanelGrid.gap) {
                        ForEach(ids, id: \.self) { id in
                            Editable(id: id, editing: editing) { card(id, wide: ids.count == 1) }
                        }
                    }
                case .rows(let ids):
                    ControlRows(model: model, ids: ids, editing: editing)
                }
            }
        }
        .animation(Motion.snappy, value: lines)
    }

    @ViewBuilder
    private func card(_ id: String, wide: Bool) -> some View {
        switch PanelLayoutStore.Widget(id: id) {
        case .card(.battery):
            BatteryWidget(model: model, wide: wide)
        case .card(let reading) where PanelLayout.readingIDs.contains(reading.rawValue):
            if let system = model.system {
                ReadingTile(reading: reading, system: system, sensors: model.sensors, wide: wide)
            }
        case .card(.sound):
            if let sound = model.sound, SoundModule.isSupported { SoundCard(sound: sound) }
        case .card(.tools):
            ToolsCard(model: model)
        case .plugin(let id):
            PluginCard(model: model, id: id, wide: wide)
        default:
            EmptyView()
        }
    }
}

/// On the Customize page, a card is something to pick up and move, or click to select; its
/// own controls don't respond there.
private struct Editable<Content: View>: View {
    var id: String
    var editing: PanelEditing?
    var radius: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        if let editing {
            let shape = RoundedRectangle(cornerRadius: Radius.of(radius), style: .continuous)
            content
                .allowsHitTesting(false)
                .overlay {
                    shape.fill(Color.white.opacity(0.001))
                        .overlay(shape.strokeBorder(Color.themeAccent, lineWidth: editing.selected == id ? 2 : 0))
                        .overlay(shape.strokeBorder(Color.themeAccent.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                            .opacity(editing.target == id && editing.dragging != id ? 1 : 0))
                        .contentShape(shape)
                        .onTapGesture { editing.selected = id }
                        .onDrag {
                            editing.dragging = id
                            editing.selected = id
                            DragWatch.whenReleased {
                                editing.dragging = nil
                                editing.target = nil
                            }
                            return NSItemProvider(object: id as NSString)
                        }
                        .onDrop(of: [.plainText], delegate: CardDrop(id: id, editing: editing))
                }
                .opacity(editing.dragging == id ? 0.4 : 1)
                .animation(Motion.micro, value: editing.selected)
        } else {
            content
        }
    }
}

/// SwiftUI says nothing when a drag is cancelled: this clears a drag's state once the mouse
/// button is up again (after a drop it's already clear).
@MainActor
enum DragWatch {
    static func whenReleased(_ action: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            MainActor.assumeIsolated {
                if NSEvent.pressedMouseButtons & 1 == 0 { action() } else { whenReleased(action) }
            }
        }
    }
}

/// Dropping a card on another moves it to that card's place.
private struct CardDrop: DropDelegate {
    var id: String
    var editing: PanelEditing

    func dropEntered(info: DropInfo) { editing.target = id }

    func dropExited(info: DropInfo) { if editing.target == id { editing.target = nil } }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            editing.dragging = nil
            editing.target = nil
        }
        guard let moving = editing.dragging, moving != id else { return false }
        withAnimation(Motion.snappy) { editing.move(moving, id) }
        return true
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

@MainActor
private extension View {
    /// A group on the panel: a soft rounded surface instead of rules and captions. `vertical` trims
    /// a one-row card (the sides stay on the grid).
    func panelCard(vertical: CGFloat? = nil) -> some View {
        padding(.horizontal, PanelGrid.inset)
            .padding(.vertical, vertical ?? PanelGrid.inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CardSurface(radius: 12))
    }

    /// A hover background that reaches `x` and `y` past the content, so the content stays on the grid.
    func hoverBackground(_ on: Bool, x: CGFloat = 8, y: CGFloat = 0) -> some View {
        padding(.horizontal, x)
            .padding(.vertical, y)
            .background(RoundedRectangle(cornerRadius: Radius.of(8), style: .continuous).fill(on ? Color.ink.opacity(0.08) : .clear))
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
                                .font(.figure(24, weight: .semibold))
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
                                .font(.figure(17, weight: .medium))
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
/// The Customize page sets which show and in what order; an odd one out takes the whole last row.
/// With Sensors & Fans off there's no temperature tile.
/// One of the readings: CPU, memory, GPU, disk, network or temperature. Temperatures are read only
/// while their tile is on screen.
private struct ReadingTile: View {
    var reading: PanelLayoutStore.Card
    var system: SystemMonitor
    var sensors: SensorsModule?
    var wide: Bool

    var body: some View {
        tile(reading, wide: wide)
            .background {
                if reading == .temperature, let sensors {
                    VisibilityReader { visible in visible ? sensors.begin() : sensors.end() }
                }
            }
    }

    @ViewBuilder
    private func tile(_ reading: PanelLayoutStore.Card, wide: Bool) -> some View {
        switch reading {
        case .cpu:
            StatTile(caption: "CPU", value: Format.percent(system.cpu.total), unit: "%", detail: loadText,
                     page: .cpu, help: "Processor load · load average \(loadValue)",
                     spokenName: "CPU", spokenValue: "\(Format.percent(system.cpu.total)) percent, load average \(loadValue)", wide: wide) {
                Sparkline(values: system.cpuHistory, color: .themeAccent, stretch: true)
            }
        case .memory:
            StatTile(caption: "Memory", value: Format.percent(system.memory?.usedFraction ?? 0), unit: "%", detail: memoryUsed,
                     alert: system.memory?.pressure == .critical, page: .memory,
                     help: "Memory used · pressure \(system.memory?.pressure.label.lowercased() ?? "unknown")",
                     spokenName: "Memory", spokenValue: "\(Format.percent(system.memory?.usedFraction ?? 0)) percent, \(memoryUsed) used",
                     wide: wide) {
                Sparkline(values: system.memoryHistory, color: .themeAccent, stretch: true)
            }
        case .gpu:
            StatTile(caption: "GPU", value: Format.percent(system.gpu?.utilization ?? 0), unit: "%", detail: gpuMemory,
                     page: .gpu, help: "Graphics load",
                     spokenName: "GPU", spokenValue: "\(Format.percent(system.gpu?.utilization ?? 0)) percent", wide: wide) {
                Sparkline(values: system.gpuHistory, color: .themeAccent, stretch: true)
            }
        case .disk:
            let disk = system.rootVolume.map { Format.diskParts($0.available) } ?? ("—", "")
            let full = (system.rootVolume?.usedFraction ?? 0) >= 0.95
            StatTile(caption: "Disk", value: disk.0, unit: disk.1, detail: "free", alert: full, page: .disk,
                     help: "Free space on \(system.rootVolume?.name ?? "the startup disk")",
                     spokenName: "Disk", spokenValue: system.rootVolume == nil ? "unavailable" : "\(disk.0) \(disk.1) free", wide: wide) {
                Meter(value: system.rootVolume?.usedFraction ?? 0, height: 4, alert: full, fill: .themeAccent, track: Color.ink.opacity(0.1))
                    .frame(height: 4)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 4)
            }
        case .network:
            let down = Format.rateParts(system.networkIn)
            StatTile(caption: "Network", value: down.0, unit: down.1, detail: "↑ " + Format.rate(system.networkOut),
                     prefix: "↓", page: .network, help: "Downloading and uploading",
                     spokenName: "Network",
                     spokenValue: "download \(Format.spokenRate(system.networkIn)), upload \(Format.spokenRate(system.networkOut))",
                     wide: wide) {
                Sparkline(values: system.networkHistory, color: .themeAccent, stretch: true)
            }
        case .temperature:
            let hot = (temperature ?? 0) >= 95
            StatTile(caption: "Temp", value: temperature.map { "\(Int($0.rounded()))" } ?? "—", unit: temperature == nil ? "" : "°C",
                     detail: fanText, alert: hot, page: .sensors, help: temperatureHelp,
                     spokenName: "Temperature",
                     spokenValue: temperature.map { "\(Int($0.rounded())) degrees Celsius" + ((sensors?.summary?.gpuAverage).map { ", graphics \(Int($0.rounded())) degrees" } ?? "") } ?? "unavailable",
                     wide: wide) {
                Meter(value: ((temperature ?? 30) - 30) / 70, height: 4, alert: hot, fill: .themeAccent, track: Color.ink.opacity(0.1))
                    .frame(height: 4)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 4)
            }
        default:
            EmptyView()
        }
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

    /// The graphics chip's temperature beside the processor's (the fans have a card of their own).
    private var fanText: String {
        guard let gpu = sensors?.summary?.gpuAverage else { return "" }
        return "GPU \(Int(gpu.rounded()))°"
    }

    private var temperatureHelp: String {
        guard temperature != nil else { return "No temperature sensor could be read on this Mac" }
        return ["Processor temperature", sensors?.summary?.gpuAverage.map { "graphics \(Int($0.rounded())) °C" } ?? ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
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
                    // The caption keeps its width; the detail beside it gives way.
                    Caption(caption)
                        .lineLimit(1)
                        .fixedSize()
                    Spacer(minLength: 4)
                    Text(detail)
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(Color.ink3)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
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
                            .font(.figure(21, weight: .medium))
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
            .background(CardSurface(radius: 10, hovering: hovering))
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

// MARK: - Controls

/// The things you switch on from the menu bar, one line each: Stay awake, the auto clicker and the
/// fan. Next to each other on the panel they share a card. A row grows only while it's in use (a
/// session's countdown, the clicker's count, the fan's custom speed).
private struct ControlRows: View {
    var model: AppModel
    var ids: [String]
    var editing: PanelEditing?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                Editable(id: id, editing: editing, radius: 8) {
                    Group {
                        switch id {
                        case "awake": if let awake = model.awake { AwakeRow(awake: awake) }
                        case "clicker": if let clicker = model.clicker { ClickerRow(clicker: clicker, model: model) }
                        case "fan": if let sensors = model.sensors { FanRow(sensors: sensors) }
                        default: EmptyView()
                        }
                    }
                    .padding(.vertical, 5)
                }
                if index < ids.count - 1 { Hairline().opacity(0.5) }
            }
        }
        .panelCard(vertical: 3)
    }
}

/// A control row's name in the panel's title weight; while the control is running, an accent dot
/// ahead of it (the panel's one colour for what's live).
private struct RowLabel: View {
    var symbol: String
    var title: String
    var live = false
    var help: String?

    var body: some View {
        HStack(spacing: 5) {
            if live {
                Circle().fill(Color.themeAccent).frame(width: 6, height: 6)
                    .transition(.scale.combined(with: .opacity))
            }
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.ink)
        }
        .fixedSize()
        .help(help ?? title)
        .animation(Motion.micro, value: live)
    }
}

/// The auto clicker on one line: its name, what it'll do, a chevron for the speed and button, and
/// its switch. Switched on here, it starts 2 s after the panel closes (so it doesn't click the panel).
private struct ClickerRow: View {
    @Bindable var clicker: ClickerModule
    var model: AppModel
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                RowLabel(symbol: ModuleID.clicker.symbol, title: clicker.state == .clicking ? "Clicking" : "Auto clicker",
                         live: clicker.isOn)
                Text(detail)
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color.ink3)
                    .lineLimit(1)
                    .contentTransition(.numericText())
                Spacer(minLength: 4)
                Button {
                    withAnimation(Motion.snappy) { expanded.toggle() }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.ink3)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expanded ? "Fewer settings" : "Speed and button")
                InkSwitch(isOn: Binding(get: { clicker.isOn }, set: { on in
                    if on { afterPanelCloses { clicker.begin(fromPanel: true) } } else { clicker.end("Stopped") }
                }), label: "Auto clicker")
                .help(clicker.isOn ? "Stop clicking" : "Start clicking 2 s after the panel closes")
            }
            .frame(height: 26)
            if expanded {
                HStack(spacing: 8) {
                    InkStepper(label: "CPS", value: Int(clicker.settings.clicksPerSecond.rounded()), range: 1...100) { value in
                        clicker.update { $0.clicksPerSecond = Double(value) }
                    }
                    Spacer(minLength: 4)
                    InkSegmented(selection: Binding(get: { clicker.settings.button }, set: { value in clicker.update { $0.button = value } }),
                                 options: ClickButton.allCases.map { ($0, $0.title) })
                        .fixedSize()
                }
                .transition(.opacity)
                HStack {
                    Text(clicker.settings.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.ink3)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    QuietLink(title: "More…") { showInApp(.clicker) }
                }
                .transition(.opacity)
            }
            if let notice = clicker.notice {
                Text(notice)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var detail: String {
        let keys = model.shortcuts.shortcut(for: .toggleClicker)?.displayString
        switch clicker.state {
        case .idle: return [clicker.settings.speedLabel, keys].compactMap { $0 }.joined(separator: " · ")
        case .countdown(let n): return "in \(n)…"
        case .clicking: return "\(clicker.clicks.formatted()) · \(clicker.settings.speedLabel)"
        }
    }
}

// MARK: - Stay Awake

/// Stay Awake: type a time (or pick one) and the Mac stays on, lid closed included. While it runs:
/// the countdown, when it ends, chips to add time, End, and one line on what the lid does.
private struct AwakeRow: View {
    @Bindable var awake: StayAwakeModule
    @State private var typed = ""
    @State private var visible = false
    @State private var shake = 0
    @FocusState private var focused: Bool

    private var typedSeconds: TimeInterval? { AwakeDuration.seconds(from: typed) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let session = awake.session {
                running(session)
            } else {
                idle
            }
            status
        }
        .animation(Motion.snappy, value: awake.isRunning)
        .background(VisibilityReader { visible = $0 })
    }

    // Idle: one line, the name, a field and three chips (8h and more: type it).
    private var idle: some View {
        HStack(spacing: 6) {
            RowLabel(symbol: ModuleID.awake.symbol, title: "Stay awake",
                     help: awake.lastEnded.map { "Last session: \($0)" } ?? "The lid can close and agents keep going")
            Spacer(minLength: 4)
            field(placeholder: "Time…")
                .frame(width: 66)
            ForEach(AwakeDuration.presets.prefix(3), id: \.self) { seconds in
                TimeChip(title: AwakeDuration.label(seconds), help: "Stay awake for \(AwakeDuration.label(seconds))") {
                    awake.start(for: seconds)
                }
            }
        }
        .frame(height: 26)
        .transition(.opacity)
    }

    // Running: the countdown, its end, chips to add time, End.
    private func running(_ session: StayAwakeModule.Session) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                RowLabel(symbol: ModuleID.awake.symbol, title: "Awake", live: true)
                if session.agents == true {
                    Text("while agents work")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.ink3)
                    Spacer(minLength: 8)
                } else {
                    Text("until \(session.endsAt.formatted(date: session.endsAt.timeIntervalSinceNow > 20 * 3600 ? .abbreviated : .omitted, time: .shortened))")
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(Color.ink3)
                    Spacer(minLength: 8)
                    countdown(session)
                }
            }
            .lineLimit(1)
            HStack(spacing: 6) {
                ForEach(AwakeDuration.additions, id: \.self) { seconds in
                    TimeChip(title: "+" + AwakeDuration.label(seconds), help: "Add \(AwakeDuration.label(seconds))") {
                        awake.start(for: seconds)
                    }
                }
                field(placeholder: "Add time")
                Button("End") { awake.endNow() }
                    .buttonStyle(OutlineButtonStyle(compact: true))
                    .fixedSize()
                    .help("Let the Mac sleep as usual again")
            }
        }
        .transition(.opacity)
    }

    @ViewBuilder
    private func countdown(_ session: StayAwakeModule.Session) -> some View {
        if visible {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                countdownText(session.endsAt.timeIntervalSince(context.date))
            }
        } else {
            countdownText(session.endsAt.timeIntervalSinceNow)
        }
    }

    private func countdownText(_ remaining: TimeInterval) -> some View {
        let parts = AwakeDuration.countdown(remaining)
        return (Text(parts.main).foregroundStyle(Color.ink) + Text(parts.seconds).foregroundStyle(Color.ink4))
            .font(.figure(15, weight: .semibold))
            .contentTransition(.numericText(countsDown: true))
            .accessibilityLabel("\(AwakeDuration.menuBar(remaining)) left")
    }

    /// The typed time: Enter starts it (or adds it while running); a time it can't read shakes.
    private func field(placeholder: String) -> some View {
        TextField(placeholder, text: $typed)
            .textFieldStyle(.plain)
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundStyle(Color.ink)
            .focused($focused)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: Radius.of(7), style: .continuous).fill(Color.ink.opacity(focused ? 0.09 : 0.06)))
            .overlay(alignment: .trailing) {
                if typedSeconds != nil {
                    Text("↩")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.ink3)
                        .padding(.trailing, 7)
                        .transition(.opacity)
                }
            }
            .modifier(Shake(count: shake))
            .onSubmit {
                guard let seconds = typedSeconds else {
                    if !typed.isEmpty { withAnimation(.linear(duration: 0.3)) { shake += 1 } }
                    return
                }
                awake.start(for: seconds)
                typed = ""
            }
            .help("Minutes (90), or with units: 2h30, 1.5h, 1d 6h, 45m")
            .accessibilityLabel(awake.isRunning ? "Add time" : "Stay awake for")
            .animation(Motion.micro, value: typedSeconds != nil)
    }

    /// One quiet line: what closing the lid does, why it can't, or what happened.
    @ViewBuilder
    private var status: some View {
        let line = statusLine
        if let line {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(line)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if awake.isRunning && !awake.lidSafe && awake.helperStatus != .enabled {
                    Button("Set Up") { awake.setUpHelper() }
                        .buttonStyle(OutlineButtonStyle(compact: true))
                        .fixedSize()
                }
            }
            .transition(.opacity)
        }
    }

    private var statusLine: String? {
        guard awake.isRunning else { return nil }
        if let notice = awake.notice { return notice }
        if let hotspot = awake.hotspotStatus { return hotspot }
        var parts: [String] = []
        if let closed = awake.lastClosed {
            var done: [String] = []
            if closed.darkened { done.append("display off") }
            if closed.muted { done.append("sound muted") }
            if !closed.paused.isEmpty || !closed.pausedNames.isEmpty {
                done.append(closed.pausedNames.count == 1 ? "\(closed.pausedNames[0]) paused" : "\(closed.pausedNames.count) apps paused")
            }
            if !done.isEmpty { parts.append("While closed: " + done.joined(separator: ", ") + ".") }
        }
        if let reason = awake.lowPowerReason, !awake.lidClosed { parts.append("Low Power Mode on (\(reason)).") }
        if awake.isAgentSession, parts.isEmpty {
            return "Ends \(awake.policy.agentQuietMinutes) min after they go quiet. Close the lid any time."
        }
        if parts.isEmpty { return awake.lidSafe ? "Close the lid any time: it stays on." : nil }
        return parts.joined(separator: " ")
    }
}

/// A small time chip: "2h", "+15m".
private struct TimeChip: View {
    var title: String
    var help: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(hovering ? Color.ink : Color.ink2)
                .padding(.horizontal, 7)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: Radius.of(7), style: .continuous).fill(Color.ink.opacity(hovering ? 0.12 : 0.07)))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .fixedSize()
        .onHover { hovering = $0 }
        .animation(Motion.micro, value: hovering)
        .help(help)
    }
}

/// A short side-to-side shake for a time the field can't read.
private struct Shake: GeometryEffect {
    var count: Int
    var animatableData: CGFloat

    init(count: Int) {
        self.count = count
        animatableData = CGFloat(count)
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 4 * sin(animatableData * .pi * 4), y: 0))
    }
}

// MARK: - Sound

/// The apps on the Mac as icons: click one to mute it at the speakers. Muted apps first, then
/// the ones playing, then the rest in the order they opened.
// MARK: - Fan

/// Auto, Custom or Max for the fans, right in the panel (Bryan: "very useful and convenient to have
/// there"). Every fan follows the one choice; the helper set-up and the full fan page are in the app.
private struct FanRow: View {
    @Bindable var sensors: SensorsModule
    @State private var customRPM: Double = 0

    private enum Choice: Hashable { case auto, custom, maximum }

    private var fan: FanReading? { sensors.fans.first }

    private var choice: Choice {
        switch fan.flatMap({ sensors.commands[$0.index] }) {
        case .none, .auto?: .auto
        case .rpm?: .custom
        case .maximum?: .maximum
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                RowLabel(symbol: "fan", title: "Fan")
                Text(speed)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color.ink3)
                    .contentTransition(.identity)
                Spacer(minLength: 6)
                InkSegmented(selection: Binding(get: { choice }, set: { select($0) }),
                             options: [(Choice.auto, "Auto"), (.custom, "Custom"), (.maximum, "Max")])
                    .fixedSize()
                    .help("Auto: macOS controls the fan · Custom: hold a speed you choose · Max: full speed, for heavy work")
            }
            if choice == .custom, let fan {
                HStack(spacing: 8) {
                    Slider(value: $customRPM, in: fan.minRPM...fan.maxRPM, step: 100) { editing in
                        if !editing { apply(.rpm(customRPM)) }
                    }
                    .controlSize(.mini)
                    .accessibilityLabel("Fan speed")
                    Text("\(Format.number(Int(customRPM))) rpm")
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(Color.ink2)
                        .frame(width: 70, alignment: .trailing)
                }
                .transition(.opacity)
            }
            // Why a choice didn't take: the helper isn't set up, or it answered with an error.
            if let message = sensors.helperMessage {
                HStack(spacing: 8) {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    if sensors.helperStatus != .enabled {
                        Button("Set Up") { afterPanelCloses { MainWindowController.shared.show(page: .sensors) } }
                            .buttonStyle(OutlineButtonStyle(compact: true))
                    }
                }
            }
        }
        .animation(Motion.snappy, value: choice)
        .background(VisibilityReader { visible in visible ? sensors.begin() : sensors.end() })
        .onAppear {
            if let fan, case .rpm(let rpm)? = sensors.commands[fan.index] { customRPM = rpm }
            else if let fan { customRPM = fan.minRPM + (fan.maxRPM - fan.minRPM) / 2 }
        }
        .onChange(of: fan?.maxRPM) {
            if let fan, customRPM == 0 { customRPM = fan.minRPM + (fan.maxRPM - fan.minRPM) / 2 }
        }
    }

    private var speed: String {
        guard let fan else { return "" }
        return fan.isStopped ? "Off" : "\(Format.number(Int(fan.currentRPM))) rpm"
    }

    private func select(_ choice: Choice) {
        switch choice {
        case .auto: apply(.auto)
        case .custom: apply(.rpm(customRPM))
        case .maximum: apply(.maximum)
        }
    }

    /// Every fan gets the same choice (a custom speed is clamped to each fan's own range).
    private func apply(_ command: FanCommand) {
        for fan in sensors.fans { sensors.set(command, for: fan) }
    }
}

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
                .background(Circle().fill(Color.ink.opacity(0.08)))
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

// MARK: - Battery, small or wide

/// The battery: the full card when wide, a tile with the charge and the watts when small. A Mac
/// without a battery shows its busiest apps instead.
private struct BatteryWidget: View {
    var model: AppModel
    var wide: Bool

    var body: some View {
        if let system = model.system {
            if let battery = system.battery {
                if wide {
                    BatteryCard(battery: battery, system: system)
                } else {
                    let low = battery.percent <= 10 && !battery.isPluggedIn
                    StatTile(caption: "Battery", value: "\(battery.percent)", unit: "%",
                             detail: Format.watts(battery.powerDraw) + " W", alert: low, page: .battery,
                             help: "Battery · \(battery.stateText)",
                             spokenName: "Battery", spokenValue: "\(battery.percent) percent, \(battery.stateText)", wide: false) {
                        BatteryGlyph(level: Double(battery.percent) / 100, charging: battery.isCharging, alert: low)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            } else {
                BusyAppsList(apps: system.busyApps, measured: system.busyAppsMeasured).panelCard()
            }
        }
    }
}

// MARK: - Plugins' cards

/// A plugin's card: what its command printed, drawn like Tutto's own tiles in the theme's colours.
/// It refreshes while it's on screen (the panel, the Customize preview). Clicking it opens its
/// link, or runs the plugin, or refreshes the card.
private struct PluginCard: View {
    var model: AppModel
    var id: UUID
    var wide: Bool
    @State private var hovering = false

    var body: some View {
        if let plugin = model.plugins.plugin(id) {
            let state = model.plugins.cards[id] ?? PluginCardState()
            Button {
                click(plugin, state.content)
            } label: {
                card(plugin, state)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(state.failure.map { "\(plugin.name) failed: \($0)" } ?? help(plugin, state.content))
            .accessibilityLabel(state.content?.title ?? plugin.name)
            .accessibilityValue([state.content?.value, state.content?.unit, state.content?.detail].compactMap { $0 }.joined(separator: " "))
            .background(VisibilityReader { visible in model.plugins.host.card(id, shown: visible) })
        }
    }

    private func card(_ plugin: ScriptPlugin, _ state: PluginCardState) -> some View {
        let content = state.content
        let alert = content?.level == .alert || (state.failure != nil && content == nil)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if content?.level == .notice {
                    Circle().fill(Color.themeAccent).frame(width: 5, height: 5)
                }
                Caption(content?.title ?? plugin.name)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                if state.running && content == nil {
                    ProgressView().controlSize(.mini)
                } else if let line = state.failure ?? content?.detail {
                    Text(line)
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(state.failure != nil ? Color.alert : Color.ink3)
                        .lineLimit(1)
                }
            }
            HStack(alignment: .bottom, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    if let symbol = content?.symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.ink3)
                    }
                    Text(content?.value ?? "—")
                        .font(.figure(21))
                        .foregroundStyle(alert ? Color.alert : Color.ink)
                    if let unit = content?.unit {
                        Text(unit)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.ink3)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .layoutPriority(1)
                Spacer(minLength: 2)
                graph(content, alert: alert)
                    .frame(minWidth: 26, maxWidth: wide ? 120 : 46)
                    .frame(height: 20)
            }
            .frame(height: 24)
            if wide, let items = content?.items, !items.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(items.prefix(5).enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 6) {
                            if let symbol = item.symbol {
                                Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(Color.ink3).frame(width: 14)
                            }
                            Text(item.title)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Color.ink2)
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            if let detail = item.detail {
                                Text(detail).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Color.ink3).lineLimit(1)
                            }
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, PanelGrid.inset)
        .padding(.vertical, 9)
        .frame(width: wide ? PanelGrid.tile * 2 + PanelGrid.gap : PanelGrid.tile, alignment: .leading)
        .background(CardSurface(radius: 10, hovering: hovering))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func graph(_ content: PluginWidgetContent?, alert: Bool) -> some View {
        if let content, content.series.count >= 2 {
            Sparkline(values: content.normalizedSeries(), color: alert ? .alert : .themeAccent, stretch: true)
        } else if let progress = content?.progress {
            Meter(value: progress, height: 4, alert: alert, fill: .themeAccent, track: Color.ink.opacity(0.1))
                .frame(height: 4)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 4)
        } else {
            Color.clear
        }
    }

    private func help(_ plugin: ScriptPlugin, _ content: PluginWidgetContent?) -> String {
        if let url = content?.url { return "Open \(url)" }
        return plugin.hasAction ? "Run \(plugin.name)" : "Refresh"
    }

    private func click(_ plugin: ScriptPlugin, _ content: PluginWidgetContent?) {
        if let link = content?.url, let url = URL(string: link), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            afterPanelCloses { NSWorkspace.shared.open(url) }
        } else if plugin.hasAction {
            model.plugins.run(plugin)
        } else {
            model.plugins.refreshCard(plugin)
        }
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

    /// The tools to show, in the order set on the Customize page.
    static func visible(_ model: AppModel) -> [Row] {
        let all = rows(model)
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return model.layout.tools(available: all.map(\.id)).compactMap { byID[$0] }
    }

    /// Every tool that could be in the row: the built-in ones whose tool is on, then your plugins.
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
        for plugin in model.plugins.plugins where model.plugins.isOn(plugin) && plugin.hasAction {
            rows.append(Row(action: .plugin(plugin.id), title: plugin.name, short: plugin.name, symbol: plugin.symbol))
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
        // Six to a row at most; each tile an equal share of its row, so a long shortcut can't widen it.
        let lines = PanelLayout.rows(ShortcutRows.visible(model), perRow: PanelLayout.toolsPerRow)
        let count = CGFloat(min(max(lines.first?.count ?? 1, 1), PanelLayout.toolsPerRow))
        let tile = (PanelGrid.width - 2 * PanelGrid.outer - 2 * Self.inset - Self.gap * (count - 1)) / count
        VStack(alignment: .leading, spacing: Self.gap) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(spacing: Self.gap) {
                    ForEach(line) { row in
                        ToolTile(row: row, shortcut: model.shortcuts.shortcut(for: row.action), launching: $launching) {
                            afterPanelCloses { model.perform(row.action) }
                        }
                        .frame(width: tile)
                    }
                }
            }
        }
        .padding(.horizontal, Self.inset)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(CardSurface(radius: 12))
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
            .background(RoundedRectangle(cornerRadius: Radius.of(8), style: .continuous).fill(hovering ? Color.ink.opacity(0.08) : .clear))
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
                .foregroundStyle(lit > 0 ? Color.themeAccent : Color.ink2)
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
                    .background(RoundedRectangle(cornerRadius: Radius.of(3), style: .continuous).fill(lit > index ? Color.themeAccent : Color.wash))
                    .overlay(RoundedRectangle(cornerRadius: Radius.of(3), style: .continuous).strokeBorder(lit > index ? Color.clear : Color.hairline))
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
            if let strip = model.strip, strip.isRunning {
                WindowModeSwitch(strip: strip)
            }
            if let system = model.system, let footprint = system.ownFootprint {
                // What Tutto itself costs, right now: never a guess.
                Text("\(Int(footprint.rounded())) MB")
                    .font(.geist(10.5, weight: .medium))
                    .foregroundStyle(Color.ink3)
                    .help("What Tutto itself is using right now: \(ownCost(footprint, system.ownCPU))")
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

/// Strip ⇄ full windows, as two words: the one in use in ink on a faint pill, the other quiet.
/// Every window on the strip switches size at once (⌃⌥⇧F does the same).
private struct WindowModeSwitch: View {
    var strip: StripModule

    var body: some View {
        HStack(spacing: 1) {
            option("Strip", full: false)
            option("Full", full: true)
        }
        .padding(2)
        .background(Capsule().fill(Color.ink.opacity(0.06)))
        .disabled(strip.isSwitchingWindows)
        .help("Windows side by side on the strip, or every window in full screen as its green button does (⌃⌥⇧F)")
    }

    private func option(_ title: String, full: Bool) -> some View {
        let selected = strip.fullWindows == full
        return Button {
            guard !selected else { return }
            // Windows slide into Spaces of their own (or back): the panel goes first.
            afterPanelCloses { strip.setFullWindows(full) }
        } label: {
            Text(title)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.ink : Color.ink3)
                .padding(.horizontal, 7)
                .frame(height: 18)
                .background(Capsule().fill(selected ? Color.ink.opacity(0.1) : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(full ? "Full windows" : "Strip")
        .accessibilityAddTraits(selected ? .isSelected : [])
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
        .background(CardSurface(radius: 12))
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
                RoundedRectangle(cornerRadius: Radius.of(4), style: .continuous)
                    .strokeBorder(Color.ink.opacity(0.55), lineWidth: 1.2)
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: Radius.of(2), style: .continuous)
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
            RoundedRectangle(cornerRadius: Radius.of(1), style: .continuous)
                .fill(Color.ink.opacity(0.55))
                .frame(width: 2, height: 6)
        }
        .accessibilityHidden(true)
    }
}
