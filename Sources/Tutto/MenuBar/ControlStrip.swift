//
//  ControlStrip.swift
//  Tutto
//
//  The controls as one row of chips (Bryan, 2026-11-21, picking layout A of the shorter-panel
//  studies: the panel was 946 pt on an 835 pt screen, so it scrolled and the tools fell below the
//  fold). Stay awake, the auto clicker, the fan, Sound and Convert & Compress each become a chip
//  on the cards' own surface, its state in the tooltip (Bryan, 2026-11-21: the chips' own fill and
//  third line read as clutter, not glass); a click opens that control, as the
//  panel always drew it, under the row, and a second click (or another chip) closes it. Files
//  dragged over the Compress chip open it, so dropping still works in one move.
//
//  The Customize page still orders and hides each control: the chips follow that order, and the
//  row sits where the first of them is.
//

import SwiftUI
import TuttoKit

enum ControlStrip {
    /// The row's id among the cards (never saved; the layout keeps each control's own id).
    static let id = "strip.controls"
    /// The cards that become chips.
    static let ids = ["awake", "clicker", "fan", "sound", "compress"]
}

/// The panel's cards after folding: the controls into one row of chips, and the Bluetooth
/// devices into the battery card when they sit right under it.
struct PanelFold {
    var slots: [WidgetSlot]
    var chips: [String] = []
    var devicesInBattery = false

    init(_ slots: [WidgetSlot], editing: Bool) {
        var slots = slots
        // On the Customize page the devices card stays its own, to pick up and move.
        if !editing, let battery = slots.firstIndex(where: { $0.id == "battery" }), slots[battery].size == .wide,
           battery + 1 < slots.count, slots[battery + 1].id == "devices" {
            slots.remove(at: battery + 1)
            devicesInBattery = true
        }
        chips = slots.map(\.id).filter(ControlStrip.ids.contains)
        if let first = slots.firstIndex(where: { ControlStrip.ids.contains($0.id) }) {
            slots[first] = WidgetSlot(id: ControlStrip.id, size: .wide)
            slots.removeAll { ControlStrip.ids.contains($0.id) }
        }
        self.slots = slots
    }
}

/// The chips, and under them the control that's open.
struct ControlStripView: View {
    var model: AppModel
    var ids: [String]
    var editing: PanelEditing?
    @State private var open: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Snapshots: the control drawn open (`open:<id>`).
    nonisolated(unsafe) static var startsOpen: String?
    #if DEBUG
    /// The click probe: which control is open, and where each chip is (window, top-left origin).
    nonisolated(unsafe) static var probeOpen: String?
    #endif

    private var shown: String? {
        let id = open ?? Self.startsOpen
        return id.flatMap { ids.contains($0) ? $0 : nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PanelGrid.gap) {
            HStack(spacing: PanelGrid.gap) {
                ForEach(ids, id: \.self) { id in
                    Editable(id: id, editing: editing, radius: 10) {
                        ControlChip(model: model, id: id, selected: shown == id) { toggle(id) }
                            .probeFrame("chip.\(id)")
                            .onDrop(of: [.fileURL], isTargeted: Binding(get: { false }, set: { over in
                                if over, id == "compress", shown != id { toggle(id) }
                            })) { _ in false }
                    }
                }
            }
            if let shown {
                control(shown)
                    .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.18).delay(0.06)),
                                            removal: .opacity.animation(.easeOut(duration: 0.08))))
                    .id(shown)
            }
        }
        // The sound and fan states are read only while the chips are on screen.
        .background(VisibilityReader { visible in
            if let sound = model.sound, ids.contains("sound") { visible ? sound.begin() : sound.end() }
            if let sensors = model.sensors, ids.contains("fan") { visible ? sensors.begin() : sensors.end() }
        })
    }

    private func toggle(_ id: String) {
        Self.startsOpen = nil
        withAnimation(reduceMotion ? nil : Motion.snappy) { open = shown == id ? nil : id }
        #if DEBUG
        Self.probeOpen = open
        #endif
    }

    @ViewBuilder
    private func control(_ id: String) -> some View {
        switch id {
        case "sound": if let sound = model.sound, SoundModule.isSupported { SoundCard(sound: sound) }
        case "compress": if let converter = model.converter { ConvertCard(converter: converter, placeholder: editing != nil, startsExpanded: true) }
        default: ControlRows(model: model, ids: [id], editing: nil)
        }
    }
}

