//
//  SelectionOverlay.swift
//  Tutto
//
//  The capture overlay. The screen is frozen first (so menus and hover states stay put),
//  then drawn back full-screen exactly as it was: nothing is dimmed, ever. The pointer is a
//  plain crosshair with its position in pixels just below-right of it (the selection's W × H
//  while dragging). Drag to select (the selection is a very light box with a fine edge, the
//  rest stays as it is), click a window to take just that window (a thin outline shows which),
//  click the desktop for the whole screen, Tab copies the color under the pointer, Esc
//  cancels. Everything is Core Animation layers, so following the pointer costs almost
//  nothing. It appears with no animation: it was opened from the keyboard.
//

import AppKit
import Carbon.HIToolbox
import QuartzCore

struct Selection {
    let shot: DisplayShot
    /// In image pixels, top-left origin.
    let rect: CGRect
}

@MainActor
final class SelectionOverlay {
    private var windows: [OverlayWindow] = []
    private var completion: ((Selection?) -> Void)?
    private var previousApp: NSRunningApplication?
    private var appSwitchObserver: NSObjectProtocol?

    /// Shows the overlay on every captured display. `completion` gets the selection, or nil if cancelled.
    func begin(shots: [DisplayShot], completion: @escaping (Selection?) -> Void) {
        self.completion = completion
        previousApp = NSWorkspace.shared.frontmostApplication
        let windowFrames = Self.onScreenWindowFrames()
        for shot in shots {
            let window = OverlayWindow(shot: shot, windowFrames: windowFrames) { [weak self] result in
                self?.finish(result)
            }
            window.orderFrontRegardless()
            windows.append(window)
        }
        // No app activation. The overlay is a key-capable non-activating panel, so it gets Esc,
        // Tab, Space and ↩ while the app you were in stays active. Activating Tutto made that app
        // reset the pointer to an arrow as it lost focus, over the new crosshair. A background app
        // may set the pointer only with the window server's permission; the overlay then shows
        // the crosshair once the covered app has finished reacting (OverlayView.showCrosshair).
        let mouse = NSEvent.mouseLocation
        let key = windows.first { NSMouseInRect(mouse, $0.frame, false) } ?? windows.first
        key?.makeKey()
        BackgroundCursor.allow()
        for window in windows { (window.contentView as? OverlayView)?.showCrosshair() }
        // If another app takes focus (an app opening itself, a notification click), the keyboard
        // goes there; cancel rather than leave a frozen screen that no longer receives Esc.
        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            MainActor.assumeIsolated { self?.finish(nil) }
        }
    }

    private func finish(_ selection: Selection?) {
        guard let completion else { return }
        self.completion = nil
        if let appSwitchObserver { NSWorkspace.shared.notificationCenter.removeObserver(appSwitchObserver) }
        appSwitchObserver = nil
        for window in windows {
            window.orderOut(nil)
            window.contentView = nil
        }
        windows.removeAll()
        NSCursor.arrow.set()
        completion(selection)
    }

    /// Give focus back to the app the user was in (for captures that don't open the editor).
    func restoreFocus() {
        if let previousApp, previousApp.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp.activate()
        }
    }

    /// Frames of on-screen windows, front to back, in global top-left coordinates.
    private static func onScreenWindowFrames() -> [CGRect] {
        // Tutto's own windows count too (you can capture the main window); the overlay itself is
        // never at layer 0.
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.width > 40, rect.height > 40 else { return nil }
            return rect
        }
    }
}

// MARK: - Pointer

/// Lets Tutto set the pointer while another app is active (the window server ignores cursor
/// changes from background apps otherwise). Undocumented but long-standing: it's how overlays
/// that don't steal focus show their own pointer.
enum BackgroundCursor {
    @_silgen_name("CGSMainConnectionID") private static func mainConnection() -> Int32
    @_silgen_name("CGSSetConnectionProperty")
    private static func setConnectionProperty(_ cid: Int32, _ target: Int32, _ key: CFString, _ value: CFTypeRef) -> Int32

    private static var allowed = false

    static func allow() {
        guard !allowed else { return }
        let connection = mainConnection()
        allowed = setConnectionProperty(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue) == 0
    }
}

// MARK: - Window

private final class OverlayWindow: NSPanel {
    init(shot: DisplayShot, windowFrames: [CGRect], finish: @escaping (Selection?) -> Void) {
        super.init(contentRect: shot.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = true
        hasShadow = false
        backgroundColor = .black
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Window frames arrive in global top-left coordinates; make them local to this display.
        let displayBounds = CGDisplayBounds(shot.displayID)
        let local = windowFrames.map { $0.offsetBy(dx: -displayBounds.minX, dy: -displayBounds.minY) }
            .filter { $0.intersects(CGRect(origin: .zero, size: shot.frame.size)) }
        contentView = OverlayView(shot: shot, windowFrames: local, finish: finish)
        setFrame(shot.frame, display: false)
        // Tutto sets the crosshair itself (on show, every pointer event, and each frame for the
        // first second). AppKit's cursor rects would reset it to an arrow while the window is
        // still appearing, so they're off for this window.
        disableCursorRects()
    }

    override var canBecomeKey: Bool { true }
}

// MARK: - View

private final class OverlayView: NSView {
    private let shot: DisplayShot
    private let windowFrames: [CGRect]
    private let finish: (Selection?) -> Void

