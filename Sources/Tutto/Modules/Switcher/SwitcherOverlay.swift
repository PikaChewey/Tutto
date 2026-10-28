//
//  SwitcherOverlay.swift
//  Tutto
//
//  The switcher on screen: one strip of window cards that slides to keep the selection in
//  view, a small row of app icons underneath when there are more windows than fit, and the
//  keys along the bottom. It floats over everything (full-screen apps included) without
//  taking focus from the app you're in, so letting go of ⌘ lands exactly where you were
//  headed.
//

import AppKit
import SwiftUI

struct SwitcherActions {
    var select: (Int) -> Void
    var commit: (Int) -> Void
    var saveRename: () -> Void
    var cancelRename: () -> Void
    var searchCommit: () -> Void
    var searchCancel: () -> Void
    var searchStep: (Int) -> Void
    var clickedOutside: () -> Void
}

// MARK: - Panel

@MainActor
final class SwitcherOverlay {
    private let session: SwitcherSession
    private let actions: SwitcherActions
    private let panel: SwitcherPanel
    private var clickMonitor: Any?
    private var cardClickMonitor: Any?
    private var pointerTimer: Timer?

    enum Metrics {
        static let card = CGSize(width: 208, height: 130)
        static let spacing: CGFloat = 14
        static let sidePadding: CGFloat = 22
        static let cardBlock: CGFloat = 130 + 10 + 34
    }

    init(session: SwitcherSession, actions: SwitcherActions) {
        self.session = session
        self.actions = actions
        panel = SwitcherPanel()
        let host = NSHostingView(rootView: SwitcherView(session: session, actions: actions))
        host.sizingOptions = []
        panel.contentView = host
    }

    func show(near screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main else { return }
        layout(on: screen)
        // Lay out and draw this opening's cards before the panel is on screen, so its first
        // frame is already the final one (a reused panel would otherwise show last time's).
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        if !panel.isVisible { panel.orderFrontRegardless() }
        if clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.actions.clickedOutside() }
            }
        }
        // Clicks and the pointer are handled here rather than by the cards: Tutto isn't the active
        // app while the switcher is up, and SwiftUI's hover tracking can go quiet then.
        if cardClickMonitor == nil {
            cardClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, event.window === self.panel, let index = self.card(at: NSEvent.mouseLocation) else { return event }
                    self.actions.commit(index)
                    return nil
                }
            }
        }
        if pointerTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.followPointer() }
            }
            RunLoop.main.add(timer, forMode: .common)
            pointerTimer = timer
        }
    }

    /// The card under the pointer becomes the selection, but only once the pointer has moved:
    /// one resting where the switcher opened, or a card sliding under a still pointer, picks nothing.
    private func followPointer() {
        let point = NSEvent.mouseLocation
        guard panel.frame.contains(point), session.pointer.moved(to: point),
              let index = card(at: point), index != session.selection else { return }
        actions.select(index)
    }

    /// The card at a screen point (AppKit coordinates).
    private func card(at point: NSPoint) -> Int? {
        let inWindow = CGPoint(x: point.x - panel.frame.minX, y: panel.frame.maxY - point.y)
        return session.cardFrames.first { $0.value.contains(inWindow) }?.key
    }

    /// Sizes the panel for the cards it shows, centred on `screen`.
    func layout(on screen: NSScreen) {
        let visible = screen.visibleFrame
        let perCard = Metrics.card.width + Metrics.spacing
        let maxCards = max(Int((visible.width * 0.92 - Metrics.sidePadding * 2 + Metrics.spacing) / perCard), 1)
        let count = max(min(session.visible.count, maxCards), min(session.all.count, 3))
        let width = CGFloat(count) * perCard - Metrics.spacing + Metrics.sidePadding * 2
        var height: CGFloat = 18 + Metrics.cardBlock + 14
        if session.all.count > maxCards { height += 22 }
        if session.showHints { height += 24 }
        height += 40  // search / rename row space, kept so the panel doesn't jump
        let frame = NSRect(x: (visible.midX - width / 2).rounded(), y: (visible.midY - height / 2 + visible.height * 0.06).rounded(),
                           width: width, height: height)
        panel.setFrame(frame, display: true)
    }

    /// Redraws the hidden panel once its cards are gone, so the pictures its layers drew go too.
    func flush() {
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
    }

    func hide() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        if let cardClickMonitor { NSEvent.removeMonitor(cardClickMonitor) }
        cardClickMonitor = nil
        pointerTimer?.invalidate()
        pointerTimer = nil
        panel.orderOut(nil)
    }

    func close() {
        hide()
        panel.close()
    }

    /// Gives the panel the keyboard for the search or rename field.
    func focusText() {
        panel.makeKey()
        DispatchQueue.main.async { [weak self] in
            guard let self, let content = self.panel.contentView else { return }
            if let field = Self.firstEditableField(in: content) { self.panel.makeFirstResponder(field) }
        }
    }

    func endTextFocus() {
        panel.makeFirstResponder(nil)
    }

    private static func firstEditableField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for subview in view.subviews {
            if let field = firstEditableField(in: subview) { return field }
        }
        return nil
    }
}

