// Renders the Icon Composer layers for Tutto (full-bleed 1024 canvas; macOS applies the shape and glass).
// The double t of Tutto: two stems hanging from one bar, the way everything in Tutto hangs from the
// menu bar (the menu bar glyph is the same mark, drawn in `MenuBarGlyph`). White PNGs, because SVG
// layers turn to dark glass in the dark appearance. Check every appearance with Icon Composer's ictool.
// Usage: swift scripts/make-icon-layers.swift Resources/AppIcon.icon/Assets
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let stroke: CGFloat = 104
let stems: [CGFloat] = [369, 655]
let top: CGFloat = 257, bar: CGFloat = 415, base: CGFloat = 767

func layer(_ name: String, _ draw: (CGMutablePath) -> Void) {
    let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: 1024)
    ctx.scaleBy(x: 1, y: -1)  // top-left coordinates
    let path = CGMutablePath()
    draw(path)
    ctx.addPath(path)
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.setLineWidth(stroke)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}

// Behind: the bar.
layer("bar") { path in
    path.move(to: CGPoint(x: 215, y: bar))
    path.addLine(to: CGPoint(x: 809, y: bar))
}
// In front: the two stems, rising above the bar so it reads "tt" (never π), with a lowercase tail each.
layer("stems") { path in
    for x in stems {
        path.move(to: CGPoint(x: x, y: top))
        path.addLine(to: CGPoint(x: x, y: base - 114))
        path.addCurve(to: CGPoint(x: x + 132, y: base), control1: CGPoint(x: x, y: base - 40), control2: CGPoint(x: x + 46, y: base))
    }
}
print("layers written to \(out)")
