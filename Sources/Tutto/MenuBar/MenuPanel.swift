//
//  MenuPanel.swift
//  Tutto
//
//  The menu bar panel: what you click the menu bar for, and nothing else. How the Mac is doing
//  (a verdict line, the four numbers people check large, GPU, disk and network small, every
//  number a click away from its page), per-app sound, and the tools' shortcuts as rows you can
//  click. Settings live in the app. Each part appears only if its module is on, and readings
//  run only while the panel is open.
//
//  One grid: cards inset 10 pt from the panel, content 12 pt inside them (text starts at
//  x = 22 and ends at 298), 8 pt between blocks. Hover backgrounds reach outward, so nothing
//  moves. One accent (the system's), on meters and the playing badge; red only for alarms.
//

import AppKit
import SwiftUI
import TuttoKit

private enum Grid {
    static let width: CGFloat = 320
    static let outer: CGFloat = 10
    static let inset: CGFloat = 12
    static let gap: CGFloat = 8
    /// Columns in the stats card: the content width split in four.
    static let column: CGFloat = (width - 2 * outer - 2 * inset) / 4
}

struct MenuPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Grid.gap) {
            if let system = model.system {
                VitalsCard(system: system, sensors: model.sensors)
            }
            if let sound = model.sound, SoundModule.isSupported {
                SoundCard(sound: sound)
            }
            if !ShortcutRows.rows(model).isEmpty {
                ShortcutsCard(model: model)
            }
            Notices(model: model)
            PanelFooter(model: model)
        }
        .padding(.horizontal, Grid.outer)
        .padding(.top, Grid.outer)
        .padding(.bottom, 6)
        .frame(width: Grid.width)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Pieces

private extension View {
    /// A group on the panel: a soft rounded surface instead of rules and captions.
    func panelCard() -> some View {
        padding(Grid.inset)
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

// MARK: - Vitals

/// How the Mac is doing: the verdict as the card's title, the four numbers people check, and
/// GPU, disk and network on the same columns underneath. Every number opens its page.
private struct VitalsCard: View {
    var system: SystemMonitor
    var sensors: SensorsModule?

    private enum Vital: Hashable { case battery, cpu, memory, temperature, gpu }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VerdictLine(glance: glance)
            HStack(alignment: .top, spacing: 0) {
                ForEach(heroes, id: \.self) { vital in column(vital) }
            }
            HStack(spacing: 0) {
                if !heroes.contains(.gpu) {
                    SmallReadout(label: "GPU", value: "\(Format.percent(system.gpu?.utilization ?? 0))%", page: .gpu, help: "Graphics load")
                }
                if let volume = system.rootVolume {
                    SmallReadout(label: "Disk", value: diskFree(volume.available), page: .disk, help: "Free space on \(volume.name)")
                }
                SmallReadout(label: "↓", value: Format.rate(system.networkIn), page: .network, help: "Downloading")
                SmallReadout(label: "↑", value: Format.rate(system.networkOut), page: .network, help: "Uploading")
            }
        }
        .panelCard()
        .watching(system, system.panelFeeds)
        .background(VisibilityReader { visible in
            guard let sensors else { return }
            visible ? sensors.begin() : sensors.end()
        })
    }

    private var glance: Glance {
        Glance.make(battery: system.battery, cpu: system.cpu.total, memoryPressure: system.memory?.pressure,
                    hottest: sensors?.summary?.hottest, diskFree: system.rootVolume?.available,
                    diskUsed: system.rootVolume?.usedFraction)
    }

    private var temperature: Double? { sensors?.summary.flatMap { $0.cpuAverage ?? $0.socAverage } }

    private var heroes: [Vital] {
        var list: [Vital] = system.battery == nil ? [] : [.battery]
        list += [.cpu, .memory]
        if temperature != nil { list.append(.temperature) }
        if list.count < 4 { list.insert(.gpu, at: min(2, list.count)) }
        return Array(list.prefix(4))
    }

