//
//  WindowControllers.swift
//  Tutto
//
//  The main window, the floating palette shell shared by Clipboard and Windows, and
//  the small toast used to confirm things (copied, saved). Windows are built when
//  shown and released when closed, so a closed window costs no memory.
//

import AppKit
import os
import SwiftUI

// MARK: - Main window

@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    static let shared = MainWindowController()

    private var window: NSWindow?
    let navigation = MainNavigation()

    func show(page: MainPage? = nil) {
        if let page { navigation.page = page }
        if window == nil {
            let hosting = NSHostingController(rootView: MainView(model: AppModel.shared, navigation: navigation))
            hosting.sizingOptions = []
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.toolbarStyle = .unified
            window.title = "Tutto"
            window.setContentSize(NSSize(width: 920, height: 640))
            window.contentMinSize = NSSize(width: 780, height: 520)
            window.isReleasedWhenClosed = false
            window.collectionBehavior = AppActivation.windowBehavior
            window.setFrameAutosaveName("TuttoMain")
            window.delegate = self
            if !window.setFrameUsingName("TuttoMain") { window.center() }
            self.window = window
        }
        // A regular app while the window is open: Dock icon, ⌘-Tab, menu bar menus.
        NSApp.setActivationPolicy(.regular)
        if let window { AppActivation.present(window) }
    }

    var isVisible: Bool { window?.isVisible ?? false }
    /// The main window while it's open, e.g. to attach a sheet to.
    var openWindow: NSWindow? { window?.isVisible == true ? window : nil }

    func windowWillClose(_ notification: Notification) {
        window = nil  // drop the views so nothing keeps sampling
        DispatchQueue.main.async {
            MainActor.assumeIsolated { AppActivation.update() }
        }
    }
}

@MainActor
@Observable
final class MainNavigation {
    var page: MainPage = .overview
}

/// Tutto is a menu bar app (no Dock icon) except while one of its full windows is open.
@MainActor
enum AppActivation {
    /// Brings Tutto to the front for a window the user asked for (a shortcut, a prompt).
    /// macOS 14+'s cooperative `activate()` is declined when no click preceded it, which would
    /// leave keystrokes going to the previous app, so ask firmly.
    static func bringForward() {
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The main and welcome windows may open over a full-screen app (`.fullScreenAuxiliary`); without
    /// it, opening one from a full-screen app left it on no Space at all. They don't follow every
    /// Space change (`.moveToActiveSpace` made them jump away on ⌘-Tab); instead `present` and the
    /// activation hook below move a window to the Space you're looking at when it needs to.
    static let windowBehavior: NSWindow.CollectionBehavior = [.fullScreenAuxiliary]

    /// The screenshot editor opens right over a full-screen app, where the capture started.
    static let editorBehavior: NSWindow.CollectionBehavior = [.fullScreenAuxiliary]

    /// Whenever Tutto becomes active (⌘-Tab, Dock, a shortcut) and macOS switches Spaces on the way,
    /// bring Tutto's front window to the Space you land on.
    static func followSpaceSwitchesOnActivation() {
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let front = NSApp.orderedWindows.first { $0.isVisible && $0.styleMask.contains(.titled) }
                if let front { followSpaceSwitch(front) }
            }
        }
    }

    /// Shows a window on the Space you're looking at and brings Tutto forward. Activating from a
    /// full-screen app can still make macOS switch to a desktop Space; the window then follows you
    /// there instead of staying behind on the Space you left.
    static func present(_ window: NSWindow) {
        spaceLog.debug("present \(window.title, privacy: .public): active=\(NSApp.isActive) onActive=\(window.isOnActiveSpace) visible=\(window.isVisible)")
        window.orderFrontRegardless()
        spaceLog.debug("  ordered: onActive=\(window.isOnActiveSpace) visible=\(window.isVisible) number=\(window.windowNumber)")
        bringForward()
        window.makeKeyAndOrderFront(nil)
        spaceLog.debug("  key: active=\(NSApp.isActive) onActive=\(window.isOnActiveSpace) key=\(window.isKeyWindow)")
        // A window that already exists keeps its Space, and macOS may put a new one on a desktop
        // while you're in a full-screen Space (the welcome tour opened from the main window landed
        // where you couldn't see it). Bring it to the Space you're looking at.
        if !window.isOnActiveSpace { moveToActiveSpace(window) }
        followSpaceSwitch(window)
    }

    /// Asks macOS to put a window on the Space you're looking at, for this one ordering.
    private static func moveToActiveSpace(_ window: NSWindow) {
        let had = window.collectionBehavior.contains(.moveToActiveSpace)
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.makeKeyAndOrderFront(nil)
        if !had { window.collectionBehavior.remove(.moveToActiveSpace) }
        spaceLog.debug("  moved: onActive=\(window.isOnActiveSpace)")
    }

    private static var spaceObserver: NSObjectProtocol?
    private static let spaceLog = Logger(subsystem: "ca.bryanyao.Tutto", category: "spaces")

    private static func followSpaceSwitch(_ window: NSWindow) {
        stopFollowing()
        let center = NSWorkspace.shared.notificationCenter
        spaceObserver = center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak window] _ in
            MainActor.assumeIsolated {
                if let window, window.isVisible, !window.isOnActiveSpace { moveToActiveSpace(window) }
                stopFollowing()
            }
        }
        // Only the switch caused by this activation counts; later ones are the user's.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MainActor.assumeIsolated { stopFollowing() }
        }
    }

    private static func stopFollowing() {
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        spaceObserver = nil
    }

    static func update() {
        let hasRegularWindow = NSApp.windows.contains { window in
            window.isVisible && window.styleMask.contains(.titled) && !(window is NSPanel) && window.level == .normal
                && window.className != "NSStatusBarWindow"
        }
        NSApp.setActivationPolicy(hasRegularWindow ? .regular : .accessory)
    }
}

