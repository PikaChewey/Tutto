//
//  PanelStudies.swift
//  Tutto
//
//  Layout studies for a shorter panel (Bryan, 2026-11-20: the panel is "too long. By default, you
//  have to scroll to see everything ... compact it more so that everything fits on one panel").
//  Each study is drawn from the real cards with the real readings, at rest and after one click,
//  for the snapshot board (`--snapshot DIR study-<name> agents-demo`). Nothing here ships.
//

#if DEBUG
import SwiftUI
import TuttoKit

/// The panel's frame for a study: the same margins, width and stand-in material as the real one.
struct StudyPanel<Content: View>: View {
    var width: CGFloat = PanelGrid.width
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: PanelGrid.gap) { content }
            .padding(.horizontal, PanelGrid.outer)
            .padding(.top, PanelGrid.outer)
            .padding(.bottom, 6)
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
            .background(PanelMaterialStandIn())
            .tint(Color.themeAccent)
    }
}

// MARK: - Shared parts

/// The header with the battery folded in: the charge where Tutto's mark was, then the verdict
/// ("On battery · 50 min left"), then the watts. Replaces the battery card's 100 pt.
struct StudyBatteryHeader: View {
    var model: AppModel

    var body: some View {
        HStack(alignment: .center, spacing: 7) {
            if let system = model.system, let battery = system.battery {
                BatteryGlyph(level: Double(battery.percent) / 100, charging: battery.isCharging, alert: battery.percent <= 10)
                    .scaleEffect(0.8)
                    .frame(width: 26)
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(battery.percent)").font(.figure(14, weight: .semibold)).foregroundStyle(Color.ink)
                    Text("%").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Color.ink3)
                }
                Text("·").foregroundStyle(Color.ink3)
                let glance = StudyData.glance(model)
                // The charge is already on the left: no second "31%" on the right.
                VerdictLine(glance: Glance(glance.title, glance.detail?.hasSuffix("%") == true ? nil : glance.detail, level: glance.level))
                if let watts = battery.powerDraw, !battery.isPluggedIn {
                    Text("· \(Format.watts(watts)) W")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(Color.ink3)
                        .fixedSize()
                }
            } else {
                PanelHeader(model: model)
            }
        }
        .frame(height: 22)
        .padding(.horizontal, PanelGrid.inset)
    }
}

enum StudyData {
    @MainActor static func glance(_ model: AppModel) -> Glance {
        guard let system = model.system else { return Glance("Tutto", nil) }
        return Glance.make(battery: system.battery, cpu: system.cpu.total, memoryPressure: system.memory?.pressure,
                           hottest: model.sensors?.summary?.hottest, heatPressure: HeatPressure.now,
                           diskFree: system.rootVolume?.available, diskUsed: system.rootVolume?.usedFraction)
    }

    struct Vital: Identifiable {
        var id: String { caption }
        var caption: String
        var value: String
        var unit: String
        var prefix: String = ""
        var fraction: Double?
        var history: [Double] = []
    }

    @MainActor static func vitals(_ model: AppModel) -> [Vital] {
        guard let system = model.system else { return [] }
        let disk = system.rootVolume.map { Format.diskParts($0.available) } ?? ("—", "")
        let down = Format.rateParts(system.networkIn)
        let temp = model.sensors?.summary.flatMap { $0.cpuAverage ?? $0.socAverage }
        return [
            Vital(caption: "CPU", value: Format.percent(system.cpu.total), unit: "%", fraction: system.cpu.total, history: system.cpuHistory),
            Vital(caption: "Memory", value: Format.percent(system.memory?.usedFraction ?? 0), unit: "%",
                  fraction: system.memory?.usedFraction, history: system.memoryHistory),
            Vital(caption: "GPU", value: Format.percent(system.gpu?.utilization ?? 0), unit: "%",
                  fraction: system.gpu?.utilization, history: system.gpuHistory),
            Vital(caption: "Disk", value: disk.0, unit: disk.1, fraction: system.rootVolume?.usedFraction),
            Vital(caption: "Network", value: down.0, unit: down.1, prefix: "↓", history: system.networkHistory),
            Vital(caption: "Temp", value: temp.map { "\(Int($0.rounded()))" } ?? "—", unit: temp == nil ? "" : "°C",
                  fraction: temp.map { ($0 - 30) / 70 }),
        ]
    }
}

