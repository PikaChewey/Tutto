//
//  GainStage.swift
//  Tutto
//
//  The arithmetic of an app's volume, for the audio thread: the level moves smoothly from one
//  buffer to the next (no zipper noise when a slider moves), and past 100 % a peak limiter keeps
//  every sample under the ceiling, so a boosted quiet video gets louder instead of distorting.
//  No allocation, no locks: a struct the volume rig keeps beside its tap.
//

import Foundation

/// What a slider's percentage means as a gain.
public enum VolumeCurve {
    public static let maximum = 300.0
    /// Below 100 % the curve is squared, so 50 % sounds about half as loud (−12 dB) instead of
    /// barely quieter; above it the boost is plain: 200 % is twice the amplitude (+6 dB).
    public static func gain(percent: Double) -> Float {
        let p = min(max(percent, 0), maximum) / 100
        return Float(p <= 1 ? p * p : p)
    }

    /// A slider let go near 100 % lands on it (and the app goes back to costing nothing).
    public static func snapped(_ percent: Double) -> Double {
        let clamped = min(max(percent, 0), maximum)
        return abs(clamped - 100) < 4 ? 100 : (clamped / 5).rounded() * 5
    }

    /// "70 %", "180 %".
    public static func label(_ percent: Double) -> String { "\(Int(percent.rounded())) %" }
}

public struct GainStage: Sendable {
    /// Samples never leave the limiter louder than this.
    public static let ceiling: Float = 0.97

    /// The gain at the end of the last buffer.
    public private(set) var gain: Float
    /// The limiter's current reduction (1: none).
    public private(set) var reduction: Float = 1
    private let recovery: Float

    /// `releaseSeconds`: how quickly the limiter lets go after a peak.
    public init(gain: Float = 1, sampleRate: Double = 48_000, releaseSeconds: Double = 0.08) {
        self.gain = gain
        recovery = Float(1 - exp(-1 / (max(sampleRate, 8_000) * releaseSeconds)))
    }

    /// One stereo frame at gain `g`.
    @inline(__always)
    public mutating func frame(_ left: inout Float, _ right: inout Float, gain g: Float) {
        var l = left * g
        var r = right * g
        reduction += (1 - reduction) * recovery
        let peak = max(abs(l), abs(r))
        if peak * reduction > Self.ceiling { reduction = Self.ceiling / peak }
        l *= reduction
        r *= reduction
        left = l
        right = r
    }

    /// Runs `frames` stereo frames (planar left and right) toward `target`, the gain moving in
    /// a straight line from where the last buffer left it.
    public mutating func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int, target: Float) {
        guard frames > 0 else { return }
        let step = (target - gain) / Float(frames)
        var g = gain
        for i in 0..<frames {
            g += step
            frame(&left[i], &right[i], gain: g)
        }
        gain = target
    }
}