    private let imageLayer = CALayer()
    /// The selection: a very light box over what it covers (the screen around it stays as it is).
    private let selectionLayer = CAShapeLayer()
    /// Its edge, and the window outline before a drag: a fine white line on a faint dark one, so
    /// it shows on white pages and dark ones alike.
    private let edgeDark = CAShapeLayer()
    private let edgeLight = CAShapeLayer()
    private lazy var readout = PointerReadout(scale: shot.scale)

    private var start: CGPoint?
    private var current: CGPoint = .zero
    private var selection: CGRect?
    private var dragging = false
    private var spaceHeld = false
    private var hoveredWindow: CGRect?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(shot: DisplayShot, windowFrames: [CGRect], finish: @escaping (Selection?) -> Void) {
        self.shot = shot
        self.windowFrames = windowFrames
        self.finish = finish
        super.init(frame: CGRect(origin: .zero, size: shot.frame.size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = shot.image
        imageLayer.contentsGravity = .resize
        imageLayer.frame = bounds
        layer?.addSublayer(imageLayer)

        selectionLayer.fillColor = NSColor.white.withAlphaComponent(0.18).cgColor
        selectionLayer.frame = bounds
        layer?.addSublayer(selectionLayer)

        edgeDark.fillColor = nil
        edgeDark.strokeColor = NSColor.black.withAlphaComponent(0.35).cgColor
        edgeDark.lineWidth = 1
        edgeDark.frame = bounds
        layer?.addSublayer(edgeDark)

        edgeLight.fillColor = nil
        edgeLight.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        edgeLight.lineWidth = 1
        edgeLight.frame = bounds
        layer?.addSublayer(edgeLight)

        layer?.addSublayer(readout)
        CATransaction.commit()

        let tracking = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
                                      owner: self, userInfo: nil)
        addTrackingArea(tracking)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var cursorGuard: Timer?
    /// The crosshair is shown from this moment on (see `showCrosshair`).
    private var crosshairFrom = Date.distantFuture

    /// Called once the overlay is on screen. The app underneath reacts to the overlay covering it
    /// by setting its own pointer, once, within about 50 ms. Setting the crosshair before that
    /// made it flip back to an arrow; so wait 120 ms, then set it and hold it for a second
    /// (each frame), after which pointer events keep it. One clean change, no flip back.
    func showCrosshair() {
        cursorGuard?.invalidate()
        let start = Date()
        crosshairFrom = start.addingTimeInterval(0.12)
        cursorGuard = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.window != nil, Date().timeIntervalSince(start) < 1.12 else {
                    timer.invalidate()
                    return
                }
                self.setCrosshair()
            }
        }
    }

