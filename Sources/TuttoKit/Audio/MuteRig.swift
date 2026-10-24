//
//  MuteRig.swift
//  Tutto
//
//  Holds chosen processes' sound back from the speakers, with Core Audio process taps
//  (macOS 14.2+). A tap with `CATapMuted` "is captured by the tap but no audio is sent
//  from the process to the audio hardware" (CATapDescription.h); the tap only takes
//  effect while it is in use, so it sits in a private aggregate device with a do-nothing
//  IO callback. Nothing is read, kept or written anywhere.
//
//  Other apps can still hear a muted process: any other tap or screen recording of it
//  gets its audio as usual. Only the path to the output device is cut.
//
//  The tap is private to Tutto, so it dies with Tutto's process: a crash or quit can't
//  leave an app muted.
//

import CoreAudio
import Foundation

public struct MuteRigError: Error, CustomStringConvertible {
    public let stage: String
    public let status: OSStatus
    public var description: String { "\(stage) failed (\(status))" }
}

@available(macOS 14.2, *)
public final class MuteRig {
    public struct Config: Sendable, Equatable {
        /// Clock the aggregate device from the current output device (as recorders do).
        public var includeOutputDevice = true
        /// Let Core Audio start the device only when a tapped process actually plays.
        public var tapAutoStart = true
        public var behavior: CATapMuteBehavior = .muted

        public init(includeOutputDevice: Bool = true, tapAutoStart: Bool = true, behavior: CATapMuteBehavior = .muted) {
            self.includeOutputDevice = includeOutputDevice
            self.tapAutoStart = tapAutoStart
            self.behavior = behavior
        }
    }

    public private(set) var processes: [AudioObjectID]
    public let outputDeviceUID: String?
    private let description: CATapDescription
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?

    /// Builds and starts the rig. Throws (and leaves nothing behind) if any step fails.
    public init(processes: [AudioObjectID], config: Config = Config()) throws {
        self.processes = processes
        outputDeviceUID = config.includeOutputDevice ? AudioDevices.defaultOutputUID() : nil

        description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.name = "Tutto mute"
        description.muteBehavior = config.behavior
        description.isPrivate = true

        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw MuteRigError(stage: "Creating the tap", status: status) }

        var composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Tutto mute",
            kAudioAggregateDeviceUIDKey: "ca.bryanyao.Tutto.mute.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        if config.tapAutoStart { composition[kAudioAggregateDeviceTapAutoStartKey] = true }
        if let outputDeviceUID {
            composition[kAudioAggregateDeviceMainSubDeviceKey] = outputDeviceUID
            composition[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputDeviceUID]]
        }
        status = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate)
        guard status == noErr else {
            teardown()
            throw MuteRigError(stage: "Creating the audio device", status: status)
        }
        // The callback does nothing: being called is what keeps the tap, and so the mute, in force.
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregate, nil) { _, _, _, _, _ in }
        guard status == noErr else {
            teardown()
            throw MuteRigError(stage: "Preparing the audio device", status: status)
        }
        status = AudioDeviceStart(aggregate, ioProc)
        guard status == noErr else {
            teardown()
            throw MuteRigError(stage: "Starting the audio device", status: status)
        }
    }

    deinit { teardown() }

    /// Retargets the running tap to a new set of processes without a gap. Returns false
    /// if Core Audio refuses; build a new rig then.
    public func update(processes newProcesses: [AudioObjectID]) -> Bool {
        guard newProcesses != processes else { return true }
        description.processes = newProcesses
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyDescription,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
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

    /// Stops the device and arms it again, so with tap auto-start it sleeps until a muted
    /// process plays again (a device left running keeps the Mac from idle-sleeping).
    @discardableResult
    public func rearm() -> OSStatus {
        guard let ioProc, aggregate != kAudioObjectUnknown else { return OSStatus(kAudioHardwareNotRunningError) }
        AudioDeviceStop(aggregate, ioProc)
        return AudioDeviceStart(aggregate, ioProc)
    }

    /// Whether the rig's device is running right now (it only runs while a muted process plays).
    public var isRunning: Bool {
        guard aggregate != kAudioObjectUnknown else { return false }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunning,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(aggregate, &address, 0, nil, &size, &running)
        return running != 0
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

public enum AudioDevices {
    public static func defaultOutputID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }

    public static func defaultOutputUID() -> String? {
        guard let device = defaultOutputID() else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }
}
