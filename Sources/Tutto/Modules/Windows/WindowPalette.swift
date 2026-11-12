//
//  WindowPalette.swift
//  Tutto
//
//  ⌃⇧B: type what you want ("left half", "lh", "max"), press ↩. Each row carries a
//  tiny to-scale screen with the target region inked in, in the same drawing language
//  as the Trackpad Corner trackpad.
//

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI
import TuttoKit

/// A row in the window palette: a window action, or keeping the window on top.
enum WindowPaletteItem: Hashable {
    case action(WindowAction)
    case keepOnTop
}

@MainActor
@Observable
final class WindowPaletteModel {
    var query = "" { didSet { refresh() } }
    var selection = 0
    private(set) var results: [WindowPaletteItem] = []
    var appName: String?
    var hasWindow = true
    /// The window is already kept on top (the row then lets it go).
    var windowPinned = false
    let module: WindowModule

    init(module: WindowModule) {
        self.module = module
        refresh()
    }

    func refresh() {
        let actions = module.rankedActions(for: query)
        results = actions.map { .action($0) }
        let scores = actions.map { FuzzyMatcher.score(query, title: $0.title, aliases: $0.aliases) ?? 0 }
        if let index = PinRules.paletteIndex(query: query, rankedActionScores: scores) {
            results.insert(.keepOnTop, at: index)
        }
        selection = 0
    }

    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = min(max(selection + delta, 0), results.count - 1)
    }

    var selected: WindowPaletteItem? { results.indices.contains(selection) ? results[selection] : nil }

    private let openedAt = NSEvent.mouseLocation

    /// True once the pointer has moved since the palette opened.
    func pointerMoved() -> Bool {
        let now = NSEvent.mouseLocation
        return hypot(now.x - openedAt.x, now.y - openedAt.y) > 3
    }
}

@MainActor
final class WindowPaletteController: NSObject, NSWindowDelegate {
    private weak var module: WindowModule?
    private var panel: FloatingPanel?
    private var keyMonitor: Any?
    private var model: WindowPaletteModel?
    private var app: NSRunningApplication?
    private var window: AXUIElement?

    init(module: WindowModule) {
        self.module = module
    }

    func show(app: NSRunningApplication?, window: AXUIElement?) {
        guard let module else { return }
        if let panel, panel.isVisible {
            close()
            return
        }
        self.app = app
        self.window = window
        let model = WindowPaletteModel(module: module)
        model.appName = app?.localizedName
        model.hasWindow = window != nil
        model.windowPinned = window.map { module.pins.isPinned($0) } ?? false
        self.model = model

        let panel = FloatingPanel(size: NSSize(width: 560, height: 420))
        panel.delegate = self
        panel.onResignKey = { [weak self] in self?.close() }
        panel.contentView = NSHostingView(rootView: WindowPaletteView(model: model, perform: { [weak self] item in
            self?.perform(item)
        }))
        panel.positionOnActiveScreen()
        panel.makeKeyAndOrderFront(nil)
        panel.focusSearchField()
        self.panel = panel
        installKeys()
    }

    func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        guard let panel else { return }
        self.panel = nil
        panel.onResignKey = nil
        panel.orderOut(nil)
        panel.contentView = nil
        model = nil
        module?.paletteDidClose()
    }

    func windowWillClose(_ notification: Notification) { close() }

    private func perform(_ item: WindowPaletteItem?) {
        guard let item, let module else { return }
        let window = self.window
        let app = self.app
        close()
        guard let window else {
            if !AXIsProcessTrusted() { AppModel.shared.permissions.request(.accessibility) } else { NSSound.beep() }
            return
        }
        switch item {
        case .action(let action): module.perform(action, on: window, app: app)
        case .keepOnTop: module.pins.toggle(window: window, app: app)
        }
    }

    private func installKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let model = self.model, event.window === self.panel else { return event }
            switch Int(event.keyCode) {
            case kVK_DownArrow: model.move(1); return nil
            case kVK_UpArrow: model.move(-1); return nil
            case kVK_Return, kVK_ANSI_KeypadEnter: perform(model.selected); return nil
            case kVK_Escape: close(); return nil
            default: return event
            }
        }
    }
}

