import Foundation
import XCTest
@testable import TuttoKit

final class GainStageTests: XCTestCase {
    private func sine(_ frames: Int, amplitude: Float, frequency: Double = 440, rate: Double = 48_000) -> [Float] {
        (0..<frames).map { amplitude * Float(sin(2 * Double.pi * frequency * Double($0) / rate)) }
    }

    func testUnityLeavesSoundUntouched() {
        var stage = GainStage(gain: 1)
        var left = sine(4800, amplitude: 0.8), right = sine(4800, amplitude: 0.5)
        let original = (left, right)
        left.withUnsafeMutableBufferPointer { l in right.withUnsafeMutableBufferPointer { r in
            stage.process(left: l.baseAddress!, right: r.baseAddress!, frames: 4800, target: 1)
        } }
        XCTAssertEqual(left, original.0)
        XCTAssertEqual(right, original.1)
    }

    func testHalfGainHalves() {
        var stage = GainStage(gain: 0.5)
        var left = sine(480, amplitude: 0.6), right = sine(480, amplitude: 0.6)
        let original = left
        left.withUnsafeMutableBufferPointer { l in right.withUnsafeMutableBufferPointer { r in
            stage.process(left: l.baseAddress!, right: r.baseAddress!, frames: 480, target: 0.5)
        } }
        for i in 0..<480 { XCTAssertEqual(left[i], original[i] * 0.5, accuracy: 1e-6) }
    }

    /// Moving a slider ramps across the buffer: no sample-to-sample jump bigger than the music's own.
    func testChangesRampWithoutSteps() {
        var stage = GainStage(gain: 1)
        var left = [Float](repeating: 0.5, count: 512), right = [Float](repeating: 0.5, count: 512)
        left.withUnsafeMutableBufferPointer { l in right.withUnsafeMutableBufferPointer { r in
            stage.process(left: l.baseAddress!, right: r.baseAddress!, frames: 512, target: 0.25)
        } }
        XCTAssertEqual(left.first!, 0.5, accuracy: 0.002)
        XCTAssertEqual(left.last!, 0.125, accuracy: 0.001)
        for i in 1..<512 { XCTAssertLessThan(abs(left[i] - left[i - 1]), 0.001) }
        XCTAssertEqual(stage.gain, 0.25)
    }

    /// 300 % on a full-scale sine: louder, never past the ceiling, and it lets go afterwards.
    func testBoostIsLimitedNotClipped() {
        var stage = GainStage(gain: 3)
        var left = sine(48_000, amplitude: 1), right = sine(48_000, amplitude: 1)
        left.withUnsafeMutableBufferPointer { l in right.withUnsafeMutableBufferPointer { r in
            stage.process(left: l.baseAddress!, right: r.baseAddress!, frames: 48_000, target: 3)
        } }
        XCTAssertLessThanOrEqual(left.map(abs).max()!, GainStage.ceiling + 1e-6)
        // Louder on average than the original (a quiet passage boosted is what boost is for).
        let rms = (left.reduce(0) { $0 + $1 * $1 } / 48_000).squareRoot()
        XCTAssertGreaterThan(rms, 0.69)
        // Quiet input afterwards: the limiter recovers and the boost applies in full.
        var quietL = sine(48_000, amplitude: 0.1), quietR = sine(48_000, amplitude: 0.1)
        quietL.withUnsafeMutableBufferPointer { l in quietR.withUnsafeMutableBufferPointer { r in
            stage.process(left: l.baseAddress!, right: r.baseAddress!, frames: 48_000, target: 3)
        } }
        XCTAssertEqual(quietL.suffix(4800).map(abs).max()!, 0.3, accuracy: 0.01)
        XCTAssertGreaterThan(stage.reduction, 0.99)
    }

    func testTheSliderCurve() {
        XCTAssertEqual(VolumeCurve.gain(percent: 100), 1)
        XCTAssertEqual(VolumeCurve.gain(percent: 50), 0.25)
        XCTAssertEqual(VolumeCurve.gain(percent: 0), 0)
        XCTAssertEqual(VolumeCurve.gain(percent: 200), 2)
        XCTAssertEqual(VolumeCurve.gain(percent: 900), 3)
        XCTAssertEqual(VolumeCurve.snapped(102), 100)
        XCTAssertEqual(VolumeCurve.snapped(73), 75)
        XCTAssertEqual(VolumeCurve.snapped(-5), 0)
        XCTAssertEqual(VolumeCurve.label(180), "180 %")
    }

    /// Where the rig writes left and right: built-in speakers, a mono speaker, an interface that
    /// splits its outputs over streams, and a stereo pair moved to channels 3–4.
    func testTheOutputsStereoPair() {
        XCTAssertTrue(AudioDevices.locate(channel: 1, in: [2])! == (0, 0))
        XCTAssertTrue(AudioDevices.locate(channel: 2, in: [2])! == (0, 1))
        XCTAssertNil(AudioDevices.locate(channel: 2, in: [1]))
        XCTAssertTrue(AudioDevices.locate(channel: 2, in: [1, 1])! == (1, 0))
        XCTAssertTrue(AudioDevices.locate(channel: 3, in: [2, 2])! == (1, 0))
        XCTAssertTrue(AudioDevices.locate(channel: 4, in: [2, 2])! == (1, 1))
        XCTAssertNil(AudioDevices.locate(channel: 0, in: [2]))
        XCTAssertNil(AudioDevices.locate(channel: 1, in: []))
    }

    /// Only the tap's streams (the last inputs) stay on; nothing is sent when there's nothing else.
    func testOnlyTheTapsInputsStayOn() {
        XCTAssertNil(AudioDevices.streamUsage(inputStreams: 1, keeping: 1), "speakers: just the tap")
        XCTAssertEqual(AudioDevices.streamUsage(inputStreams: 2, keeping: 1), [0, 1], "a headset's microphone first")
        XCTAssertEqual(AudioDevices.streamUsage(inputStreams: 4, keeping: 2), [0, 0, 1, 1])
        XCTAssertNil(AudioDevices.streamUsage(inputStreams: 0, keeping: 1))
        XCTAssertNil(AudioDevices.streamUsage(inputStreams: 3, keeping: 0), "never everything off")
    }
}