/// Borderless, non-activating, above full-screen apps, on every Space.
final class SwitcherPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 600, height: 260),
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        // After isFloatingPanel, which would otherwise reset it to the floating level.
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Views

struct SwitcherView: View {
    @Bindable var session: SwitcherSession
    var actions: SwitcherActions
    @FocusState private var fieldFocused: Bool

    private var overflow: Bool {
        let perCard = SwitcherOverlay.Metrics.card.width + SwitcherOverlay.Metrics.spacing
        let screen = NSScreen.main?.visibleFrame.width ?? 1440
        return CGFloat(session.visible.count) * perCard > screen * 0.92
    }

    var body: some View {
        VStack(spacing: 0) {
            topRow
                .frame(height: 40)
            // New cards for every opening: nothing animates from the last opening's order.
            strip
                .id(session.generation)
            if overflow {
                indicator
                    .frame(height: 22)
                    .id(session.generation)
            }
            if session.showHints {
                hints
                    .frame(height: 24)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(PaletteBackground())
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: Search / rename / title row

    @ViewBuilder
    private var topRow: some View {
        if let id = session.renaming, let item = session.all.first(where: { $0.id == id }) {
            HStack(spacing: 8) {
                Caption("Rename")
                TextField(item.title.isEmpty ? item.appName : item.title, text: $session.renameText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .focused($fieldFocused)
                    .onSubmit { actions.saveRename() }
                    .onExitCommand { actions.cancelRename() }
                Text("↩ save · esc cancel · empty resets")
                    .font(.geist(10))
                    .foregroundStyle(Color.ink3)
            }
            .padding(.horizontal, SwitcherOverlay.Metrics.sidePadding)
            .onAppear { fieldFocused = true }
        } else if session.query != nil {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.ink3)
                TextField("Search windows", text: Binding(get: { session.query ?? "" }, set: {
                    session.query = $0
                    session.refilter()
                }))
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .medium))
                .focused($fieldFocused)
                .onSubmit { actions.searchCommit() }
                .onExitCommand { actions.searchCancel() }
                .onKeyPress(.downArrow) { actions.searchStep(1); return .handled }
                .onKeyPress(.upArrow) { actions.searchStep(-1); return .handled }
                .onKeyPress(.tab) { actions.searchStep(1); return .handled }
                Text("\(session.visible.count) of \(session.all.count)")
                    .font(.geist(10))
                    .foregroundStyle(Color.ink3)
            }
            .padding(.horizontal, SwitcherOverlay.Metrics.sidePadding)
            .onAppear { fieldFocused = true }
        } else {
            HStack(spacing: 6) {
                if let app = session.appFilter, let name = session.all.first(where: { $0.bundleID == app })?.appName {
                    Caption("\(name) windows")
                } else {
                    Caption("Windows")
                }
                Text("\(session.visible.count)")
                    .font(.geist(10, weight: .semibold))
                    .foregroundStyle(Color.ink3)
                Spacer()
                if let item = session.selected, item.place != nil || item.isMinimized || item.isHidden {
                    Text([item.place, item.isMinimized ? "Minimized" : nil, item.isHidden ? "Hidden" : nil].compactMap { $0 }.joined(separator: " · "))
                        .font(.geist(10))
                        .foregroundStyle(Color.ink3)
                }
            }
            .padding(.horizontal, SwitcherOverlay.Metrics.sidePadding)
        }
    }

    // MARK: Strip

