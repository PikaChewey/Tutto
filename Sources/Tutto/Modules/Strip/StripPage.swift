//
//  StripPage.swift
//  Tutto (scrolling strip)
//
//  The Scrolling Strip page: whether it's running, the keys to start with, how windows are
//  laid out, what it draws, the trackpad, displays, apps that float, and a check of the
//  macOS settings that fight it.
//

import AppKit
import SwiftUI
import TuttoKit

struct StripPage: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: "Scrolling Strip",
                       subtitle: "Every window sits side by side on one strip, full height, and the screen scrolls along it. Nothing overlaps, and opening another window never shrinks the rest.",
                       module: .strip)
            if let strip = model.strip {
                StripSettings(strip: strip, model: model)
            } else {
                ModuleOffView(module: .strip, model: model)
            }
        }
    }
}

private struct StripSettings: View {
    @Bindable var strip: StripModule
    @Bindable var model: AppModel

    private static let widthChoices: [Double] = [0.2, 0.25, 1.0 / 3.0, 0.4, 0.5, 0.6, 2.0 / 3.0, 0.75, 0.8]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            status
            keys
            layout
            InkGroup("Show") {
                toggle("Strip bar", detail: "Along the bottom while you hold ⌃⌥ or move around: one tile per column. Click a tile to go there, drag one to reorder.",
                       isOn: $strip.showsIndicator)
                Hairline().opacity(0.6)
                toggle("Window pictures in the strip bar", detail: WindowPictures.canCapture
                       ? "A picture of each window instead of its app's icon. Windows out of view show how they looked before they slid away."
                       : "Needs Screen Recording (Permissions). Until then the bar shows app icons.",
                       isOn: $strip.barPreviews)
                Hairline().opacity(0.6)
                toggle("Border around the focused window", detail: "A thin outline on the window you're in.", isOn: $strip.focusBorder)
                Hairline().opacity(0.6)
                toggle("Dim the other windows", detail: "Everything but the window you're in, a little darker.", isOn: $strip.dimInactive)
            }
            trackpad
            displays
            floatingApps
            setup
            Text("Dialogs, Quick Look, picture in picture and fixed-size windows float above the strip on their own. A window in native full screen is left alone, and comes back to its place when it leaves full screen.")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .background(VisibilityReader { visible in if visible { strip.refreshSetupChecks() } })
    }

    // MARK: Groups

    @ViewBuilder
    private var status: some View {
        InkGroup {
            if !strip.isTrusted {
                LabeledRow("Allow Accessibility to move windows",
                           detail: "That's how macOS lets an app move other apps' windows. Privacy & Security › Accessibility.") {
                    Button("Allow") { model.permissions.request(.accessibility) }
                        .buttonStyle(InkButtonStyle(compact: true))
                }
            } else {
                LabeledRow(strip.isRunning ? "\(strip.windowCount) \(strip.windowCount == 1 ? "window" : "windows") on the strip" : "Stopped",
                           detail: strip.isRunning
                               ? "Hold ⌃⌥ and press ← → or scroll to slide along it. Stopping puts every window back on screen."
                               : "Windows are where you left them. Start lays them out again.") {
                    HStack(spacing: 8) {
                        if strip.isRunning {
                            Button("Tile Again") { strip.retileNow() }
                                .buttonStyle(OutlineButtonStyle(compact: true))
                                .help("Lay out every window on screen again, left to right.")
                        }
                        Button(strip.isRunning ? "Stop" : "Start") { strip.perform(.toggleRunning) }
                            .buttonStyle(InkButtonStyle(compact: true))
                    }
                }
                if strip.isRunning, strip.fullScreenWindowCount > 0 {
                    Hairline().opacity(0.6)
                    LabeledRow("\(strip.fullScreenWindowCount) \(strip.fullScreenWindowCount == 1 ? "window is" : "windows are") in full screen",
                               detail: "A window in native full screen keeps a Space of its own, so the strip leaves it alone. Bring them here and each becomes a full-width column: it still fills the screen, and ⌃⌥ ← → slides between them.") {
                        Button(strip.isBringingHome ? "Bringing…" : "Bring Them Here") { strip.bringFullScreenWindowsHere() }
                            .buttonStyle(InkButtonStyle(compact: true))
                            .disabled(strip.isBringingHome)
                    }
                }
            }
        }
    }

    private var keys: some View {
        InkGroup("Keys", trailing: AnyView(Button("All Shortcuts…") { MainWindowController.shared.show(page: .shortcuts) }
            .buttonStyle(OutlineButtonStyle(compact: true)))) {
            keyRow("Move between windows", [.focusLeft, .focusRight])
            Hairline().opacity(0.6)
            keyRow("Move a window along the strip", [.moveLeft, .moveRight])
            Hairline().opacity(0.6)
            keyRow("Jump to window 1 to 9 (9 is the last)", [.focusNumber(1)], trailing: "…9")
            Hairline().opacity(0.6)
            keyRow("Cycle width · full width · centre", [.cycleWidth, .fullWidth, .centre])
            Hairline().opacity(0.6)
            keyRow("Stack into the left or right column · pop out", [.stackLeft, .stackRight, .popOutRight])
            Hairline().opacity(0.6)
            keyRow("Tabbed column · float or tile", [.toggleTabbed, .toggleFloat])
            Hairline().opacity(0.6)
            keyRow("Pin to the left or right edge", [.pinLeft, .pinRight])
            Hairline().opacity(0.6)
            keyRow("Show the strip · stop or start it", [.showStrip, .toggleRunning])
        }
    }

    private var layout: some View {
        InkGroup("Layout") {
            LabeledRow("Arrange windows", detail: strip.arrangeMode == .onCommand
                       ? "Only when you use a strip key, or switch to a window that's out of view. Windows you move yourself (or with the window palette) stay where you put them until then."
                       : "All the time: every window keeps its place on the strip, whatever moves it.") {
                InkSegmented(selection: $strip.arrangeMode, options: [(StripModule.ArrangeMode.onCommand, "On a strip key"), (.always, "All the time")])
            }
            Hairline().opacity(0.6)
            LabeledRow("Gap", detail: strip.gap == 0 ? "None: windows edge to edge." : "\(Int(strip.gap)) pt between windows and at the screen edges.") {
                InkSegmented(selection: $strip.gap, options: [(0, "0"), (4, "4"), (8, "8"), (12, "12"), (16, "16")])
            }
            Hairline().opacity(0.6)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: Metrics.titleToDetail) {
                        Text("Widths to cycle through").font(.system(size: 13, weight: .medium))
                        Text("⌃⌥R steps a window up through these, then back to the smallest.")
                            .font(.system(size: 11.5)).foregroundStyle(Color.ink3)
                    }
                    Spacer()
                }
                HStack(spacing: 6) {
                    ForEach(Self.widthChoices, id: \.self) { width in
                        let on = strip.presets.contains { abs($0 - width) < 0.001 }
                        Button(Strip.percent(width)) { togglePreset(width) }
                            .buttonStyle(ChipStyle(on: on))
                            .disabled(on && strip.presets.count <= 2)
                    }
                }
            }
            .padding(.vertical, Metrics.rowPadding)
            Hairline().opacity(0.6)
            LabeledRow("New windows open at", detail: "Beside the window you're in.") {
                InkSegmented(selection: $strip.defaultWidth,
                             options: (strip.presets.sorted() + [1]).map { ($0, $0 >= 0.999 ? "Full" : Strip.percent($0)) })
            }
            Hairline().opacity(0.6)
            toggle("Fill the height", detail: strip.fullHeight ? "Every window runs from the menu bar to the Dock."
                       : "Windows keep the height they opened with, along the top.", isOn: $strip.fullHeight)
            Hairline().opacity(0.6)
            LabeledRow("Keep the focused window centred", detail: centringDetail) {
                InkSegmented(selection: $strip.centring, options: [(StripCentring.never, "Never"), (.whenOverflowing, "When it overflows"), (.always, "Always")])
            }
            Hairline().opacity(0.6)
            LabeledRow("Motion", detail: strip.animation == .instant ? "Windows jump straight to their place." : "A spring that starts the moment you press the key.") {
                InkSegmented(selection: $strip.animation, options: [(StripAnimation.smooth, "Smooth"), (.fast, "Fast"), (.instant, "Instant")])
            }
        }
    }

    private var centringDetail: String {
        switch strip.centring {
        case .never: "The strip scrolls just far enough to show the window."
        case .whenOverflowing: "Centred once the windows don't all fit on the screen."
        case .always: "The window you're in always sits in the middle."
        }
    }

    private var trackpad: some View {
        InkGroup("Trackpad and mouse") {
            LabeledRow("Swipe along the strip", detail: strip.swipeFingers == 0 ? "Off. Turn it on for a swipe that moves the strip with your fingers."
                       : "Sideways with \(strip.swipeFingers) fingers. If macOS uses the same swipe, change one of them (Mac Setup below).") {
                InkSegmented(selection: $strip.swipeFingers, options: [(0, "Off"), (3, "3 fingers"), (4, "4 fingers")])
            }
            if strip.swipeFingers > 0 {
                Hairline().opacity(0.6)
                LabeledRow("When you let go", detail: strip.swipeSnaps ? "The strip settles on the nearest window." : "The strip stays where it stops.") {
                    InkSegmented(selection: $strip.swipeSnaps, options: [(true, "Settle on a window"), (false, "Stay put")])
                }
            }
            Hairline().opacity(0.6)
            toggle("⌃⌥ and scroll", detail: "A scroll wheel moves one window per notch; a trackpad scroll follows your fingers.", isOn: $strip.modifierScroll)
            Hairline().opacity(0.6)
            toggle("Focus follows the pointer", detail: "The window under the pointer gets the keyboard, without clicking.", isOn: $strip.focusFollowsMouse)
            Hairline().opacity(0.6)
            toggle("Pointer follows focus", detail: "Moving with the keys brings the pointer to the window.", isOn: $strip.mouseFollowsFocus)
        }
    }

    @ViewBuilder
    private var displays: some View {
        if strip.displayList.count > 1 {
            InkGroup("Displays") {
                ForEach(Array(strip.displayList.enumerated()), id: \.element.uuid) { index, display in
                    LabeledRow(display.name, detail: "\(Int(display.frame.width)) × \(Int(display.frame.height)). Off leaves its windows exactly where you put them.") {
                        InkSwitch(isOn: Binding(get: { !strip.disabledDisplays.contains(display.uuid) },
                                                set: { strip.setDisplay(display.uuid, enabled: $0) }),
                                  label: "Strip on \(display.name)")
                    }
                    if index < strip.displayList.count - 1 { Hairline().opacity(0.6) }
                }
            }
        }
    }

    private var floatingApps: some View {
        InkGroup("Apps that float", trailing: AnyView(addAppMenu)) {
            if strip.floatingApps.isEmpty {
                Text("Every app's windows join the strip. Float an app with Add, or one window with ⌃⌥T.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.ink3)
                    .padding(.vertical, Metrics.rowPadding)
            }
            ForEach(Array(strip.floatingApps.enumerated()), id: \.element) { index, bundleID in
                LabeledRow(AppNames.appName(for: bundleID)) {
                    Button("Tile Again") { strip.tileApp(bundleID) }
                        .buttonStyle(OutlineButtonStyle(compact: true))
                }
                if index < strip.floatingApps.count - 1 { Hairline().opacity(0.6) }
            }
        }
    }

    private var setup: some View {
        InkGroup("Mac Setup", trailing: AnyView(Button("Check Again") { strip.refreshSetupChecks() }
            .buttonStyle(OutlineButtonStyle(compact: true)))) {
            ForEach(Array(strip.setupChecks.enumerated()), id: \.element.id) { index, check in
                HStack(alignment: .center, spacing: 12) {
                    StatusDot(on: check.isOK)
                    VStack(alignment: .leading, spacing: Metrics.titleToDetail) {
                        Text(check.title).font(.system(size: 13, weight: .medium))
                        Text(check.advice).font(.system(size: 11.5)).foregroundStyle(Color.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if check.isOK {
                        Text("Good").font(.system(size: 12)).foregroundStyle(Color.ink3)
                    } else if let url = URL(string: check.pane.rawValue) {
                        Button("Open") { NSWorkspace.shared.open(url) }
                            .buttonStyle(OutlineButtonStyle(compact: true))
                    }
                }
                .padding(.vertical, Metrics.rowPadding)
                if index < strip.setupChecks.count - 1 { Hairline().opacity(0.6) }
            }
        }
    }

    // MARK: Pieces

    private var addAppMenu: some View {
        Menu("Add") {
            ForEach(runningApps, id: \.bundleIdentifier) { app in
                Button(app.localizedName ?? app.bundleIdentifier ?? "App") {
                    if let id = app.bundleIdentifier { strip.floatApp(id) }
                }
            }
        }
        .menuStyle(.button)
        .buttonStyle(OutlineButtonStyle(compact: true))
        .fixedSize()
    }

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier
                && !strip.floatingApps.contains($0.bundleIdentifier!) }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func togglePreset(_ width: Double) {
        if let index = strip.presets.firstIndex(where: { abs($0 - width) < 0.001 }) {
            guard strip.presets.count > 2 else { return }
            strip.presets.remove(at: index)
        } else {
            strip.presets = (strip.presets + [width]).sorted()
        }
        if !strip.presets.contains(where: { abs($0 - strip.defaultWidth) < 0.001 }), strip.defaultWidth < 0.999 {
            strip.defaultWidth = strip.presets.min { abs($0 - 0.5) < abs($1 - 0.5) } ?? 0.5
        }
    }

    private func keyRow(_ title: String, _ commands: [StripCommand], trailing: String? = nil) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 12.5)).foregroundStyle(Color.ink2)
            Spacer()
            HStack(spacing: 6) {
                ForEach(commands, id: \.self) { command in
                    KeyCaps(shortcut: model.shortcuts.shortcut(for: .strip(command)), compact: true)
                }
                if let trailing {
                    Text(trailing).font(.geist(10.5, weight: .medium)).foregroundStyle(Color.ink3)
                }
            }
        }
        .frame(minHeight: 32)
    }

    private func toggle(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        LabeledRow(title, detail: detail) {
            InkSwitch(isOn: isOn, label: title)
        }
    }
}

/// A small on/off pill, for picking several values out of a row.
private struct ChipStyle: ButtonStyle {
    var on: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.geist(10.5, weight: .semibold))
            .foregroundStyle(on ? Color.paper : Color.ink2)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Capsule().fill(on ? Color.ink : Color.wash))
            .overlay(Capsule().strokeBorder(on ? Color.clear : Color.hairline))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(Motion.micro, value: on)
    }
}