    /// Whole gigabytes above 10 ("96 GB"), one decimal below ("9.6 GB").
    private func diskFree(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 1000 { return String(format: "%.1f TB", gb / 1000) }
        return gb >= 10 ? "\(Int(gb.rounded())) GB" : String(format: "%.1f GB", gb)
    }

    @ViewBuilder
    private func column(_ vital: Vital) -> some View {
        switch vital {
        case .battery:
            let battery = system.battery
            let percent = battery?.percent ?? 0
            VitalColumn(label: "Battery", value: "\(percent)", unit: "%", fraction: Double(percent) / 100,
                        alert: percent <= 10 && battery?.isPluggedIn == false, page: .battery,
                        help: battery.map { "\($0.stateText), \($0.percent)%" } ?? "Battery",
                        badge: battery?.isCharging == true ? "bolt.fill" : nil)
        case .cpu:
            VitalColumn(label: "CPU", value: Format.percent(system.cpu.total), unit: "%", fraction: system.cpu.total,
                        page: .cpu, help: "Processor load")
        case .memory:
            let used = system.memory?.usedFraction ?? 0
            VitalColumn(label: "Memory", value: Format.percent(used), unit: "%", fraction: used,
                        alert: system.memory?.pressure == .critical, page: .memory,
                        help: "Memory used · pressure \(system.memory?.pressure.label.lowercased() ?? "unknown")")
        case .temperature:
            let celsius = temperature ?? 0
            VitalColumn(label: "Temp", value: temperature.map { "\(Int($0.rounded()))" } ?? "—", unit: "°C",
                        fraction: (celsius - 30) / 70, alert: celsius >= 95, page: .sensors, help: fanHelp)
        case .gpu:
            let load = system.gpu?.utilization ?? 0
            VitalColumn(label: "GPU", value: Format.percent(load), unit: "%", fraction: load, page: .gpu, help: "Graphics load")
        }
    }

    private var fanHelp: String {
        guard let fan = sensors?.fans.first else { return "Temperatures" }
        return fan.isStopped ? "Temperatures · fan off" : "Temperatures · fan \(Format.number(Int(fan.currentRPM))) rpm"
    }
}

/// The stats card's title: the verdict on the left, its detail on the right. A problem gets a ⚠︎
/// ahead of it (red when it's an alarm); a calm Mac gets nothing.
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

/// Small label, a large light number with a small unit, and a meter in the accent colour.
/// One quarter of the card; opens its page.
private struct VitalColumn: View {
    var label: String
    var value: String
    var unit: String
    var fraction: Double
    var alert = false
    var page: MainPage
    var help: String
    /// An SF Symbol beside the label (a bolt while the battery charges).
    var badge: String?
    @State private var hovering = false

    var body: some View {
        Button {
            showInApp(page)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    Text(label)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.ink3)
                    if let badge {
                        Image(systemName: badge)
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(Color.ink3)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(value)
                        .font(.system(size: 28, weight: .light).monospacedDigit())
                        .foregroundStyle(alert ? Color.alert : Color.ink)
                    Text(unit)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.ink3)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                Meter(value: fraction, height: 3, alert: alert, fill: .accentColor, track: Color.primary.opacity(0.1))
                    .padding(.top, 4)
                    .padding(.trailing, 10)
            }
            .frame(width: Grid.column, alignment: .leading)
            .hoverBackground(hovering, x: 6, y: 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        // On the button itself, so it stays a button (a new element with `.ignore` wasn't one).
        .accessibilityLabel(label)
        .accessibilityValue("\(value)\(unit == "%" ? " percent" : (unit == "°C" ? " degrees" : unit))")
        .accessibilityHint("Shows details")
    }
}

/// A label and a value in one quarter of the card, for the second line.
private struct SmallReadout: View {
    var label: String
    var value: String
    var page: MainPage
    var help: String
    @State private var hovering = false

