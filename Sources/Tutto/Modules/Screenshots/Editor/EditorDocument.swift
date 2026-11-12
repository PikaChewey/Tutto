//
//  EditorDocument.swift
//  Tutto
//
//  The screenshot being edited. Crops and drawings are kept as data on top of the
//  original pixels (all in image-pixel coordinates, top-left origin), so undo is exact
//  and the export is rendered once, at full resolution, when you copy or save.
//

import AppKit
import Observation
import TuttoKit
import Vision

enum EditorTool: String, CaseIterable, Identifiable {
    case select, pen, highlighter, arrow, rectangle, pixelate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: "Select"
        case .pen: "Draw"
        case .highlighter: "Highlight"
        case .arrow: "Arrow"
        case .rectangle: "Rectangle"
        case .pixelate: "Pixelate"
        }
    }

    var symbol: String {
        switch self {
        case .select: "crop"
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .pixelate: "checkerboard.rectangle"
        }
    }

    var key: String {
        switch self {
        case .select: "V"
        case .pen: "P"
        case .highlighter: "H"
        case .arrow: "A"
        case .rectangle: "R"
        case .pixelate: "B"
        }
    }
}

struct Annotation: Identifiable, Equatable {
    enum Shape: Equatable {
        case stroke([CGPoint])
        case arrow(CGPoint, CGPoint)
        case rectangle(CGRect)
        /// Hides what's underneath (passwords, names) behind coarse blocks of the original pixels.
        case pixelate(CGRect)
    }

    let id = UUID()
    var shape: Shape
    var color: NSColor
    var width: CGFloat
    var highlighter = false

    /// The picture rows and columns the drawing covers (for a highlighter's background).
    var bounds: CGRect {
        let points: [CGPoint]
        switch shape {
        case .stroke(let p): points = p
        case .arrow(let a, let b): points = [a, b]
        default: return .null
        }
        guard let first = points.first else { return .null }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
            .insetBy(dx: -width / 2, dy: -width / 2)
    }

    /// Mean brightness (0–1) of `image` inside `rect` (image pixels, top-left origin), from an
    /// 8 × 8 reduction.
    static func brightness(of image: CGImage, in rect: CGRect) -> CGFloat? {
        let area = rect.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
        guard !area.isNull, area.width >= 1, area.height >= 1, let crop = image.cropping(to: area),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 8 * 8 * 4)
        guard let context = CGContext(data: &bytes, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(crop, in: CGRect(x: 0, y: 0, width: 8, height: 8))
        var total = 0.0
        for i in stride(from: 0, to: bytes.count, by: 4) {
            total += 0.2126 * Double(bytes[i]) + 0.7152 * Double(bytes[i + 1]) + 0.0722 * Double(bytes[i + 2])
        }
        return CGFloat(total / 64 / 255)
    }

