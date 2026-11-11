//
//  CornerControls.swift
//  Tutto
//
//  The Trackpad Corner controls: size presets worked out in millimetres for your
//  trackpad, custom width × height, corner side, and click/tap triggers.
//

import AppKit
import SwiftUI
import TuttoKit

/// Ready-made zone sizes, worked out in millimetres for the trackpad you actually have.
enum ZonePreset: String, CaseIterable, Identifiable {
    case small = "S"
    case medium = "M"
    case large = "L"

    var id: String { rawValue }

    var help: String {
        switch self {
        case .small: "Small: a compact corner"
        case .medium: "Medium: close to macOS's own bottom-corner secondary click, a little roomier"
        case .large: "Large: a generous corner for big hands and quick taps"
        }
    }

    /// Width × height of the zone in mm on a trackpad of `size`.
    func millimetres(on size: TrackpadSize) -> (width: Double, height: Double) {
        switch self {
        case .small: (size.width * 0.35, max(size.height * 0.25, 17))
        case .medium: (size.width * 0.45, max(size.height * 0.36, 24))
        case .large: (size.width * 0.55, max(size.height * 0.48, 32))
        }
    }

    func zone(corner: Corner, on size: TrackpadSize) -> CornerZone {
        let mm = millimetres(on: size)
        return CornerZone(corner: corner, width: mm.width / size.width, height: mm.height / size.height).clamped
    }

    static func matching(_ zone: CornerZone, on size: TrackpadSize) -> ZonePreset? {
        allCases.first { preset in
            let mm = preset.millimetres(on: size)
            let z = zone.clamped
            return abs(z.width * size.width - mm.width) < 1.5 && abs(z.height * size.height - mm.height) < 1.5
        }
    }
}

private enum SizeChoice: Hashable {
    case preset(ZonePreset)
    case custom
}

struct ZonePresetPicker: View {
    @Bindable var module: CornerModule

    var body: some View {
        let current: SizeChoice = module.zoneIsCustom
            ? .custom
            : (ZonePreset.matching(module.zone, on: module.trackpadSize).map(SizeChoice.preset) ?? .custom)
        InkSegmented(
            selection: Binding(
                get: { current },
                set: { choice in
                    switch choice {
                    case .preset(let preset):
                        module.zoneIsCustom = false
                        module.zone = preset.zone(corner: module.zone.corner, on: module.trackpadSize)
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                    case .custom:
                        module.zoneIsCustom = true
                    }
                }
            ),
            options: ZonePreset.allCases.map { (SizeChoice.preset($0), $0.rawValue) } + [(.custom, "Custom")],
            help: { choice in
                if case .preset(let preset) = choice { return preset.help }
                return "Set your own width and height"
            },
            spoken: { choice in
                if case .preset(let preset) = choice {
                    return ["S": "Small", "M": "Medium", "L": "Large"][preset.rawValue]
                }
                return "Custom"
            }
        )
    }
}

/// Width and height in millimetres, for people who want exactly their own corner.
struct CustomSizeRow: View {
    @Bindable var module: CornerModule

    var body: some View {
        let size = module.trackpadSize
        let zone = module.zone.clamped
        HStack(spacing: 6) {
            InkStepper(label: "Width",
                       value: Int((zone.width * size.width).rounded()),
                       range: Int((CornerZone.minimumSize * size.width).rounded(.up))...Int((CornerZone.maximumSize * size.width).rounded(.down))) { mm in
                module.zone = CornerZone(corner: zone.corner, width: Double(mm) / size.width, height: zone.height).clamped
            }
            Text("×")
                .font(.system(size: 11))
                .foregroundStyle(Color.ink3)
                .accessibilityHidden(true)
            InkStepper(label: "Height",
                       value: Int((zone.height * size.height).rounded()),
                       range: Int((CornerZone.minimumSize * size.height).rounded(.up))...Int((CornerZone.maximumSize * size.height).rounded(.down))) { mm in
                module.zone = CornerZone(corner: zone.corner, width: zone.width, height: Double(mm) / size.height).clamped
            }
            Caption("mm", uppercase: false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Custom size in millimetres")
    }
}

/// The full Trackpad Corner editor: live drawing, readout and controls. Used in the menu bar panel
/// (compact) and on the Trackpad Corner page.
struct CornerEditor: View {
    @Bindable var module: CornerModule
    var compact = false
    @State private var triggerNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let problem = module.problem {
                ProblemRow(problem: problem)
                    .padding(.bottom, 10)
            }
            if !compact {
                // The live drawing lives on the Trackpad Corner page; the menu bar keeps just the controls.
                TrackpadView(contacts: module.contacts,
                             zone: $module.zone,
                             size: module.trackpadSize,
                             pulse: module.pulse,
                             editable: module.isEnabled,
                             dimmed: !module.status.isRunning,
                             onResize: { if !module.zoneIsCustom { module.zoneIsCustom = true } })
            }
            if compact {
                // Menu bar: size, side and triggers in two rows.
                HStack(spacing: 8) {
                    readout
                    InkSegmented(selection: $module.zone.corner,
                                 options: [(Corner.bottomLeft, "Left"), (Corner.bottomRight, "Right")],
                                 help: { $0 == .bottomLeft ? "Bottom-left corner" : "Bottom-right corner" })
                        .disabled(!module.isEnabled)
                        .opacity(module.isEnabled ? 1 : 0.4)
                }
                HStack {
                    ZonePresetPicker(module: module)
                    Spacer(minLength: 6)
                    triggers
                }
                .padding(.top, 4)
                .disabled(!module.isEnabled)
                .opacity(module.isEnabled ? 1 : 0.4)
            } else {
                readout
                    .padding(.top, 6)
                VStack(spacing: 8) {
                    row("Size") { ZonePresetPicker(module: module) }
                    row("Corner") {
                        InkSegmented(selection: $module.zone.corner,
                                     options: [(Corner.bottomLeft, "Left"), (Corner.bottomRight, "Right")],
                                     help: { $0 == .bottomLeft ? "Bottom-left corner" : "Bottom-right corner" })
                    }
                    row("Trigger") { triggers }
                }
                .padding(.top, 6)
                .disabled(!module.isEnabled)
                .opacity(module.isEnabled ? 1 : 0.4)
            }
        }
        .background(VisibilityReader { visible in
            // Finger positions are only read while the drawing is on screen.
            guard !compact else { return }
            if visible { module.beginWatching() } else { module.endWatching() }
        })
    }

