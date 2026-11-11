//
//  VolumeRig.swift
//  Tutto
//
//  An app's own volume (0–300 %), with Core Audio process taps (macOS 14.2+). A private tap over
//  the app's sound processes takes their sound from the speakers while it's being read
//  (`mutedWhenTapped`: if Tutto ever stops reading, the app simply plays as before), and a
//  private device clocked by the current output plays it back through GainStage: louder or
//  quieter, ramped, and limited so a boost never clips.
//
//  The device starts only while the app plays (tap auto-start), so an app turned down that's
//  silent costs nothing, and the macOS "audio in use" dot shows only then. The audio callback
//  allocates nothing and takes no locks; its buffers and state live beside the rig.
//
//  The tap's sound is the last of the device's inputs (an output with a microphone lists that
//  first, and it's told to stay off); it plays on the output's own stereo pair, as the app would.
//

import CoreAudio
import Foundation

@available(macOS 14.2, *)
public final class VolumeRig {
    /// The audio thread's state: the level to reach, the gain stage, what the tap delivers and
    /// where left and right go (stream, channel in it).
    struct State {
        var target: Float
        var stage: GainStage
        var inputChannels: Int
        var inputInterleaved: Bool
        var left: (stream: Int, channel: Int) = (0, 0)
        var right: (stream: Int, channel: Int) = (0, 1)

        /// Streams the tap's sound arrives in: one interleaved, or one per channel.
        var tapStreams: Int { inputInterleaved ? 1 : max(inputChannels, 1) }
    }

    static let maxFrames = 16_384

    public private(set) var processes: [AudioObjectID]
    private let description: CATapDescription
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private let state: UnsafeMutablePointer<State>
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>

    public init(processes: [AudioObjectID], gain: Float) throws {
        self.processes = processes
        state = .allocate(capacity: 1)
        left = .allocate(capacity: Self.maxFrames)
        right = .allocate(capacity: Self.maxFrames)
        left.initialize(repeating: 0, count: Self.maxFrames)
        right.initialize(repeating: 0, count: Self.maxFrames)
        // Ready before anything can fail: deinit (which runs after a throw too) releases it.
        state.initialize(to: State(target: gain, stage: GainStage(gain: gain), inputChannels: 2, inputInterleaved: true))

        description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.name = "Tutto volume"
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true

        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw MuteRigError(stage: "Creating the tap", status: status) }