/// The six readings in one card, three across: caption, number, a thin line. 104 pt where the
/// tiles took 150 (and the battery card 100 more).
struct StudyVitals: View {
    var model: AppModel
    var columns = 3

    var body: some View {
        let vitals = StudyData.vitals(model)
        let rows = stride(from: 0, to: vitals.count, by: columns).map { Array(vitals[$0 ..< min($0 + columns, vitals.count)]) }
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 14) {
                    ForEach(row) { vital in cell(vital).frame(maxWidth: .infinity, alignment: .leading) }
                }
            }
        }
        .panelCard(vertical: 10)
    }

    private func cell(_ vital: StudyData.Vital) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(vital.caption)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.ink3)
            HStack(alignment: .firstTextBaseline, spacing: 1.5) {
                if !vital.prefix.isEmpty {
                    Text(vital.prefix).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Color.ink3)
                }
                Text(vital.value).font(.figure(16, weight: .semibold)).foregroundStyle(Color.ink)
                Text(vital.unit).font(.system(size: 10, weight: .medium)).foregroundStyle(Color.ink3)
            }
            .lineLimit(1)
            .fixedSize()
            Group {
                if vital.history.count > 2 {
                    Sparkline(values: vital.history, color: .themeAccent, stretch: true)
                } else {
                    Meter(value: vital.fraction ?? 0, height: 3, fill: .themeAccent, track: Color.ink.opacity(0.1))
                }
            }
            .frame(height: 3)
            .padding(.top, 2)
        }
    }
}

/// A rounded chip that opens one control under the row.
struct StudyChip: View {
    var symbol: String
    var title: String
    var state: String
    var on = false
    var selected = false

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(on || selected ? Color.themeAccent : Color.ink2)
                .frame(height: 16)
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.ink)
            Text(state)
                .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Color.ink3)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: Radius.of(10), style: .continuous)
            .fill(selected ? Color.themeAccent.opacity(0.16) : Color.ink.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: Radius.of(10), style: .continuous)
            .strokeBorder(selected ? Color.themeAccent.opacity(0.5) : .clear, lineWidth: 1))
    }
}

enum StudyChips {
    static let ids = ["awake", "clicker", "fan", "sound", "convert"]

    @MainActor static func chip(_ id: String, model: AppModel, selected: String?) -> StudyChip {
        switch id {
        case "awake":
            let on = model.awake?.session != nil
            return StudyChip(symbol: "cup.and.saucer", title: "Awake", state: on ? "On" : "Off", on: on, selected: selected == id)
        case "clicker":
            let cps = Int((model.clicker?.settings.clicksPerSecond ?? 10).rounded())
            return StudyChip(symbol: "cursorarrow.click.2", title: "Clicker", state: "\(cps) CPS", selected: selected == id)
        case "fan":
            let rpm = model.sensors?.fans.first.map { Int($0.currentRPM) } ?? 0
            return StudyChip(symbol: "fan", title: "Fan", state: rpm > 0 ? "\(rpm.formatted()) rpm" : "Auto", selected: selected == id)
        case "sound":
            let count = model.sound?.apps.count ?? 0
            return StudyChip(symbol: "speaker.wave.2", title: "Sound", state: "\(count) apps", selected: selected == id)
        default:
            return StudyChip(symbol: "arrow.down.right.and.arrow.up.left", title: "Compress", state: "Drop files", selected: selected == id)
        }
    }
}

/// A row in a list card: symbol, title, something on the right, a chevron.
struct StudyRow<Trailing: View>: View {
    var symbol: String
    var title: String
    var open = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.ink2)
                .frame(width: 18)
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.ink)
            Spacer(minLength: 6)
            trailing
            Image(systemName: "chevron.right")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Color.ink3)
                .rotationEffect(.degrees(open ? 90 : 0))
        }
        .lineLimit(1)
        .frame(height: 30)
    }
}

