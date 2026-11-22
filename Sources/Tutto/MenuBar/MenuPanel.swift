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
import QuickLookThumbnailing
import SwiftUI
import TuttoKit

/// The grid, its spacing scaled by the theme's density (the panel's width never changes).
@MainActor
enum PanelGrid {
    static let width: CGFloat = 320
    static var outer: CGFloat { (10 * ThemeStore.shared.tokens.densityScale).rounded() }
    static var inset: CGFloat { (12 * ThemeStore.shared.tokens.densityScale).rounded() }
    static var gap: CGFloat { (8 * ThemeStore.shared.tokens.densityScale).rounded() }
    /// A tile: half the cards' width.
    static var tile: CGFloat { (width - 2 * outer - gap) / 2 }
    /// The cards' width. Everything in the panel is laid out to it exactly: a grid left to size
    /// itself took its tiles' widest content, pushed the panel past its window and cut it off.
    static var content: CGFloat { width - 2 * outer }
    /// One of `count` equal tiles across the cards' width.
    static func across(_ count: Int) -> CGFloat {
        let count = CGFloat(max(count, 1))
        return (content - gap * (count - 1)) / count
    }
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
    /// Draws its own sheet of Liquid Glass (the glass preview stage; the menu bar window brings its own).
    var glassRoot = false

    var body: some View {
        VStack(alignment: .leading, spacing: PanelGrid.gap) {
            PanelHeader(model: model)
            if let recorder = model.screenshots?.recorder, let since = recorder.recordingSince {
                RecordingBanner(recorder: recorder, since: since)
            }
            // The cards in the order and sizes set on the Customize page. They grow with their
            // content up to the screen's height, then scroll between the header and the footer.
            if preview && ThinScrollStage.limit == nil {
                cards
            } else {
                // Its scroll line runs in the margin, along the frame, never over a card.
                ThinScrollArea(lane: PanelGrid.outer) { cards }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: Self.cardsHeightLimit)
                    .fixedSize(horizontal: false, vertical: true)
                    // Exactly the cards' width, whatever a scroll view asks for: anything wider
                    // shifts the whole column off-centre in the frame.
                    .frame(width: PanelGrid.content)
            }
            PanelFooter(model: model)
        }
        .modifier(GlassGroup())
        .padding(.horizontal, PanelGrid.outer)
        .padding(.top, PanelGrid.outer)
        .padding(.bottom, 6)
        .frame(width: PanelGrid.width)
        .fixedSize(horizontal: false, vertical: true)
        // Liquid Glass: nothing over the glass (the system's in the menu bar, its own on the stage).
        .background { if !(drawsGlass && ThemeStore.liquid) { PanelBackdrop() } }
        .modifier(StageSheet(enabled: drawsGlass))
        // Floating glass: the cards sit on one frosted frame (in the menu bar and on the stage).
        .background {
            if ThemeStore.liquid, GlassLook.current == .floating, glassRoot || !preview {
                FrostedFrame()
                    .overlay(GlassRim(shape: RoundedRectangle(cornerRadius: 26, style: .continuous), strength: 0.6))
            }
        }
        .watching(model.system, model.system?.panelFeeds ?? [])
        .background { if !preview { PanelWindowReader() } }
        .tint(Color.themeAccent)
    }

    /// The glass stage draws its sheet, and so does the menu bar panel in the clear and pane looks:
    /// its window is Tutto's own and clear, so the sheet is the frame under the cards. (In macOS's
    /// menu bar window a second sheet doubled the system's glass and darkened it.)
    private var drawsGlass: Bool { glassRoot || (!preview && GlassLook.drawsSheet) }

    private var cards: some View {
        VStack(alignment: .leading, spacing: PanelGrid.gap) {
            WidgetGrid(model: model, editing: editing)
            Notices(model: model)
        }
        .frame(width: PanelGrid.content)
        // The cards' glass in a group of its own inside the scroll view, so it scrolls and is cut off
        // at the edges with the cards (in the panel's group alone it drew over the footer).
        .modifier(GlassGroup())
    }

    /// The screen's usable height, less the header, the footer and a margin.
    @MainActor static var cardsHeightLimit: CGFloat {
        if let limit = ThinScrollStage.limit { return limit }
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height ?? 900
        return max(visible - 24 - 104, 320)
    }
}

/// The glass stage's sheet: regular glass (what ships), none for the floating prototype (each card is
/// glass), or clear glass with a light dimming layer under the text for the clear prototype.
private struct StageSheet: ViewModifier {
    var enabled: Bool
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        if !enabled || !ThemeStore.liquid {
            content
        } else {
            switch GlassLook.current {
            case .sheet:
                content.liquidGlass(shape)
            case .floating:
                content
            case .pane:
                // No blur: the desktop shows through, darkened (or paled) a little, with light of its own.
                content
                    .background {
                        ZStack {
                            shape.fill(scheme == .dark ? Color.black.opacity(GlassSheet.darkDim) : Color.white.opacity(GlassSheet.lightVeil))
                            if GlassSheet.sheen > 0 { GlassSheen(shape: shape, strength: GlassSheet.sheen) }
                        }
                    }
                    .overlay(GlassRim(shape: shape, strength: GlassSheet.rim))
            case .clear, .frost:
                // Clear glass around everything. B dimmed it, which made it "almost completely opaque" over a
                // dark window; the frost lightens it instead, as frosted glass scatters light.
                let frosted = GlassLook.current == .frost
                content
                    .background {
                        ZStack {
                            Color.clear.prototypeGlass(shape, clear: true).opacity(GlassSheet.glassOpacity)
                            if scheme == .light {
                                shape.fill(Color.white.opacity(GlassSheet.lightVeil))
                            } else if frosted {
                                shape.fill(Color.white.opacity(GlassSheet.frost))
                            } else {
                                shape.fill(Color.black.opacity(GlassSheet.darkDim))
                            }
                            if GlassSheet.sheen > 0 { GlassSheen(shape: shape, strength: GlassSheet.sheen) }
                        }
                    }
                    .overlay(GlassRim(shape: shape, strength: GlassSheet.rim))
            }
        }
    }
}

/// Every piece of the panel's glass in one container, so macOS judges them together. On their own,
/// macOS turns a small piece of glass light when what's behind it is bright: over a white page the
/// header, the tools, the control chips and the footer went white (and not all of them, nor the
/// same ones each time) while the larger cards stayed dark (Bryan, 2026-11-22: "why is it not
/// black frame like ... the rest of the project"). Together they keep one look over any background.
private struct GlassGroup: ViewModifier {
    /// Renders: each piece on its own, as before (`no-glass-group`).
    nonisolated(unsafe) static var off = CommandLine.arguments.contains("no-glass-group")
    func body(content: Content) -> some View {
        if #available(macOS 26, *), ThemeStore.liquid, !Self.off {
            GlassEffectContainer(spacing: 0) { content }
        } else {
            content
        }
    }
}

/// The floating prototype's header and footer: a glass capsule each.
private struct FloatingCapsule: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    /// Outside the cards' own group (they scroll; these stay put), the two capsules come out a
    /// shade lighter than the cards over a bright page: a little shade under the text evens them up.
    nonisolated(unsafe) static var shade = 0.18

    func body(content: Content) -> some View {
        if ThemeStore.liquid, GlassLook.glassCards {
            content
                .padding(.vertical, 6)
                .background { if scheme == .dark { Capsule().fill(Color.black.opacity(Self.shade)) } }
                .prototypeGlass(Capsule())
                .overlay(GlassRim(shape: Capsule()))
        } else {
            content
        }
    }
}

/// While the screen is recording: how long, and Stop (the panel is where you'd look for it).
private struct RecordingBanner: View {
    var recorder: ScreenRecorder
    var since: Date

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.red).frame(width: 7, height: 7)
            Text("Recording")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.ink)
            TimelineView(.periodic(from: since, by: 1)) { context in
                Text(RecordingRules.elapsed(context.date.timeIntervalSince(since)))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color.ink3)
            }
            Spacer(minLength: 8)
            Button("Stop") { afterPanelCloses { recorder.stop() } }
                .buttonStyle(OutlineButtonStyle(compact: true))
                .help("Stop and save the recording")
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .cardSurface(radius: 12)
    }
}

/// Over the panel's glass: the theme's tint, or its solid background instead of glass.
private struct PanelBackdrop: View {
    var body: some View {
        let tokens = ThemeStore.shared.tokens
        // Liquid Glass: nothing over the window's own glass.
        Rectangle()
            .fill(tokens.liquid ? Color.clear : (tokens.solidBackground ? tokens.canvas : tokens.tint))
            .ignoresSafeArea()
    }
}

/// The cards in lines: two small ones side by side, a wide one (or a small one alone) across,
/// one-line controls together in one card.
private struct WidgetGrid: View {
    var model: AppModel
    var editing: PanelEditing?

