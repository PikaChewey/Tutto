//
//  PanelController.swift
//  Tutto
//
//  The menu bar icon and the panel under it, in a window of Tutto's own. macOS's menu bar
//  window (SwiftUI's MenuBarExtra) comes with a solid material drawn by the window server,
//  under every view, that no app setting removes; Liquid Glass needs a clear window, so the
//  panel draws its own frosted sheet of clear glass with the cards as glass on it (GlassLook.frost,
//  2026-11-13). The Classic look draws the system's popover material itself.
//
//  It behaves as the menu bar window did: a click on the icon opens and closes it; a click
//  anywhere else, Esc, or switching apps closes it. A click that turns into dragging files stays
//  open, so files can be dragged from Finder onto the Convert & Compress card; dragging files onto the icon
//  opens it, and dropping them on the icon compresses (or converts, resizes, crops) them. The
//  panel is built fresh each time it opens and dropped when it closes, so its readings run only
//  while it's on screen.
//

import AppKit
import SwiftUI
import TuttoKit

/// Whether files are being dragged while the panel is up, and which: the Convert & Compress card
/// turns into places to drop them, dimming the ones that don't suit them.
@MainActor
@Observable
final class PanelDrag {
    static let shared = PanelDrag()
    var files = false {
        didSet {
            guard files != oldValue else { return }
            urls = files ? Self.dragged() : []
        }
    }
    private(set) var urls: [URL] = []

    /// The files on the drag pasteboard now (read once, when a drag starts).
    private static func dragged() -> [URL] {
        (NSPasteboard(name: .drag).readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}

@MainActor
final class PanelController: NSObject {
    static let shared = PanelController()

    private var item: NSStatusItem?
    private var panel: TuttoPanelWindow?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    /// A press outside the panel: it closes on release, unless the press turns into dragging files.
    private var closeOnRelease = false
    private var dragCountAtPress = 0
    /// Files are being dragged while it's open: it stays until they're dropped (and the Convert &
    /// Compress card becomes places to drop them).
    private var draggingFiles = false {
        didSet { if PanelDrag.shared.files != draggingFiles { PanelDrag.shared.files = draggingFiles } }
    }
    private let iconDrop = StatusIconDrop()

    var isOpen: Bool { panel?.isVisible == true }
    /// The icon's button (the panel opens under it; the notch check looks at its window).
    var button: NSStatusBarButton? { item?.button }

    /// Puts the icon in the menu bar (where macOS kept Tutto's before: the same saved name).
    func install(model: AppModel) {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "Item-0"
        // macOS 26 keeps a shown/hidden flag per saved name ("VisibleCC"); the icon is Tutto's way in,
        // so it starts shown (hiding it is Control Center's choice, made there).
        item.isVisible = true
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.setAccessibilityLabel("Tutto")
            let label = StatusLabelHost(rootView: StatusLabel(model: model))
            label.onResize = { [weak item, weak label] in
                guard let item, let label else { return }
                item.length = max(NSStatusItem.squareLength, ceil(label.fittingSize.width) + 8)
            }
            label.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            ])
            label.onResize?()
            // Files dragged onto the icon: the window's delegate hears it (the icon's views don't take drags).
            button.window?.registerForDraggedTypes([.fileURL])
            button.window?.delegate = iconDrop
        }
        self.item = item
    }

    /// Files dragged onto the icon open the panel (its Convert & Compress card becomes places to drop them).
    func openForDrag() {
        guard !isOpen else { return }
        open()
        draggingFiles = true
    }

    @objc private func clicked(_ sender: Any?) {
        // Out of the click's own call (an Accessibility press runs it inside a callout, where laying
        // out the glass overflowed the stack): a moment later on the main queue.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.toggle() }
        }
    }

    func toggle() { isOpen ? close() : open() }

    func open() {
        guard !isOpen, let button = item?.button, let buttonWindow = button.window else { return }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width: CGFloat = 320
        // Under the icon, its middle over the icon's middle, kept 8 pt inside the screen; the top
        // stays put as the panel grows or shrinks (Levels opening, a row growing).
        let x = min(max(buttonFrame.midX - width / 2, visible.minX + 8), visible.maxX - width - 8).rounded()
        let top = min(buttonFrame.minY - 6, visible.maxY - 2)
        let panel = TuttoPanelWindow(contentRect: NSRect(x: x, y: top - 500, width: width, height: 500),
                                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Glass draws its own depth; the classic sheet takes the window's shadow.
        panel.hasShadow = !ThemeStore.liquid
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.anchorTop = top
        panel.alphaValue = 0
        // The window is on screen (clear) before the glass is laid out in it, as on the glass stage.
        panel.orderFrontRegardless()
        let host = PanelHost(rootView: AnyView(MenuPanel(model: AppModel.shared).modifier(PanelChrome())))
        host.sizingOptions = [.intrinsicContentSize]
        host.onResize = { [weak panel, weak host] in
            guard let panel, let host else { return }
            let size = host.fittingSize
            guard size.height > 0 else { return }
            panel.setFrame(NSRect(x: panel.frame.minX, y: 0, width: width, height: size.height), display: true)
        }
        panel.contentView = host
        self.panel = panel
        PanelWindow.current = panel
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                host.onResize?()
                panel.makeKey()
                // Opening is instant in feel (it's opened many times a day): a 0.1 s fade, nothing more.
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.1
                    panel.animator().alphaValue = 1
                }
            }
        }
        button.highlight(true)
        watchForDismissal(button: button)
    }

    func close() {
        guard let panel else { return }
        self.panel = nil
        closeOnRelease = false
        draggingFiles = false
        stopWatching()
        item?.button?.highlight(false)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.08
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                // Dropping the SwiftUI tree ends the readings it started.
                panel.contentView = nil
            }
        })
    }

    // MARK: Closing it

    private func watchForDismissal(button: NSStatusBarButton) {
        // A click in another app: right and middle presses close it at once; a left press closes it on
        // release, unless it became a drag of files (from Finder to the Convert & Compress card).
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged, .leftMouseUp],
                                                          handler: { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated { self?.outside(type) }
        }) { monitors.append(global) }
        // A click in another of Tutto's windows (not the panel, its menus, or the icon, which
        // toggles by itself); Esc.
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return event }
                if event.type == .keyDown {
                    if event.keyCode == 53, panel.isKeyWindow {
                        self.close()
                        return nil
                    }
                    return event
                }
                guard let window = event.window else { return event }
                if window === panel || window === button.window || window.level.rawValue >= NSWindow.Level.popUpMenu.rawValue + 1
                    || window.className.contains("Menu") {
                    return event
                }
                self.close()
                return event
            }
        }) { monitors.append(local) }
        // Switching apps (⌘Tab) or Spaces.
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            MainActor.assumeIsolated {
                // A press that activated the app it's in: the press decides (a drag keeps it open).
                guard let self, !self.draggingFiles, NSEvent.pressedMouseButtons & 1 == 0 else { return }
                self.close()
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        })
    }

    private func outside(_ type: NSEvent.EventType) {
        guard let panel else { return }
        switch type {
        case .leftMouseDown:
            if draggingFiles { return }
            closeOnRelease = true
            dragCountAtPress = NSPasteboard(name: .drag).changeCount
        case .leftMouseDragged:
            let pasteboard = NSPasteboard(name: .drag)
            if closeOnRelease, pasteboard.changeCount != dragCountAtPress,
               pasteboard.types?.contains(.fileURL) == true {
                closeOnRelease = false
                draggingFiles = true
            }
        case .leftMouseUp:
            if closeOnRelease {
                close()
            } else if draggingFiles {
                draggingFiles = false
                // Dropped somewhere else: done with the panel. On the panel: it stays, to show the work.
                if !panel.frame.contains(NSEvent.mouseLocation) { close() }
            }
        default:
            close()
        }
    }

    private func stopWatching() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.removeAll()
    }
}