/// A Control Center module: a symbol in a disc, a title, its state.
struct StudyTile<Extra: View>: View {
    var symbol: String
    var title: String
    var state: String
    var on = false
    var accentState = false
    @ViewBuilder var extra: Extra

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(on ? Color.white : Color.ink2)
                .frame(width: 28, height: 28)
                .background(Circle().fill(on ? Color.themeAccent : Color.ink.opacity(0.09)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.ink)
                Text(state)
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(accentState ? Color.themeAccent : Color.ink3)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            extra
        }
        .padding(.horizontal, 10)
        .frame(height: 50)
        .frame(maxWidth: .infinity)
        .background(CardSurface(radius: 12))
    }
}

extension StudyTile where Extra == EmptyView {
    init(symbol: String, title: String, state: String, on: Bool = false, accentState: Bool = false) {
        self.init(symbol: symbol, title: title, state: state, on: on, accentState: accentState) { EmptyView() }
    }
}

/// A few of the apps playing sound, small.
struct StudyAppIcons: View {
    var model: AppModel
    var count = 4
    var size: CGFloat = 16

    var body: some View {
        HStack(spacing: 3) {
            ForEach((model.sound?.apps ?? []).prefix(count)) { app in
                Image(nsImage: app.icon).resizable().frame(width: size, height: size)
            }
        }
    }
}

// MARK: - The studies

/// A · Glance first: the battery in the header, the tools on top, the readings in one card, the
/// agents, then one row of chips for the controls; a chip opens its control under the row.
struct StudyGlance: View {
    var model: AppModel
    var open: String?

    var body: some View {
        StudyPanel {
            StudyBatteryHeader(model: model)
            ToolsCard(model: model)
            StudyVitals(model: model)
            if let agents = model.agents { AgentsCard(agents: agents) }
            HStack(spacing: 6) {
                ForEach(StudyChips.ids, id: \.self) { StudyChips.chip($0, model: model, selected: open) }
            }
            if let open { StudyControl(model: model, id: open) }
            PanelFooter(model: model)
        }
    }
}

/// The control a chip or a tile opens, as the panel draws it today.
struct StudyControl: View {
    var model: AppModel
    var id: String

    var body: some View {
        switch id {
        case "sound": if let sound = model.sound { SoundCard(sound: sound) }
        case "convert": if let converter = model.converter { ConvertCard(converter: converter) }
        case "agents": if let agents = model.agents { AgentsCard(agents: agents) }
        default: ControlRows(model: model, ids: [id], editing: nil)
        }
    }
}

/// B · Control Center: the readings stay, everything else is a module; a click swaps the grid
/// for that module (with a back arrow), so the panel keeps about the same height.
struct StudyModules: View {
    var model: AppModel
    var open: String?

    var body: some View {
        StudyPanel {
            StudyBatteryHeader(model: model)
            ToolsCard(model: model)
            if let open {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    Text("All").font(.system(size: 12.5, weight: .medium))
                    Spacer()
                }
                .foregroundStyle(Color.ink2)
                .padding(.horizontal, PanelGrid.inset)
                .frame(height: 20)
                StudyControl(model: model, id: open)
            } else {
                StudyVitals(model: model)
                let agents = model.agents
                let waiting = agents?.needsYou.count ?? 0
                let working = agents?.sessions.filter { $0.activity == .working }.count ?? 0
                Grid(horizontalSpacing: PanelGrid.gap, verticalSpacing: PanelGrid.gap) {
                    GridRow {
                        StudyTile(symbol: "sparkles", title: "Agents",
                                  state: waiting > 0 ? "\(waiting) needs you" : "\(working) working", on: waiting > 0, accentState: waiting > 0)
                        StudyTile(symbol: "speaker.wave.2", title: "Sound", state: "\(model.sound?.apps.count ?? 0) apps playing")
                    }
                    GridRow {
                        let chip = StudyChips.chip("awake", model: model, selected: nil)
                        StudyTile(symbol: "cup.and.saucer", title: "Stay awake", state: chip.state, on: chip.on)
                        StudyTile(symbol: "cursorarrow.click.2", title: "Clicker", state: StudyChips.chip("clicker", model: model, selected: nil).state)
                    }
                    GridRow {
                        StudyTile(symbol: "fan", title: "Fan", state: StudyChips.chip("fan", model: model, selected: nil).state)
                        StudyTile(symbol: "arrow.down.right.and.arrow.up.left", title: "Compress", state: "Drop files")
                    }
                }
            }
            PanelFooter(model: model)
        }
    }
}

