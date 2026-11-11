//
//  RecordingRules.swift
//  Tutto
//
//  The arithmetic of a screen recording, kept apart from ScreenCaptureKit so it can be tested:
//  the area in the display's points and the video's size in pixels (even, as H.264 and HEVC
//  need), the time shown while recording, and the file's name.
//

import CoreGraphics
import Foundation

public enum RecordingRules {
    /// Video encoders need even dimensions; anything smaller than this isn't worth a video.
    public static let minimumSide = 16

    /// The area to record in the display's points (top-left origin), from a selection in the
    /// display picture's pixels.
    public static func sourceRect(pixels: CGRect, scale: CGFloat) -> CGRect {
        let scale = max(scale, 1)
        return CGRect(x: pixels.minX / scale, y: pixels.minY / scale, width: pixels.width / scale, height: pixels.height / scale)
    }

    /// The video's size in pixels for an area of `points` at `scale`: native resolution, rounded
    /// down to even numbers, never below `minimumSide`.
    public static func videoSize(points: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
        func even(_ value: CGFloat) -> Int {
            let pixels = Int((value * max(scale, 1)).rounded(.down))
            return max(pixels - pixels % 2, minimumSide)
        }
        return (even(points.width), even(points.height))
    }

    /// Whether a selection is big enough to record (a click without a drag selects a window or the
    /// whole screen, so a tiny box only comes from a mistaken drag).
    public static func isRecordable(pixels: CGRect) -> Bool {
        pixels.width >= CGFloat(minimumSide) && pixels.height >= CGFloat(minimumSide)
    }

    /// "0:07", "4:32", "1:02:03".
    public static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds.rounded(.down)), 0)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "Recording 2026-11-11 at 05.12.04", in the Mac's time zone (the screenshot's pattern).
    public static func baseName(at date: Date, timeZone: TimeZone = .current) -> String {
        ScreenshotNames.base(at: date, timeZone: timeZone).replacingOccurrences(of: "Screenshot ", with: "Recording ")
    }
}