    private var strip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: SwitcherOverlay.Metrics.spacing) {
                    ForEach(Array(session.visible.enumerated()), id: \.element.id) { index, item in
                        SwitcherCard(item: item, number: index < 9 ? index + 1 : nil, selected: index == session.selection,
                                     thumbnail: item.windowID.flatMap { session.thumbnails[$0] }, showPreviews: session.showPreviews,
                                     closing: session.closing.contains(item.id))
                            .id(item.id)
                            // Where each card is, for the overlay's own pointer and click handling.
                            .background(GeometryReader { proxy in
                                Color.clear.preference(key: CardFramesKey.self, value: [index: proxy.frame(in: .global)])
                            })
                            .accessibilityAction { actions.commit(index) }
                    }
                }
                .padding(.horizontal, SwitcherOverlay.Metrics.sidePadding)
                .padding(.vertical, 4)
                .onPreferenceChange(CardFramesKey.self) { frames in session.cardFrames = frames }
            }
            .frame(height: SwitcherOverlay.Metrics.cardBlock + 8)
            .mask(edgeFade)
            // Scroll just far enough to bring the selection into view, on a spring.
            .onChange(of: session.selection) { _, selection in
                guard session.visible.indices.contains(selection) else { return }
                withAnimation(Motion.smooth) { proxy.scrollTo(session.visible[selection].id) }
            }
            .onAppear {
                if session.visible.indices.contains(session.selection) {
                    proxy.scrollTo(session.visible[session.selection].id)
                }
            }
        }
    }

    /// Soft edges when the strip runs past the panel, so cut-off cards read as "more this way".
    private var edgeFade: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: overflow ? 28 : 0)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: overflow ? 28 : 0)
        }
    }

    // MARK: Indicator (more windows than fit)

    private var indicator: some View {
        HStack(spacing: 4) {
            ForEach(Array(session.visible.prefix(48).enumerated()), id: \.element.id) { index, item in
                Image(nsImage: item.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 13, height: 13)
                    .opacity(index == session.selection ? 1 : 0.45)
                    .overlay(alignment: .bottom) {
                        if index == session.selection {
                            Capsule().fill(Color.ink).frame(width: 9, height: 2).offset(y: 4)
                        }
                    }
            }
        }
        .animation(Motion.micro, value: session.selection)
        .accessibilityHidden(true)
    }

    // MARK: Hints

    private var hints: some View {
        Text(session.query != nil || session.renaming != nil
             ? "↑ ↓ MOVE · ↩ SWITCH · ESC BACK"
             : "1–9 JUMP · W CLOSE · M MINIMIZE · Q QUIT · F FILL · R RENAME · / SEARCH · ` SAME APP · ESC")
            .font(.geist(10, weight: .medium))
            .tracking(0.8)
            .foregroundStyle(Color.ink3)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, SwitcherOverlay.Metrics.sidePadding)
    }
}

/// Each card's frame in the panel (top-left origin), keyed by its position.
private struct CardFramesKey: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// One window: its picture (or the app's icon), number, title and app.
struct SwitcherCard: View {
    var item: SwitcherItem
    var number: Int?
    var selected: Bool
    var thumbnail: NSImage?
    var showPreviews: Bool
    var closing: Bool

    private var size: CGSize { SwitcherOverlay.Metrics.card }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            picture
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.hairline, lineWidth: 1))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(Color.ink, lineWidth: 2)
                        .padding(-3)
                        .opacity(selected ? 1 : 0)
                )
                .overlay(alignment: .topLeading) { badges }
            HStack(spacing: 7) {
                Image(nsImage: item.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.displayTitle)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(item.subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.ink3)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(width: size.width, height: 24, alignment: .leading)
        }
        .scaleEffect(selected ? 1.0 : 0.97)
        .opacity(closing ? 0.35 : 1)
        .animation(Motion.micro, value: selected)
        .contentShape(Rectangle())
        .help(item.rawTitle.isEmpty ? item.appName : item.rawTitle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.displayTitle), \(item.appName)")
        .accessibilityValue([item.isMinimized ? "Minimized" : nil, item.isHidden ? "Hidden" : nil, item.place].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var picture: some View {
        ZStack {
            Color.wash
            if showPreviews, let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .saturation(item.isMinimized || item.isHidden ? 0.2 : 1)
                    .opacity(item.isMinimized || item.isHidden ? 0.55 : 1)
            } else {
                Image(nsImage: item.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 56, height: 56)
                    .opacity(item.isMinimized || item.isHidden ? 0.5 : 1)
            }
        }
    }

    private var badges: some View {
        HStack(spacing: 4) {
            if let number {
                Text("\(number)")
                    .font(.geist(10, weight: .semibold))
                    .foregroundStyle(selected ? Color.paper : Color.ink)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(selected ? Color.ink : Color.paper.opacity(0.92)))
            }
            if let chip = item.isMinimized ? "Minimized" : (item.isHidden ? "Hidden" : item.place) {
                Text(chip.uppercased())
                    .font(.geist(9, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Color.ink)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(Capsule().fill(Color.paper.opacity(0.92)))
            }
        }
        .padding(6)
    }
}