    var body: some View {
        // The controls fold into one row of chips; the Bluetooth devices into the battery card.
        let fold = PanelFold(model.layout.slots(model, editing: editing != nil), editing: editing != nil)
        let lines = PanelLayout.lines(fold.slots)
        VStack(spacing: PanelGrid.gap) {
            ForEach(Self.blocks(lines), id: \.self) { block in
                switch block {
                case .line(.cards([ControlStrip.id])):
                    ControlStripView(model: model, ids: fold.chips, editing: editing)
                case .line(.cards(let ids)):
                    HStack(spacing: PanelGrid.gap) {
                        ForEach(ids, id: \.self) { id in
                            Editable(id: id, editing: editing) { card(id, wide: ids.count == 1, devices: fold.devicesInBattery) }
                        }
                    }
                case .line(.rows(let ids)):
                    ControlRows(model: model, ids: ids, editing: editing)
                case .vitals(let ids):
                    // The readings together: three across, the label and the number (details on hover),
                    // each exactly a third of the cards' width.
                    VStack(alignment: .leading, spacing: PanelGrid.gap) {
                        ForEach(PanelLayout.rows(ids, perRow: 3), id: \.self) { row in
                            HStack(spacing: PanelGrid.gap) {
                                ForEach(row, id: \.self) { id in
                                    Editable(id: id, editing: editing) {
                                        if let system = model.system, case .card(let reading) = PanelLayoutStore.Widget(id: id) {
                                            ReadingTile(reading: reading, system: system, sensors: model.sensors, wide: false, compact: true)
                                        }
                                    }
                                    .frame(width: PanelGrid.across(3))
                                }
                            }
                        }
                    }
                }
            }
        }
        .animation(Motion.snappy, value: lines)
        // Devices are read only while the panel (or the Customize preview) is on screen.
        .background {
            if model.layout.layout.widgets.isShown(PanelLayoutStore.Card.devices.id) { Color.clear.watchingBluetoothBatteries() }
        }
    }

    enum Block: Hashable {
        case line(WidgetLine)
        case vitals([String])
    }

    /// Lines of nothing but readings next to each other become one grid.
    static func blocks(_ lines: [WidgetLine]) -> [Block] {
        var blocks: [Block] = []
        for line in lines {
            if case .cards(let ids) = line, ids.allSatisfy(PanelLayout.readingIDs.contains) {
                if case .vitals(let earlier)? = blocks.last {
                    blocks[blocks.count - 1] = .vitals(earlier + ids)
                } else {
                    blocks.append(.vitals(ids))
                }
            } else {
                blocks.append(.line(line))
            }
        }
        return blocks
    }

    @ViewBuilder
    private func card(_ id: String, wide: Bool, devices: Bool) -> some View {
        switch PanelLayoutStore.Widget(id: id) {
        case .card(.battery):
            BatteryWidget(model: model, wide: wide, devices: devices)
        case .card(let reading) where PanelLayout.readingIDs.contains(reading.rawValue):
            if let system = model.system {
                ReadingTile(reading: reading, system: system, sensors: model.sensors, wide: wide)
            }
        case .card(.devices):
            DevicesCard(placeholder: editing != nil)
        case .card(.agents):
            if let agents = model.agents { AgentsCard(agents: agents, placeholder: editing != nil) }
        case .card(.compress):
            if let converter = model.converter { ConvertCard(converter: converter, placeholder: editing != nil) }
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
struct Editable<Content: View>: View {
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
enum PanelWindow {
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
extension View {
    /// A group on the panel: a soft rounded surface instead of rules and captions. `vertical` trims
    /// a one-row card (the sides stay on the grid).
    func panelCard(vertical: CGFloat? = nil) -> some View {
        padding(.horizontal, PanelGrid.inset)
            .padding(.vertical, vertical ?? PanelGrid.inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface(radius: 12)
    }

    /// A hover background that reaches `x` and `y` past the content, so the content stays on the grid.
    /// It's the tools bar's lens (raised glass on its spring), so every hover on the panel feels the same.
    func hoverBackground(_ on: Bool, x: CGFloat = 8, y: CGFloat = 0) -> some View {
        modifier(LensBackground(on: on, shape: RoundedRectangle(cornerRadius: Radius.of(10), style: .continuous), x: x, y: y))
    }
}

/// Text button that brightens on hover, for the few quiet actions on the panel.
struct QuietLink: View {
    var title: String
    var size: CGFloat = 12
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(hovering ? Color.ink : Color.ink3)
                .contentShape(Rectangle())
                .lensHover(x: 7, y: 3, stageKey: title, hovering: { hovering = $0 })
        }
        .buttonStyle(PressStyle())
    }
}

/// A card's title row: the title, and something quiet on the right.
struct CardTitle<Trailing: View>: View {
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
/// the app you were in is the front app again.
@MainActor
func afterPanelCloses(_ action: @escaping @MainActor () -> Void) {
    closePanel()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
        MainActor.assumeIsolated { action() }
    }
}

/// Closes the panel. Opening Tutto's window doesn't close it by itself, so anything that opens a
/// page closes the panel first.
@MainActor
func closePanel() {
    PanelController.shared.close()
}

/// Opens a page of the app (or the app where you left it) and closes the panel.
@MainActor
func showInApp(_ page: MainPage? = nil) {
    #if DEBUG
    // The click probe counts what a click opened instead of opening it.
    if ClickProbe.running { ClickProbe.opened.append(page.map { "\($0)" } ?? "app"); return }
    #endif
    closePanel()
    if let page { MainWindowController.shared.show(page: page) } else { MainWindowController.shared.show() }
}

// MARK: - Header

/// Tutto's mark and how the Mac is doing in plain words: a problem first, else the battery.
struct PanelHeader: View {
    var model: AppModel

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(nsImage: MenuBarGlyph.image())
                .renderingMode(.template)
                .foregroundStyle(Color.ink)
                .accessibilityHidden(true)
            if let system = model.system {
                VerdictLine(glance: Glance.make(battery: system.battery, cpu: system.cpu.total, memoryPressure: system.memory?.pressure,
                                                hottest: model.sensors?.summary?.hottest,
                                                heatPressure: HeatPressure.now,
                                                diskFree: system.rootVolume?.available,
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
        .modifier(FloatingCapsule())
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
/// processor most right now. Compact (Bryan, 2026-11-21: "smaller but show the same amount of
/// information"): the charge, health and cycles, and the watts share one 30 pt line, the busiest
/// apps the next; with `devices`, the Bluetooth batteries follow in the same card.
struct BatteryCard: View {
    var battery: BatteryInfo
    var system: SystemMonitor
    /// The Bluetooth devices card folded in under a hairline (it sits right below the battery).
    var devices = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                showInApp(.battery)
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    BatteryGlyph(level: Double(battery.percent) / 100, charging: battery.isCharging, alert: low)
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text("\(battery.percent)")
                            .font(.figure(22, weight: .semibold))
                            .foregroundStyle(low ? Color.alert : Color.ink)
                        Text("%")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Color.ink3)
                    }
                    .fixedSize()
                    // Health and cycles stacked beside the charge, not on a line of their own.
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Health \(battery.healthPercent) %")
                        Text("\(Format.number(battery.cycleCount)) cycles")
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.ink3)
                    .lineLimit(1)
                    .fixedSize()
                    Spacer(minLength: 6)
                    VStack(alignment: .trailing, spacing: 0) {
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text(Format.watts(battery.powerDraw))
                                .font(.figure(16, weight: .medium))
                                .foregroundStyle(Color.ink)
                            Text("W")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(Color.ink3)
                        }
                        Caption(powerCaption)
                    }
                    .fixedSize()
                }
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Battery details")
            .accessibilityLabel("Battery")
            .accessibilityValue("\(battery.percent) percent, \(battery.stateText), \(Format.watts(battery.powerDraw)) watts \(powerCaption), \(healthLine)\(ChargeLimitController.shared.panelNote.map { ", \($0)" } ?? "")")
            .accessibilityHint("Shows details")
            // Charge limit holding the charge ("Held at 80 %"): one dim line, only then.
            if let note = ChargeLimitController.shared.panelNote {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ink3)
                    .lineLimit(1)
            }
            // A battery that needs attention says so on a line of its own (it's rare, and it matters).
            if let condition = unusualCondition {
                Label(condition, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.alert)
                    .lineLimit(1)
            }
            BusyAppsList(apps: system.busyApps, measured: system.busyAppsMeasured)
            if devices {
                Hairline().opacity(0.5)
                DevicesCard(placeholder: false, inline: true)
            }
        }
        // One card, one answer to the pointer (Bryan, 2026-11-21: a box lighting up around the top
        // line alone "doesn't make sense"): the whole card brightens like the readings' tiles, and a
        // click anywhere on it opens Battery (the Show button inside still does its own thing).
        .padding(.horizontal, PanelGrid.inset)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { showInApp(.battery) }
        .modifier(CardLift(on: hovering || LensStage.on("Battery"), radius: 12))
        .cardSurface(radius: 12)
        .onHover { hovering = $0 }
        .probeFrame("battery")
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
/// from the kernel every 2 s while the panel is open): one row of chips, an icon and its share
/// each (the name on hover). Three equal slots, so the row doesn't jump as apps come and go.
private struct BusyAppsList: View {
    var apps: [AppActivity]
    /// False until the first reading since the panel opened.
    var measured: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text("Busiest")
                .font(.system(size: 11))
                .foregroundStyle(Color.ink3)
                .fixedSize()
            if apps.isEmpty {
                Text(measured ? "All quiet" : "Measuring…")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ink3)
                Spacer(minLength: 0)
            } else {
                ForEach(0..<3, id: \.self) { index in
                    if index < apps.count {
                        BusyAppChip(app: apps[index])
                    } else {
                        Color.clear.frame(maxWidth: .infinity).frame(height: 22)
                    }
                }
            }
        }
        .frame(height: 22)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Busiest apps")
    }
}