struct WindowPaletteView: View {
    @Bindable var model: WindowPaletteModel
    var perform: (WindowPaletteItem?) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.ink3)
                TextField("Move window… (left half, max, next display)", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($focused)
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            Hairline()
            if !AXIsProcessTrusted() {
                AccessibilityCard(purpose: "Moving another app's window needs Accessibility access. Tutto only changes window positions and sizes.")
                    .padding(14)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(model.results.enumerated()), id: \.element) { index, item in
                            Group {
                                switch item {
                                case .action(let action):
                                    WindowActionRow(action: action, selected: index == model.selection,
                                                    shortcut: AppModel.shared.shortcuts.shortcut(for: .window(action)))
                                case .keepOnTop:
                                    KeepOnTopRow(pinned: model.windowPinned, selected: index == model.selection,
                                                 shortcut: AppModel.shared.shortcuts.shortcut(for: .pinWindow))
                                }
                            }
                                .id(item)
                                .onTapGesture { perform(item) }
                                .onContinuousHover { phase in
                                    // Only a pointer that moved selects: one resting where the palette
                                    // opens must not override what you type.
                                    if case .active = phase, model.pointerMoved() { model.selection = index }
                                }
                        }
                        if model.results.isEmpty {
                            Text("No window action matches “\(model.query)”.")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.ink3)
                                .padding(16)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: model.selection) { _, index in
                    if model.results.indices.contains(index) { proxy.scrollTo(model.results[index]) }
                }
            }
            Hairline()
            HStack(spacing: 14) {
                Text(model.hasWindow ? "Moves \(model.appName ?? "the front window")" : "No window to move")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ink2)
                    .lineLimit(1)
                Spacer()
                Text("↩").font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundStyle(Color.ink3)
                Text("Esc").font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundStyle(Color.ink3)
            }
            .padding(.horizontal, 16)
            .frame(height: 32)
        }
        .background(PaletteBackground())
        .overlay(RoundedRectangle(cornerRadius: Radius.of(14), style: .continuous).strokeBorder(Color.hairline))
        .onAppear { focused = true }
    }
}

private struct WindowActionRow: View {
    var action: WindowAction
    var selected: Bool
    var shortcut: KeyShortcut?