/// C · Wide: two columns side by side, 628 pt across; nothing hidden, nothing scrolls.
struct StudyWide: View {
    var model: AppModel

    var body: some View {
        StudyPanel(width: PanelGrid.content * 2 + PanelGrid.gap + 2 * PanelGrid.outer) {
            PanelHeader(model: model)
            HStack(alignment: .top, spacing: PanelGrid.gap) {
                VStack(spacing: PanelGrid.gap) {
                    ToolsCard(model: model)
                    BatteryWidget(model: model, wide: true)
                    if let system = model.system {
                        VStack(spacing: PanelGrid.gap) {
                            ForEach([["cpu", "memory", "gpu"], ["disk", "network", "temperature"]], id: \.self) { row in
                                HStack(spacing: PanelGrid.gap) {
                                    ForEach(row, id: \.self) { id in
                                        if case .card(let reading) = PanelLayoutStore.Widget(id: id) {
                                            ReadingTile(reading: reading, system: system, sensors: model.sensors, wide: false, compact: true)
                                                .frame(width: PanelGrid.across(3))
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if let converter = model.converter { ConvertCard(converter: converter) }
                }
                .frame(width: PanelGrid.content)
                VStack(spacing: PanelGrid.gap) {
                    if let agents = model.agents { AgentsCard(agents: agents) }
                    ControlRows(model: model, ids: PanelLayout.controlIDs, editing: nil)
                    if let sound = model.sound { SoundCard(sound: sound) }
                }
                .frame(width: PanelGrid.content)
            }
            PanelFooter(model: model)
        }
    }
}

/// D · List: the readings stay a grid; everything else is one line with its state, and a click
/// opens that line into its card (one at a time).
struct StudyList: View {
    var model: AppModel
    var open: String?

    var body: some View {
        StudyPanel {
            StudyBatteryHeader(model: model)
            ToolsCard(model: model)
            StudyVitals(model: model)
            if open == "agents" { StudyControl(model: model, id: "agents") }
            VStack(spacing: 0) {
                let agents = model.agents
                let waiting = agents?.needsYou.first
                if open != "agents" {
                    StudyRow(symbol: "sparkles", title: "Agents") {
                        if let waiting {
                            Text("Waiting \(AgentText.age(since: waiting.since, now: agents?.now ?? Date()))")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.themeAccent)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Capsule().fill(Color.themeAccent.opacity(0.15)))
                        }
                        let working = agents?.sessions.filter { $0.activity == .working }.count ?? 0
                        Text("\(working) working").font(.system(size: 11.5)).foregroundStyle(Color.ink3)
                    }
                    Hairline().opacity(0.5)
                }
                StudyRow(symbol: "cup.and.saucer", title: "Stay awake") {
                    Text(StudyChips.chip("awake", model: model, selected: nil).state).font(.system(size: 11.5)).foregroundStyle(Color.ink3)
                }
                Hairline().opacity(0.5)
                StudyRow(symbol: "cursorarrow.click.2", title: "Auto clicker") {
                    Text(StudyChips.chip("clicker", model: model, selected: nil).state).font(.system(size: 11.5)).foregroundStyle(Color.ink3)
                }
                Hairline().opacity(0.5)
                StudyRow(symbol: "fan", title: "Fan") {
                    Text(StudyChips.chip("fan", model: model, selected: nil).state).font(.system(size: 11.5)).foregroundStyle(Color.ink3)
                }
                Hairline().opacity(0.5)
                StudyRow(symbol: "speaker.wave.2", title: "Sound") { StudyAppIcons(model: model, count: 5, size: 15) }
                Hairline().opacity(0.5)
                StudyRow(symbol: "arrow.down.right.and.arrow.up.left", title: "Convert & Compress") {
                    Text("Drop files").font(.system(size: 11.5)).foregroundStyle(Color.ink3)
                }
            }
            .panelCard(vertical: 4)
            PanelFooter(model: model)
        }
    }
}
#endif