private struct BusyAppChip: View {
    var app: AppActivity

    var body: some View {
        HStack(spacing: 5) {
            AppIcon(pid: app.pid)
                .frame(width: 14, height: 14)
            Text(app.cpu >= 10 ? "\(Int(app.cpu.rounded())) %" : String(format: "%.1f %%", app.cpu))
                .font(.geist(11, weight: .medium))
                .foregroundStyle(Color.ink2)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .frame(maxWidth: .infinity, minHeight: 22)
        .background(Capsule().fill(Color.ink.opacity(0.06)))
        .help("\(app.name) · \(String(format: "%.1f", app.cpu)) % CPU")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(app.name)
        .accessibilityValue("\(Int(app.cpu.rounded())) percent CPU")
    }
}

// MARK: - Tiles

/// Six tiles in two columns: CPU, memory, GPU, disk, network and temperature, each a number,
/// an engraved caption, a detail and the last minute as a line (or a meter). Each opens its page.
/// The Customize page sets which show and in what order; an odd one out takes the whole last row.
/// With Sensors & Fans off there's no temperature tile.
/// One of the readings: CPU, memory, GPU, disk, network or temperature. Temperatures are read only
/// while their tile is on screen.
struct ReadingTile: View {
    var reading: PanelLayoutStore.Card
    var system: SystemMonitor
    var sensors: SensorsModule?
    var wide: Bool
    /// In the readings grid: the label and the number; the detail moves into the tooltip.
    var compact = false