    var body: some View {
        HStack(spacing: 12) {
            ScreenGlyph(region: action.unitRegion, action: action, inverted: selected)
                .frame(width: 22, height: 14)
            Text(action.title)
                .font(.system(size: 13))
                .foregroundStyle(selected ? Color.paper : Color.ink)
            Spacer()
            if let shortcut {
                Text(shortcut.displayString)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(selected ? Color.paper.opacity(0.75) : Color.ink3)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: Radius.of(7), style: .continuous).fill(selected ? Color.ink : .clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(action.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The palette's "Keep on Top" row: a pin where the others have a screen.
private struct KeepOnTopRow: View {
    var pinned: Bool
    var selected: Bool
    var shortcut: KeyShortcut?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: pinned ? "pin.slash" : "pin")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(selected ? Color.paper : Color.ink)
                .frame(width: 22, height: 14)
            Text(PinRules.paletteTitle(pinned: pinned))
                .font(.system(size: 13))
                .foregroundStyle(selected ? Color.paper : Color.ink)
            Spacer()
            if let shortcut {
                Text(shortcut.displayString)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(selected ? Color.paper.opacity(0.75) : Color.ink3)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: Radius.of(7), style: .continuous).fill(selected ? Color.ink : .clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PinRules.paletteTitle(pinned: pinned))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A tiny screen outline with the target region filled.
struct ScreenGlyph: View {
    var region: CGRect?
    var action: WindowAction
    var inverted = false

    var body: some View {
        Canvas { context, size in
            let ink = inverted ? Color.paper : Color.ink
            let outline = CGRect(origin: .zero, size: size).insetBy(dx: 0.75, dy: 0.75)
            context.stroke(Path(roundedRect: outline, cornerRadius: Radius.of(2.5)), with: .color(ink.opacity(0.6)), lineWidth: 1.2)
            if let region {
                let inner = outline.insetBy(dx: 2, dy: 2)
                let rect = CGRect(x: inner.minX + region.minX * inner.width, y: inner.minY + region.minY * inner.height,
                                  width: region.width * inner.width, height: region.height * inner.height)
                context.fill(Path(roundedRect: rect, cornerRadius: Radius.of(1)), with: .color(ink))
            } else {
                let symbol = action == .restore ? "arrow.uturn.backward" : (action == .nextDisplay ? "arrow.right" : "arrow.left")
                context.draw(Text(Image(systemName: symbol)).font(.system(size: 7, weight: .bold)).foregroundStyle(ink),
                             at: CGPoint(x: size.width / 2, y: size.height / 2))
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Page

struct WindowsPage: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Windows", subtitle: "Snap the front window to halves, thirds and quarters, center it, or move it to another display.",
                       module: .windows)
            if let windows = model.windows {
                WindowSettings(windows: windows, model: model)
            } else {
                ModuleOffView(module: .windows, model: model)
            }
        }
    }
}

private struct WindowSettings: View {
    @Bindable var windows: WindowModule
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if !model.permissions.accessibility {
                AccessibilityCard(purpose: "Moving another app's window needs Accessibility access. Tutto only changes window positions and sizes.")
            }
            InkGroup {
                LabeledRow("Window palette", detail: "Type an action like “left half”, press ↩.") {
                    ShortcutRecorder(action: .windowPalette, model: model)
                }
                Hairline().opacity(0.6)
                LabeledRow("Snap by dragging", detail: windows.dragSnap && windows.macOSTilesByDragging
                           ? "macOS's own tiling is on, so Tutto stays out of its way."
                           : "Drag a window to an edge or corner: halves, quarters, full screen, thirds along the bottom. Drag it away for its old size; Esc cancels.") {
                    InkSwitch(isOn: $windows.dragSnap, label: "Snap by dragging", active: !windows.macOSTilesByDragging)
                }
                if windows.dragSnap && windows.macOSTilesByDragging {
                    HStack(spacing: 10) {
                        Text("To use Tutto's (with thirds, gaps and sizes given back), switch off “Drag windows to screen edges to tile” in System Settings › Desktop & Dock.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button("Open Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension")!)
                        }
                        .buttonStyle(OutlineButtonStyle(compact: true))
                    }
                    .padding(.vertical, 6)
                }
                Hairline().opacity(0.6)
                LabeledRow("Gap between windows", detail: windows.gap == 0 ? "None, edge to edge." : "\(Int(windows.gap)) pt around and between windows.") {
                    InkSegmented(selection: $windows.gap, options: [(0, "0"), (4, "4"), (8, "8"), (12, "12")])
                }
            }
            KeepOnTopGroup(pins: windows.pins, model: model)
            InkGroup("Actions", trailing: AnyView(Caption("optional shortcuts"))) {
                ForEach(WindowAction.allCases) { action in
                    HStack(spacing: 12) {
                        ScreenGlyph(region: action.unitRegion, action: action).frame(width: 22, height: 14)
                        Text(action.title).font(.system(size: 12.5))
                        Spacer()
                        ShortcutRecorder(action: .window(action), model: model)
                    }
                    .frame(minHeight: 34)
                    .overlay(alignment: .bottom) { if action != WindowAction.allCases.last { Hairline().opacity(0.6) } }
                }
            }
        }
    }
}

/// Keep on top: its keys, and the windows on top now with a way to let each go.
private struct KeepOnTopGroup: View {
    var pins: WindowPins
    @Bindable var model: AppModel

    var body: some View {
        InkGroup("Keep on top") {
            LabeledRow("Keep the front window on top",
                       detail: "A live copy floats above other windows. Click it to use the window; the keys again stop it. Up to three.") {
                ShortcutRecorder(action: .pinWindow, model: model)
            }
            ForEach(pins.pinned) { pin in
                Hairline().opacity(0.6)
                HStack(spacing: 10) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.ink3)
                        .frame(width: 16)
                    Text(pin.label)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 12)
                    Button("Unpin") { pins.unpin(pin.id) }
                        .buttonStyle(OutlineButtonStyle(compact: true))
                }
                .frame(minHeight: 34)
            }
        }
    }
}
