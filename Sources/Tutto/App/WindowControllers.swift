//
//  WindowControllers.swift
//  Tutto
//
//  The main window, the floating palette shell shared by Clipboard and Windows, and
//  the small toast used to confirm things (copied, saved). Windows are built when
//  shown and released when closed, so a closed window costs no memory.
//

import AppKit
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
            // Open on the Space you're in, even over a full-screen app (otherwise macOS may put
            // it on another Space where you'd never see it).
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
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

    /// Shows a window on the Space you're looking at and brings Tutto forward. Activating from a
    /// full-screen app can still make macOS switch to a desktop Space; the window then follows you
    /// there instead of staying behind on the Space you left.
    static func present(_ window: NSWindow) {
        window.orderFrontRegardless()
        bringForward()
        window.makeKeyAndOrderFront(nil)
        followSpaceSwitch(window)
    }

    private static var spaceObserver: NSObjectProtocol?

    private static func followSpaceSwitch(_ window: NSWindow) {
        stopFollowing()
        let center = NSWorkspace.shared.notificationCenter
        spaceObserver = center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak window] _ in
            MainActor.assumeIsolated {
                // `.moveToActiveSpace` windows move to the active Space when made key again.
                if let window, window.isVisible, !window.isOnActiveSpace { window.makeKeyAndOrderFront(nil) }
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
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 14
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
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
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

private struct ToastView: View {
    var content: Toast.Content
    var click: () -> Void
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: click) {
            HStack(spacing: 10) {
                if let swatch = content.swatch {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: swatch))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.hairline))
                        .frame(width: 28, height: 28)
                } else if let image = content.image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.hairline))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(content.title.uppercased())
                        .font(.mono(10.5, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(Color.ink)
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
            .padding(.vertical, 9)
            .padding(.leading, content.image != nil || content.swatch != nil ? 9 : 14)
            .padding(.trailing, 16)
            .frame(maxWidth: 420)
            .background(PaletteBackground())
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.hairline))
        }
        .buttonStyle(.plain)
        .offset(y: shown || reduceMotion ? 0 : 8)
        .onAppear { withAnimation(Motion.snappy) { shown = true } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}
