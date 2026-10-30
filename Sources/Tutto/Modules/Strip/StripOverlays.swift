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

    /// Pictures or icons, at a scale.
    struct Layout: Equatable {
        var previews: Bool
        /// Below 1 when there are more columns than fit across the screen.
        var scale: CGFloat

        var tile: CGSize { previews ? CGSize(width: 200 * scale, height: 125 * scale) : CGSize(width: 56 * scale, height: 56 * scale) }
        var spacing: CGFloat { (previews ? 12 : 10) * max(scale, 0.6) }
        var corner: CGFloat { previews ? 10 : 12 }
        /// The app icon: in the corner of a picture, or the whole tile.
        var iconSide: CGFloat { previews ? 22 * max(scale, 0.7) : tile.width * 0.72 }
    }

    /// Trips round the strip's ends so far, and which way the last went (forward: → on the last
    /// window). The outline carries on that way, off one end of the bar and back in at the other.
    struct Turn: Equatable {
        var count = 0
        var forward = true
    }

    var tiles: [Tile] = []
    var message: String?
    var refused = false
    var layout = Layout(previews: false, scale: 1)
    var turn = Turn()

    /// Window pictures instead of app icons.
    var previews: Bool { layout.previews }
    var tileSize: CGSize { layout.tile }
    var spacing: CGFloat { layout.spacing }
    var corner: CGFloat { layout.corner }
    var iconSide: CGFloat { layout.iconSide }
    /// 1 with pictures, 0 with icons.
    var pictures: Double { layout.previews ? 1 : 0 }
}

@MainActor
final class StripIndicator {
    /// How long it stays: while ⌃⌥ are held (it goes the moment they're let go), or for a moment
    /// after something moved the strip without them (a swipe).
    enum Lifetime: Equatable {
        case whileHeld
        case briefly(TimeInterval)
    }

    /// One bar: a window and what it shows. There are two, so the bar can change between
    /// pictures and icons by fading one window into the other (no redrawing while the strip
    /// moves windows; a window fade is drawn by macOS, not by Tutto).
    @MainActor
    private final class Surface {
        let state = StripIndicatorState()
        var panel: NSPanel?
    }

    private let surfaces = [Surface(), Surface()]
    private var front = 0
    /// What the bar in front shows.
    var state: StripIndicatorState { surfaces[front].state }
    var onSelect: ((Int) -> Void)?
    var onMove: ((Int, Int) -> Void)?
    /// Whether ⌃⌥ are held right now (the strip asks its key filter as well as macOS).
    var isHeld: () -> Bool = { StripIndicator.modifiersHeld() }
    /// The bar went away (let go of ⌃⌥, or its moment was over).
    var onHidden: (() -> Void)?

    private var panel: NSPanel? { surfaces[front].panel }
    private var hideWork: DispatchWorkItem?
    /// Lets go of the tiles' pictures a minute after the bar was last up.
    private var releaseWork: DispatchWorkItem?
    private var watchdog: Timer?
    private var shownOn: CGDirectDisplayID?
    private var shown = false

    static let padding: CGFloat = 14
    private static let messageFont = NSFont(name: "Geist", size: 12) ?? .systemFont(ofSize: 12, weight: .medium)
    private var messageWidths: [String: CGFloat] = [:]
    private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    var isVisible: Bool { shown }

    /// Focus went round from one end of the strip to the other: the outline carries on the same
    /// way instead of sliding back across every tile.
    func wentRound(forward: Bool) {
        for surface in surfaces {
            surface.state.turn.count += 1
            surface.state.turn.forward = forward
        }
    }

