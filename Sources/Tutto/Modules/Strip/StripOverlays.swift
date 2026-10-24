//
//  StripOverlays.swift
//  Tutto (scrolling strip)
//
//  What the strip draws on screen, all in Tutto's own windows that never take focus:
//  - The strip indicator: a frosted bar of app icons, one tile per column, in order. The
//    focused tile is outlined, tiles out of view are faded. It shows while you move around,
//    stays while ⌃⌥ is held, then fades. Click a tile to go there, drag one to reorder.
//  - A tab bar over each tabbed column. Click a tab to show that window.
//  - An optional border around the focused window and optional dimming of the rest (a
//    single dark sheet ordered just below the focused window).
//

import AppKit
import SwiftUI
import TuttoKit

// MARK: - Indicator

@MainActor
@Observable
final class StripIndicatorState {
    struct Tile: Identifiable, Equatable {
        let id: Int
        let icons: [NSImage]
        /// One per window in the column (nil until it has been photographed).
        let pictures: [NSImage?]
        let activeTab: Int
        let focused: Bool
        /// 0…1 of the column on screen.
        let visible: Double
        let pin: StripSide?
        let tabbed: Bool
    }

    var tiles: [Tile] = []
    var message: String?
    var refused = false
    /// Window pictures instead of app icons.
    var previews = false
    /// Below 1 when there are more columns than fit across the screen.
    var scale: CGFloat = 1

    var tileSize: CGSize {
        previews ? CGSize(width: 200 * scale, height: 125 * scale) : CGSize(width: 56 * scale, height: 56 * scale)
    }
    var spacing: CGFloat { (previews ? 12 : 10) * max(scale, 0.6) }
}

@MainActor
final class StripIndicator {
    /// How long it stays: while ⌃⌥ are held (it goes the moment they're let go), or for a moment
    /// after something moved the strip without them (a swipe).
    enum Lifetime: Equatable {
        case whileHeld
        case briefly(TimeInterval)
    }

    let state = StripIndicatorState()
    var onSelect: ((Int) -> Void)?
    var onMove: ((Int, Int) -> Void)?
    /// Whether ⌃⌥ are held right now (the strip asks its key filter as well as macOS).
    var isHeld: () -> Bool = { StripIndicator.modifiersHeld() }

    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private var watchdog: Timer?
    private var shownOn: CGDirectDisplayID?
    private var shown = false

    static let padding: CGFloat = 14

    var isVisible: Bool { shown }

    func show(tiles: [StripIndicatorState.Tile], message: String?, refused: Bool, display: StripDisplay, lifetime: Lifetime) {
        let panel = layOut(tiles: tiles, message: message, refused: refused, display: display)
        panel.ignoresMouseEvents = false
        if !shown || shownOn != display.id {
            if !panel.isVisible { panel.alphaValue = 0 }
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.04 : 0.1
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
        shown = true
        shownOn = display.id
        hideWork?.cancel()
        switch lifetime {
        case .whileHeld:
            startWatchdog()
        case .briefly(let duration):
            watchdog?.invalidate()
            watchdog = nil
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.isHeld() else { return }
                    self.hide()
                }
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
        }
    }