    var body: some View {
        tile(reading, wide: wide)
            .environment(\.compactTile, compact)
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
            // Red only when macOS itself is slowing the Mac to cool it, never for a number: Apple
            // silicon runs its cores at 80–100 °C under load with no heat pressure (Bryan,
            // 2026-11-13: "why does the temperature always say it's running hot").
            let hot = sensors?.underHeatPressure ?? false
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
        let verdict = (sensors?.underHeatPressure ?? false)
            ? "macOS is slowing the Mac to cool it"
            : "macOS: no heat pressure (80–100 °C is normal for Apple silicon under load)"
        return ["Processor, the average of its cores", sensors?.summary?.gpuAverage.map { "graphics \(Int($0.rounded())) °C" } ?? "", verdict]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

private struct CompactTileKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var compactTile: Bool {
        get { self[CompactTileKey.self] }
        set { self[CompactTileKey.self] = newValue }
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
    @Environment(\.compactTile) private var compact
    private var lifted: Bool { hovering || LensStage.on(caption) }

    var body: some View {
        if compact { compactBody } else { fullBody }
    }

    /// Three across: the label, the number and a faint line; the detail is in the tooltip.
    private var compactBody: some View {
        Button {
            showInApp(page)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(caption)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.ink3)
                    .lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: unit.first?.isLetter == true ? 2 : 1) {
                    if let prefix {
                        Text(prefix)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Color.ink3)
                    }
                    Text(value)
                        .font(.figure(19, weight: .medium))
                        .foregroundStyle(alert ? Color.alert : Color.ink)
                    if !unit.isEmpty {
                        Text(unit)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Color.ink3)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                graph
                    .frame(height: 10)
                    .opacity(0.8)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(CardLift(on: lifted, radius: 10))
            .cardSurface(radius: 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .probeFrame("tile.\(caption)")
        .help(detail.isEmpty ? help : "\(help) · \(detail)")
        .accessibilityLabel(spokenName)
        .accessibilityValue(spokenValue)
        .accessibilityHint("Shows details")
    }

    private var fullBody: some View {
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
            .modifier(CardLift(on: lifted, radius: 10))
            .cardSurface(radius: 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
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
/// Bryan picked these rows over tiles, typed lines and a drawer (2026-11-12).
struct ControlRows: View {
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

/// The auto clicker. Closed, one line: its name and what it'll do (the speed, and the limit when
/// there is one), which opens its settings, then its switch. Open: the speed, the click, when it
/// stops and its shortcut, each set in one place. While it runs the line says so, with the time
/// left when it stops after a time (no click count: nobody needs it). Switched on here, it starts 2 s after the panel closes (so it doesn't
/// click the panel); changes made while it clicks apply at once.
struct ClickerRow: View {
    @Bindable var clicker: ClickerModule
    var model: AppModel
    @State private var expanded: Bool
    @State private var hovering = false
    @State private var visible = false
    /// Snapshots render it open (`clicker-open`).
    nonisolated(unsafe) static var startsExpanded = false

    init(clicker: ClickerModule, model: AppModel, open: Bool = ClickerRow.startsExpanded) {
        _clicker = Bindable(clicker)
        self.model = model
        _expanded = State(initialValue: open)
    }

    private var settings: ClickerSettings { clicker.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if expanded {
                options
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }
            if let notice = clicker.notice {
                Text(notice)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .background(VisibilityReader { visible = $0 })
    }

    // MARK: The line

    private var header: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(Motion.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    RowLabel(symbol: ModuleID.clicker.symbol, title: title, live: clicker.isOn, help: clicker.lastRun)
                    status
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(hovering ? Color.ink2 : Color.ink4)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                // The hover reaches past the text, so nothing moves.
                .frame(height: 26)
                .hoverBackground(hovering, x: 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(Motion.micro, value: hovering)
            .help(expanded ? "Hide its settings" : "Speed, click, when it stops")
            .accessibilityLabel("Auto clicker settings")
            .accessibilityValue(expanded ? "Shown" : "Hidden")
            Spacer(minLength: 4)
            InkSwitch(isOn: Binding(get: { clicker.isOn }, set: { on in
                if on { afterPanelCloses { clicker.begin(fromPanel: true) } } else { clicker.end("Stopped") }
            }), label: "Auto clicker")
            .help(clicker.isOn ? "Stop clicking" : "Start clicking 2 s after the panel closes")
        }
        .frame(height: 26)
    }

    private var title: String {
        switch clicker.state {
        case .idle: "Auto clicker"
        case .countdown: "Starting"
        case .clicking: "Clicking"
        }
    }

    /// Idle: what it'll do. Counting down: when. Clicking: the time left when it stops after a
    /// time (ticking each second while the panel shows it), otherwise the speed.
    @ViewBuilder
    private var status: some View {
        switch clicker.state {
        case .idle:
            // Open, the settings say it below.
            if !expanded {
                detail([settings.speedLabel, settings.stopShort].compactMap { $0 }.joined(separator: " · "))
                    .transition(.opacity)
            }
        case .countdown(let n):
            detail("in \(n) s")
        case .clicking:
            if case .afterSeconds = settings.stop, let since = clicker.clickingSince {
                if visible {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        detail(ClickerRules.timeLeft(settings, elapsed: context.date.timeIntervalSince(since)) ?? "")
                    }
                } else {
                    detail(ClickerRules.timeLeft(settings, elapsed: Date().timeIntervalSince(since)) ?? "")
                }
            } else if !expanded {
                detail(settings.speedLabel)
            }
        }
    }

    private func detail(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium).monospacedDigit())
            .foregroundStyle(Color.ink3)
            .lineLimit(1)
            .contentTransition(.numericText())
    }

    // MARK: Its settings

    private var options: some View {
        VStack(spacing: 4) {
            OptionRow(title: "Speed") {
                InkStepper(label: "CPS", value: Int(settings.clicksPerSecond.rounded()), range: 1...100, showsUnit: true) { value in
                    clicker.update { $0.clicksPerSecond = Double(value) }
                }
                .fixedSize()
                .help("Clicks per second, up to 100. Click the number to type one.")
            }
            OptionRow(title: "Click") { clickMenu }
            OptionRow(title: "Stops") { stopMenu }
            HStack(spacing: 6) {
                KeyCaps(shortcut: model.shortcuts.shortcut(for: .toggleClicker), compact: true)
                Text("starts or stops it")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ink3)
                    .lineLimit(1)
                Spacer(minLength: 4)
                QuietLink(title: "All settings", size: 11) { showInApp(.clicker) }
            }
            .frame(height: 22)
            .padding(.top, 2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Radius.of(10), style: .continuous).fill(Color.ink.opacity(0.045)))
    }

    /// The button, single or double, and where: one menu, since they're picked together and rarely.
    private var clickMenu: some View {
        Menu {
            Picker("Button", selection: Binding(get: { settings.button }, set: { value in clicker.update { $0.button = value } })) {
                ForEach(ClickButton.allCases, id: \.self) { button in Text("\(button.title) Click").tag(button) }
            }
            .pickerStyle(.inline)
            Toggle("Double-Click", isOn: Binding(get: { settings.double }, set: { value in clicker.update { $0.double = value } }))
            Section("Where") {
                Toggle("At the Pointer", isOn: Binding(get: { settings.target == .pointer }, set: { on in
                    if on { clicker.update { $0.target = .pointer } }
                }))
                if case .point(let x, let y) = settings.target {
                    Toggle("At \(Int(x)), \(Int(y))", isOn: .constant(true))
                }
                Button(settings.target == .pointer ? "Pick a Spot…" : "Pick Another Spot…") {
                    afterPanelCloses { clicker.pickPoint() }
                }
            }
        } label: {
            MenuValue(text: settings.clickLabel + (settings.target == .pointer ? "" : " · spot"))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Which button, and where it clicks")
        .accessibilityLabel("Click: \(settings.clickLabel)\(settings.target == .pointer ? "" : ", at a set spot")")
    }

    /// When it stops by itself: never, after a time or after a number of clicks.
    private var stopMenu: some View {
        let presets = ClickerSettings.stopPresets
        let times = presets.filter { if case .afterSeconds = $0 { true } else { false } }
        let counts = presets.filter { if case .afterClicks = $0 { true } else { false } }
        let binding = Binding(get: { settings.stop }, set: { value in clicker.update { $0.stop = value } })
        return Menu {
            Picker("Stops", selection: binding) {
                Text("Never").tag(ClickStop.never)
                if !presets.contains(settings.stop), settings.stop != .never {
                    Text(settings.stopLabel).tag(settings.stop)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Section("After a Time") {
                Picker("After a Time", selection: binding) {
                    ForEach(times, id: \.self) { stop in Text(label(stop)).tag(stop) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section("After a Number of Clicks") {
                Picker("After a Number of Clicks", selection: binding) {
                    ForEach(counts, id: \.self) { stop in Text(label(stop)).tag(stop) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Divider()
            Button("Other…") { showInApp(.clicker) }
        } label: {
            MenuValue(text: settings.stopLabel)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Stop by itself after a time or a number of clicks")
        .accessibilityLabel("Stops: \(settings.stopLabel)")
    }

    private func label(_ stop: ClickStop) -> String {
        var probe = settings
        probe.stop = stop
        return probe.stopShort ?? "Never"
    }
}

/// One of the clicker's settings: its name on the left, its control on the right.
private struct OptionRow<Control: View>: View {
    var title: String
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.ink2)
            Spacer(minLength: 8)
            control
        }
        .frame(height: 28)
    }
}

/// A menu's current value with the up-down chevrons macOS puts on pop-up buttons, on the same
/// wash as the panel's chips.
private struct MenuValue: View {
    var text: String
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Text(text)
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Color.ink)
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Color.ink3)
        }
        .padding(.leading, 9)
        .padding(.trailing, 7)
        .frame(height: 24)
        .background {
            if ThemeStore.liquid {
                LiquidFill(shape: RoundedRectangle(cornerRadius: Radius.of(8), style: .continuous), raise: hovering ? 1.6 : 1, hovering: hovering)
            } else {
                RoundedRectangle(cornerRadius: Radius.of(7), style: .continuous).fill(Color.ink.opacity(hovering ? 0.12 : 0.07))
            }
        }
        .scaleEffect(hovering ? Motion.textSwell : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Motion.lens, value: hovering)
    }
}

// MARK: - Stay Awake

/// Stay Awake: type a time (or pick one) and the Mac stays on, lid closed included. While it runs:
/// the countdown, when it ends, chips to add time, End, and one line on what the lid does.
struct AwakeRow: View {
    @Bindable var awake: StayAwakeModule
    @State private var visible = false

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
            AwakeTimeField(awake: awake, placeholder: "Time…")
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
                AwakeTimeField(awake: awake, placeholder: "Add time")
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

/// The typed time: Enter starts it (or adds it while running); a time it can't read shakes.
private struct AwakeTimeField: View {
    var awake: StayAwakeModule
    var placeholder: String
    @State private var typed = ""
    @State private var shake = 0
    @FocusState private var focused: Bool

    private var typedSeconds: TimeInterval? { AwakeDuration.seconds(from: typed) }

    var body: some View {
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
}

/// A small time chip: "2h", "+15m".
private struct TimeChip: View {
    var title: String
    var help: String
    var action: () -> Void
    @State private var hovering = false
    private var lit: Bool { hovering || LensStage.on(title) }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(hovering ? Color.ink : Color.ink2)
                .padding(.horizontal, ThemeStore.liquid ? 9 : 7)
                .frame(height: 24)
                .background {
                    if ThemeStore.liquid {
                        LiquidFill(shape: Capsule(), raise: lit ? 1.6 : 1, hovering: lit)
                    } else {
                        RoundedRectangle(cornerRadius: Radius.of(7), style: .continuous).fill(Color.ink.opacity(lit ? 0.12 : 0.07))
                    }
                }
                .scaleEffect(lit ? Motion.textSwell : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .fixedSize()
        .onHover { hovering = $0 }
        .animation(Motion.lens, value: hovering)
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
struct FanRow: View {
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

struct SoundCard: View {
    @Bindable var sound: SoundModule
    @State private var order: [String] = []
    /// The levels, opened from the title, stay open the next time the panel opens.
    @AppStorage("panel.soundLevels") private var keptLevels = false
    /// This panel's state (a stored setting changes the view outside the animation, so the levels
    /// snapped open; this animates, and the setting follows it).
    @State private var levelsOpen: Bool?
    @State private var levelsHover = false
    /// The app icon under the pointer, and the one just clicked (its label says what happened).
    @State private var hoveredApp: String?
    @State private var toggledApp: String?
    @State private var overflowHover = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var showLevels: Bool {
        get { SoundCard.startsShowingLevels || (levelsOpen ?? keptLevels) }
        nonmutating set { levelsOpen = newValue }
    }
    /// Snapshots render it open (`sound-levels`).
    nonisolated(unsafe) static var startsShowingLevels = false

    /// Icons that fit across the card before the rest go into a menu.
    private static let capacity = 8
    /// From one icon's start to the next.
    private static let iconPitch: CGFloat = 34.5
    /// Strip and levels: the old one goes quickly, the new one comes in as the card makes room,
    /// so the two never show on top of each other.
    private static let swap: AnyTransition = .asymmetric(
        insertion: .opacity.animation(.easeOut(duration: 0.18).delay(0.08)),
        removal: .opacity.animation(.easeOut(duration: 0.07)))

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardTitle(title: "Sound") {
                HStack(spacing: 10) {
                    // Only for an app you can see muted here; apps muted while closed stay muted.
                    if sound.apps.contains(where: { sound.isMuted($0.bundleID) }) {
                        QuietLink(title: "Unmute All") { withAnimation(Motion.micro) { sound.unmuteOpen() } }
                    }
                    if !sound.apps.isEmpty && SoundModule.isSupported {
                        Button {
                            let open = !showLevels
                            withAnimation(Motion.snappy) { showLevels = open }
                            keptLevels = open
                        } label: {
                            HStack(spacing: 4) {
                                Text("Levels")
                                    .font(.system(size: 12, weight: .medium))
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 8.5, weight: .bold))
                                    .rotationEffect(.degrees(showLevels ? 180 : 0))
                            }
                            .foregroundStyle(levelsHover ? Color.ink : Color.ink3)
                            .contentShape(Rectangle())
                            .lensHover(x: 7, y: 3, stageKey: "Levels", hovering: { levelsHover = $0 })
                        }
                        .buttonStyle(PressStyle())
                        .help(showLevels ? "Hide the levels" : "Each app's level, with boost past 100 %")
                    }
                }
            }
            if sound.apps.isEmpty {
                Text("No apps open")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.ink3)
                    .frame(height: 34)
            } else if showLevels {
                // Levels take the strip's place (a mixer under the strip is what made the panel long).
                levels.transition(Self.swap)
            } else {
                let apps = visible
                HStack(spacing: 0) {
                    ForEach(apps) { app in
                        SoundAppButton(app: app, muted: sound.isMuted(app.bundleID), usingAudio: sound.usingAudio.contains(app.bundleID),
                                       level: sound.volumes[app.bundleID], size: 30,
                                       previewing: LensStage.on(app.bundleID) ? true : nil,
                                       hover: { inside in
                                           if inside { hoveredApp = app.bundleID } else if hoveredApp == app.bundleID { hoveredApp = nil; toggledApp = nil }
                                       }) {
                            toggledApp = app.bundleID
                            withAnimation(Motion.micro) { sound.toggle(app) }
                        }
                        .frame(width: Self.iconPitch, alignment: .leading)
                    }
                    if !overflow.isEmpty { overflowMenu }
                    Spacer(minLength: 0)
                }
                // Over the icon under the pointer, as on the tools bar: what a click does to which app
                // ("Mute Chrome"), and once clicked, what it did. It glides along the row.
                .overlay(alignment: .topLeading) {
                    let id = hoveredApp ?? apps.first { LensStage.on($0.bundleID) }?.bundleID
                    if let id, let index = apps.firstIndex(where: { $0.bundleID == id }) {
                        let app = apps[index]
                        CenteredOver(center: CGFloat(index) * Self.iconPitch + 17) {
                            SoundAppLabel(name: app.name, muted: sound.isMuted(id), done: toggledApp == id,
                                          level: sound.volumes[id])
                        }
                        .offset(y: -29)
                        .animation(reduceMotion ? nil : .spring(duration: 0.22, bounce: 0.12), value: id)
                        .transition(ThemeStore.liquid && !reduceMotion
                            ? .scale(scale: 0.55, anchor: .bottom).combined(with: .opacity).animation(.spring(duration: 0.28, bounce: 0.2))
                            : .opacity.animation(reduceMotion ? nil : .easeOut(duration: 0.12)))
                        .allowsHitTesting(false)
                    }
                }
                // Each button is 2 pt wider than its icon, and an app icon's artwork sits about 3 pt
                // inside its square at this size: pull the row left so the artwork lines up with the text.
                .padding(.leading, -5)
                .zIndex(1)
                .transition(Self.swap)
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
        // While the card grows or shrinks, what's swapping in stays inside it (the levels were drawn
        // over the tools bar for a few frames); the strip's label may still rise into the title row.
        .mask(alignment: .top) { Rectangle().padding(.top, -40).padding(.horizontal, -12).padding(.bottom, -5) }
        .panelCard()
        .background(VisibilityReader { visible in
            if visible { sound.begin(); fixOrder(reset: true) } else { sound.end() }
        })
        .onAppear { fixOrder(reset: true) }
        .onChange(of: sound.apps.map(\.bundleID)) { fixOrder(reset: false) }
    }

    /// Every open app with its level, quiet ones included (they may play later): muted first, then
    /// the ones playing, then the order they opened. A click on an icon mutes it, as on the strip.
    /// Past eight, the list scrolls inside the card.
    private static let levelRows = 8
    private static let levelRowHeight: CGFloat = 26
    /// What's left of the card for the slider: the icon, the name, the level and the gaps take the
    /// rest (a fixed 126 pt made each line 22 pt wider than the card and pushed the panel aside).
    @MainActor private static var sliderWidth: CGFloat {
        PanelGrid.content - 2 * PanelGrid.inset - 20 - (18 + 66 + 40 + 3 * 8)
    }

    @ViewBuilder
    private var levels: some View {
        let apps = ordered
        Group {
            if apps.count > Self.levelRows {
                ThinScrollArea(lane: 10, edgeInset: 2) { levelList(apps) }
                    .frame(height: CGFloat(Self.levelRows) * Self.levelRowHeight + 4)
            } else {
                levelList(apps)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: Radius.of(10), style: .continuous).fill(Color.ink.opacity(0.045)))
    }

    private func levelList(_ apps: [SoundApp]) -> some View {
        VStack(spacing: 2) {
            ForEach(apps) { app in
                let muted = sound.isMuted(app.bundleID)
                let level = sound.volume(of: app.bundleID)
                HStack(spacing: 8) {
                    LevelAppIcon(app: app, muted: muted) {
                        withAnimation(Motion.micro) { sound.toggle(app) }
                    }
                    Text(app.name)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.ink2)
                        .lineLimit(1)
                        .frame(width: 66, alignment: .leading)
                    VolumeSlider(value: level, width: Self.sliderWidth) { sound.setVolume(app.bundleID, $0) }
                        .disabled(muted)
                        .opacity(muted ? 0.4 : 1)
                    Text(muted ? "Muted" : VolumeCurve.label(level))
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(level > 100 && !muted ? Color.themeAccent : Color.ink3)
                        .frame(width: 40, alignment: .trailing)
                }
                .frame(height: 24)
            }
        }
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
                .foregroundStyle(overflow.contains { sound.isMuted($0.bundleID) } || overflowHover ? Color.ink : Color.ink2)
                .frame(width: 25, height: 25)   // the size of an icon's artwork, not its square
                .background(Circle().fill(Color.ink.opacity(overflowHover ? 0.14 : 0.08)))
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { inside in withAnimation(Motion.micro) { overflowHover = inside } }
        .help("\(overflow.count) more apps")
        .accessibilityLabel("\(overflow.count) more apps")
    }
}

// MARK: - Convert & Compress

/// Convert & Compress, on the panel itself (Bryan, 2026-11-13: a "bigger part of the tutto menu bar
/// gui", "isn't just compress—it also has file conversion and stuff", "don't make it automatically
/// expanded", no Auto, then "it's like sort of cluttered right now"). Shaped after the tools people
/// praise most (DESIGN.md, Convert & Compress v3): nothing to read at rest, and the drag itself
/// brings up the choices, so where you drop is what happens.
/// - Closed: one line, its name, what compressing has saved, an arrow.
/// - Open: one drop well that says what a drop does ("Drop files to convert to JPEG"), click it to
///   choose files instead; one small menu picks the action and its setting.
/// - While files are dragged over the panel: the well (or the closed line, at the same height, so
///   nothing jumps) becomes four targets, Compress, Convert, Resize, Crop, each with its setting,
///   the ones that don't suit the files dimmed. ⌥ on the drop opens the Convert window.
/// - Under it, the last result: "83 % smaller · 410 KB", Undo and Show under the pointer.
struct ConvertCard: View {
    @Bindable var converter: ConverterModule
    /// On the Customize page: shown closed, not used.
    var placeholder = false
    /// Opened from its arrow, it stays open the next time the panel opens.
    @AppStorage("panel.convertOpen") private var keptOpen = false
    /// The arrow's state for this panel (a stored setting changes the view outside the animation, so
    /// opening snapped; this animates, and the setting follows it).
    @State private var opened: Bool?
    @State private var hoveringHeader = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Snapshots render it open (`convert-open`) or closed (`convert-closed`).
    nonisolated(unsafe) static var startsOpen = false
    nonisolated(unsafe) static var startsClosed = false

    private var isOpen: Bool { !placeholder && !Self.startsClosed && (Self.startsOpen || (opened ?? keptOpen)) }
    private var dragging: Bool { !placeholder && PanelDrag.shared.files }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                if dragging && !isOpen {
                    targets(compact: true)
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                } else {
                    header
                        .transition(.opacity)
                }
            }
            .frame(height: 28)
            if isOpen {
                ZStack {
                    if dragging {
                        targets(compact: false)
                            .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    } else {
                        DropWell(converter: converter)
                            .transition(.opacity.combined(with: .scale(scale: 1.02)))
                    }
                }
                .frame(height: 58)
                .transition(.opacity)
            }
            if converter.working != nil {
                progress
                    .transition(.opacity)
            } else if isOpen, let latest = converter.made.first, Date().timeIntervalSince(latest.date) < 12 * 3_600 {
                ResultRow(made: latest, converter: converter)
                    .transition(.opacity)
            }
        }
        .panelCard(vertical: 9)
        .clipped()
        .animation(Motion.lens(reduceMotion: reduceMotion), value: dragging)
        .allowsHitTesting(!placeholder)
    }

    // MARK: The line

    private var header: some View {
        HStack(spacing: 8) {
            RowLabel(symbol: ModuleID.converter.symbol, title: "Convert & Compress", live: converter.working != nil,
                     help: "Compress, convert, resize, crop or zip files")
            Spacer(minLength: 6)
            Button(action: toggle) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(hoveringHeader ? Color.ink : Color.ink3)
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
                    .lensHover(cornerRadius: 8, x: 0, y: 0, swell: Motion.iconSwell)
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel(isOpen ? "Hide actions" : "Show actions")
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onHover { hoveringHeader = $0 }
        .help(isOpen ? "Hide it" : "Drop files on the panel to compress, convert, resize or crop them, or open this")
    }

    private func toggle() {
        let open = !isOpen
        withAnimation(Motion.adaptive(Motion.snappy, reduceMotion: reduceMotion)) { opened = open }
        keptOpen = open
    }

    /// The four places to drop, side by side.
    private func targets(compact: Bool) -> some View {
        HStack(spacing: compact ? 4 : 6) {
            ForEach(ConverterModule.PanelDropMode.allCases, id: \.self) { mode in
                DropTarget(mode: mode, converter: converter, compact: compact,
                           fits: converter.fits(PanelDrag.shared.urls, mode: mode))
            }
        }
    }

    /// While it works: what, and how far along.
    private var progress: some View {
        HStack(spacing: 8) {
            ProgressView(value: min(max(converter.progress, 0), 1))
                .progressViewStyle(.linear)
                .controlSize(.small)
                .tint(Color.themeAccent)
                .frame(width: 70)
            Text(converter.working ?? "")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.ink2)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(height: 14)
    }

    /// The file URLs in a drop, all at once.
    static func urls(_ providers: [NSItemProvider], done: @escaping @MainActor ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        nonisolated(unsafe) var urls: [URL] = []
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated { done(urls) }
        }
    }

    /// Choose files for an action, in an Open panel once the menu bar panel has closed.
    static func choose(_ mode: ConverterModule.PanelDropMode, converter: ConverterModule) {
        afterPanelCloses {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = mode == .compress && converter.zips
            panel.message = "Choose files to \(converter.verb(mode))"
            panel.prompt = mode.title
            NSApp.activate()
            guard panel.runModal() == .OK else { return }
            converter.panelDrop(panel.urls, mode: mode)
        }
    }
}

extension ConverterModule.PanelDropMode {
    var symbol: String {
        switch self {
        case .compress: "arrow.down.right.and.arrow.up.left"
        case .convert: "arrow.triangle.2.circlepath"
        case .resize: "arrow.up.left.and.arrow.down.right"
        case .crop: "crop"
        }
    }
}

extension ConverterModule {
    /// "compress", "zip", "convert to JPEG", "resize to Half", "crop to 16:9".
    func verb(_ mode: PanelDropMode) -> String {
        switch mode {
        case .compress: zips ? "zip" : "compress"
        case .convert: "convert to \(panelFormat.title)"
        case .resize: "resize to \(panelResize.title)"
        case .crop: "crop to \(panelCrop.title)"
        }
    }

    /// An action's setting, in a word: "Smaller", "Zip", "JPEG", "Half", "16:9".
    func setting(_ mode: PanelDropMode) -> String {
        switch mode {
        case .compress: zips ? "Zip" : "Smaller"
        case .convert: panelFormat.title
        case .resize: panelResize.title
        case .crop: panelCrop.title
        }
    }

    /// Whether files being dragged suit an action (unknown files suit everything).
    func fits(_ files: [URL], mode: PanelDropMode) -> Bool {
        guard !files.isEmpty else { return true }
        if mode == .compress, zips { return true }
        return panelAction(for: files, mode: mode) != nil
    }

    /// Every action and its settings, in one menu: the action is picked with its setting.
    func actionMenu() -> [ChoiceMenu.Item] {
        var compress = [ChoiceMenu.Item(title: "Smaller copies", detail: "pictures, video, PDFs, sound", checked: panelMode == .compress && !zips) {
            self.panelMode = .compress
            self.panelZip = false
        }]
        if AppModel.shared.archives != nil {
            compress.append(ChoiceMenu.Item(title: "One .zip", detail: "anything, folders too", checked: panelMode == .compress && zips) {
                self.panelMode = .compress
                self.panelZip = true
            })
        }
        let groups: [(String, [OutputFormat])] = [("Pictures", [.jpeg, .png, .heic, .avif, .pdf, .tiff, .gif]),
                                                  ("Video", [.mp4, .mp4HEVC, .mov, .gif, .m4a]),
                                                  ("Sound", [.m4a, .wav, .flac, .aiff]), ("Documents", [.pdf, .docx, .txt])]
        let convert = groups.flatMap { section, formats in
            formats.enumerated().map { index, format in
                ChoiceMenu.Item(title: format.title, section: index == 0 ? section : nil, checked: panelMode == .convert && format == panelFormat) {
                    self.panelMode = .convert
                    self.panelFormat = format
                }
            }
        }
        let resize = ResizeSpec.picturePresets.map { spec in
            ChoiceMenu.Item(title: spec.title, detail: spec.detail, checked: panelMode == .resize && spec == panelResize) {
                self.panelMode = .resize
                self.panelResize = spec
            }
        }
        let crop = ChoiceMenu.crops(pdf: false, current: panelMode == .crop ? panelCrop : nil) { spec in
            self.panelMode = .crop
            self.panelCrop = spec
        }
        return [ChoiceMenu.Item(title: "Compress", checked: panelMode == .compress, children: compress),
                ChoiceMenu.Item(title: "Convert to", checked: panelMode == .convert, children: convert),
                ChoiceMenu.Item(title: "Resize", checked: panelMode == .resize, children: resize),
                ChoiceMenu.Item(title: "Crop", checked: panelMode == .crop, children: crop)]
    }
}

/// The card at rest: one well. A drop does what it says; a click chooses files for it; the menu at
/// its end changes what it does.
private struct DropWell: View {
    @Bindable var converter: ConverterModule
    @State private var hovering = false
    @State private var targeted = false
    @State private var menuHover = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.of(12), style: .continuous)
        let mode = converter.panelMode
        HStack(spacing: 10) {
            Image(systemName: converter.zips && mode == .compress ? "doc.zipper" : mode.symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(targeted ? Color.themeAccent : Color.ink2)
                .frame(width: 32, height: 32)
                .background { LensPlatter(shape: Circle(), raise: hovering || targeted ? 1.5 : 0.9) }
                .scaleEffect(hovering && !reduceMotion ? Motion.iconSwell : 1)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 1) {
                Text("Drop files to \(converter.verb(mode))")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .contentTransition(.opacity)
                Text("or click to choose them")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.ink3)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button { ChoiceMenu.show(converter.actionMenu()) } label: {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(menuHover ? Color.ink : Color.ink3)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
                    .lensHover(cornerRadius: 8, x: 0, y: 0, swell: Motion.iconSwell, hovering: { menuHover = $0 })
            }
            .buttonStyle(PressStyle())
            .help("What a drop does: compress, convert, resize or crop, and how")
            .accessibilityLabel("Action: \(converter.verb(mode))")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if ThemeStore.liquid {
                shape.fill(Color.ink.opacity(hovering || targeted ? 0.07 : 0.035))
            } else {
                shape.fill(Color.ink.opacity(hovering || targeted ? 0.08 : 0.04))
            }
        }
        .overlay {
            shape.strokeBorder(targeted ? Color.themeAccent : Color.ink.opacity(hovering ? 0.3 : 0.18),
                               style: StrokeStyle(lineWidth: targeted ? 1.5 : 1, dash: [4, 3]))
        }
        .scaleEffect(targeted && !reduceMotion ? 1.02 : 1)
        .animation(Motion.lens(reduceMotion: reduceMotion), value: hovering)
        .animation(Motion.lens(reduceMotion: reduceMotion), value: targeted)
        .animation(Motion.lens(reduceMotion: reduceMotion), value: mode)
        .contentShape(shape)
        .onTapGesture { ConvertCard.choose(converter.panelMode, converter: converter) }
        .onHover { hovering = $0 }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            ConvertCard.urls(providers) { files in converter.panelDrop(files) }
            return true
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Drop files to \(converter.verb(mode)), or choose them")
        .accessibilityAction { ConvertCard.choose(converter.panelMode, converter: converter) }
        .help("Drop files to \(converter.verb(mode)), or click to choose them · ⌥ when you drop: every option")
    }
}

/// A place to drop while files are on the move: the action, and its setting under it (beside it on
/// the closed line). The one under the files lights up; one that doesn't suit them is dimmed.
private struct DropTarget: View {
    var mode: ConverterModule.PanelDropMode
    var converter: ConverterModule
    var compact: Bool
    var fits: Bool
    @State private var targeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.of(compact ? 9 : 12), style: .continuous)
        let symbol = mode == .compress && converter.zips ? "doc.zipper" : mode.symbol
        Group {
            if compact {
                // The closed line is too narrow for icons: the names alone, as on the open card.
                Text(mode.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(targeted ? Color.themeAccent : Color.ink)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
            } else {
                VStack(spacing: 2) {
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(targeted ? Color.themeAccent : Color.ink2)
                        .frame(height: 17)
                    Text(mode.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                    Text(converter.setting(mode))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.ink3)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if ThemeStore.liquid {
                LiquidFill(shape: shape, raise: targeted ? 1.8 : 1, hovering: targeted)
            } else {
                shape.fill(Color.ink.opacity(targeted ? 0.12 : 0.05))
            }
        }
        .overlay {
            shape.strokeBorder(targeted ? Color.themeAccent : Color.ink.opacity(0.26),
                               style: StrokeStyle(lineWidth: targeted ? 1.5 : 1, dash: [4, 3]))
        }
        .opacity(fits || targeted ? 1 : 0.4)
        .scaleEffect(targeted && !reduceMotion ? 1.06 : 1)
        .animation(Motion.lens(reduceMotion: reduceMotion), value: targeted)
        .contentShape(shape)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            ConvertCard.urls(providers) { files in converter.panelDrop(files, mode: mode) }
            return true
        }
        .accessibilityLabel("\(mode.title): \(converter.setting(mode))")
        .help("\(mode.title): \(converter.setting(mode))")
    }
}

/// The last thing made: its picture, its name, how much smaller in words, and, under the pointer,
/// Undo and Show. Drag it out to put it anywhere.
private struct ResultRow: View {
    var made: ConverterModule.Made
    var converter: ConverterModule
    @State private var hovering = false
    @State private var thumbnail: NSImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: thumbnail ?? NSWorkspace.shared.icon(forFile: made.url.path))
                .resizable()
                .aspectRatio(contentMode: thumbnail == nil ? .fit : .fill)
                .frame(width: 26, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.ink.opacity(thumbnail == nil ? 0 : 0.12)))
            VStack(alignment: .leading, spacing: 0) {
                Text(made.url.lastPathComponent)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(summary)
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(Color.ink3)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if hovering {
                HStack(spacing: 2) {
                    action("arrow.uturn.backward", help: "Undo: move this copy to the Trash") { converter.undo(made) }
                    action("folder", help: "Show in Finder") {
                        afterPanelCloses { NSWorkspace.shared.activateFileViewerSelecting([made.url]) }
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .frame(height: 30)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Motion.lens(reduceMotion: reduceMotion), value: hovering)
        .onDrag { NSItemProvider(contentsOf: made.url) ?? NSItemProvider() }
        .help("Drag it anywhere")
        .task(id: made.url) { thumbnail = await Self.thumbnail(made.url) }
    }

    /// "83 % smaller · 410 KB", "Converted to PNG · 1.2 MB".
    private var summary: String {
        let size = ConverterModule.bytes(made.after)
        let smaller = SavedBytes.smaller(before: made.before, after: made.after)
        if made.action == .compress { return smaller.isEmpty ? "Already small · \(size)" : "\(smaller) · \(size)" }
        return "\(made.action.done) · \(size)"
    }

    private func action(_ symbol: String, help: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.ink2)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .lensHover(cornerRadius: 7, x: 0, y: 0, swell: Motion.iconSwell)
        }
        .buttonStyle(PressStyle())
        .help(help)
        .accessibilityLabel(help)
    }

