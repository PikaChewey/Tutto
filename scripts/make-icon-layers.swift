// Writes Tutto's app icon document (Icon Composer): three layers on full-bleed 1024 canvases plus
// icon.json. macOS applies the shape and the glass. The mark is three sliders, the controls the panel
// holds, in the GUI's own colours: graphite tracks filled to white knobs on white glass, the top one
// filled in the system blue (the panel's colour for what's live). The menu bar glyph is the same
// mark (`MenuBarGlyph`). Check every appearance with Icon Composer's ictool.
// Usage: swift scripts/make-icon-layers.swift Resources/AppIcon.icon
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icon")
let graphite = CGColor(srgbRed: 0.17, green: 0.17, blue: 0.19, alpha: 1)
let track = CGColor(srgbRed: 0.78, green: 0.78, blue: 0.80, alpha: 1)
let blue = CGColor(srgbRed: 0.0, green: 0.48, blue: 1.0, alpha: 1)
let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

// Geometry on the 1024 canvas, y down: three rows, tracks from x 188 to 836 (about 63 % of the
// width, so the mark holds up at 16 px), each knob at its row's level: right, left, right of centre.
let rows: [CGFloat] = [328, 512, 696]
let left: CGFloat = 188, right: CGFloat = 836
let levels: [CGFloat] = [0.70, 0.32, 0.56]
let trackHeight: CGFloat = 60, knob: CGFloat = 92, ring: CGFloat = 22

func knobX(_ row: Int) -> CGFloat { left + (right - left) * levels[row] }
func capsule(_ ctx: CGContext, from x0: CGFloat, to x1: CGFloat, row: Int) {
    let r = CGRect(x: x0, y: rows[row] - trackHeight / 2, width: x1 - x0, height: trackHeight)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: trackHeight / 2, cornerHeight: trackHeight / 2, transform: nil))
}

struct Layer {
    let name: String
    let glass: Bool
    let shadow: String
    let draw: (CGContext) -> Void
}

// Front to back.
let layers = [
    // Knobs: white discs with a graphite edge, like a control you'd move.
    Layer(name: "knobs", glass: true, shadow: "neutral") { ctx in
        for row in rows.indices {
            let c = CGPoint(x: knobX(row), y: rows[row])
            ctx.setFillColor(graphite)
            ctx.fillEllipse(in: CGRect(x: c.x - knob, y: c.y - knob, width: knob * 2, height: knob * 2))
            ctx.setFillColor(white)
            let inner = knob - ring
            ctx.fillEllipse(in: CGRect(x: c.x - inner, y: c.y - inner, width: inner * 2, height: inner * 2))
        }
    },
    // Fills up to each knob: the top one blue, the others graphite.
    Layer(name: "fills", glass: true, shadow: "none") { ctx in
        for row in rows.indices {
            ctx.setFillColor(row == 0 ? blue : graphite)
            capsule(ctx, from: left, to: knobX(row), row: row)
            ctx.fillPath()
        }
    },
    // Tracks behind, light grey and flat.
    Layer(name: "tracks", glass: false, shadow: "none") { ctx in
        ctx.setFillColor(track)
        for row in rows.indices { capsule(ctx, from: left, to: right, row: row) }
        ctx.fillPath()
    },
]

let assets = out.appendingPathComponent("Assets")
try? FileManager.default.removeItem(at: assets)
try! FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
var groups: [[String: Any]] = []
for layer in layers {
    let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: 1024)
    ctx.scaleBy(x: 1, y: -1)  // top-left coordinates
    layer.draw(ctx)
    let file = "\(layer.name).png"
    try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
        .write(to: assets.appendingPathComponent(file))
    groups.append([
        "layers": [["glass": layer.glass, "image-name": file, "name": layer.name]],
        "shadow": ["kind": layer.shadow, "opacity": 0.5],
        "translucency": ["enabled": false, "value": 0.5],
    ])
}
// White glass: Icon Composer builds the light gradient from this colour.
let json: [String: Any] = [
    "fill": ["automatic-gradient": "srgb:0.96500,0.96500,0.97500,1.00000"],
    "groups": groups,
    "supported-platforms": ["squares": ["macOS"]],
]
try! JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    .write(to: out.appendingPathComponent("icon.json"))
print("icon written to \(out.path): \(layers.map(\.name).joined(separator: ", "))")