    /// `previews`: window pictures, else app icons. Changing it while the bar is up fades the
    /// bar into the other one.
    func show(tiles: [StripIndicatorState.Tile], message: String?, refused: Bool, display: StripDisplay, previews: Bool, lifetime: Lifetime) {
        let timing = PerfLog.begin("bar show"); defer { timing.end() }
        releaseWork?.cancel()
        releaseWork = nil
        let onScreen = shown && shownOn == display.id && panel?.isVisible == true
        if onScreen, previews != state.previews, !Self.reduceMotion {
            crossfade(to: previews, tiles: tiles, message: message, refused: refused, display: display)
        } else {
            let panel = layOut(surfaces[front], tiles: tiles, message: message, refused: refused, display: display, previews: previews)
            panel.ignoresMouseEvents = false
            if !shown || shownOn != display.id {
                if !panel.isVisible { panel.alphaValue = 0 }
                panel.orderFrontRegardless()
                fade(panel, to: 1, duration: Self.reduceMotion ? 0.04 : 0.1, curve: .easeOut)
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

    /// The other bar takes the new layout (one redraw), comes in over this one and the two cross:
    /// window fades only, nothing redrawn while they run.
    private func crossfade(to previews: Bool, tiles: [StripIndicatorState.Tile], message: String?, refused: Bool, display: StripDisplay) {
        guard let old = panel else { return }
        front = 1 - front
        let new = layOut(surfaces[front], tiles: tiles, message: message, refused: refused, display: display, previews: previews)
        new.ignoresMouseEvents = false
        new.alphaValue = 0
        new.orderFrontRegardless()
        old.ignoresMouseEvents = true
        fade(new, to: 1, duration: 0.16, curve: .easeOut)
        fade(old, to: 0, duration: 0.16, curve: .easeIn) { [weak self] in
            guard let self, self.panel !== old else { return }
            old.orderOut(nil)
        }
    }

    /// Builds both bars and draws each once, unseen, so the first ⌃⌥ (and the first size key,
    /// which fades to the other bar) is as quick as the rest: making a window and drawing its
    /// first frame is most of that first wait.
    func prepare(tiles: [StripIndicatorState.Tile], display: StripDisplay, previews: Bool) {
        guard surfaces.allSatisfy({ $0.panel == nil }), !tiles.isEmpty else { return }
        for (surface, pictures) in [(surfaces[front], previews), (surfaces[1 - front], false)] {
            let panel = layOut(surface, tiles: tiles, message: nil, refused: false, display: display, previews: pictures)
            panel.alphaValue = 0
            panel.ignoresMouseEvents = true
            panel.orderFrontRegardless()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                for surface in self.surfaces where !(self.shown && surface === self.surfaces[self.front]) {
                    surface.panel?.orderOut(nil)
                }
            }
        }
    }

    @discardableResult
    private func layOut(_ surface: Surface, tiles: [StripIndicatorState.Tile], message: String?, refused: Bool, display: StripDisplay, previews: Bool) -> NSPanel {
        let state = surface.state
        state.tiles = tiles
        state.message = message
        state.refused = refused
        let panel = surface.panel ?? makePanel(showing: state)
        surface.panel = panel
        let target = destination(previews: previews, count: tiles.count, message: message, display: display)
        state.layout = target.layout
        if panel.frame != target.frame { panel.setFrame(target.frame, display: true) }
        return panel
    }

    private func fade(_ panel: NSPanel, to alpha: CGFloat, duration: TimeInterval, curve: CAMediaTimingFunctionName, then: (@MainActor () -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: curve)
            panel.animator().alphaValue = alpha
        }, completionHandler: {
            MainActor.assumeIsolated { then?() }
        })
    }

    /// Keeps the tiles current while it's on screen (pictures arriving, columns moving).
    func update(tiles: [StripIndicatorState.Tile]) {
        let timing = PerfLog.begin("bar update"); defer { timing.end() }
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
        onHidden?()
        fade(panel, to: 0, duration: Self.reduceMotion ? 0.04 : 0.12, curve: .easeIn) { [weak self] in
            guard let self, !self.shown else { return }
            panel.orderOut(nil)
            self.releaseSoon()
        }
    }