    private static func thumbnail(_ url: URL) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 26, height: 26),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }
}

// MARK: - Battery, small or wide

/// The battery: the full card when wide, a tile with the charge and the watts when small. A Mac
/// without a battery shows its busiest apps instead.
struct BatteryWidget: View {
    var model: AppModel
    var wide: Bool
    /// The Bluetooth devices drawn inside the battery card.
    var devices = false

    var body: some View {
        if let system = model.system {
            if let battery = system.battery {
                if wide {
                    BatteryCard(battery: battery, system: system, devices: devices)
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

// MARK: - Bluetooth devices

/// One line per Bluetooth device that reports a charge: symbol, name, levels (low ones in the
/// alert colour). Nothing is drawn when none does; on the Customize page it shows a stand-in.
struct DevicesCard: View {
    var placeholder: Bool
    /// Inside the battery card: no card of its own.
    var inline = false
    @State private var hovering = false

    var body: some View {
        let devices = BluetoothBatteries.shared.devices
        if !devices.isEmpty {
            Button {
                showInApp(.battery)
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(devices) { device in
                        HStack(spacing: 8) {
                            Image(systemName: device.kind.symbol)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Color.ink3)
                                .frame(width: 16)
                            Text(BluetoothBatteryRules.shortName(device.name))
                                .font(.system(size: 12))
                                .foregroundStyle(Color.ink2)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 8)
                            // The levels keep their room; a long name gives way.
                            BluetoothLevelsText(parts: device.parts, size: 12)
                                .fixedSize()
                                .layoutPriority(1)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(device.name)
                        .accessibilityValue(BluetoothBatteryRules.spoken(device.levels))
                    }
                }
                // Inside the battery card, the card answers the pointer; on its own, its own lens.
                .hoverBackground(hovering && !inline, x: 6, y: 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("Bluetooth device batteries")
            .modifier(DeviceCardSurface(inline: inline, vertical: 10))
        } else if BluetoothBatteries.shared.access != .allowed {
            // AirPods' levels need Bluetooth access, which macOS asks for once: until then, say so.
            let blocked = BluetoothBatteries.shared.access == .blocked
            HStack(spacing: 8) {
                Image(systemName: "airpods")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.ink3)
                    .frame(width: 16)
                Text(blocked ? "Bluetooth is off for Tutto" : "Bluetooth batteries")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.ink2)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Button(blocked ? "Settings" : "Show") {
                    if blocked {
                        afterPanelCloses {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    } else {
                        BluetoothBatteries.shared.requestAccess()
                    }
                }
                .buttonStyle(OutlineButtonStyle(compact: true))
                .fixedSize()
                .probeFrame("battery.show")
                .help(blocked ? "Turn Tutto on under Privacy & Security → Bluetooth" : "macOS asks once to let Tutto read Bluetooth devices")
            }
            .modifier(DeviceCardSurface(inline: inline, vertical: 8))
        } else if placeholder {
            HStack(spacing: 8) {
                Image(systemName: "headphones")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.ink3)
                Text("Bluetooth devices appear here when one is connected")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.ink3)
                    .lineLimit(1)
            }
            .modifier(DeviceCardSurface(inline: inline, vertical: 10))
        }
    }
}

/// The devices card's own surface, or none inside the battery card.
private struct DeviceCardSurface: ViewModifier {
    var inline: Bool
    var vertical: CGFloat

    func body(content: Content) -> some View {
        if inline { content } else { content.panelCard(vertical: vertical) }
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
                    .modifier(CardLift(on: hovering, radius: 10))
            }
            .buttonStyle(PressStyle())
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
        .cardSurface(radius: 10, hovering: hovering)
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
            rows.append(Row(action: .recordScreen, title: "Record Screen", short: "Record", symbol: "record.circle"))
            rows.append(Row(action: .scrollingCapture, title: "Scrolling Capture", short: "Scroll", symbol: "arrow.down.to.line.compact"))
        }
        if model.clipboard != nil {
            rows.append(Row(action: .clipboardHistory, title: "Clipboard History", short: "History", symbol: "list.clipboard"))
        }
        if model.windows != nil { rows.append(Row(action: .windowPalette, title: "Snap Window", short: "Snap", symbol: "rectangle.split.2x1")) }
        if model.wordCounter != nil {
            rows.append(Row(action: .wordCounter, title: "Count Words", short: "Words", symbol: ModuleID.wordCounter.symbol))
        }
        // The Convert & Compress card has it, bigger; the tool stays for a panel without the card.
        if model.converter != nil, !model.layout.layout.widgets.isShown(PanelLayoutStore.Card.compress.id) {
            rows.append(Row(action: .convertFiles, title: "Convert Files", short: "Convert", symbol: ModuleID.converter.symbol))
        }
        if model.cleaner != nil {
            rows.append(Row(action: .cleanUp, title: "Clean Up", short: "Clean", symbol: ModuleID.cleaner.symbol))
        }
        for plugin in model.plugins.plugins where model.plugins.isOn(plugin) && plugin.hasAction {
            rows.append(Row(action: .plugin(plugin.id), title: plugin.name, short: plugin.name, symbol: plugin.symbol))
        }
        return rows
    }
}

