//
//  SelectionOverlay.swift
//  Tutto
//
//  The capture overlay. The screen is frozen first (so menus and hover states stay put),
//  then drawn back full-screen with a crosshair, a loupe with the exact pixel and its hex,
//  and a live W × H in pixels. Drag to select, click a window to take just that window,
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
        AppActivation.bringForward()
        let mouse = NSEvent.mouseLocation
        let key = windows.first { NSMouseInRect(mouse, $0.frame, false) } ?? windows.first
        key?.makeKey()
        NSCursor.crosshair.set()
    }

    private func finish(_ selection: Selection?) {
        guard let completion else { return }
        self.completion = nil
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
        let own = getpid()
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? Int32) != own,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.width > 40, rect.height > 40 else { return nil }
            return rect
        }
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
    }

    override var canBecomeKey: Bool { true }
}

// MARK: - View

private final class OverlayView: NSView {
    private let shot: DisplayShot
    private let windowFrames: [CGRect]
    private let finish: (Selection?) -> Void

    private let imageLayer = CALayer()
    private let dimLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    private let crossH = CALayer()
    private let crossV = CALayer()
    private let loupe = LoupeLayer()
    private let sizeLabel = PillLabel()

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

        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.4).cgColor
        dimLayer.frame = bounds
        layer?.addSublayer(dimLayer)

        borderLayer.fillColor = nil
        borderLayer.strokeColor = NSColor.white.withAlphaComponent(0.95).cgColor
        borderLayer.lineWidth = 1
        borderLayer.frame = bounds
        layer?.addSublayer(borderLayer)

        for line in [crossH, crossV] {
            line.backgroundColor = NSColor.white.withAlphaComponent(0.7).cgColor
            line.shadowColor = NSColor.black.cgColor
            line.shadowOpacity = 0.5
            line.shadowRadius = 0
            line.shadowOffset = CGSize(width: 1, height: 1)
            layer?.addSublayer(line)
        }
        loupe.configure(scale: shot.scale)
        layer?.addSublayer(loupe)
        addSubview(sizeLabel)
        sizeLabel.isHidden = true
        CATransaction.commit()

        let tracking = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
                                      owner: self, userInfo: nil)
        addTrackingArea(tracking)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        if let window {
            updatePointer(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    // MARK: Mouse

    override func mouseMoved(with event: NSEvent) {
        updatePointer(convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
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
        let highlight = selection ?? hoveredWindow
        let path = CGMutablePath()
        path.addRect(bounds)
        if let highlight { path.addRect(highlight) }
        dimLayer.path = path
        dimLayer.fillColor = NSColor.black.withAlphaComponent(highlight == nil ? 0.18 : 0.4).cgColor
        borderLayer.path = highlight.map { CGPath(rect: $0.insetBy(dx: -0.5, dy: -0.5), transform: nil) }
        borderLayer.lineDashPattern = selection == nil && highlight != nil ? [4, 3] : nil

        let showCross = !dragging
        crossH.isHidden = !showCross
        crossV.isHidden = !showCross
        let line = 1 / max(shot.scale, 1)
        crossH.frame = CGRect(x: 0, y: current.y.rounded(.down), width: bounds.width, height: line)
        crossV.frame = CGRect(x: current.x.rounded(.down), y: 0, width: line, height: bounds.height)

        let pixel = CGPoint(x: Int(current.x * shot.scale), y: Int(current.y * shot.scale))
        loupe.update(image: shot.image, pixel: pixel, color: shot.image.color(atX: Int(pixel.x), y: Int(pixel.y)))
        var loupeOrigin = CGPoint(x: current.x + 22, y: current.y + 22)
        if loupeOrigin.x + loupe.bounds.width > bounds.width - 8 { loupeOrigin.x = current.x - 22 - loupe.bounds.width }
        if loupeOrigin.y + loupe.bounds.height > bounds.height - 8 { loupeOrigin.y = current.y - 22 - loupe.bounds.height }
        loupe.frame.origin = loupeOrigin
        loupe.isHidden = dragging && (selection?.width ?? 0) > 160
        CATransaction.commit()

        if let selection, dragging || selection.width > 0 {
            let w = Int((selection.width * shot.scale).rounded()), h = Int((selection.height * shot.scale).rounded())
            sizeLabel.text = "\(w) × \(h)"
            sizeLabel.isHidden = false
            let size = sizeLabel.fittingSize
            var origin = CGPoint(x: selection.maxX - size.width, y: selection.maxY + 8)
            if origin.y + size.height > bounds.height - 4 { origin.y = selection.maxY - size.height - 8 }
            origin.x = max(4, origin.x)
            sizeLabel.frame = CGRect(origin: origin, size: size)
        } else {
            sizeLabel.isHidden = true
        }
    }
}

// MARK: - Loupe

/// Magnified pixels around the pointer with a pixel grid, the center pixel outlined, and its hex.
private final class LoupeLayer: CALayer {
    private let pixels = CALayer()
    private let grid = CAShapeLayer()
    private let center = CAShapeLayer()
    private let label = CATextLayer()
    private let span = 13          // pixels across
    private let cell: CGFloat = 9  // points per magnified pixel

    func configure(scale: CGFloat) {
        let side = CGFloat(span) * cell
        bounds = CGRect(x: 0, y: 0, width: side, height: side + 24)
        anchorPoint = .zero
        backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        cornerRadius = 10
        cornerCurve = .continuous
        masksToBounds = true
        borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        borderWidth = 1

        pixels.frame = CGRect(x: 0, y: 0, width: side, height: side)
        pixels.magnificationFilter = .nearest
        pixels.contentsGravity = .resize
        addSublayer(pixels)

        let path = CGMutablePath()
        for i in 1..<span {
            let v = CGFloat(i) * cell
            path.move(to: CGPoint(x: v, y: 0)); path.addLine(to: CGPoint(x: v, y: side))
            path.move(to: CGPoint(x: 0, y: v)); path.addLine(to: CGPoint(x: side, y: v))
        }
        grid.path = path
        grid.strokeColor = NSColor.black.withAlphaComponent(0.18).cgColor
        grid.lineWidth = 0.5
        grid.frame = pixels.frame
        addSublayer(grid)

        let mid = CGFloat(span / 2) * cell
        center.path = CGPath(rect: CGRect(x: mid, y: mid, width: cell, height: cell), transform: nil)
        center.fillColor = nil
        center.strokeColor = NSColor.white.cgColor
        center.lineWidth = 1.5
        center.shadowColor = NSColor.black.cgColor
        center.shadowOpacity = 0.8
        center.shadowRadius = 0.5
        center.shadowOffset = .zero
        center.frame = pixels.frame
        addSublayer(center)

        label.frame = CGRect(x: 8, y: side + 5, width: side - 16, height: 16)
        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        label.fontSize = 11
        label.foregroundColor = NSColor.white.cgColor
        label.contentsScale = scale
        label.alignmentMode = .center
        addSublayer(label)
    }

    func update(image: CGImage, pixel: CGPoint, color: NSColor?) {
        let half = span / 2
        let rect = CGRect(x: Int(pixel.x) - half, y: Int(pixel.y) - half, width: span, height: span)
        pixels.contents = image.cropping(to: rect.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)))
        label.string = "\(color?.hexString ?? "—")   \(Int(pixel.x)), \(Int(pixel.y))"
    }
}

// MARK: - Size pill

private final class PillLabel: NSView {
    private let field = NSTextField(labelWithString: "")

    var text: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        field.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        field.textColor = .white
        addSubview(field)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var fittingSize: NSSize {
        let size = field.fittingSize
        return NSSize(width: size.width + 16, height: size.height + 8)
    }

    override func layout() {
        super.layout()
        let size = field.fittingSize
        field.frame = CGRect(x: 8, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }
}
