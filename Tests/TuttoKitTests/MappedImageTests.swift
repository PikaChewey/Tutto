import CoreGraphics
import XCTest
@testable import TuttoKit

/// Window pictures are made with MappedImage so that letting go of them gives their memory back
/// to macOS at once; pictures in ordinary bitmaps left about half of it counted against Tutto.
final class MappedImageTests: XCTestCase {
    private func footprint() -> Double {
        var info = rusage_info_v4()
        let status: Int32 = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { raw -> Int32 in proc_pid_rusage(getpid(), RUSAGE_INFO_V4, raw) }
        }
        return status == 0 ? Double(info.ri_phys_footprint) / 1_048_576 : 0
    }

    func testThePictureHoldsWhatWasDrawn() throws {
        let image = try XCTUnwrap(MappedImage.make(width: 416, height: 260) { context in
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 416, height: 260))
        })
        XCTAssertEqual(image.width, 416)
        XCTAssertEqual(image.height, 260)
        // Read one pixel back through a fresh context: red, fully opaque.
        var pixel = [UInt8](repeating: 0, count: 4)
        let probe = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        probe.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(pixel[0], 255)
        XCTAssertEqual(pixel[3], 255)
        XCTAssertNil(MappedImage.make(width: 0, height: 10) { _ in })
    }

    func testLettingGoGivesTheMemoryBackAtOnce() {
        let before = footprint()
        var images: [CGImage] = []
        for _ in 0..<60 {
            if let image = MappedImage.make(width: 416, height: 260, draw: { context in
                context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: 416, height: 260))
            }) { images.append(image) }
        }
        XCTAssertEqual(images.count, 60)
        let holding = footprint() - before
        XCTAssertGreaterThan(holding, 18, "60 pictures of 432 KB are about 25 MB")
        images.removeAll()
        let after = footprint() - before
        XCTAssertLessThan(after, 3, "all of it comes back at once, not half of it later")
    }
}