struct ToolsCard: View {
    var model: AppModel
    /// A tool is on its way (keys lighting, panel closing): the bar ignores further clicks, so a
    /// quick double click can't run it twice or bring the panel back.
    @State private var launching = false
    /// The tool under the pointer (or being pressed): its name and keys float above the bar.
    @State private var hovered: String? = ToolsCard.startsHovered
    @State private var lit = 0
    /// Renders with this tool's label up (`tool-hover:<id>`).
    nonisolated(unsafe) static var startsHovered: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Liquid Glass: the one lens that glides from icon to icon.
    @Namespace private var lens
    private static let inset: CGFloat = 6
    private static let gap: CGFloat = 2
    /// Icons in a row before the bar wraps.
    private static let perRow = 10

    var body: some View {
        let rows = ShortcutRows.visible(model)
        let lines = PanelLayout.rows(rows, perRow: Self.perRow)
        let count = CGFloat(min(max(lines.first?.count ?? 1, 1), Self.perRow))
        let tile = (PanelGrid.width - 2 * PanelGrid.outer - 2 * Self.inset - Self.gap * (count - 1)) / count
        VStack(alignment: .leading, spacing: Self.gap) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(spacing: Self.gap) {
                    ForEach(line) { row in
                        toolButton(row)
                            .frame(width: tile)
                    }
                }
            }
        }
        .padding(.horizontal, Self.inset)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .cardSurface(radius: 12)
        .overlay(alignment: .topLeading) {
            if let id = hovered, let index = rows.firstIndex(where: { $0.id == id }) {
                let row = rows[index]
                let column = CGFloat(index % Self.perRow), line = CGFloat(index / Self.perRow)
                // Centered over its own icon (kept inside the card at the ends); moving to the next
                // icon glides it there instead of fading out and in.
                CenteredOver(center: Self.inset + column * (tile + Self.gap) + tile / 2) {
                    ToolLabel(row: row, shortcut: model.shortcuts.shortcut(for: row.action), lit: lit)
                }
                .offset(y: -30 + line * 32)
                .animation(reduceMotion ? nil : .spring(duration: 0.22, bounce: 0.12), value: id)
                // Liquid Glass: the label grows out of its icon instead of fading in.
                .transition(ThemeStore.liquid && !reduceMotion
                    ? .scale(scale: 0.55, anchor: .bottom).combined(with: .opacity).animation(.spring(duration: 0.28, bounce: 0.2))
                    : .opacity.animation(reduceMotion ? nil : .easeOut(duration: 0.12)))
                .allowsHitTesting(false)
            }
        }
        .zIndex(1)
    }

    private func toolButton(_ row: ShortcutRows.Row) -> some View {
        Button {
            press(row)
        } label: {
            Image(systemName: row.symbol)
                .font(.system(size: 14.5))
                .foregroundStyle(Color.ink)
                // Under the lens the icon swells a little, as if magnified.
                .scaleEffect(ThemeStore.liquid && hovered == row.id ? 1.14 : 1)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background {
                    if ThemeStore.liquid {
                        if hovered == row.id {
                            LiquidFill(shape: RoundedRectangle(cornerRadius: 11, style: .continuous), raise: 1.5)
                                .matchedGeometryEffect(id: "lens", in: lens)
                        }
                    } else {
                        RoundedRectangle(cornerRadius: Radius.of(8), style: .continuous)
                            .fill(hovered == row.id ? Color.ink.opacity(0.08) : .clear)
                    }
                }
                .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.18), value: hovered)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { inside in
            guard !launching else { return }
            if inside { hovered = row.id } else if hovered == row.id { hovered = nil }
        }
        .accessibilityLabel(row.title)
        .accessibilityValue(model.shortcuts.shortcut(for: row.action)?.spokenDescription ?? "")
    }

    /// Keys light 30 ms apart (all at once under Reduce Motion), the tool runs 80 ms after the last,
    /// and the keys go dark once the panel has faded. One launch at a time for the whole bar.
    private func press(_ row: ShortcutRows.Row) {
        guard !launching else { return }
        launching = true
        hovered = row.id
        let count = model.shortcuts.shortcut(for: row.action)?.symbols.count ?? 0
        let step = reduceMotion ? 0 : 0.03
        for index in 0..<count {
            DispatchQueue.main.asyncAfter(deadline: .now() + step * Double(index)) {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.05)) { lit = index + 1 }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + step * Double(count) + 0.08) {
            afterPanelCloses { model.perform(row.action) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                lit = 0
                launching = false
                hovered = nil
            }
        }
    }
}