    /// A minute after the bar was last up, both bars let go of their tiles and redraw empty, so
    /// the pictures (and the copies their layers drew) go; the next ⌃⌥ brings fresh tiles. Used
    /// often, the bar keeps them and stays as quick as ever.
    private func releaseSoon() {
        releaseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.releasePictures() }
        }
        releaseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
    }

    /// Lets go of every tile now (a minute after the bar was last up, when the strip stops, or
    /// when macOS runs short of memory). Nothing changes while the bar is up.
    func releasePictures() {
        releaseWork?.cancel()
        releaseWork = nil
        guard !shown else { return }
        for surface in surfaces where !surface.state.tiles.isEmpty {
            surface.state.tiles = []
            surface.panel?.contentView?.layoutSubtreeIfNeeded()
            surface.panel?.displayIfNeeded()
        }
    }

    func close() {
        hideWork?.cancel()
        watchdog?.invalidate()
        for surface in surfaces {
            surface.panel?.orderOut(nil)
            surface.panel = nil
        }
        if shown { onHidden?() }
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

    /// The layout and panel frame for `count` tiles, along the bottom of the display, the tiles
    /// shrinking when they don't fit across it.
    private func destination(previews: Bool, count: Int, message: String?, display: StripDisplay) -> (layout: StripIndicatorState.Layout, frame: NSRect) {
        let visible = StripDisplay.cocoa(display.visible)
        let width = visible.width * 0.92
        let columns = CGFloat(max(count, 1))
        var layout = StripIndicatorState.Layout(previews: previews, scale: 1)
        let natural = columns * layout.tile.width + (columns - 1) * layout.spacing
        let room = width - Self.padding * 2
        if natural > room { layout.scale = max(room / natural, 0.45) }
        let tiles = columns * layout.tile.width + (columns - 1) * layout.spacing + Self.padding * 2
        var text: CGFloat = 0
        if let message {
            // Looking a font up by name and measuring text took a few ms on every key: once each.
            if messageWidths.count > 64 { messageWidths.removeAll() }
            let measured = messageWidths[message] ?? (message as NSString).size(withAttributes: [.font: Self.messageFont]).width.rounded(.up)
            messageWidths[message] = measured
            text = measured + 36
        }
        let size = NSSize(width: min(max(tiles, text, 80), width), height: layout.tile.height + Self.padding * 2 + (message != nil ? 26 : 0))
        let frame = NSRect(x: (visible.midX - size.width / 2).rounded(), y: (visible.minY + 28).rounded(), width: size.width, height: size.height)
        return (layout, frame)
    }

    private func makePanel(showing state: StripIndicatorState) -> NSPanel {
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
    /// The tile the outline is on (past an end while it goes round); nil: the focused tile.
    @State private var outline: CGFloat?
    @State private var outlineShows = true
    @State private var outlineMoves = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var focusIndex: Int? { state.tiles.firstIndex(where: \.focused) }

    private struct OutlineGoal: Equatable {
        var index: Int?
        var turn: StripIndicatorState.Turn
    }

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
                    RoundedRectangle(cornerRadius: state.corner + 3, style: .continuous)
                        .strokeBorder(Color.ink, lineWidth: 2.5)
                        .frame(width: state.tileSize.width + 6, height: state.tileSize.height + 6)
                        .offset(x: (outline ?? CGFloat(focusIndex)) * (state.tileSize.width + state.spacing) - 3)
                        .opacity(outlineShows ? 1 : 0)
                        .allowsHitTesting(false)
                }
            }
            .onChange(of: OutlineGoal(index: focusIndex, turn: state.turn)) { old, new in moveOutline(from: old, to: new) }
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

    /// The outline slides to the focused tile. When focus went round from one end of the strip to
    /// the other it carries on the same way, off the end of the bar, and comes back in at the
    /// other end, as the windows do.
    private func moveOutline(from old: OutlineGoal, to new: OutlineGoal) {
        guard let index = new.index else { return }
        outlineMoves += 1
        let move = outlineMoves
        guard new.turn != old.turn, let from = old.index, from != index else {
            withAnimation(reduceMotion ? nil : Motion.snappy) {
                outline = CGFloat(index)
                outlineShows = true
            }
            return
        }
        guard !reduceMotion else {
            outline = CGFloat(index)
            outlineShows = true
            return
        }
        let forward = new.turn.forward
        let count = CGFloat(state.tiles.count)
        withAnimation(.easeIn(duration: 0.09)) {
            outline = CGFloat(from) + (forward ? 1 : -1)
            outlineShows = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
            guard move == outlineMoves else { return }
            var jump = Transaction()
            jump.disablesAnimations = true
            withTransaction(jump) { outline = forward ? -1 : count }
            withAnimation(Motion.snappy) {
                outline = CGFloat(focusIndex ?? index)
                outlineShows = true
            }
        }
    }

    /// A tile, with pictures or with icons: the app's icon sits in the corner of the picture, or
    /// fills the tile.
    private func tileView(_ tile: StripIndicatorState.Tile) -> some View {
        let size = state.tileSize
        let corner = state.corner
        let pictures = state.pictures
        let single = tile.icons.count <= 1
        return ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Color.wash.opacity(tile.focused ? 1 : pictures))
            if pictures > 0 {
                self.pictures(tile, size: size)
                    .opacity(pictures)
            }
            if !single, pictures < 1 {
                stackIcons(tile, size: size)
                    .opacity(1 - pictures)
            }
            if let icon = tile.icons.first, single || pictures > 0 {
                leadIcon(icon, in: size, pictures: pictures)
                    .opacity(single ? 1 : pictures)
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

    /// The app's icon: the whole of an icon tile, or small in the corner of a picture.
    private func leadIcon(_ icon: NSImage, in size: CGSize, pictures: Double) -> some View {
        let side = state.iconSide
        let inset: CGFloat = 5
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let corner = CGPoint(x: inset + side / 2, y: size.height - inset - side / 2)
        return Image(nsImage: icon).resizable().interpolation(.high)
            .frame(width: side, height: side)
            .position(x: centre.x + (corner.x - centre.x) * pictures, y: centre.y + (corner.y - centre.y) * pictures)
    }

    /// A stack's windows' icons, one above the other (tabs side by side).
    @ViewBuilder
    private func stackIcons(_ tile: StripIndicatorState.Tile, size: CGSize) -> some View {
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

    /// The column's windows as pictures: one, a stack one above the other, or a tabbed
    /// column's front tab (the app's icon is drawn over it, in the corner).
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
