// Renders the Icon Composer layers for Tutto (full-bleed 1024 canvas; macOS applies the shape and glass).
// A 2×2 grid of rounded tiles: three frosted, the bottom-right one solid — four tools in one,
// and the corner CornerClick turned into a right-click.
// Usage: swift scripts/make-icon-layers.swift Resources/AppIcon.icon/Assets
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let tile: CGFloat = 268, gap: CGFloat = 44, radius: CGFloat = 62
let origin = (1024 - (tile * 2 + gap)) / 2
func rect(_ column: Int, _ row: Int) -> CGRect {
    CGRect(x: origin + CGFloat(column) * (tile + gap), y: origin + CGFloat(row) * (tile + gap), width: tile, height: tile)
}

func layer(_ name: String, _ rects: [CGRect]) {
    let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: 1024)
    ctx.scaleBy(x: 1, y: -1)  // top-left coordinates
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    for r in rects {
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
    }
    ctx.fillPath()
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}

layer("tiles", [rect(0, 0), rect(1, 0), rect(0, 1)])
layer("corner", [rect(1, 1)])
print("layers written to \(out)")