/// Places one view centered at `center` across the width it's given, kept 2 pt inside the edges.
/// (An alignment guide did this before and was ignored: every label sat at the left end.)
private struct CenteredOver: Layout {
    var center: CGFloat
    var margin: CGFloat = 2

    var animatableData: CGFloat {
        get { center }
        set { center = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews.first?.sizeThatFits(.unspecified) ?? .zero
        return CGSize(width: proposal.width ?? size.width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let label = subviews.first else { return }
        let size = label.sizeThatFits(.unspecified)
        let x = min(max(center - size.width / 2, margin), max(bounds.width - size.width - margin, margin))
        label.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY), proposal: ProposedViewSize(size))
    }
}

/// Over the tools bar: the hovered tool's name and its keys as small keycaps (lit in turn when pressed).
private struct ToolLabel: View {
    var row: ShortcutRows.Row
    var shortcut: KeyShortcut?
    var lit: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(row.title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.ink)
                .lineLimit(1)
            if let shortcut {
                HStack(spacing: 1.5) {
                    ForEach(Array(shortcut.symbols.enumerated()), id: \.offset) { index, symbol in
                        Text(symbol)
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(lit > index ? Color.white : Color.ink2)
                            .frame(minWidth: 12, minHeight: 14)
                            .padding(.horizontal, symbol.count > 1 ? 2 : 0)
                            .background(RoundedRectangle(cornerRadius: Radius.of(3), style: .continuous)
                                .fill(lit > index ? Color.themeAccent : Color.wash))
                            .overlay(RoundedRectangle(cornerRadius: Radius.of(3), style: .continuous)
                                .strokeBorder(lit > index ? Color.clear : Color.hairline))
                    }
                }
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 24)
        .modifier(ToolLabelSurface())
    }
}