// MARK: - Floating palette

/// A Spotlight-style panel: takes keyboard focus without activating Tutto, so the app
/// you came from stays frontmost and receives the paste or the window move.
final class FloatingPanel: NSPanel {
    var onResignKey: (() -> Void)?

    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
                   backing: .buffered, defer: true)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        isFloatingPanel = true
        level = .modalPanel
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        animationBehavior = .none  // opened from the keyboard: appear instantly
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    /// Puts the text cursor in the panel's search field. SwiftUI's focus state alone doesn't
    /// reliably reach a non-activating panel, so find the field and focus it directly.
    func focusSearchField() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let content = self.contentView else { return }
            if let field = Self.firstEditableField(in: content) {
                self.makeFirstResponder(field)
            }
        }
    }

    private static func firstEditableField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for subview in view.subviews {
            if let field = firstEditableField(in: subview) { return field }
        }
        return nil
    }

    /// Centers horizontally in the upper third of the screen with the pointer.
    func positionOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = frame.size
        let origin = NSPoint(x: visible.midX - size.width / 2,
                             y: visible.maxY - visible.height * 0.22 - size.height)
        setFrameOrigin(NSPoint(x: origin.x.rounded(), y: max(origin.y, visible.minY + 20).rounded()))
    }
}

/// Glass background for palettes: the system material is the only glass.
struct PaletteBackground: NSViewRepresentable {
    var radius: CGFloat = 14

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = radius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

// MARK: - Toast

/// A small confirmation that appears near the bottom of the active screen and fades away.
/// Never takes focus. Clicking it runs `onClick` (e.g. open the editor).
@MainActor
final class Toast {
    static let shared = Toast()

    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    struct Content {
        var title: String
        var detail: String?
        var image: NSImage?
        var swatch: NSColor?
        var onClick: (() -> Void)?
    }

    func show(_ title: String, detail: String? = nil, image: NSImage? = nil, swatch: NSColor? = nil,
              duration: TimeInterval = 1.6, onClick: (() -> Void)? = nil) {
        let content = Content(title: title, detail: detail, image: image, swatch: swatch, onClick: onClick)
        hideWork?.cancel()
        panel?.orderOut(nil)

        let hosting = NSHostingView(rootView: ToastView(content: content) { [weak self] in
            onClick?()
            self?.dismiss()
        })
        let size = Self.size(for: content, hosting: hosting)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = onClick == nil
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = hosting
        panel.isReleasedWhenClosed = false

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: (visible.midX - size.width / 2).rounded(), y: visible.minY + 72))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.1 : 0.18
            panel.animator().alphaValue = 1
        }
        self.panel = panel

        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// The toast's size. A detail too long for one line is drawn on two, but the fitting size
    /// measures one: at the toast's widest, it's measured again at that width for the real height.
    static func size(for content: Content, hosting: NSView? = nil) -> CGSize {
        let view = hosting ?? NSHostingView(rootView: ToastView(content: content) {})
        view.layoutSubtreeIfNeeded()
        var size = view.fittingSize
        if size.width >= ToastView.widest - 1 {
            let measured = NSHostingController(rootView: ToastView(content: content) {})
                .sizeThatFits(in: CGSize(width: size.width, height: 1_000))
            size.height = max(size.height, measured.height.rounded(.up))
        }
        return size
    }

    func dismiss() {
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }
}

/// A pill of Liquid Glass (Bryan picked design A, 2026-11-21): the picture, the title in sentence
/// case at the panel's title weight, the detail beneath. The text sits inside the glass so it turns
/// dark when the glass turns light over a bright window. Before macOS 26 (or with glass off) it
/// falls back to the frosted popover material in the same shape.
struct ToastView: View {
    static let widest: CGFloat = 420
    var content: Toast.Content
    var click: () -> Void
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hasArt: Bool { content.image != nil || content.swatch != nil }
    /// Round enough to read as a capsule at one line of detail, still tidy when the detail wraps.
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 27, style: .continuous) }
    private var liquid: Bool {
        if #available(macOS 26, *) { return ThemeStore.shared.tokens.liquid }
        return false
    }

    var body: some View {
        Button(action: click) {
            HStack(spacing: 12) {
                if let swatch = content.swatch {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: swatch))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.hairline))
                        .frame(width: 32, height: 32)
                } else if let image = content.image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.hairline))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(content.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                    if let detail = content.detail {
                        Text(detail)
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(Color.ink2)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, content.detail == nil ? 15 : 11)
            .padding(.leading, hasArt ? 11 : 22)
            .padding(.trailing, 24)
            .frame(minHeight: 54)
            .frame(maxWidth: Self.widest)
            .background { if !liquid { PaletteBackground(radius: 27) } }
            .prototypeGlass(shape)
            .overlay(liquid ? AnyView(GlassRim(shape: shape, strength: 0.7)) : AnyView(shape.strokeBorder(Color.hairline)))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .scaleEffect(shown || reduceMotion ? 1 : 0.96, anchor: .bottom)
        .offset(y: shown || reduceMotion ? 0 : 8)
        .onAppear { withAnimation(Motion.snappy) { shown = true } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}