        // What the tap delivers (stereo, 32-bit float; interleaved or not).
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format)
        let channels = max(Int(format.mChannelsPerFrame), 1)
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        state.pointee = State(target: gain, stage: GainStage(gain: gain, sampleRate: format.mSampleRate > 0 ? format.mSampleRate : 48_000),
                              inputChannels: channels, inputInterleaved: interleaved)

        guard let output = AudioDevices.defaultOutputID(), let outputUID = AudioDevices.uid(of: output) else {
            throw MuteRigError(stage: "Finding the output", status: OSStatus(kAudioHardwareBadDeviceError))
        }
        // The output's stereo pair (a mono output gets both sides mixed).
        let streams = AudioDevices.outputChannelsPerStream(of: output)
        let pair = AudioDevices.preferredStereoChannels(of: output)
        let leftSpot = AudioDevices.locate(channel: pair.left, in: streams) ?? (0, 0)
        let rightSpot = AudioDevices.locate(channel: pair.right, in: streams)
            ?? AudioDevices.locate(channel: 2, in: streams) ?? leftSpot
        state.pointee.left = leftSpot
        state.pointee.right = rightSpot
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Tutto volume",
            kAudioAggregateDeviceUIDKey: "ca.bryanyao.Tutto.volume.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
        ]
        status = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate)
        guard status == noErr else { throw MuteRigError(stage: "Creating the audio device", status: status) }

        let state = self.state, left = self.left, right = self.right
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregate, nil) { _, input, _, output, _ in
            Self.render(input: input, output: output, state: state, left: left, right: right)
        }
        guard status == noErr, let ioProc else { throw MuteRigError(stage: "Preparing the audio device", status: status) }
        AudioDevices.useOnlyTrailingInputs(of: aggregate, ioProc: ioProc, keeping: state.pointee.tapStreams)
        status = AudioDeviceStart(aggregate, ioProc)
        guard status == noErr else { throw MuteRigError(stage: "Starting the audio device", status: status) }
    }

    deinit {
        teardown()
        state.deinitialize(count: 1)
        state.deallocate()
        left.deallocate()
        right.deallocate()
    }

    /// The new level; the next buffers ramp to it.
    public func setGain(_ gain: Float) {
        state.pointee.target = gain
    }

    /// Retargets the tap to the app's current sound processes; false if Core Audio refuses.
    public func update(processes newProcesses: [AudioObjectID]) -> Bool {
        guard newProcesses != processes else { return true }
        description.processes = newProcesses
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyDescription, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: CATapDescription? = description
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectSetPropertyData(tap, &address, 0, nil, UInt32(MemoryLayout<CATapDescription?>.size), $0)
        }
        guard status == noErr else { return false }
        processes = newProcesses
        return true
    }

    public func stop() { teardown() }

    /// Stops the device and arms it again, so it sleeps until the app plays again (tap auto-start).
    @discardableResult
    public func rearm() -> OSStatus {
        guard let ioProc, aggregate != kAudioObjectUnknown else { return OSStatus(kAudioHardwareNotRunningError) }
        AudioDeviceStop(aggregate, ioProc)
        return AudioDeviceStart(aggregate, ioProc)
    }

    /// Whether the device is running (only while the app plays).
    public var isRunning: Bool {
        guard aggregate != kAudioObjectUnknown else { return false }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunning, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(aggregate, &address, 0, nil, &size, &running)
        return running != 0
    }

    /// The audio thread: the tap's streams (the last inputs) in, gain and limiter, then left and
    /// right onto the output's stereo pair, silence everywhere else.
    private static func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>,
                               state: UnsafeMutablePointer<State>, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        var frames = 0
        let first = max(inputs.count - state.pointee.tapStreams, 0)
        if first < inputs.count, let data = inputs[first].mData?.assumingMemoryBound(to: Float.self) {
            let buffer = inputs[first]
            if state.pointee.inputInterleaved {
                let channels = max(Int(buffer.mNumberChannels), 1)
                frames = min(Int(buffer.mDataByteSize) / (4 * channels), maxFrames)
                for i in 0..<frames {
                    left[i] = data[i * channels]
                    right[i] = channels > 1 ? data[i * channels + 1] : data[i * channels]
                }
            } else {
                frames = min(Int(buffer.mDataByteSize) / 4, maxFrames)
                let second = first + 1 < inputs.count ? inputs[first + 1].mData?.assumingMemoryBound(to: Float.self) : nil
                for i in 0..<frames {
                    left[i] = data[i]
                    right[i] = second?[i] ?? data[i]
                }
            }
            state.pointee.stage.process(left: left, right: right, frames: frames, target: state.pointee.target)
        }
        for buffer in outputs {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        guard frames > 0 else { return }
        let l = state.pointee.left, r = state.pointee.right
        if l == r {
            // One channel for both: the two sides mixed.
            for i in 0..<frames { left[i] = (left[i] + right[i]) * 0.5 }
            write(left, frames: frames, to: l, in: outputs)
        } else {
            write(left, frames: frames, to: l, in: outputs)
            write(right, frames: frames, to: r, in: outputs)
        }
    }

    private static func write(_ samples: UnsafeMutablePointer<Float>, frames: Int, to spot: (stream: Int, channel: Int),
                              in outputs: UnsafeMutableAudioBufferListPointer) {
        guard spot.stream < outputs.count else { return }
        let buffer = outputs[spot.stream]
        let channels = max(Int(buffer.mNumberChannels), 1)
        guard spot.channel < channels, let out = buffer.mData?.assumingMemoryBound(to: Float.self) else { return }
        let count = min(frames, Int(buffer.mDataByteSize) / (4 * channels))
        for i in 0..<count { out[i * channels + spot.channel] = samples[i] }
    }

    private func teardown() {
        if let ioProc, aggregate != kAudioObjectUnknown {
            AudioDeviceStop(aggregate, ioProc)
            AudioDeviceDestroyIOProcID(aggregate, ioProc)
        }
        ioProc = nil
        if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate) }
        aggregate = AudioObjectID(kAudioObjectUnknown)
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        tap = AudioObjectID(kAudioObjectUnknown)
    }
}