    var body: some View {
        Button {
            showInApp(page)
        } label: {
            HStack(spacing: 4) {
                Text(label).foregroundStyle(Color.ink3)
                Text(value).foregroundStyle(hovering ? Color.ink : Color.ink2)
            }
            .font(.system(size: 11.5).monospacedDigit())
            .lineLimit(1)
            .frame(width: Grid.column, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityElement(children: .combine)
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

// MARK: - Shortcuts

/// The tools' shortcuts, as rows: click one to do the same as pressing its keys.
@MainActor
enum ShortcutRows {
    struct Row: Identifiable {
        var action: ShortcutAction
        var title: String
        var symbol: String
        var id: String { action.id }
    }

    static func rows(_ model: AppModel) -> [Row] {
        var rows: [Row] = []
        if model.screenshots != nil {
            rows.append(Row(action: .captureArea, title: "Capture Area", symbol: "rectangle.dashed"))
            rows.append(Row(action: .captureAreaEdit, title: "Capture and Edit", symbol: "pencil.and.scribble"))
            rows.append(Row(action: .captureScreen, title: "Capture Screen", symbol: "laptopcomputer"))
        }
        if model.clipboard != nil { rows.append(Row(action: .clipboardHistory, title: "Clipboard History", symbol: "list.clipboard")) }
        if model.windows != nil { rows.append(Row(action: .windowPalette, title: "Snap Window", symbol: "rectangle.split.2x1")) }
        if model.wordCounter != nil { rows.append(Row(action: .wordCounter, title: "Count Words", symbol: ModuleID.wordCounter.symbol)) }
        return rows
    }
}

private struct ShortcutsCard: View {
    var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            CardTitle(title: "Shortcuts") { EmptyView() }
                .padding(.bottom, 4)
            ForEach(ShortcutRows.rows(model)) { row in
                ShortcutRow(row: row, shortcut: model.shortcuts.shortcut(for: row.action)) {
                    afterPanelCloses { model.perform(row.action) }
                }
            }
        }
        .panelCard()
    }
}

/// A row like a menu item: symbol and name on the left, the keys on the right the way a menu
/// sets them (modifiers, then the key in its own column). Clicking it presses the keys you'd
/// press: they light up one after another, then the panel closes and the tool runs.
private struct ShortcutRow: View {
    var row: ShortcutRows.Row
    var shortcut: KeyShortcut?
    var action: () -> Void
    @State private var hovering = false
    @State private var lit = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: press) {
            HStack(spacing: 10) {
                Image(systemName: row.symbol)
                    .font(.system(size: 12.5))
                    .foregroundStyle(hovering ? Color.ink : Color.ink2)
                    .frame(width: 18)
                Text(row.title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.ink)
                Spacer(minLength: 8)
                if let shortcut { keys(shortcut.symbols) }
            }
            .frame(height: 24)   // a native menu row
            .hoverBackground(hovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .help(shortcut.map { "\(row.action.title) (\($0.displayString))" } ?? row.action.title)
        .accessibilityLabel(row.title)
        .accessibilityValue(shortcut?.spokenDescription ?? "")
    }

    /// ⇧⌘ right-aligned, then the key in a fixed column, as in a native menu. While pressed, each
    /// key fills in turn with the accent.
    private func keys(_ symbols: [String]) -> some View {
        HStack(spacing: 1) {
            ForEach(Array(symbols.enumerated()), id: \.offset) { index, symbol in
                Text(symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(lit > index ? Color.white : Color.ink3)
                    .frame(minWidth: index == symbols.count - 1 ? 12 : nil)
                    .padding(.horizontal, 1.5)
                    .background(RoundedRectangle(cornerRadius: 3.5, style: .continuous).fill(Color.accentColor).opacity(lit > index ? 1 : 0))
            }
        }
    }

    /// Keys light 30 ms apart (all at once under Reduce Motion), the tool runs 80 ms after the last,
    /// and the keys go dark once the panel has faded.
    private func press() {
        let count = shortcut?.symbols.count ?? 0
        let step = reduceMotion ? 0 : 0.03
        for index in 0..<count {
            DispatchQueue.main.asyncAfter(deadline: .now() + step * Double(index)) {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.05)) { lit = index + 1 }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + step * Double(count) + 0.08) {
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { lit = 0 }
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
        .padding(.leading, Grid.inset)
        .padding(.trailing, Grid.inset - 6)
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
        .padding(.horizontal, Grid.inset)
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
