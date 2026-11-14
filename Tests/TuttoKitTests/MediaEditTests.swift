import CoreGraphics
import Foundation
import XCTest
@testable import TuttoKit

final class MediaEditTests: XCTestCase {
    func testResizeNeverGrows() {
        XCTAssertTrue(ResizeSpec.scale(0.5).size(width: 3024, height: 1964) == (1512, 982))
        XCTAssertTrue(ResizeSpec.longSide(1920).size(width: 3840, height: 2160) == (1920, 1080))
        XCTAssertTrue(ResizeSpec.longSide(1920).size(width: 800, height: 600) == (800, 600))
        XCTAssertTrue(ResizeSpec.longSide(1080).size(width: 1080, height: 1920) == (608, 1080))
        // Video sizes stay even.
        XCTAssertTrue(ResizeSpec.scale(0.5).size(width: 1918, height: 1078, even: true) == (958, 538))
        XCTAssertFalse(ResizeSpec.longSide(4000).shrinks(width: 1000, height: 800))
        XCTAssertTrue(ResizeSpec.scale(0.25).shrinks(width: 1000, height: 800))
    }

    func testResizeCodes() {
        XCTAssertEqual(ResizeSpec(code: "50%"), .scale(0.5))
        XCTAssertEqual(ResizeSpec(code: "0.25x"), .scale(0.25))
        XCTAssertEqual(ResizeSpec(code: "1920"), .longSide(1920))
        XCTAssertEqual(ResizeSpec(code: "1280px"), .longSide(1280))
        XCTAssertNil(ResizeSpec(code: "150%"))
        XCTAssertNil(ResizeSpec(code: "abc"))
        for spec in ResizeSpec.picturePresets { XCTAssertEqual(ResizeSpec(code: spec.code), spec) }
    }

    func testCropRectIsLargestOfItsShape() {
        let wide = CropMath.rect(width: 4000, height: 3000, ratio: 1)
        XCTAssertEqual(wide, CGRect(x: 500, y: 0, width: 3000, height: 3000))
        let tall = CropMath.rect(width: 1080, height: 1920, ratio: 16.0 / 9)
        XCTAssertEqual(tall.width, 1080)
        XCTAssertEqual(tall.height, 607)
        XCTAssertEqual(tall.minY, 657)
        // Focus pulls it toward the subject but never outside the picture.
        let left = CropMath.rect(width: 4000, height: 3000, ratio: 1, focus: CGPoint(x: 0, y: 0.5))
        XCTAssertEqual(left.minX, 0)
        let right = CropMath.rect(width: 4000, height: 3000, ratio: 1, focus: CGPoint(x: 0.9, y: 0.5))
        XCTAssertEqual(right.maxX, 4000)
        let even = CropMath.rect(width: 1921, height: 1081, ratio: 9.0 / 16, focus: CGPoint(x: 0.33, y: 0.5), even: true)
        XCTAssertEqual(Int(even.width) % 2, 0)
        XCTAssertEqual(Int(even.minX) % 2, 0)
    }

    func testCropOutputSizes() {
        XCTAssertTrue(CropSpec.aspect(16, 9).outputSize(width: 3000, height: 3000) == (3000, 1687))
        XCTAssertTrue(CropSpec.size(1080, 1080).outputSize(width: 4000, height: 3000) == (1080, 1080))
        // Never scaled up: a small picture keeps its pixels, in the shape asked for.
        XCTAssertTrue(CropSpec.size(1920, 1080).outputSize(width: 800, height: 800) == (800, 450))
        XCTAssertEqual(CropSpec(code: "16:9"), .aspect(16, 9))
        XCTAssertEqual(CropSpec(code: "1920x1080"), .size(1920, 1080))
        XCTAssertEqual(CropSpec(code: "square"), .aspect(1, 1))
        XCTAssertNil(CropSpec(code: "0:9"))
        for spec in CropSpec.aspects + CropSpec.sizes { XCTAssertEqual(CropSpec(code: spec.code), spec) }
    }

    func testFocusFromSalientRegions() {
        XCTAssertEqual(CropMath.focus(of: []), CGPoint(x: 0.5, y: 0.5))
        let focus = CropMath.focus(of: [(CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), 1)])
        XCTAssertEqual(focus.x, 0.2, accuracy: 0.0001)
        XCTAssertEqual(focus.y, 0.2, accuracy: 0.0001)
    }

    func testCompressWorthKeeping() {
        XCTAssertTrue(CompressRules.worthKeeping(before: 1_000, after: 900))
        XCTAssertFalse(CompressRules.worthKeeping(before: 1_000, after: 970))
        XCTAssertFalse(CompressRules.worthKeeping(before: 0, after: 0))
    }

    func testNamesAndPlanner() {
        let source = URL(fileURLWithPath: "/tmp/beach.jpg")
        XCTAssertEqual(OutputNames.edited(source, mark: "cropped", exists: { _ in false }).lastPathComponent, "beach (cropped).jpg")
        XCTAssertTrue(ConvertPlanner.canCrop(.pdf))
        XCTAssertFalse(ConvertPlanner.canResize(.pdf))
        XCTAssertEqual(SavedBytes.percent(before: 1000, after: 180), "−82 %")
        XCTAssertEqual(SavedBytes.percent(before: 1000, after: 1000), "")
    }
}