/// The panel's window: borderless and clear, takes the keyboard (the Stay awake field) without
/// making Tutto the active app, and keeps its top edge where it opened as its height changes.
final class TuttoPanelWindow: NSPanel {
    var anchorTop: CGFloat?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var frame = frameRect
        if let anchorTop { frame.origin.y = anchorTop - frame.height }
        super.setFrame(frame, display: flag)
    }
}

/// Classic look: the panel draws the system's popover material and a hairline itself (the menu
/// bar window used to bring them). Liquid Glass: nothing, the cards are the glass.
private struct PanelChrome: ViewModifier {
    func body(content: Content) -> some View {
        if ThemeStore.liquid {
            content
        } else {
            let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
            content
                .background(PanelMaterial())
                .clipShape(shape)
                .overlay(shape.strokeBorder(Color.hairline))
        }
    }
}

private struct PanelMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// The panel's SwiftUI, telling the window when its height changes.
private final class PanelHost: NSHostingView<AnyView> {
    var onResize: (() -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onResize?() }
        }
    }
}

/// The label inside the icon's button: lets clicks through to the button and tells the item
/// when its width changes (the time left while staying awake, the recording's clock).
private final class StatusLabelHost: NSHostingView<StatusLabel> {
    var onResize: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onResize?() }
        }
    }
}

/// The menu bar icon; while Stay Awake runs, the time left beside it; while the auto clicker
/// clicks, its symbol, so a running clicker is never forgotten.
struct StatusLabel: View {
    var model: AppModel

    var body: some View {
        let awake = model.awake?.menuBarText
        let agents = model.awake?.isAgentSession == true
        let clicking = model.clicker?.isOn == true
        let recording = model.screenshots?.recorder.recordingSince
        Group {
            if awake != nil || clicking || agents || recording != nil {
                HStack(spacing: 3) {
                    Image(nsImage: MenuBarGlyph.image())
                    if let recording {
                        // The time, a tick a second, only while recording.
                        TimelineView(.periodic(from: recording, by: 1)) { context in
                            HStack(spacing: 3) {
                                Image(systemName: "record.circle")
                                Text(RecordingRules.elapsed(context.date.timeIntervalSince(recording))).monospacedDigit()
                            }
                        }
                    }
                    if agents { Image(systemName: "cup.and.heat.waves") }
                    if clicking { Image(systemName: "cursorarrow.click.2") }
                    if let awake { Text(awake).monospacedDigit() }
                }
            } else {
                Image(nsImage: MenuBarGlyph.image())
            }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.primary)
        .fixedSize()
        .accessibilityHidden(true)
    }
}

/// Files dragged onto the menu bar icon: the panel opens (to drop on one of its Convert & Compress
/// actions); dropped on the icon itself, they get the action used last.
@MainActor
private final class StatusIconDrop: NSObject, NSWindowDelegate, NSDraggingDestination {
    private var converter: ConverterModule? { AppModel.shared.converter }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard converter != nil, !files(sender).isEmpty else { return [] }
        PanelController.shared.openForDrag()
        return .copy
    }

    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        converter != nil ? .copy : []
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let converter else { return false }
        let files = files(sender)
        guard !files.isEmpty else { return false }
        converter.panelDrop(files)
        return true
    }

    private func files(_ sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}
