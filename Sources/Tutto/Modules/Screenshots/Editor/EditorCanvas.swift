//
//  EditorCanvas.swift
//  Tutto
//
//  The picture and everything drawn on it. The pixels sit in a Core Animation layer
//  (composited by the GPU); drawings, the selection box and its handles are drawn
//  above. With no tool, dragging makes a selection with a live pixel size; drag it to
//  move it, drag its handles to resize it, ↩ crops to it.
//

import AppKit
import Carbon.HIToolbox
import Observation
import QuartzCore

final class EditorCanvas: NSView {
    let document: EditorDocument
    var onEscape: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSave: ((Bool) -> Void)?
    var onRecognizeText: (() -> Void)?
    var onCopyColor: (() -> Void)?
    var onClose: (() -> Void)?

    private let imageLayer = CALayer()
    /// Drawings and the selection sit in their own view so they render above the picture's layer.
    private let overlay = CanvasOverlay()
    private var userZoom: CGFloat = 1
    private var pan: CGPoint = .zero
    private var draft: Annotation?

    private enum Handle: CaseIterable { case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left }
    private enum Drag {
        case none
        case newSelection(start: CGPoint)
        case move(start: CGPoint, original: CGRect)
        case resize(Handle, original: CGRect)
        case drawing
        case shape(start: CGPoint)
    }
    private var drag: Drag = .none

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    init(document: EditorDocument) {
        self.document = document
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        imageLayer.magnificationFilter = .nearest
        imageLayer.minificationFilter = .trilinear
        imageLayer.shadowColor = NSColor.black.cgColor
        imageLayer.shadowOpacity = 0.18
        imageLayer.shadowRadius = 12
        imageLayer.shadowOffset = CGSize(width: 0, height: -2)
        layer?.addSublayer(imageLayer)
        overlay.drawHandler = { [weak self] context in self?.drawOverlay(in: context) }
        addSubview(overlay)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                                       owner: self, userInfo: nil))
        observeDocument()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Geometry

    private var fitScale: CGFloat {
        let margin: CGFloat = 28
        let crop = document.size
        guard crop.width > 0, crop.height > 0, bounds.width > margin * 2, bounds.height > margin * 2 else { return 1 }
        let backing = window?.backingScaleFactor ?? 2
        return min((bounds.width - margin * 2) / crop.width, (bounds.height - margin * 2) / crop.height, 1 / backing)
    }

    /// Points per image pixel.
    private var scale: CGFloat { fitScale * userZoom }

    private var imageRect: CGRect {
        let size = CGSize(width: document.size.width * scale, height: document.size.height * scale)
        return CGRect(x: ((bounds.width - size.width) / 2 + pan.x).rounded(), y: ((bounds.height - size.height) / 2 + pan.y).rounded(),
                      width: size.width, height: size.height)
    }

    private func toView(_ point: CGPoint) -> CGPoint {
        let crop = currentCrop
        let rect = imageRect
        return CGPoint(x: rect.minX + (point.x - crop.minX) * scale, y: rect.minY + (point.y - crop.minY) * scale)
    }

    private func toImage(_ point: CGPoint) -> CGPoint {
        let crop = currentCrop
        let rect = imageRect
        return CGPoint(x: crop.minX + (point.x - rect.minX) / scale, y: crop.minY + (point.y - rect.minY) / scale)
    }

    private func toView(_ rect: CGRect) -> CGRect {
        let origin = toView(rect.origin)
        return CGRect(x: origin.x, y: origin.y, width: rect.width * scale, height: rect.height * scale)
    }

    private var currentCrop: CGRect { document.crop }

    // MARK: Updating

    private func observeDocument() {
        withObservationTracking {
            _ = document.annotations
            _ = document.selection
            _ = document.textBoxes
            _ = document.crop
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.refresh()
                self.observeDocument()
            }
        }
    }

    func refresh() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = imageRect
        if imageLayer.contents == nil || lastCrop != currentCrop {
            imageLayer.contents = document.base.cropping(to: currentCrop)
            lastCrop = currentCrop
        }
        imageLayer.magnificationFilter = scale * (window?.backingScaleFactor ?? 2) > 1.01 ? .nearest : .linear
        CATransaction.commit()
        document.zoomPercent = Int((scale * (window?.backingScaleFactor ?? 2) * 100).rounded())
        overlay.frame = bounds
        overlay.needsDisplay = true
    }

    override var needsDisplay: Bool {
        didSet { if needsDisplay { overlay.needsDisplay = true } }
    }

    private var lastCrop: CGRect = .null

    override func layout() {
        super.layout()
        refresh()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refresh()
    }

    // MARK: Drawing

    private func drawOverlay(in context: CGContext) {
        let rect = imageRect

        // Drawings, clipped to the picture.
        context.saveGState()
        context.clip(to: rect)
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -currentCrop.minX, y: -currentCrop.minY)
        for annotation in document.annotations { annotation.draw(in: context) }
        draft?.draw(in: context)
        context.restoreGState()

        // Recognized text, flashed after OCR.
        if !document.textBoxes.isEmpty {
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(1)
            context.setShadow(offset: .zero, blur: 2, color: NSColor.black.withAlphaComponent(0.6).cgColor)
            for box in document.textBoxes {
                context.stroke(toView(box).insetBy(dx: -2, dy: -2))
            }
            context.setShadow(offset: .zero, blur: 0, color: nil)
        }

        // Selection: dim outside, hairline border, handles, size.
        if let selection = document.selection {
            let box = toView(selection).integral
            context.saveGState()
            context.addRect(rect)
            context.addRect(box)
            context.setFillColor(NSColor.black.withAlphaComponent(0.38).cgColor)
            context.fillPath(using: .evenOdd)
            context.restoreGState()
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(1)
            context.stroke(box.insetBy(dx: -0.5, dy: -0.5))
            if case .select = document.tool {
                for handle in Handle.allCases {
                    let center = point(of: handle, in: box)
                    let square = CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)
                    context.setFillColor(NSColor.white.cgColor)
                    context.fill(square)
                    context.setStrokeColor(NSColor.black.withAlphaComponent(0.5).cgColor)
                    context.stroke(square.insetBy(dx: 0.5, dy: 0.5))
                }
            }
            drawSizeLabel("\(Int(selection.width)) × \(Int(selection.height))", below: box, in: context)
        }
    }

    private func drawSizeLabel(_ text: String, below box: CGRect, in context: CGContext) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        var origin = CGPoint(x: box.maxX - size.width - 12, y: box.maxY + 6)
        if origin.y + size.height + 6 > bounds.height { origin.y = box.maxY - size.height - 12 }
        origin.x = max(origin.x, 4)
        let pill = CGRect(x: origin.x, y: origin.y, width: size.width + 12, height: size.height + 6)
        let path = NSBezierPath(roundedRect: pill, xRadius: 5, yRadius: 5)
        NSColor.black.withAlphaComponent(0.78).setFill()
        path.fill()
        string.draw(at: CGPoint(x: pill.minX + 6, y: pill.minY + 3))
    }

    private func point(of handle: Handle, in box: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: CGPoint(x: box.minX, y: box.minY)
        case .top: CGPoint(x: box.midX, y: box.minY)
        case .topRight: CGPoint(x: box.maxX, y: box.minY)
        case .right: CGPoint(x: box.maxX, y: box.midY)
        case .bottomRight: CGPoint(x: box.maxX, y: box.maxY)
        case .bottom: CGPoint(x: box.midX, y: box.maxY)
        case .bottomLeft: CGPoint(x: box.minX, y: box.maxY)
        case .left: CGPoint(x: box.minX, y: box.midY)
        }
    }

    private func handle(at point: CGPoint) -> Handle? {
        guard let selection = document.selection, document.tool == .select else { return nil }
        let box = toView(selection)
        return Handle.allCases.first { hypot(self.point(of: $0, in: box).x - point.x, self.point(of: $0, in: box).y - point.y) <= 7 }
    }

    // MARK: Mouse

    override func cursorUpdate(with event: NSEvent) { updateCursor(at: convert(event.locationInWindow, from: nil)) }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateHover(point)
        updateCursor(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        document.hover = nil
    }

    private func updateHover(_ point: CGPoint) {
        let pixel = toImage(point)
        let floored = CGPoint(x: floor(pixel.x), y: floor(pixel.y))
        if currentCrop.contains(floored), let color = document.color(at: floored) {
            document.hover = (floored, color)
        } else {
            document.hover = nil
        }
    }

    private func updateCursor(at point: CGPoint) {
        if let handle = handle(at: point) {
            switch handle {
            case .left, .right: NSCursor.resizeLeftRight.set()
            case .top, .bottom: NSCursor.resizeUpDown.set()
            default: NSCursor.crosshair.set()
            }
        } else if document.tool == .select, let selection = document.selection, toView(selection).contains(point) {
            NSCursor.openHand.set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let pixel = clamp(toImage(point))
        switch document.tool {
        case .select:
            if let handle = handle(at: point), let selection = document.selection {
                drag = .resize(handle, original: selection)
            } else if let selection = document.selection, toView(selection).contains(point) {
                drag = .move(start: pixel, original: selection)
                NSCursor.closedHand.set()
            } else {
                drag = .newSelection(start: pixel)
                document.selection = nil
            }
        case .pen, .highlighter:
            draft = Annotation(shape: .stroke([pixel]), color: document.color, width: document.currentWidth,
                               highlighter: document.tool == .highlighter)
            drag = .drawing
        case .arrow:
            draft = Annotation(shape: .arrow(pixel, pixel), color: document.color, width: document.currentWidth)
            drag = .shape(start: pixel)
        case .rectangle:
            draft = Annotation(shape: .rectangle(CGRect(origin: pixel, size: .zero)), color: document.color, width: document.currentWidth)
            drag = .shape(start: pixel)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        var pixel = clamp(toImage(point))
        let shift = event.modifierFlags.contains(.shift)
        switch drag {
        case .newSelection(let start):
            if shift {
                let side = max(abs(pixel.x - start.x), abs(pixel.y - start.y))
                pixel = CGPoint(x: start.x + (pixel.x >= start.x ? side : -side), y: start.y + (pixel.y >= start.y ? side : -side))
            }
            let rect = CGRect(x: min(start.x, pixel.x), y: min(start.y, pixel.y), width: abs(pixel.x - start.x),
                              height: abs(pixel.y - start.y)).integral.intersection(currentCrop)
            document.selection = rect.width >= 1 && rect.height >= 1 ? rect : nil
        case .move(let start, let original):
            var moved = original.offsetBy(dx: (pixel.x - start.x).rounded(), dy: (pixel.y - start.y).rounded())
            moved.origin.x = min(max(moved.minX, currentCrop.minX), currentCrop.maxX - moved.width)
            moved.origin.y = min(max(moved.minY, currentCrop.minY), currentCrop.maxY - moved.height)
            document.selection = moved
        case .resize(let handle, let original):
            document.selection = resized(original, handle: handle, to: pixel)
        case .drawing:
            guard var draft, case .stroke(var points) = draft.shape else { return }
            if shift, let first = points.first {
                points = [first, pixel]
            } else if let last = points.last, hypot(pixel.x - last.x, pixel.y - last.y) >= 0.75 {
                points.append(pixel)
            }
            draft.shape = .stroke(points)
            self.draft = draft
        case .shape(let start):
            guard var draft else { return }
            switch draft.shape {
            case .arrow:
                var end = pixel
                if shift {  // snap to 45°
                    let angle = (atan2(end.y - start.y, end.x - start.x) / (.pi / 4)).rounded() * (.pi / 4)
                    let length = hypot(end.x - start.x, end.y - start.y)
                    end = CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
                }
                draft.shape = .arrow(start, end)
            case .rectangle:
                draft.shape = .rectangle(CGRect(x: min(start.x, pixel.x), y: min(start.y, pixel.y),
                                                width: abs(pixel.x - start.x), height: abs(pixel.y - start.y)))
            case .stroke: break
            }
            self.draft = draft
        case .none:
            break
        }
        updateHover(point)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            drag = .none
            draft = nil
            needsDisplay = true
        }
        switch drag {
        case .newSelection:
            if let selection = document.selection, selection.width < 3 || selection.height < 3 { document.selection = nil }
        case .drawing, .shape:
            if let draft, isMeaningful(draft) { document.add(draft) }
        case .move:
            NSCursor.openHand.set()
        default:
            break
        }
    }

    private func isMeaningful(_ annotation: Annotation) -> Bool {
        switch annotation.shape {
        case .stroke(let points): !points.isEmpty
        case .arrow(let a, let b): hypot(b.x - a.x, b.y - a.y) > 3
        case .rectangle(let rect): rect.width > 2 && rect.height > 2
        }
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, currentCrop.minX), currentCrop.maxX), y: min(max(point.y, currentCrop.minY), currentCrop.maxY))
    }

    private func resized(_ rect: CGRect, handle: Handle, to p: CGPoint) -> CGRect {
        var minX = rect.minX, minY = rect.minY, maxX = rect.maxX, maxY = rect.maxY
        switch handle {
        case .topLeft: minX = p.x; minY = p.y
        case .top: minY = p.y
        case .topRight: maxX = p.x; minY = p.y
        case .right: maxX = p.x
        case .bottomRight: maxX = p.x; maxY = p.y
        case .bottom: maxY = p.y
        case .bottomLeft: minX = p.x; maxY = p.y
        case .left: minX = p.x
        }
        return CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
            .integral.intersection(currentCrop)
    }

    // MARK: Zoom & pan

    override func magnify(with event: NSEvent) {
        setZoom(userZoom * (1 + event.magnification))
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            setZoom(userZoom * (1 + event.scrollingDeltaY / 200))
            return
        }
        guard userZoom > 1.001 else { return }
        pan.x += event.scrollingDeltaX
        pan.y += event.scrollingDeltaY
        refresh()
    }

    func setZoom(_ zoom: CGFloat) {
        userZoom = min(max(zoom, 0.25), 24)
        if userZoom <= 1.001 { pan = .zero }
        refresh()
    }

    func zoomToActualPixels() {
        let backing = window?.backingScaleFactor ?? 2
        setZoom(1 / backing / fitScale)
    }

    // MARK: Keys

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command), window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let shift = event.modifierFlags.contains(.shift)
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c": onCopy?()
        case "s": onSave?(shift)
        case "z": shift ? document.redo() : document.undo()
        case "0": setZoom(1)
        case "1": zoomToActualPixels()
        case "=", "+": setZoom(userZoom * 1.25)
        case "-": setZoom(userZoom / 1.25)
        case "w": onClose?()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    override func keyDown(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        switch Int(event.keyCode) {
        case kVK_Escape: onEscape?(); return
        case kVK_Return, kVK_ANSI_KeypadEnter: document.cropToSelection(); return
        case kVK_Tab: onCopyColor?(); return
        case kVK_Delete, kVK_ForwardDelete: document.selection = nil; return
        case kVK_LeftArrow: nudge(dx: shift ? -10 : -1, dy: 0); return
        case kVK_RightArrow: nudge(dx: shift ? 10 : 1, dy: 0); return
        case kVK_UpArrow: nudge(dx: 0, dy: shift ? -10 : -1); return
        case kVK_DownArrow: nudge(dx: 0, dy: shift ? 10 : 1); return
        default: break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "v": document.tool = .select
        case "p", "d": document.tool = .pen
        case "h": document.tool = .highlighter
        case "a": document.tool = .arrow
        case "r": document.tool = .rectangle
        case "t": onRecognizeText?()
        case "[": stepThickness(-1)
        case "]": stepThickness(1)
        default: super.keyDown(with: event)
        }
    }

    private func nudge(dx: CGFloat, dy: CGFloat) {
        guard var selection = document.selection else { return }
        selection = selection.offsetBy(dx: dx, dy: dy)
        selection.origin.x = min(max(selection.minX, currentCrop.minX), currentCrop.maxX - selection.width)
        selection.origin.y = min(max(selection.minY, currentCrop.minY), currentCrop.maxY - selection.height)
        document.selection = selection
    }

    private func stepThickness(_ delta: Int) {
        let all = EditorDocument.Thickness.allCases
        guard let index = all.firstIndex(of: document.thickness) else { return }
        let next = all[min(max(index + delta, 0), all.count - 1)]
        if next != document.thickness {
            document.thickness = next
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
    }
}

/// Transparent, click-through view that draws the editor's drawings and selection.
final class CanvasOverlay: NSView {
    var drawHandler: ((CGContext) -> Void)?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        drawHandler?(context)
    }
}
