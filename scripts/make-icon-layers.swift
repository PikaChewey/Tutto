// Renders the Icon Composer layer for Tutto (full-bleed 1024 canvas; macOS applies the shape and glass).
// The mark is ∀, the logic symbol for "for all": tutto. One monoline with round caps and joins, an
// upside-down A whose crossbar sits a little over a third down, so the triangle under it stays open
// at small sizes. Drawn in amber; the document's automatic gradient is ink navy. The menu bar glyph
// is the same mark (`MenuBarGlyph`). Check every appearance with Icon Composer's ictool.
// Usage: swift scripts/make-icon-layers.swift Resources/AppIcon.icon/Assets
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let amber = CGColor(srgbRed: 1.0, green: 0.68, blue: 0.14, alpha: 1)

// Geometry on the 1024 canvas, y down. Centre lines: the legs run from the top corners to the
// apex at the bottom (a 2:1 slope), the bar crosses between them.
let centreX: CGFloat = 512
let width: CGFloat = 510, height: CGFloat = 510
let legStroke: CGFloat = 80, barStroke: CGFloat = 76
let optical: CGFloat = 10                     // the mass sits high, so the whole mark sits a little low
let top = 512 + optical - height / 2
let slope = (width / 2) / height
let legHalfX = (legStroke / 2) * (1 + slope * slope).squareRoot()   // a leg's horizontal half width
let barY = top + height * 0.36
let barTop = barY - barStroke / 2, barBottom = barY + barStroke / 2

func legX(_ y: CGFloat) -> CGFloat { width / 2 - slope * (y - top) }
func gap(_ y: CGFloat) -> CGFloat { legX(y) - legHalfX }
let notchY = top + (width / 2 - legHalfX) / slope   // where the legs' inner edges meet

func unit(_ x: CGFloat, _ y: CGFloat) -> CGPoint { let l = hypot(x, y); return CGPoint(x: x / l, y: y / l) }

/// Rounds a concave corner at `c` between edges running along `u` and `v` (away from the corner).
func fillet(_ c: CGPoint, _ u: CGPoint, _ v: CGPoint, _ r: CGFloat) -> CGPath {
    let phi = acos(u.x * v.x + u.y * v.y)
    let d = r / tan(phi / 2)
    let bx = u.x + v.x, by = u.y + v.y, bl = hypot(bx, by)
    let p = CGMutablePath()
    p.move(to: CGPoint(x: c.x + u.x * d, y: c.y + u.y * d))
    p.addArc(tangent1End: c, tangent2End: CGPoint(x: c.x + v.x * 200, y: c.y + v.y * 200), radius: r)
    p.addLine(to: CGPoint(x: c.x - bx / bl * 6, y: c.y - by / bl * 6))
    p.closeSubpath()
    return p
}

let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.translateBy(x: 0, y: 1024)
ctx.scaleBy(x: 1, y: -1)  // top-left coordinates
ctx.setStrokeColor(amber)
ctx.setFillColor(amber)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
// The bar, then the legs over it.
ctx.setLineWidth(barStroke)
ctx.move(to: CGPoint(x: centreX - legX(barY), y: barY)); ctx.addLine(to: CGPoint(x: centreX + legX(barY), y: barY))
ctx.strokePath()
ctx.setLineWidth(legStroke)
ctx.move(to: CGPoint(x: centreX - width / 2, y: top))
ctx.addLine(to: CGPoint(x: centreX, y: top + height))
ctx.addLine(to: CGPoint(x: centreX + width / 2, y: top))
ctx.strokePath()
// Soft inner corners: the point of the triangle, its two upper corners, and the two at the foot of the mouth.
ctx.addPath(fillet(CGPoint(x: centreX, y: notchY), unit(-slope, -1), unit(slope, -1), 20))
for side in [CGFloat(-1), 1] {
    ctx.addPath(fillet(CGPoint(x: centreX + side * gap(barTop), y: barTop), CGPoint(x: -side, y: 0), unit(side * slope, -1), 24))
    ctx.addPath(fillet(CGPoint(x: centreX + side * gap(barBottom), y: barBottom), CGPoint(x: -side, y: 0), unit(-side * slope, 1), 18))
}
ctx.fillPath()
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/forall.png"))
print("layer written to \(out)/forall.png")