    /// Draws in image-pixel coordinates (the context's CTM maps those to the output).
    /// `source` is the original picture, needed by Pixelate.
    func draw(in context: CGContext, source: CGImage? = nil) {
        if case .pixelate(let rect) = shape {
            guard let source, let blocks = Self.pixelated(source, rect: rect.standardized.integral) else { return }
            context.saveGState()
            context.interpolationQuality = .none
            // Images draw bottom-up; flip locally so the blocks land where the rect is.
            let r = rect.standardized.integral
            context.translateBy(x: r.minX, y: r.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(blocks, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
            context.restoreGState()
            return
        }
        context.saveGState()
        defer { context.restoreGState() }
        // A highlighter darkens what's under it (multiply), which can't show on a dark picture:
        // there it lightens instead (screen), a little stronger, so it reads on both.
        let onDark = highlighter && (source.flatMap { Self.brightness(of: $0, in: bounds) } ?? 1) < 0.42
        let alpha: CGFloat = highlighter ? (onDark ? 0.55 : 0.38) : 1
        context.setStrokeColor(color.withAlphaComponent(alpha).cgColor)
        context.setFillColor(color.withAlphaComponent(alpha).cgColor)
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        if highlighter { context.setBlendMode(onDark ? .screen : .multiply) }
        switch shape {
        case .stroke(let points):
            context.addPath(Self.smoothPath(points))
            context.strokePath()
        case .arrow(let from, let to):
            let length = hypot(to.x - from.x, to.y - from.y)
            guard length > 1 else { return }
            let head = min(max(width * 4, 14), length * 0.6)
            let angle = atan2(to.y - from.y, to.x - from.x)
            let base = CGPoint(x: to.x - cos(angle) * head * 0.8, y: to.y - sin(angle) * head * 0.8)
            context.move(to: from)
            context.addLine(to: base)
            context.strokePath()
            let spread: CGFloat = .pi / 7
            context.move(to: to)
            context.addLine(to: CGPoint(x: to.x - cos(angle - spread) * head, y: to.y - sin(angle - spread) * head))
            context.addLine(to: CGPoint(x: to.x - cos(angle + spread) * head, y: to.y - sin(angle + spread) * head))
            context.closePath()
            context.fillPath()
        case .rectangle(let rect):
            context.stroke(rect.standardized)
        case .pixelate:
            break
        }
    }

    /// The region shrunk to a few blocks across (averaging the pixels), to be drawn back up without smoothing.
    static func pixelated(_ source: CGImage, rect: CGRect) -> CGImage? {
        guard rect.width >= 2, rect.height >= 2,
              let region = source.cropping(to: rect.intersection(CGRect(x: 0, y: 0, width: source.width, height: source.height))),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let block = min(max(max(rect.width, rect.height) / 16, 8), 40)
        let width = max(Int((rect.width / block).rounded()), 1), height = max(Int((rect.height / block).rounded()), 1)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(region, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Quadratic curves through the midpoints: smooth freehand lines without lag.
    static func smoothPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count == 1 {
            path.addLine(to: CGPoint(x: first.x + 0.01, y: first.y))
            return path
        }
        if points.count == 2 {
            path.addLine(to: points[1])
            return path
        }
        for index in 1..<points.count - 1 {
            let mid = CGPoint(x: (points[index].x + points[index + 1].x) / 2, y: (points[index].y + points[index + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[index])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }
}

@MainActor
@Observable
final class EditorDocument {
    let base: CGImage
    /// The part of `base` that is the picture right now (crops are non-destructive).
    private(set) var crop: CGRect
    private(set) var annotations: [Annotation] = []
    /// A drawn box, in base-image pixels. Used for crop, copy, save and text recognition.
    var selection: CGRect?
    var tool: EditorTool = .select
    var color: NSColor = EditorPalette.colors[0]
    /// Line width in image pixels for the current tool.
    var thickness: Thickness = .medium
    /// The pixel under the pointer and its color, for the status line and Tab.
    var hover: (point: CGPoint, color: NSColor)?
    /// Recognized text boxes, flashed briefly after OCR.
    var textBoxes: [CGRect] = []
    var zoomPercent: Int = 100

    private var undoStack: [(CGRect, [Annotation])] = []
    private var redoStack: [(CGRect, [Annotation])] = []

    enum Thickness: CGFloat, CaseIterable {
        case thin = 3, medium = 6, thick = 12

        var title: String {
            switch self {
            case .thin: "Thin"
            case .medium: "Medium"
            case .thick: "Thick"
            }
        }
    }

    init(image: CGImage) {
        base = image
        crop = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    }

    var size: CGSize { crop.size }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Width in image pixels for the active tool (highlighters draw wider).
    var currentWidth: CGFloat { thickness.rawValue * (tool == .highlighter ? 3 : 1) }

    // MARK: Editing

    private func checkpoint() {
        undoStack.append((crop, annotations))
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func add(_ annotation: Annotation) {
        checkpoint()
        annotations.append(annotation)
    }

    func cropToSelection() {
        guard let selection = selection?.intersection(crop).integral, selection.width >= 2, selection.height >= 2 else { return }
        checkpoint()
        crop = selection
        self.selection = nil
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append((crop, annotations))
        (crop, annotations) = last
        selection = nil
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append((crop, annotations))
        (crop, annotations) = next
        selection = nil
    }

    // MARK: Output

    /// What copy and save produce: the selection if there is one, otherwise the whole picture.
    var exportRegion: CGRect {
        if let selection = selection?.intersection(crop).integral, selection.width >= 1, selection.height >= 1 {
            return selection
        }
        return crop
    }

    /// Renders `region` of the picture with its drawings, at full resolution.
    /// `annotated` false: the picture as captured, except what's been pixelated stays pixelated.
    func render(_ region: CGRect? = nil, annotated: Bool = true) -> CGImage? {
        let region = (region ?? exportRegion).integral
        let width = Int(region.width), height = Int(region.height)
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = base.cropping(to: region) else { return nil }
        context.interpolationQuality = .none
        context.draw(pixels, in: CGRect(x: 0, y: 0, width: width, height: height))
        let drawn = annotated ? annotations : annotations.filter { if case .pixelate = $0.shape { true } else { false } }
        if !drawn.isEmpty {
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.translateBy(x: -region.minX, y: -region.minY)
            for annotation in drawn { annotation.draw(in: context, source: base) }
        }
        return context.makeImage()
    }

    /// The sRGB color of a base-image pixel.
    func color(at point: CGPoint) -> NSColor? {
        base.color(atX: Int(point.x), y: Int(point.y))
    }

    // MARK: Text recognition

    struct TextResult {
        var text: String
        var lineCount: Int
        var codes: [String]
    }

    /// Recognizes text (and QR/barcodes) in the selection or the whole picture, off the main thread.
    func recognizeText() async -> TextResult {
        let region = exportRegion
        guard let image = render(region, annotated: false) else { return TextResult(text: "", lineCount: 0, codes: []) }
        let result = await Task.detached(priority: .userInitiated) { () -> (String, Int, [String], [CGRect]) in
            let textRequest = VNRecognizeTextRequest()
            textRequest.recognitionLevel = .accurate
            textRequest.usesLanguageCorrection = true
            textRequest.automaticallyDetectsLanguage = true
            let codeRequest = VNDetectBarcodesRequest()
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try? handler.perform([textRequest, codeRequest])
            let observations = textRequest.results ?? []
            let lines = TextLayout.lines(observations.compactMap { observation in
                observation.topCandidates(1).first.map { (observation.boundingBox, $0.string) }
            }).map(RecognizedLines.fixingSlashedZeros)
            let codes = (codeRequest.results ?? []).compactMap(\.payloadStringValue)
            // Normalized boxes (bottom-left origin) → base-image pixels.
            let boxes = observations.map { observation -> CGRect in
                let box = observation.boundingBox
                return CGRect(x: region.minX + box.minX * region.width,
                              y: region.minY + (1 - box.maxY) * region.height,
                              width: box.width * region.width, height: box.height * region.height)
            }
            return (lines.joined(separator: "\n"), lines.count, codes, boxes)
        }.value
        textBoxes = result.3
        return TextResult(text: result.0, lineCount: result.1, codes: result.2)
    }
}

/// Puts recognized fragments back into reading order: rows top to bottom, left to right
/// within a row (fragments whose vertical extents mostly overlap share a row).
enum TextLayout {
    static func lines(_ fragments: [(box: CGRect, text: String)]) -> [String] {
        let sorted = fragments.sorted { $0.box.midY > $1.box.midY }
        var rows: [[(box: CGRect, text: String)]] = []
        for fragment in sorted {
            if let index = rows.lastIndex(where: { row in
                guard let first = row.first else { return false }
                let overlap = min(first.box.maxY, fragment.box.maxY) - max(first.box.minY, fragment.box.minY)
                return overlap > min(first.box.height, fragment.box.height) * 0.5
            }) {
                rows[index].append(fragment)
            } else {
                rows.append([fragment])
            }
        }
        return rows.map { $0.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ") }
    }
}

enum EditorPalette {
    static let colors: [NSColor] = [
        NSColor(srgbRed: 1.0, green: 0.23, blue: 0.19, alpha: 1),   // red
        NSColor(srgbRed: 1.0, green: 0.62, blue: 0.04, alpha: 1),   // orange
        NSColor(srgbRed: 1.0, green: 0.84, blue: 0.04, alpha: 1),   // yellow
        NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1),  // green
        NSColor(srgbRed: 0.04, green: 0.52, blue: 1.0, alpha: 1),   // blue
        NSColor(srgbRed: 0.69, green: 0.32, blue: 0.87, alpha: 1),  // purple
        NSColor.black,
        NSColor.white,
    ]
}