    private var triggers: some View {
        HStack(spacing: compact ? 10 : 14) {
            InkCheck(title: "Click", isOn: triggerBinding(\.clickEnabled, other: \.tapEnabled))
                .help("Press the corner until it clicks")
            InkCheck(title: "Tap", isOn: triggerBinding(\.tapEnabled, other: \.clickEnabled))
                .help("Tap the corner lightly (works with or without macOS Tap to click)")
        }
    }

    /// One fixed-height line under the drawing: the zone's size, or width and height steppers
    /// in Custom. It never changes height, so nothing re-lays out under your pointer.
    private var readout: some View {
        let zone = module.zone.clamped
        let size = module.trackpadSize
        return HStack(spacing: 10) {
            if module.zoneIsCustom {
                CustomSizeRow(module: module)
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))
            } else {
                Caption("\(Int((zone.width * size.width).rounded())) × \(Int((zone.height * size.height).rounded())) mm",
                        uppercase: false)
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))
            }
            Spacer(minLength: 0)
            if let note = triggerNote {
                Text(note)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.ink)
                    .transition(.opacity)
            }
        }
        .frame(height: 28)
        .monospacedDigit()
        .animation(Motion.snappy, value: triggerNote)
        .animation(.easeOut(duration: 0.15), value: module.zoneIsCustom)
    }

    /// Click and Tap can't both be off: that would leave Trackpad Corner on but doing nothing.
    private func triggerBinding(_ key: ReferenceWritableKeyPath<CornerModule, Bool>,
                                other: ReferenceWritableKeyPath<CornerModule, Bool>) -> Binding<Bool> {
        Binding(
            get: { module[keyPath: key] },
            set: { newValue in
                if !newValue && !module[keyPath: other] {
                    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                    triggerNote = "keep Click or Tap on"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { triggerNote = nil }
                    return
                }
                module[keyPath: key] = newValue
            }
        )
    }

    private func row(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack {
            Caption(title).accessibilityHidden(true)
            Spacer()
            content()
        }
        .frame(minHeight: compact ? 26 : 28)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

struct ProblemRow: View {
    var problem: CornerProblem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(problem.message)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if problem == .couldNotStart {
                Button("Reopen") { Relaunch.now() }
                    .buttonStyle(InkButtonStyle(compact: true))
            }
        }
        .padding(10)
        .background(Color.wash, in: RoundedRectangle(cornerRadius: Radius.of(8), style: .continuous))
    }
}

/// "One permission, then you're set." Shown wherever a feature waits on Accessibility.
struct AccessibilityCard: View {
    var purpose: String
    @State private var requested = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("One permission, then you're set.")
                .font(.system(size: 13, weight: .semibold))
            Text(requested
                 ? "In System Settings, switch on Tutto under Accessibility. It starts the moment you do."
                 : purpose)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                AppModel.shared.permissions.request(.accessibility)
                requested = true
            } label: {
                Text(requested ? "Open Accessibility Settings" : "Allow Accessibility Access").frame(maxWidth: .infinity)
            }
            .primaryButton()
            .padding(.top, 4)
        }
        .padding(14)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.of(12), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.of(12), style: .continuous).strokeBorder(Color.hairline))
    }
}

@MainActor
enum Relaunch {
    static func now() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

/// Reports whether the hosting window is actually on screen, so live views
/// (trackpad preview, readouts) only work while someone can see them.
struct VisibilityReader: NSViewRepresentable {
    var onChange: (Bool) -> Void

    func makeNSView(context: Context) -> VisibilityView {
        let view = VisibilityView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: VisibilityView, context: Context) {
        view.onChange = onChange
    }

    static func dismantleNSView(_ view: VisibilityView, coordinator: ()) {
        view.report(false)
    }

    final class VisibilityView: NSView {
        var onChange: ((Bool) -> Void)?
        private var isShowing = false
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            guard let window else {
                report(false)
                return
            }
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    let closing = note.name == NSWindow.willCloseNotification
                    MainActor.assumeIsolated {
                        if closing {
                            self?.report(false)
                        } else {
                            self?.evaluate()
                        }
                    }
                })
            }
            evaluate()
        }

        private func evaluate() {
            guard let window else { return report(false) }
            report(window.isVisible && window.occlusionState.contains(.visible))
        }

        func report(_ showing: Bool) {
            guard showing != isShowing else { return }
            isShowing = showing
            onChange?(showing)
        }
    }
}