/// One chip: a symbol, the control's name, its state. Accent while the control is doing something.
private struct ControlChip: View {
    var model: AppModel
    var id: String
    var selected: Bool
    var action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Under the pointer (or forced on a snapshot): the same lift as the readings' tiles.
    private var lifted: Bool { hovering || LensStage.on("chip.\(id)") }

    var body: some View {
        let state = Self.state(id, model: model)
        Button(action: action) {
            // The readings' tile, word for word: the card surface (glass in the glass look) and its
            // quiet hover (CardLift). Open, the glass stays a shade brighter with
            // its symbol in the accent; running, a dot says so.
            VStack(spacing: 4) {
                Image(systemName: Self.symbol(id))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(state.live || selected ? Color.themeAccent : Color.ink2)
                    .frame(height: 18)
                    .overlay(alignment: .topTrailing) {
                        if state.live {
                            Circle().fill(Color.themeAccent).frame(width: 5, height: 5).offset(x: 6, y: -1)
                        }
                    }
                Text(Self.title(id))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(selected ? Color.ink : Color.ink2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .allowsTightening(true)
                    .padding(.horizontal, 2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .modifier(CardLift(on: lifted, radius: 10))
            .cardSurface(radius: 10, hovering: selected)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .animation(Motion.lens(reduceMotion: reduceMotion), value: lifted)
        .animation(Motion.lens(reduceMotion: reduceMotion), value: selected)
        .help("\(Self.title(id)) · \(state.text)")
        .accessibilityLabel(Self.title(id))
        .accessibilityValue(state.text)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    static func title(_ id: String) -> String {
        switch id {
        case "awake": "Awake"
        case "clicker": "Clicker"
        case "fan": "Fan"
        case "sound": "Sound"
        default: "Compress"
        }
    }

    static func symbol(_ id: String) -> String {
        switch id {
        case "awake": ModuleID.awake.symbol
        case "clicker": ModuleID.clicker.symbol
        case "fan": "fan"
        case "sound": "speaker.wave.2"
        default: ModuleID.converter.symbol
        }
    }

    /// What the chip says under its name, and whether that's something running.
    @MainActor static func state(_ id: String, model: AppModel) -> (text: String, live: Bool) {
        switch id {
        case "awake":
            return model.awake?.isRunning == true ? ("On", true) : ("Off", false)
        case "clicker":
            guard let clicker = model.clicker else { return ("", false) }
            if clicker.isOn { return ("Clicking", true) }
            return ("\(Int(clicker.settings.clicksPerSecond.rounded())) CPS", false)
        case "fan":
            guard let sensors = model.sensors, let fan = sensors.fans.first else { return ("Auto", false) }
            let held: Bool = switch sensors.commands[fan.index] {
            case .none, .auto?: false
            default: true
            }
            let speed = fan.isStopped ? "Off" : "\(Format.number(Int(fan.currentRPM))) rpm"
            return (speed, held)
        case "sound":
            guard let sound = model.sound else { return ("", false) }
            let playing = sound.apps.filter { sound.usingAudio.contains($0.bundleID) }.count
            if playing > 0 { return ("\(playing) playing", false) }
            return (sound.apps.isEmpty ? "Quiet" : "\(sound.apps.count) apps", false)
        default:
            guard let converter = model.converter else { return ("", false) }
            if converter.working != nil { return ("\(Int((converter.progress * 100).rounded())) %", true) }
            return ("Drop files", false)
        }
    }
}

extension View {
    /// The click probe's map of where things are (window, top-left origin); nothing in a release build.
    @ViewBuilder
    func probeFrame(_ key: String) -> some View {
        #if DEBUG
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { ClickProbe.frames[key] = $0 }
        #else
        self
        #endif
    }
}