/// The label's capsule: glass under Liquid Glass, else paper with a hairline and a soft shadow.
private struct ToolLabelSurface: ViewModifier {
    func body(content: Content) -> some View {
        if ThemeStore.liquid {
            content.liquidGlass(Capsule())
        } else {
            content
                .background(Capsule().fill(Color.paper))
                .overlay(Capsule().strokeBorder(Color.hairline))
                .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
        }
    }
}

/// Over the Sound strip, as the tools bar's label: what a click does to the app under the pointer
/// ("Mute Chrome"), and once clicked, what it did ("Chrome muted"), with its level when it isn't 100 %.
private struct SoundAppLabel: View {
    var name: String
    var muted: Bool
    var done: Bool
    var level: Double?

    var body: some View {
        HStack(spacing: 4) {
            if done {
                Text(name).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Color.ink)
                Text(muted ? "muted" : "unmuted").font(.system(size: 11.5)).foregroundStyle(Color.ink2)
            } else {
                Text(muted ? "Unmute" : "Mute").font(.system(size: 11.5)).foregroundStyle(Color.ink2)
                Text(name).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Color.ink)
            }
            if let level, !muted, Int(level.rounded()) != 100 {
                Text(VolumeCurve.label(level))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(level > 100 ? Color.themeAccent : Color.ink3)
                    .padding(.leading, 2)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 9)
        .frame(height: 24)
        .modifier(ToolLabelSurface())
    }
}

/// The app icon on a level line: a click mutes it, and under the pointer it shows that, as on the strip.
private struct LevelAppIcon: View {
    var app: SoundApp
    var muted: Bool
    var action: () -> Void
    @State private var hovering = false
    @State private var toggled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var preview: Bool { hovering && !toggled }

    var body: some View {
        Button {
            toggled = true
            action()
        } label: {
            Image(nsImage: app.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 18, height: 18)
                .saturation(muted ? (preview ? 1 : 0) : (preview ? 0.35 : 1))
                .opacity(muted ? (preview ? 0.85 : 0.45) : (preview ? 0.8 : 1))
                .overlay(alignment: .bottomTrailing) {
                    if preview || muted {
                        Image(systemName: muted && preview ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(Color.ink)
                            .offset(x: 3, y: 2)
                            .id(muted && preview ? "unmute" : "mute")
                            .transition(.scale(scale: 0.5).combined(with: .opacity))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { inside in
            hovering = inside
            if !inside { toggled = false }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.1) : Motion.lens, value: preview)
        .help(muted ? "Unmute \(app.name)" : "Mute \(app.name)")
        .accessibilityLabel(app.name)
        .accessibilityValue(muted ? "Muted" : "Not muted")
    }
}

// MARK: - Footer

struct PanelFooter: View {
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
                    .hoverBackground(hovering || LensStage.on("Open Tutto"))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .onHover { hovering = $0 }
            Spacer()
            if let strip = model.strip, strip.isRunning {
                WindowModeSwitch(strip: strip)
            }
            Menu {
                if let clipboard = model.clipboard {
                    Toggle("Pause Clipboard History", isOn: Binding(get: { clipboard.isPaused }, set: { clipboard.isPaused = $0 }))
                }
                if let corner = model.corner {
                    Toggle("Pause Trackpad Corner", isOn: Binding(get: { !corner.isEnabled }, set: { corner.isEnabled = !$0 }))
                }
                if model.clipboard != nil || model.corner != nil { Divider() }
                Button("Clean the Keyboard…") { model.perform(.cleanKeyboard) }
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
                    .lensHover(cornerRadius: 9, x: 0, y: 0, swell: Motion.iconSwell, stageKey: "more")
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
        .modifier(FloatingCapsule())
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
        .cardSurface(radius: 12)
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

#if DEBUG
/// For renders: network tiles with made-up speeds, to check the caption and its detail at
/// three- and four-digit uploads.
struct PreviewNetworkTiles: View {
    var body: some View {
        VStack(spacing: PanelGrid.gap) {
            ForEach(["↑ 84 KB/s", "↑ 120 KB/s", "↑ 375 KB/s", "↑ 999 KB/s", "↑ 1.2 MB/s"], id: \.self) { detail in
                HStack(spacing: PanelGrid.gap) {
                    StatTile(caption: "Network", value: "227", unit: "KB/s", detail: detail, prefix: "↓", page: .network,
                             help: "", spokenName: "Network", spokenValue: detail, wide: false) {
                        Sparkline(values: [0.2, 0.5, 0.3, 0.7, 0.4], color: .themeAccent, stretch: true)
                    }
                    StatTile(caption: "Temp", value: "91", unit: "°C", detail: "GPU 82°", page: .sensors,
                             help: "", spokenName: "Temp", spokenValue: "91", wide: false) {
                        Meter(value: 0.6, height: 4, alert: false, fill: .themeAccent, track: Color.ink.opacity(0.1))
                            .frame(height: 4).frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 4)
                    }
                }
            }
        }
        .padding(PanelGrid.outer)
        .frame(width: PanelGrid.width)
    }
}
#endif
