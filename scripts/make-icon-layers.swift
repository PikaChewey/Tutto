// Writes Tutto's app icon document (Icon Composer): two layers on full-bleed 1024 canvases plus
// icon.json. macOS applies the shape and the glass. The mark is three sliders, the controls the panel
// holds, drawn the way the first Tutto icon was: a near-black field, the tracks in white glass at 24 %
// (on black they read as outlines) and the knobs in solid white glass, the one lit thing. The menu bar
// glyph is the same mark (`MenuBarGlyph`). Check every appearance with Icon Composer's ictool.
// Usage: swift scripts/make-icon-layers.swift Resources/AppIcon.icon
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icon")
let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

// Geometry on the 1024 canvas, y down: three rows, tracks from x 188 to 836 (about 63 % of the
// width, so the mark holds up at 16 px), each knob at its row's level: right, left, right of centre.
let rows: [CGFloat] = [328, 512, 696]
let left: CGFloat = 188, right: CGFloat = 836
let levels: [CGFloat] = [0.70, 0.32, 0.56]
let trackHeight: CGFloat = 52, knob: CGFloat = 78

func knobX(_ row: Int) -> CGFloat { left + (right - left) * levels[row] }

struct Layer {
    let name: String
    let opacity: Double?  // nil: solid white glass; otherwise frosted white glass at this opacity
    let draw: (CGContext) -> Void
}

// Front to back.
let layers = [
    // Knobs: solid white discs.
    Layer(name: "knobs", opacity: nil) { ctx in
        for row in rows.indices {
            ctx.addEllipse(in: CGRect(x: knobX(row) - knob, y: rows[row] - knob, width: knob * 2, height: knob * 2))
        }
    },
    // Tracks: full-width capsules behind the knobs.
    Layer(name: "tracks", opacity: 0.24) { ctx in
        for y in rows {
            let r = CGRect(x: left, y: y - trackHeight / 2, width: right - left, height: trackHeight)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: trackHeight / 2, cornerHeight: trackHeight / 2, transform: nil))
        }
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
    ctx.setFillColor(white)
    layer.draw(ctx)
    ctx.fillPath()
    let file = "\(layer.name).png"
    try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
        .write(to: assets.appendingPathComponent(file))
    var entry: [String: Any] = ["glass": true, "image-name": file, "name": layer.name]
    if let opacity = layer.opacity { entry["opacity"] = NSDecimalNumber(string: "\(opacity)") }  // 0.24, not 0.2399…
    groups.append([
        "layers": [entry],
        "shadow": ["kind": "neutral", "opacity": 0.5],
        "translucency": ["enabled": layer.opacity != nil, "value": 0.5],
    ])
}
// Near-black, as the first icon was; macOS's dark look lifts it to graphite.
let json: [String: Any] = [
    "fill": ["solid": "srgb:0.04314,0.04314,0.04706,1.00000"],
    "groups": groups,
    "supported-platforms": ["squares": ["macOS"]],
]
try! JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    .write(to: out.appendingPathComponent("icon.json"))
print("icon written to \(out.path): \(layers.map(\.name).joined(separator: ", "))")
