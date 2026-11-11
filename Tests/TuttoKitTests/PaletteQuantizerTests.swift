import Foundation
import XCTest
@testable import TuttoKit

final class PaletteQuantizerTests: XCTestCase {
    private func pixels(_ width: Int, _ height: Int, alpha: UInt8 = 255, _ color: (Int, Int) -> (UInt8, UInt8, UInt8)) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = color(x, y)
                let i = (y * width + x) * 4
                data[i] = r; data[i + 1] = g; data[i + 2] = b; data[i + 3] = alpha
            }
        }
        return data
    }

    func testFewColoursComeThroughExactly() {
        // A flat graphic: 12 colours in blocks, like a screenshot of an interface.
        var colours: [(UInt8, UInt8, UInt8)] = []
        for k in 0..<12 {
            let r = UInt8(k * 20), g = UInt8(255 - k * 15), b = UInt8(k * 7)
            colours.append((r, g, b))
        }
        let data = pixels(120, 80) { x, y in colours[(x / 10 + y / 20) % 12] }
        let result = data.withUnsafeBufferPointer { PaletteQuantizer.quantize(rgba: $0, width: 120, height: 80, bytesPerRow: 480) }
        XCTAssertNotNil(result)
        XCTAssertLessThanOrEqual(result!.palette.count, 12)
        XCTAssertEqual(result!.meanError, 0, accuracy: 0.001)
        for y in stride(from: 0, to: 80, by: 7) {
            for x in stride(from: 0, to: 120, by: 7) {
                let chosen = result!.palette[Int(result!.indices[y * 120 + x])]
                let want = colours[(x / 10 + y / 20) % 12]
                XCTAssertTrue(chosen == want, "pixel \(x),\(y)")
            }
        }
    }

    func testGradientsStayClose() {
        let data = pixels(300, 200) { x, y in (UInt8(x * 255 / 299), UInt8(y * 255 / 199), UInt8((x + y) % 256)) }
        let result = data.withUnsafeBufferPointer { PaletteQuantizer.quantize(rgba: $0, width: 300, height: 200, bytesPerRow: 1200) }
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.palette.count, 256)
        XCTAssertLessThan(result!.meanError, 12)
    }

    func testTransparencyIsLeftAlone() {
        let data = pixels(20, 20, alpha: 128) { _, _ in (10, 20, 30) }
        XCTAssertNil(data.withUnsafeBufferPointer { PaletteQuantizer.quantize(rgba: $0, width: 20, height: 20, bytesPerRow: 80) })
    }

    func testSpeedOfAScreenSizedPicture() {
        // 1600 × 1000 with text-like detail: the size of a screenshot.
        let data = pixels(1600, 1000) { x, y in
            let ink = (x / 3 + y / 5) % 9 == 0
            return ink ? (40, 40, 40) : (UInt8(240 - (y / 50) % 4 * 6), 242, UInt8(245 - (x / 200)))
        }
        let started = Date()
        let result = data.withUnsafeBufferPointer { PaletteQuantizer.quantize(rgba: $0, width: 1600, height: 1000, bytesPerRow: 6400) }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertNotNil(result)
        print(String(format: "palette quantizer: 1600x1000 in %.3f s, %d colours, mean error %.2f", elapsed, result?.palette.count ?? 0, result?.meanError ?? -1))
    }
}