    private func setCrosshair() {
        // NSCursor.current only knows what Tutto last set, not another app's change: always set it.
        if Date() >= crosshairFrom { NSCursor.crosshair.set() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            cursorGuard?.invalidate()
            cursorGuard = nil
        }
        window?.makeFirstResponder(self)
        if let window {
            updatePointer(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
    }

    // The window's cursor rects are off (see OverlayWindow); the crosshair is set here on every
    // pointer event instead.
    override func cursorUpdate(with event: NSEvent) { setCrosshair() }

    // MARK: Mouse

    override func mouseMoved(with event: NSEvent) {
        setCrosshair()
        updatePointer(convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        setCrosshair()
        let point = convert(event.locationInWindow, from: nil)
        guard var origin = start else { return }
        if spaceHeld, let selection {
            // Space + drag moves the whole selection.
            let dx = point.x - current.x, dy = point.y - current.y
            origin.x += dx
            origin.y += dy
            start = origin
            self.selection = selection.offsetBy(dx: dx, dy: dy)
            current = point
            render()
            return
        }
        if !dragging, hypot(point.x - origin.x, point.y - origin.y) < 3 { return }
        dragging = true
        var end = point
        if event.modifierFlags.contains(.shift) {
            let side = max(abs(end.x - origin.x), abs(end.y - origin.y))
            end = CGPoint(x: origin.x + (end.x >= origin.x ? side : -side), y: origin.y + (end.y >= origin.y ? side : -side))
        }
        selection = CGRect(x: min(origin.x, end.x), y: min(origin.y, end.y),
                           width: abs(end.x - origin.x), height: abs(end.y - origin.y))
            .intersection(bounds)
        current = point
        hoveredWindow = nil
        updatePointer(point)
    }

    override func mouseUp(with event: NSEvent) {
        defer { start = nil }
        if dragging, let selection, selection.width >= 2, selection.height >= 2 {
            complete(selection)
        } else if !dragging {
            // A click: the window under the pointer, or the whole screen over the desktop.
            complete(hoveredWindow?.intersection(bounds) ?? bounds)
        }
    }

    override func rightMouseDown(with event: NSEvent) { finish(nil) }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape: finish(nil)
        case kVK_Tab: copyColor()
        case kVK_Space: spaceHeld = true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if let selection { complete(selection) }
        default: super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if Int(event.keyCode) == kVK_Space { spaceHeld = false }
    }

    private func copyColor() {
        guard let color = shot.image.color(atX: Int(current.x * shot.scale), y: Int(current.y * shot.scale)) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(color.hexString, forType: .string)
        Toast.shared.show("Color copied", detail: color.hexString, swatch: color)
    }

    private func complete(_ rect: CGRect) {
        let pixels = CGRect(x: rect.minX * shot.scale, y: rect.minY * shot.scale,
                            width: rect.width * shot.scale, height: rect.height * shot.scale)
            .integral
            .intersection(CGRect(x: 0, y: 0, width: shot.image.width, height: shot.image.height))
        guard !pixels.isEmpty else { return finish(nil) }
        finish(Selection(shot: shot, rect: pixels))
    }

    // MARK: Drawing

    private func updatePointer(_ point: CGPoint) {
        current = CGPoint(x: min(max(point.x, 0), bounds.width - 0.5), y: min(max(point.y, 0), bounds.height - 0.5))
        if !dragging && start == nil {
            hoveredWindow = windowFrames.first { $0.contains(current) }
        }
        render()
    }

    private func render() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The selection gets the light box and its edge; before a drag, the window a click would
        // take gets the edge alone. The screen itself is never tinted.
        selectionLayer.path = selection.map { CGPath(rect: $0, transform: nil) }
        let edge = selection ?? hoveredWindow
        edgeLight.path = edge.map { CGPath(rect: $0.insetBy(dx: -0.5, dy: -0.5), transform: nil) }
        edgeDark.path = edge.map { CGPath(rect: $0.insetBy(dx: -1.5, dy: -1.5), transform: nil) }

        if let selection, dragging {
            let w = Int((selection.width * shot.scale).rounded()), h = Int((selection.height * shot.scale).rounded())
            readout.show("\(w) × \(h)")
        } else {
            readout.show("\(Int(current.x * shot.scale))\n\(Int(current.y * shot.scale))")
        }
        // Just below-right of the crosshair; flipped to the other side near the screen's edges.
        let size = readout.bounds.size
        var origin = CGPoint(x: current.x + 12, y: current.y + 14)
        if origin.x + size.width > bounds.width - 4 { origin.x = current.x - 12 - size.width }
        if origin.y + size.height > bounds.height - 4 { origin.y = current.y - 14 - size.height }
        readout.frame.origin = origin
        CATransaction.commit()
    }
}

// MARK: - Pointer readout

/// Small white monospaced numbers with a solid dark outline, readable over white text and
/// dark UI alike. No box, no magnifier: the screen under the pointer stays visible.
private final class PointerReadout: CALayer {
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    private let outline = CATextLayer()
    private let fill = CATextLayer()
    private var text = ""

    init(scale: CGFloat) {
        super.init()
        for layer in [outline, fill] {
            layer.contentsScale = scale
            layer.alignmentMode = .left
            layer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
            addSublayer(layer)
        }
        // A soft halo beyond the outline for busy backgrounds.
        outline.shadowColor = NSColor.black.cgColor
        outline.shadowOpacity = 0.6
        outline.shadowRadius = 1.5
        outline.shadowOffset = .zero
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ text: String) {
        guard text != self.text else { return }
        self.text = text
        // The outline is a stroke drawn under the white fill. A stroke is centered on the glyph edge,
        // so it also eats into the digits' small openings: keep it thin (about 0.8 pt shows outside).
        outline.string = NSAttributedString(string: text, attributes: [
            .font: Self.font, .foregroundColor: NSColor.black,
            .strokeColor: NSColor.black, .strokeWidth: 14,
        ])
        fill.string = NSAttributedString(string: text, attributes: [.font: Self.font, .foregroundColor: NSColor.white])
        let measured = (text as NSString).boundingRect(with: CGSize(width: 400, height: 400), options: [.usesLineFragmentOrigin],
                                                       attributes: [.font: Self.font])
        let size = CGSize(width: ceil(measured.width) + 6, height: ceil(measured.height) + 4)
        bounds = CGRect(origin: .zero, size: size)
        // Inset by the outline's reach so it isn't clipped at the layer's edge.
        for layer in [outline, fill] { layer.frame = CGRect(x: 2, y: 1, width: size.width - 2, height: size.height - 1) }
    }
}