    /// Builds the bar and draws it once, unseen, so the first ⌃⌥ is as quick as the rest
    /// (making the window and drawing its first frame is most of that first wait).
    func prepare(tiles: [StripIndicatorState.Tile], display: StripDisplay) {
        guard panel == nil, !tiles.isEmpty else { return }
        let panel = layOut(tiles: tiles, message: nil, refused: false, display: display)
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.shown else { return }
                panel.orderOut(nil)
            }
        }
    }

    private func layOut(tiles: [StripIndicatorState.Tile], message: String?, refused: Bool, display: StripDisplay) -> NSPanel {
        state.tiles = tiles
        state.message = message
        state.refused = refused
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let visible = StripDisplay.cocoa(display.visible)
        let size = fit(tiles.count, message: message, within: visible.width * 0.92)
        let frame = NSRect(x: (visible.midX - size.width / 2).rounded(), y: (visible.minY + 28).rounded(),
                           width: size.width, height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        return panel
    }

    /// Keeps the tiles current while it's on screen (pictures arriving, columns moving).
    func update(tiles: [StripIndicatorState.Tile]) {
        guard shown, tiles != state.tiles else { return }
        state.tiles = tiles
    }

    /// Gone, with a short fade.
    func hide() {
        hideWork?.cancel()
        hideWork = nil
        watchdog?.invalidate()
        watchdog = nil
        guard shown, let panel else { return }
        shown = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.04 : 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                if self?.shown == false { panel.orderOut(nil) }
            }
        })
    }

    func close() {
        hideWork?.cancel()
        watchdog?.invalidate()
        panel?.orderOut(nil)
        panel = nil
        shown = false
    }

    /// A safety net while the bar waits for ⌃⌥ to be let go: the key filter reports that at
    /// once, but macOS hides keys from filters in password fields, so check now and then too.
    private func startWatchdog() {
        guard watchdog == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.isHeld() { self.hide() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    static func modifiersHeld() -> Bool {
        let flags = NSEvent.modifierFlags
        return flags.contains(.control) && flags.contains(.option)
    }

    /// The panel's size for `count` tiles, shrinking the tiles when they don't fit `width`.
    private func fit(_ count: Int, message: String?, within width: CGFloat) -> NSSize {
        state.scale = 1
        let columns = CGFloat(max(count, 1))
        let natural = columns * state.tileSize.width + (columns - 1) * state.spacing
        let room = width - Self.padding * 2
        if natural > room { state.scale = max(room / natural, 0.45) }
        let tiles = columns * state.tileSize.width + (columns - 1) * state.spacing + Self.padding * 2
        var text: CGFloat = 0
        if let message {
            let font = NSFont(name: "Geist", size: 12) ?? .systemFont(ofSize: 12, weight: .medium)
            text = (message as NSString).size(withAttributes: [.font: font]).width.rounded(.up) + 36
        }
        let height = state.tileSize.height + Self.padding * 2 + (message != nil ? 26 : 0)
        return NSSize(width: min(max(tiles, text, 80), width), height: height)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let host = NSHostingView(rootView: StripIndicatorView(state: state, select: { [weak self] in self?.onSelect?($0) },
                                                              move: { [weak self] in self?.onMove?($0, $1) }))
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }
}

private struct StripIndicatorView: View {
    @Bindable var state: StripIndicatorState
    var select: (Int) -> Void
    var move: (Int, Int) -> Void
    @State private var dragging: Int?
    @State private var dragOffset: CGFloat = 0

    private var focusIndex: Int? { state.tiles.firstIndex(where: \.focused) }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: state.spacing) {
                ForEach(state.tiles) { tile in
                    tileView(tile)
                        .offset(x: dragging == tile.id ? dragOffset : 0)
                        .zIndex(dragging == tile.id ? 1 : 0)
                        .gesture(DragGesture(minimumDistance: 4)
                            .onChanged { value in
                                dragging = tile.id
                                dragOffset = value.translation.width
                            }
                            .onEnded { value in
                                let step = state.tileSize.width + state.spacing
                                let shift = Int((value.translation.width / step).rounded())
                                dragging = nil
                                dragOffset = 0
                                if shift != 0 { move(tile.id, tile.id + shift) }
                            })
                        .simultaneousGesture(TapGesture().onEnded { select(tile.id) })
                }
            }
            // One outline that slides to the focused column on a spring; the pictures themselves
            // never animate (a picture arriving just replaces the icon).
            .overlay(alignment: .leading) {
                if let focusIndex {
                    RoundedRectangle(cornerRadius: corner + 3, style: .continuous)
                        .strokeBorder(Color.ink, lineWidth: 2.5)
                        .frame(width: state.tileSize.width + 6, height: state.tileSize.height + 6)
                        .offset(x: CGFloat(focusIndex) * (state.tileSize.width + state.spacing) - 3)
                        .animation(Motion.snappy, value: focusIndex)
                        .allowsHitTesting(false)
                }
            }
            if let message = state.message {
                Text(message)
                    .font(.geist(12, weight: .medium))
                    .foregroundStyle(state.refused ? Color.ink3 : Color.ink2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(StripIndicator.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PaletteBackground())
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.hairline))
    }

    private var corner: CGFloat { state.previews ? 10 : 12 }

    private func tileView(_ tile: StripIndicatorState.Tile) -> some View {
        let size = state.tileSize
        return ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(tile.focused || state.previews ? Color.wash : Color.clear)
            if state.previews {
                pictures(tile, size: size)
            } else {
                icons(tile, size: size)
            }
            if let pin = tile.pin {
                Capsule()
                    .fill(Color.ink2)
                    .frame(width: 3, height: size.height * 0.36)
                    .frame(maxWidth: .infinity, alignment: pin == .left ? .leading : .trailing)
                    .padding(.horizontal, 3)
            }
        }
        .frame(width: size.width, height: size.height)
        // Out of view: dimmed with an opaque shade (see-through tiles let whatever is behind the
        // bar bleed into them), and a little greyer.
        .saturation(tile.visible > 0.02 ? 1 : 0.55)
        .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(Color.black.opacity(tile.visible > 0.02 ? 0 : 0.42)))
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .animation(.easeOut(duration: 0.15), value: tile.visible > 0.02)
        .contentShape(Rectangle())
        .accessibilityLabel(tile.focused ? "Focused column" : "Column \(tile.id + 1)")
    }

    @ViewBuilder
    private func icons(_ tile: StripIndicatorState.Tile, size: CGSize) -> some View {
        if tile.icons.count <= 1 {
            if let icon = tile.icons.first {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: size.width * 0.72, height: size.height * 0.72)
            }
        } else {
            // A stack: its windows' icons, one above the other (tabs side by side).
            let shown = Array(tile.icons.prefix(3))
            let side = size.width * (shown.count == 2 ? 0.44 : 0.32)
            if tile.tabbed {
                HStack(spacing: 2) {
                    ForEach(shown.indices, id: \.self) { Image(nsImage: shown[$0]).resizable().interpolation(.high).frame(width: side, height: side) }
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(shown.indices, id: \.self) { Image(nsImage: shown[$0]).resizable().interpolation(.high).frame(width: side, height: side) }
                }
            }
        }
    }

    /// The column's windows as pictures: one, a stack one above the other, or a tabbed
    /// column's front tab. The app's icon sits in the corner.
    @ViewBuilder
    private func pictures(_ tile: StripIndicatorState.Tile, size: CGSize) -> some View {
        let showing: [Int] = tile.tabbed ? [min(tile.activeTab, max(tile.pictures.count - 1, 0))] : Array(tile.pictures.indices.prefix(3))
        VStack(spacing: 2) {
            ForEach(showing, id: \.self) { index in
                ZStack {
                    if tile.pictures.indices.contains(index), let picture = tile.pictures[index] {
                        Image(nsImage: picture).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    } else if tile.icons.indices.contains(index) {
                        Image(nsImage: tile.icons[index]).resizable().interpolation(.high)
                            .frame(width: min(size.height * 0.4, 48), height: min(size.height * 0.4, 48))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(4)
        .overlay(alignment: .bottomLeading) {
            if let icon = tile.icons.first {
                Image(nsImage: icon).resizable().interpolation(.high)
                    .frame(width: 22 * max(state.scale, 0.7), height: 22 * max(state.scale, 0.7))
                    .padding(5)
            }
        }
        .overlay(alignment: .topTrailing) {
            if tile.tabbed {
                Text("\(tile.pictures.count) TABS")
                    .font(.geist(9, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(Color.ink)
                    .padding(.horizontal, 6)
                    .frame(height: 16)
                    .background(Capsule().fill(Color.paper.opacity(0.92)))
                    .padding(5)
            }
        }
    }
}

// MARK: - Tab bars

@MainActor
final class StripTabBars {
    struct Tab: Equatable, Identifiable {
        let id: CGWindowID
        let title: String
        let icon: NSImage?
    }

    struct Bar: Equatable {
        /// The strip and column it belongs to.
        let id: String
        /// Accessibility coordinates.
        let frame: CGRect
        let tabs: [Tab]
        let active: Int
    }

    var onSelect: ((CGWindowID) -> Void)?
    private var panels: [String: (panel: NSPanel, host: NSHostingView<StripTabBarView>, bar: Bar)] = [:]

    func update(_ bars: [Bar]) {
        let wanted = Set(bars.map(\.id))
        for (id, entry) in panels where !wanted.contains(id) {
            entry.panel.orderOut(nil)
            panels[id] = nil
        }
        for bar in bars {
            if var entry = panels[bar.id] {
                if entry.bar.tabs != bar.tabs || entry.bar.active != bar.active {
                    entry.host.rootView = StripTabBarView(bar: bar, select: { [weak self] in self?.onSelect?($0) })
                }
                if entry.bar.frame != bar.frame { entry.panel.setFrame(StripDisplay.cocoa(bar.frame), display: true) }
                entry.bar = bar
                panels[bar.id] = entry
            } else {
                let panel = NSPanel(contentRect: StripDisplay.cocoa(bar.frame), styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = false
                panel.level = .normal
                panel.hidesOnDeactivate = false
                panel.isReleasedWhenClosed = false
                panel.animationBehavior = .none
                panel.becomesKeyOnlyIfNeeded = true
                panel.collectionBehavior = [.managed, .ignoresCycle, .fullScreenNone]
                let host = NSHostingView(rootView: StripTabBarView(bar: bar, select: { [weak self] in self?.onSelect?($0) }))
                host.sizingOptions = []
                panel.contentView = host
                panel.orderFrontRegardless()
                panels[bar.id] = (panel, host, bar)
            }
        }
    }

    /// Moves the bars with their columns while the strip slides.
    func follow(_ frames: [String: CGRect]) {
        for (id, frame) in frames {
            guard let entry = panels[id], entry.panel.frame != StripDisplay.cocoa(frame) else { continue }
            entry.panel.setFrame(StripDisplay.cocoa(frame), display: false)
        }
    }

    func removeAll() {
        for entry in panels.values { entry.panel.orderOut(nil) }
        panels.removeAll()
    }
}

struct StripTabBarView: View {
    var bar: StripTabBars.Bar
    var select: (CGWindowID) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(bar.tabs.enumerated()), id: \.element.id) { index, tab in
                Button { select(tab.id) } label: {
                    HStack(spacing: 6) {
                        if let icon = tab.icon {
                            Image(nsImage: icon).resizable().interpolation(.high).frame(width: 14, height: 14)
                        }
                        Text(tab.title.isEmpty ? "Untitled" : tab.title)
                            .font(.system(size: 11.5, weight: index == bar.active ? .semibold : .regular))
                            .foregroundStyle(index == bar.active ? Color.ink : Color.ink3)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(index == bar.active ? Color.wash : Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(index == bar.active ? Color.hairline : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tab.title)
            }
        }
        .padding(3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PaletteBackground())
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.hairline))
    }
}

// MARK: - Focus border and dimming

@MainActor
final class StripDecor {
    private var border: NSPanel?
    private var dim: NSPanel?

    /// `frame` (Accessibility coordinates) of the focused window, `window` its id.
    func update(window: CGWindowID?, frame: CGRect?, display: StripDisplay?, showBorder: Bool, dimOthers: Bool) {
        if showBorder, let window, let frame {
            let panel = border ?? makeBorder()
            border = panel
            panel.setFrame(StripDisplay.cocoa(frame.insetBy(dx: -3, dy: -3)), display: true)
            panel.order(.above, relativeTo: Int(window))
        } else {
            border?.orderOut(nil)
        }
        if dimOthers, let window, let display {
            let panel = dim ?? makeDim()
            dim = panel
            let screen = StripDisplay.cocoa(display.frame)
            if panel.frame != screen { panel.setFrame(screen, display: true) }
            panel.order(.below, relativeTo: Int(window))
        } else {
            dim?.orderOut(nil)
        }
    }

    func removeAll() {
        border?.orderOut(nil)
        dim?.orderOut(nil)
        border = nil
        dim = nil
    }

    private func overlay() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .normal
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.managed, .ignoresCycle, .fullScreenNone]
        return panel
    }

    private func makeBorder() -> NSPanel {
        let panel = overlay()
        let view = NSView()
        view.wantsLayer = true
        view.layer?.borderWidth = 2.5
        view.layer?.cornerRadius = 14
        view.layer?.cornerCurve = .continuous
        view.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.85).cgColor
        panel.contentView = view
        return panel
    }

    private func makeDim() -> NSPanel {
        let panel = overlay()
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        panel.contentView = view
        return panel
    }
}
