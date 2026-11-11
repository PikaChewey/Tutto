//
//  PaletteQuantizer.swift
//  Tutto
//
//  Makes PNGs smaller the way the web's PNG shrinkers do: at most 256 colours, chosen by median
//  cut over the picture's own colours, with Floyd–Steinberg dithering so gradients stay smooth.
//  ImageIO then writes a real palette PNG (colour type 3), often a third of the size. Pictures
//  with transparency, or that would visibly change (a photo), are left for the caller to keep.
//

import Foundation

public enum PaletteQuantizer {
    public struct Result: Sendable {
        /// Up to 256 colours, RGB.
        public let palette: [(UInt8, UInt8, UInt8)]
        /// One palette index per pixel, row by row.
        public let indices: [UInt8]
        /// Average difference from the original per channel (0–255): how visible the change is.
        public let meanError: Double
    }

    /// Quantizes opaque 8-bit RGBA (or BGRA when `bgra`) pixels; nil when a pixel isn't opaque.
    public static func quantize(rgba pixels: UnsafeBufferPointer<UInt8>, width: Int, height: Int, bytesPerRow: Int,
                                bgra: Bool = false, colors: Int = 256, dither: Bool = true) -> Result? {
        guard width > 0, height > 0, pixels.count >= bytesPerRow * height else { return nil }
        let (r, b) = bgra ? (2, 0) : (0, 2)

        // 1. A sample of the colours (every pixel for small pictures), and an opacity check.
        var samples: [(UInt8, UInt8, UInt8)] = []
        let step = max(1, Int((Double(width * height) / 120_000).squareRoot()))
        for y in stride(from: 0, to: height, by: 1) {
            let row = y * bytesPerRow
            for x in 0..<width {
                let i = row + x * 4
                if pixels[i + 3] != 255 { return nil }
                if y % step == 0 && x % step == 0 { samples.append((pixels[i + r], pixels[i + 1], pixels[i + b])) }
            }
        }

        // 2. Median cut: split the box with the widest channel range at its median until there are enough.
        var boxes: [[(UInt8, UInt8, UInt8)]] = [samples]
        while boxes.count < colors {
            guard let (index, channel) = widestBox(boxes) else { break }
            var box = boxes.remove(at: index)
            box.sort { component($0, channel) < component($1, channel) }
            // Split where the value changes nearest the middle, so one colour never ends up in two boxes.
            let median = component(box[box.count / 2], channel)
            var cut = box.firstIndex { component($0, channel) >= median } ?? box.count / 2
            if cut == 0 { cut = box.firstIndex { component($0, channel) > median } ?? box.count / 2 }
            boxes.append(Array(box[..<cut]))
            boxes.append(Array(box[cut...]))
        }
        var seen = Set<Int>()
        let palette = boxes.filter { !$0.isEmpty }.map(average).filter { color in
            seen.insert(Int(color.0) << 16 | Int(color.1) << 8 | Int(color.2)).inserted
        }

        // 3. Map every pixel to its nearest colour (cached per 5-bit cell), diffusing the error.
        var cache = [Int16](repeating: -1, count: 32 * 32 * 32)
        func nearest(_ cr: Int, _ cg: Int, _ cb: Int) -> Int {
            let cell = (cr >> 3) << 10 | (cg >> 3) << 5 | (cb >> 3)
            if cache[cell] >= 0 { return Int(cache[cell]) }
            var best = 0
            var bestDistance = Int.max
            for (index, color) in palette.enumerated() {
                let dr = cr - Int(color.0), dg = cg - Int(color.1), db = cb - Int(color.2)
                let distance = 2 * dr * dr + 4 * dg * dg + 3 * db * db
                if distance < bestDistance { bestDistance = distance; best = index }
            }
            cache[cell] = Int16(best)
            return best
        }
        var indices = [UInt8](repeating: 0, count: width * height)
        var errorThis = [Int](repeating: 0, count: (width + 2) * 3)
        var errorNext = [Int](repeating: 0, count: (width + 2) * 3)
        var totalError = 0
        for y in 0..<height {
            let row = y * bytesPerRow
            for x in 0..<width {
                let i = row + x * 4
                let e = (x + 1) * 3
                let cr = clamp(Int(pixels[i + r]) + (dither ? errorThis[e] / 16 : 0))
                let cg = clamp(Int(pixels[i + 1]) + (dither ? errorThis[e + 1] / 16 : 0))
                let cb = clamp(Int(pixels[i + b]) + (dither ? errorThis[e + 2] / 16 : 0))
                let index = nearest(cr, cg, cb)
                indices[y * width + x] = UInt8(index)
                let chosen = palette[index]
                let er = cr - Int(chosen.0), eg = cg - Int(chosen.1), eb = cb - Int(chosen.2)
                totalError += abs(Int(pixels[i + r]) - Int(chosen.0)) + abs(Int(pixels[i + 1]) - Int(chosen.1))
                    + abs(Int(pixels[i + b]) - Int(chosen.2))
                if dither {
                    // Floyd–Steinberg: 7/16 right, 3/16 down-left, 5/16 down, 1/16 down-right.
                    errorThis[e + 3] += er * 7; errorThis[e + 4] += eg * 7; errorThis[e + 5] += eb * 7
                    errorNext[e - 3] += er * 3; errorNext[e - 2] += eg * 3; errorNext[e - 1] += eb * 3
                    errorNext[e] += er * 5; errorNext[e + 1] += eg * 5; errorNext[e + 2] += eb * 5
                    errorNext[e + 3] += er; errorNext[e + 4] += eg; errorNext[e + 5] += eb
                }
            }
            if dither {
                swap(&errorThis, &errorNext)
                for k in errorNext.indices { errorNext[k] = 0 }
            }
        }
        return Result(palette: palette, indices: indices, meanError: Double(totalError) / Double(width * height * 3))
    }

    private static func clamp(_ value: Int) -> Int { min(max(value, 0), 255) }

    private static func component(_ color: (UInt8, UInt8, UInt8), _ channel: Int) -> UInt8 {
        channel == 0 ? color.0 : channel == 1 ? color.1 : color.2
    }

    private static func widestBox(_ boxes: [[(UInt8, UInt8, UInt8)]]) -> (Int, Int)? {
        var best: (index: Int, channel: Int, range: Int)?
        for (index, box) in boxes.enumerated() where box.count > 1 {
            for channel in 0..<3 {
                var low = 255, high = 0
                for color in box {
                    let value = Int(component(color, channel))
                    low = min(low, value)
                    high = max(high, value)
                }
                // Weight by how many colours the box holds, so busy regions get more of the palette.
                let range = (high - low) * Int(Double(box.count).squareRoot())
                if high > low, range > (best?.range ?? 0) { best = (index, channel, range) }
            }
        }
        return best.map { ($0.index, $0.channel) }
    }

    private static func average(_ box: [(UInt8, UInt8, UInt8)]) -> (UInt8, UInt8, UInt8) {
        var r = 0, g = 0, b = 0
        for color in box { r += Int(color.0); g += Int(color.1); b += Int(color.2) }
        let n = max(box.count, 1)
        return (UInt8(r / n), UInt8(g / n), UInt8(b / n))
    }
}
