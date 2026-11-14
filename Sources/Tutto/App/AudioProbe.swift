//
//  AudioProbe.swift
//  Tutto
//
//  Debug-only: `Tutto --audio-probe <log> <command…>` measures the Sound tool against
//  Core Audio itself, so "muted" is a number, not an impression.
//    list                 audio processes and the app each belongs to
//    verify <pidA> <pidB> mutes A with each rig variant while metering, every 0.5 s:
//                         what A sends to the output device, what B sends (must not change),
//                         and what an independent tap on A hears (must not change)
//

#if DEBUG
import AppKit
import AudioToolbox
import AVFoundation
import CoreAudio
import IOKit.pwr_mgt
import TuttoKit

@MainActor
enum AudioProbe {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--audio-probe"), args.count > flag + 2 else { return false }
        guard #available(macOS 14.2, *) else { return true }
        let log = URL(fileURLWithPath: args[flag + 1])
        var lines: [String] = []
        let started = Date()
        func say(_ s: String) {
            lines.append(String(format: "%6.2f ", Date().timeIntervalSince(started)) + s)
            try? lines.joined(separator: "\n").write(to: log, atomically: true, encoding: .utf8)
        }
        let rest = Array(args[(flag + 2)...])
        switch rest.first {
        case "list":
            let apps = NSWorkspace.shared.runningApplications.compactMap { app -> AudioOwnership.App? in
                guard app.activationPolicy == .regular, let id = app.bundleIdentifier, let url = app.bundleURL else { return nil }
                return AudioOwnership.App(pid: app.processIdentifier, bundleID: id, bundlePath: url.path)
            }
            for process in AudioProcessList.read() {
                let owner = AudioOwnership.owner(of: process.pid, among: apps)
                say("obj=\(process.objectID) pid=\(process.pid) out=\(process.isRunningOutput) bundle=\(process.bundleID ?? "-") owner=\(owner?.bundleID ?? "-")")
            }
        case "verify":
            let a = pid_t(rest[1])!, b = pid_t(rest[2])!
            let all = AudioProcessList.read()
            guard let objA = all.first(where: { $0.pid == a })?.objectID, all.contains(where: { $0.pid == b }) else {
                say("no audio object for \(a) or \(b)"); break
            }
            let meterA = TapMeter(CATapDescription(__excludingProcesses: others(than: a, in: all),
                                                   andDeviceUID: AudioDevices.defaultOutputUID() ?? "", withStream: 0))
            let meterB = TapMeter(CATapDescription(__excludingProcesses: others(than: b, in: all),
                                                   andDeviceUID: AudioDevices.defaultOutputUID() ?? "", withStream: 0))
            let heard = TapMeter(CATapDescription(stereoMixdownOfProcesses: [objA]))
            say("meters: A=\(meterA.status) B=\(meterB.status) capture=\(heard.status)  (dBFS; — = nothing arrived)")
            func watch(_ phase: String, _ seconds: Double) {
                for _ in 0..<Int(seconds * 2) {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                    say("A→speakers \(meterA.take())  B→speakers \(meterB.take())  A heard by another tap \(heard.take())  [\(phase)]")
                }
            }
            watch("baseline", 2)
            let variants: [(String, MuteRig.Config)] = [
                ("output device + auto start", .init()),
                ("output device, no auto start", .init(tapAutoStart: false)),
                ("tap only", .init(includeOutputDevice: false, tapAutoStart: false)),
            ]
            for (name, config) in variants {
                do {
                    let rig = try MuteRig(processes: [objA], config: config)
                    watch("MUTED: \(name)", 3)
                    rig.stop()
                } catch {
                    say("\(name): \(error)")
                }
                watch("unmuted", 2)
            }
            meterA.stop(); meterB.stop(); heard.stop()
        case "listen":
            // listen <pid> <seconds>: an independent recorder of one app, like any other tool would be.
            let pid = pid_t(rest[1])!, seconds = Double(rest[2])!
            guard let obj = AudioProcessList.read().first(where: { $0.pid == pid })?.objectID else { say("no object"); break }
            let heard = TapMeter(CATapDescription(stereoMixdownOfProcesses: [obj]))
            say("listening status=\(heard.status)")
            for _ in 0..<Int(seconds * 2) {
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                say(String(format: "%.3f ", Date().timeIntervalSince1970) + "heard \(heard.take())")
            }
            heard.stop()
        case "hold":
            // hold <pid> <variant 0|1|2> <seconds>: keep one rig up, for CPU and sleep-assertion checks.
            let pid = pid_t(rest[1])!, variant = Int(rest[2])!, seconds = Double(rest[3])!
            guard let obj = AudioProcessList.read().first(where: { $0.pid == pid })?.objectID else { say("no object"); break }
            let configs: [MuteRig.Config] = [.init(), .init(tapAutoStart: false), .init(includeOutputDevice: false, tapAutoStart: false)]
            do {
                let rig = try MuteRig(processes: [obj], config: configs[variant])
                say("holding variant \(variant) pid \(ProcessInfo.processInfo.processIdentifier)")
                let until = Date().addingTimeInterval(seconds)
                var last = ""
                var quietSince: Date?
                while Date() < until {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                    if rest.count > 4, rest[4] == "rearm" {
                        if AudioProcessList.isRunningOutput(obj) { quietSince = nil }
                        else if quietSince == nil { quietSince = Date() }
                        if let q = quietSince, -q.timeIntervalSinceNow > 0.5, rig.isRunning {
                            say(String(format: "%.3f ", Date().timeIntervalSince1970) + "rearm status=\(rig.rearm())")
                            quietSince = nil
                        }
                    }
                    let state = "rig running=\(rig.isRunning) app output=\(AudioProcessList.isRunningOutput(obj))"
                    if state != last { say(String(format: "%.3f ", Date().timeIntervalSince1970) + state); last = state }
                }
                rig.stop()
            } catch { say("\(error)") }
        case "access":
            say("system audio recording access: \(SystemAudioAccess.status())")
        case "mutecheck":
            // mutecheck <pid>: does the mute hold without a running device? For each setup, what the app
            // sends to the output device, what another tap hears, and coreaudiod's assertions for Tutto/app.
            guard SystemAudioAccess.status() == .granted else { say("no system audio recording access: not tapping"); break }
            let pid = pid_t(rest[1])!
            let all = AudioProcessList.read()
            guard let obj = all.first(where: { $0.pid == pid })?.objectID else { say("no object"); break }
            let me = ProcessInfo.processInfo.processIdentifier
            let meter = TapMeter(CATapDescription(__excludingProcesses: others(than: pid, in: all),
                                                  andDeviceUID: AudioDevices.defaultOutputUID() ?? "", withStream: 0))
            let heard = TapMeter(CATapDescription(stereoMixdownOfProcesses: [obj]))
            say("meters: speakers=\(meter.status) capture=\(heard.status)")
            func watch(_ phase: String, _ seconds: Double) {
                for _ in 0..<Int(seconds * 2) {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                    let held = PowerAssertions.audio(for: [me, pid]).filter { !$0.contains("BuiltInSpeakerDevice") || $0.contains("for \(me)") }
                    say("app→speakers \(meter.take())  heard \(heard.take())  app output=\(AudioProcessList.isRunningOutput(obj))  "
                        + "[\(phase)] held: \(held.isEmpty ? "-" : held.sorted().joined(separator: " | "))")
                }
            }
            watch("unmuted", 2)
            for setup in LabRig.Setup.allCases {
                do {
                    let lab = try LabRig(process: obj, setup: setup)
                    watch(setup.rawValue, 4)
                    lab.stop()
                } catch { say("\(setup.rawValue): \(error)") }
                watch("unmuted", 2)
            }
            meter.stop(); heard.stop()
        case "power":
            // power <pid> <variant 0…3> <seconds> [norearm] [sleepok]: one rig on the app, re-armed 0.5 s after
            // the app goes quiet (as SoundModule does), logging every change of the rig, the app's output and the
            // power assertions coreaudiod holds for Tutto or the app. `sleepok` sets SleepingIsAllowed first.
            guard SystemAudioAccess.status() == .granted else { say("no system audio recording access: not tapping"); break }
            let pid = pid_t(rest[1])!, variant = Int(rest[2])!, seconds = Double(rest[3])!
            let rearms = !rest.contains("norearm")
            guard let obj = AudioProcessList.read().first(where: { $0.pid == pid })?.objectID else { say("no object"); break }
            if rest.contains("sleepok") { say("sleeping allowed: status \(setSleepingAllowed(true))") }
            let configs: [MuteRig.Config] = [.init(), .init(includeOutputDevice: false),
                                             .init(tapAutoStart: false), .init(includeOutputDevice: false, tapAutoStart: false)]
            let me = ProcessInfo.processInfo.processIdentifier
            var lastAssertions: Set<String> = PowerAssertions.audio(for: [me, pid])
            for line in lastAssertions.sorted() { say("held before: \(line)") }
            do {
                let rig = try MuteRig(processes: [obj], config: configs[variant])
                say("rig variant \(variant) built, Tutto pid \(me), app pid \(pid), rearm \(rearms)")
                let until = Date().addingTimeInterval(seconds)
                var last = ""
                var quietSince: Date?
                while Date() < until {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                    let output = AudioProcessList.isRunningOutput(obj)
                    if rearms {
                        if output { quietSince = nil } else if quietSince == nil { quietSince = Date() }
                        if let q = quietSince, -q.timeIntervalSinceNow > 0.5, rig.isRunning {
                            say("rearm status=\(rig.rearm())")
                            quietSince = nil
                        }
                    }
                    let state = "rig running=\(rig.isRunning) app output=\(output)"
                    if state != last { say(state); last = state }
                    let now = PowerAssertions.audio(for: [me, pid])
                    for line in now.subtracting(lastAssertions).sorted() { say("+ \(line)") }
                    for line in lastAssertions.subtracting(now).sorted() { say("- \(line)") }
                    lastAssertions = now
                }
                rig.stop()
                say("rig stopped")
                for _ in 0..<20 {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                    let now = PowerAssertions.audio(for: [me, pid])
                    for line in now.subtracting(lastAssertions).sorted() { say("+ \(line)") }
                    for line in lastAssertions.subtracting(now).sorted() { say("- \(line)") }
                    lastAssertions = now
                }
            } catch { say("\(error)") }
        default:
            say("unknown command")
        }
        say("done")
        return true
    }

    private static func others(than pid: pid_t, in processes: [AudioProcess]) -> [NSNumber] {
        processes.filter { $0.pid != pid }.map { NSNumber(value: $0.objectID) }
    }

    private static func setSleepingAllowed(_ allowed: Bool) -> OSStatus {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertySleepingIsAllowed,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = allowed ? 1 : 0
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                          UInt32(MemoryLayout<UInt32>.size), &value)
    }
}

/// Mute set-ups taken apart, to see which parts the mute needs: the tap alone, the tap in a device that
/// is never started, started (MuteRig as shipped), or started and then stopped (what a re-arm passes through).
private struct LabError: Error { let stage: String; let status: OSStatus }

@available(macOS 14.2, *)
private final class LabRig {
    enum Setup: String, CaseIterable { case tapOnly = "tap only", neverStarted = "device never started",
                                            started = "device started (auto start)", stopped = "device started then stopped" }
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?

    init(process: AudioObjectID, setup: Setup) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: [process])
        description.uuid = UUID()
        description.muteBehavior = .muted
        description.isPrivate = true
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw LabError(stage: "tap", status: status) }
        guard setup != .tapOnly else { return }
        let output = AudioDevices.defaultOutputUID() ?? ""
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Tutto lab", kAudioAggregateDeviceUIDKey: "ca.bryanyao.Tutto.lab.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true, kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: output,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
        ]
        status = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &device)
        guard status == noErr else { stop(); throw LabError(stage: "device", status: status) }
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil) { _, _, _, _, _ in }
        guard status == noErr else { stop(); throw LabError(stage: "ioproc", status: status) }
        guard setup != .neverStarted else { return }
        status = AudioDeviceStart(device, proc)
        guard status == noErr else { stop(); throw LabError(stage: "start", status: status) }
        if setup == .stopped {
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            AudioDeviceStop(device, proc)
        }
    }

    func stop() {
        if let proc { AudioDeviceStop(device, proc); AudioDeviceDestroyIOProcID(device, proc) }
        proc = nil
        if device != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(device) }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        device = AudioObjectID(kAudioObjectUnknown)
        tap = AudioObjectID(kAudioObjectUnknown)
    }
}

/// The power assertions coreaudiod holds on behalf of given processes ("type name" lines).
enum PowerAssertions {
    static func audio(for pids: Set<pid_t>) -> Set<String> {
        var dictionary: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&dictionary) == kIOReturnSuccess,
              let byProcess = dictionary?.takeRetainedValue() as NSDictionary? else { return [] }
        var lines: Set<String> = []
        for case let (_, list as NSArray) in byProcess {
            for case let assertion as NSDictionary in list {
                guard let name = assertion["AssertName"] as? String, name.hasPrefix("com.apple.audio."),
                      let behalf = assertion["AssertionOnBehalfOfPID"] as? Int, pids.contains(pid_t(behalf)) else { continue }
                let type = assertion["AssertType"] as? String ?? "?"
                lines.insert("\(type) for \(behalf) \(name)")
            }
        }
        return lines
    }
}

/// RMS of whatever a tap delivers, collected off the IO thread.
@available(macOS 14.2, *)
final class TapMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var sum: Float = 0, count = 0
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private(set) var status: OSStatus = noErr

    init(_ description: CATapDescription) {
        description.uuid = UUID()
        description.isPrivate = true
        status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { return }
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Tutto probe meter",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        status = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &device)
        guard status == noErr else { return }
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil) { [self] _, input, _, _, _ in
            var total: Float = 0, n = 0
            for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
                guard let data = buffer.mData else { continue }
                let samples = data.assumingMemoryBound(to: Float.self)
                let count = Int(buffer.mDataByteSize) / 4
                for i in 0..<count { total += samples[i] * samples[i] }
                n += count
            }
            lock.lock(); sum += total; count += n; lock.unlock()
        }
        guard status == noErr else { return }
        status = AudioDeviceStart(device, proc)
    }

    /// dBFS since the last call, as a number (nil when nothing arrived).
    func takeDB() -> Float? {
        lock.lock(); defer { sum = 0; count = 0; lock.unlock() }
        guard count > 0 else { return nil }
        return 20 * log10(max(sqrt(sum / Float(count)), 1e-9))
    }

    /// dBFS since the last call, or "—" when nothing arrived at all.
    func take() -> String {
        lock.lock(); defer { sum = 0; count = 0; lock.unlock() }
        guard count > 0 else { return "   —  " }
        return String(format: "%6.1f", 20 * log10(max(sqrt(sum / Float(count)), 1e-9)))
    }

    func stop() {
        if let proc { AudioDeviceStop(device, proc); AudioDeviceDestroyIOProcID(device, proc) }
        proc = nil
        if device != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(device) }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        device = AudioObjectID(kAudioObjectUnknown)
        tap = AudioObjectID(kAudioObjectUnknown)
    }
}
#endif

#if DEBUG
/// `Tutto --volume-probe DIR`: plays a quiet 1 kHz tone with afplay, measures it straight from
/// afplay, then through a VolumeRig at 50 % and at 200 % (measured off Tutto's own output), and
/// writes DIR/volume.txt. About five seconds of a quiet tone.
@available(macOS 14.2, *)
enum VolumeProbe {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--volume-probe"), args.count > flag + 1 else { return false }
        let dir = URL(fileURLWithPath: args[flag + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var lines: [String] = []
        func say(_ line: String) {
            lines.append(line)
            try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent("volume.txt"), atomically: true, encoding: .utf8)
        }
        func wait(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

        // The tone: 1 kHz at -34 dBFS, 8 s.
        let tone = dir.appendingPathComponent("tone.wav")
        if let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2),
           let file = try? AVAudioFile(forWriting: tone, settings: format.settings),
           let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 384_000) {
            buffer.frameLength = 384_000
            for i in 0..<384_000 {
                let v = Float(sin(2 * Double.pi * 1000 * Double(i) / 48_000) * 0.02)
                buffer.floatChannelData![0][i] = v
                buffer.floatChannelData![1][i] = v
            }
            try? file.write(from: buffer)
        }
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [tone.path]
        do { try player.run() } catch { say("afplay: \(error)"); return true }
        defer { player.terminate() }
        wait(0.8)
        guard let source = AudioProcessList.read().first(where: { $0.pid == player.processIdentifier })?.objectID else {
            say("no audio process for afplay"); return true
        }

        let direct = TapMeter(CATapDescription(stereoMixdownOfProcesses: [source]))
        wait(0.3); _ = direct.takeDB(); wait(0.8)
        let reference = direct.takeDB()
        direct.stop()
        say(String(format: "afplay alone: %.1f dBFS", reference ?? -999))

        let rig: VolumeRig
        do { rig = try VolumeRig(processes: [source], gain: VolumeCurve.gain(percent: 50)) } catch { say("rig: \(error)"); return true }
        wait(0.6)
        guard let own = AudioProcessList.read().first(where: { $0.pid == getpid() })?.objectID else {
            say("no audio process for Tutto"); rig.stop(); return true
        }
        let out = TapMeter(CATapDescription(stereoMixdownOfProcesses: [own]))
        wait(0.3); _ = out.takeDB(); wait(0.8)
        let half = out.takeDB()
        say(String(format: "through the rig at 50 %%: %.1f dBFS (expected about %.1f)", half ?? -999, (reference ?? 0) - 12.04))
        rig.setGain(VolumeCurve.gain(percent: 200))
        wait(0.3); _ = out.takeDB(); wait(0.8)
        let boosted = out.takeDB()
        say(String(format: "through the rig at 200 %%: %.1f dBFS (expected about %.1f)", boosted ?? -999, (reference ?? 0) + 6.02))
        out.stop()
        rig.stop()
        return true
    }
}
#endif

#if DEBUG
/// Every sample a tap delivers (first channel) with the host time of each buffer, for the glitch probe.
@available(macOS 14.2, *)
final class TapRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var samples: [Float] = []
    /// (index of the buffer's first sample, host time in seconds)
    private(set) var marks: [(Int, Double)] = []
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private(set) var status: OSStatus = noErr
    private(set) var sampleRate: Double = 48_000

    init(_ description: CATapDescription) {
        samples.reserveCapacity(48_000 * 12)
        description.uuid = UUID()
        description.isPrivate = true
        status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { return }
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format)
        if format.mSampleRate > 0 { sampleRate = format.mSampleRate }
        let channels = max(Int(format.mChannelsPerFrame), 1)
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Tutto probe recorder",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        status = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &device)
        guard status == noErr else { return }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = Double(timebase.numer) / Double(timebase.denom) / 1e9
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil) { [self] _, input, inputTime, _, _ in
            guard let buffer = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)).first,
                  let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return }
            let step = interleaved ? channels : 1
            let count = Int(buffer.mDataByteSize) / 4 / step
            let time = Double(inputTime.pointee.mHostTime) * ticks
            lock.lock()
            marks.append((samples.count, time))
            for i in 0..<count { samples.append(data[i * step]) }
            lock.unlock()
        }
        guard status == noErr else { return }
        status = AudioDeviceStart(device, proc)
    }

    func snapshot() -> (samples: [Float], marks: [(Int, Double)]) {
        lock.lock(); defer { lock.unlock() }
        return (samples, marks)
    }

    func stop() {
        if let proc { AudioDeviceStop(device, proc); AudioDeviceDestroyIOProcID(device, proc) }
        proc = nil
        if device != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(device) }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        device = AudioObjectID(kAudioObjectUnknown)
        tap = AudioObjectID(kAudioObjectUnknown)
    }

    /// Host time of the first sample at or after `from` whose level passes `threshold`.
    func firstSound(after from: Double, threshold: Float = 0.003) -> Double? {
        let (samples, marks) = snapshot()
        for (k, mark) in marks.enumerated() where mark.1 >= from {
            let end = k + 1 < marks.count ? marks[k + 1].0 : samples.count
            if let i = samples[mark.0..<end].firstIndex(where: { abs($0) > threshold }) {
                return mark.1 + Double(i - mark.0) / sampleRate
            }
        }
        return nil
    }
}

/// `Tutto --tone-player`: three one-second 1 kHz bursts with the output stopped in between
/// (how a browser pausing and playing behaves), for the glitch probe.
enum TonePlayer {
    static func runIfRequested() -> Bool {
        guard CommandLine.arguments.contains("--tone-player") else { return false }
        let engine = AVAudioEngine()
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        var phase = 0.0
        let source = AVAudioSourceNode { _, _, frames, list -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            for frame in 0..<Int(frames) {
                let value = Float(sin(phase) * 0.1)
                phase += 2 * .pi * 1000 / rate
                for buffer in buffers { buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = value }
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        for burst in 0..<3 {
            try? engine.start()
            Thread.sleep(forTimeInterval: 1.0)
            engine.stop()
            if burst < 2 { Thread.sleep(forTimeInterval: 1.5) }
        }
        return true
    }
}

/// `Tutto --volume-glitch-probe DIR`: a player with three bursts and stops in between, its sound
/// through a VolumeRig at 50 %, recorded from the player and from Tutto's own output. Reports
/// dropouts, clicks and level wobble while playing, and how long each new burst played before
/// Tutto's output had it (with "muted while read", the app is heard unprocessed for that long).
/// Run once per mute behavior. DIR/glitch.txt.
@available(macOS 14.2, *)
enum VolumeGlitchProbe {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--volume-glitch-probe"), args.count > flag + 1 else { return false }
        let dir = URL(fileURLWithPath: args[flag + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var lines: [String] = []
        func say(_ line: String) {
            lines.append(line)
            try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent("glitch.txt"), atomically: true, encoding: .utf8)
        }
        func wait(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        func now() -> Double {
            var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
            return Double(mach_absolute_time()) * Double(timebase.numer) / Double(timebase.denom) / 1e9
        }
        for (name, behavior) in [("muted while read (current)", CATapMuteBehavior.mutedWhenTapped), ("always muted", CATapMuteBehavior.muted)] {
            let player = Process()
            player.executableURL = URL(fileURLWithPath: Bundle.main.executablePath!)
            player.arguments = ["--tone-player"]
            do { try player.run() } catch { say("player: \(error)"); return true }
            let started = now()
            var source: AudioObjectID?
            for _ in 0..<40 where source == nil {
                wait(0.05)
                source = AudioProcessList.read().first(where: { $0.pid == player.processIdentifier })?.objectID
            }
            guard let source else { say("\(name): no audio process for the player"); player.terminate(); continue }
            let direct = TapRecorder(CATapDescription(stereoMixdownOfProcesses: [source]))
            let rig: VolumeRig
            do { rig = try VolumeRig(processes: [source], gain: VolumeCurve.gain(percent: 50), muteBehavior: behavior) }
            catch { say("\(name): rig \(error)"); player.terminate(); continue }
            wait(0.3)
            guard let own = AudioProcessList.read().first(where: { $0.pid == getpid() })?.objectID else {
                say("\(name): no audio process for Tutto"); rig.stop(); player.terminate(); continue
            }
            let out = TapRecorder(CATapDescription(stereoMixdownOfProcesses: [own]))
            // Bursts at about 0–1, 2.5–3.5 and 5–6 s after the player started; re-arm half a
            // second after each ends, as the Sound module does once the app goes quiet.
            for rearmAt in [1.6, 4.1] {
                let delay = started + rearmAt - now()
                if delay > 0 { wait(delay) }
                rig.rearm()
            }
            let end = started + 6.6 - now()
            if end > 0 { wait(end) }
            player.waitUntilExit()
            rig.stop()
            // Starts of bursts 2 and 3 (after a re-arm): when the player had sound, when Tutto's output did.
            for (k, from) in [(2, started + 2.0), (3, started + 4.5)] {
                if let a = direct.firstSound(after: from), let b = out.firstSound(after: from) {
                    say(String(format: "%@ · burst %d: Tutto's output began %.0f ms after the app's", name, k, (b - a) * 1000))
                } else {
                    say("\(name) · burst \(k): \(direct.firstSound(after: from) == nil ? "no sound from the app" : "no sound from Tutto")")
                }
            }
            // While playing: Tutto's output, 10 ms blocks, from 0.2 s into burst 3 for 0.6 s.
            let (samples, marks) = out.snapshot()
            if let start = out.firstSound(after: started + 4.5),
               let mark = marks.last(where: { $0.1 <= start + 0.2 }) {
                let rate = out.sampleRate
                let from = mark.0 + Int((start + 0.2 - mark.1) * rate)
                let to = min(from + Int(0.6 * rate), samples.count)
                if from >= 0, to > from {
                    let chunk = Array(samples[from..<to])
                    let block = Int(rate / 100)
                    var levels: [Float] = []
                    var index = 0
                    while index + block <= chunk.count {
                        let slice = chunk[index..<(index + block)]
                        levels.append(sqrt(slice.reduce(0) { $0 + $1 * $1 } / Float(block)))
                        index += block
                    }
                    let peak = chunk.map(abs).max() ?? 0
                    let jumps = zip(chunk, chunk.dropFirst()).filter { abs($1 - $0) > peak * 0.25 }.count
                    let silentBlocks = levels.filter { $0 < peak * 0.05 }.count
                    let mean = levels.reduce(0, +) / Float(max(levels.count, 1))
                    let spread = (levels.max() ?? 0) / max(levels.min() ?? 1, 1e-6)
                    say(String(format: "%@ · steady: level %.1f dBFS (expect about %.1f), dropouts %d of %d blocks, clicks %d, level spread %.2f×",
                               name, 20 * log10(Double(max(mean, 1e-9))), 20 * log10(0.1 / sqrt(2) * 0.25), silentBlocks, levels.count, jumps, spread))
                }
            }
            direct.stop()
            out.stop()
            wait(0.5)
        }
        return true
    }
}
#endif

#if DEBUG
/// `Tutto --sound-module-probe DIR PLAYER.app [scenario …]`: the real Sound module (its own
/// throwaway settings) with a test player app set to 25 %, through what people actually do:
/// a new player, pause and play, a player that restarts, the Mac's output switched and back,
/// the output's sample rate changed and back, a wake, and the level moved. Tutto's output is
/// recorded beside the player's own sound; every 100 ms of the player playing is checked:
/// applied (Tutto's output at the player's level × the gain), unapplied (Tutto silent, so the
/// player is heard as is), or off level. DIR/sound.txt. Output and rate are put back after.
/// The test player, opened through LaunchServices.
@MainActor
final class ProbePlayer {
    let app: NSRunningApplication
    private let wait: (Double) -> Void
    init(app: NSRunningApplication, wait: @escaping (Double) -> Void) { self.app = app; self.wait = wait }
    var processIdentifier: pid_t { app.processIdentifier }
    func waitUntilExit() { while !app.isTerminated { wait(0.05) } }
    func terminate() { app.terminate() }
}

@available(macOS 14.2, *)
@MainActor
enum SoundModuleProbe {
    static let playerID = "ca.bryanyao.TuttoProbePlayer"

    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--sound-module-probe"), args.count > flag + 2 else { return false }
        let dir = URL(fileURLWithPath: args[flag + 1], isDirectory: true)
        let playerApp = URL(fileURLWithPath: args[flag + 2])
        var only = Set(args.dropFirst(flag + 3))
        let noRestore = only.remove("norestore") != nil
        if only.remove("forcemuted") != nil { SoundModule.probeForceMuted = true }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var lines: [String] = []
        func say(_ line: String) {
            lines.append(line)
            try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent("sound.txt"), atomically: true, encoding: .utf8)
        }
        func wait(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        func now() -> Double {
            var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
            return Double(mach_absolute_time()) * Double(timebase.numer) / Double(timebase.denom) / 1e9
        }

        if noRestore { VolumeRig.restoresProcesses = false }
        say("process restore \(VolumeRig.restoresProcesses ? "on" : "off")")
        let suite = UserDefaults(suiteName: "ca.bryanyao.Tutto.soundprobe")!
        suite.removePersistentDomain(forName: "ca.bryanyao.Tutto.soundprobe")
        let module = SoundModule(defaults: suite)
        module.start()
        module.setVolume(playerID, 25)
        let originalOutput = AudioDevices.defaultOutputID()
        say("output: \(originalOutput.flatMap(AudioDevices.uid(of:)) ?? "?")")

        // Recording: Tutto's own output, and the player's (a new tap per player process).
        var players: [(pid: pid_t, recorder: TapRecorder)] = []
        var out: TapRecorder?
        var gainAt: [(Double, Double)] = [(0, 25)]  // (time, percent)

        /// Opened like any app, through `open` (so macOS lists it as running), with its script as
        /// arguments; the new instance is found by its bundle ID.
        func launch(_ script: [String]) -> ProbePlayer? {
            let before = Set(NSRunningApplication.runningApplications(withBundleIdentifier: playerID).map(\.processIdentifier))
            let opener = Process()
            opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            opener.arguments = ["-n", "-g", playerApp.path, "--args"] + script
            do { try opener.run() } catch { say("player: \(error)"); return nil }
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if let app = NSRunningApplication.runningApplications(withBundleIdentifier: playerID)
                    .first(where: { !before.contains($0.processIdentifier) && !$0.isTerminated }) {
                    return ProbePlayer(app: app, wait: wait)
                }
                wait(0.02)
            }
            say("player didn't start")
            return nil
        }
        /// Starts recording a player's sound once its audio process exists.
        func follow(_ player: ProbePlayer) {
            for _ in 0..<150 {
                if let object = AudioProcessList.read().first(where: { $0.pid == player.processIdentifier })?.objectID {
                    players.append((player.processIdentifier, TapRecorder(CATapDescription(stereoMixdownOfProcesses: [object]))))
                    if out == nil, let own = AudioProcessList.read().first(where: { $0.pid == getpid() })?.objectID {
                        out = TapRecorder(CATapDescription(stereoMixdownOfProcesses: [own]))
                    }
                    return
                }
                wait(0.02)
            }
            say("no audio process for the player")
        }
        func setLevel(_ percent: Double) {
            module.setVolume(playerID, percent)
            gainAt.append((now(), percent))
        }

        /// Every 100 ms of [from, to) in which the player had sound: was the level applied?
        func check(_ name: String, from: Double, to: Double) {
            guard let out else { say("\(name): Tutto's output wasn't recorded"); return }
            func rms(_ recorder: TapRecorder, _ t0: Double, _ t1: Double) -> Float? {
                let (samples, marks) = recorder.snapshot()
                var sum: Float = 0, n = 0
                for (k, mark) in marks.enumerated() {
                    let end = k + 1 < marks.count ? marks[k + 1].0 : samples.count
                    let count = end - mark.0
                    guard count > 0 else { continue }
                    let first = mark.1, last = mark.1 + Double(count) / recorder.sampleRate
                    guard last > t0, first < t1 else { continue }
                    for i in mark.0..<end {
                        let t = mark.1 + Double(i - mark.0) / recorder.sampleRate
                        if t >= t0 && t < t1 { sum += samples[i] * samples[i]; n += 1 }
                    }
                }
                return n > 0 ? sqrt(sum / Float(n)) : nil
            }
            var good = 0, silent = 0, off = 0, total = 0, longestSilent = 0, run = 0
            var offNotes: [String] = []
            var onsets: [String] = []
            var previous: Float = 0
            var t = from
            while t + 0.1 <= to {
                let source = players.compactMap { rms($0.recorder, t, t + 0.1) }.max() ?? 0
                let next = players.compactMap { rms($0.recorder, t + 0.1, t + 0.2) }.max() ?? 0
                defer { previous = source; t += 0.1 }
                guard source > 0.003 else { run = 0; continue }
                // A sound starting: how long until Tutto's output had it (or, at 100 %, nothing to do).
                if previous <= 0.003 {
                    let percent = gainAt.last(where: { $0.0 <= t })?.1 ?? 25
                    if percent != 100, let a = players.compactMap({ $0.recorder.firstSound(after: t - 0.1) }).min() {
                        if let b = out.firstSound(after: t - 0.1, threshold: 0.0005) {
                            onsets.append(String(format: "%.0f ms", max(0, (b - a) * 1000)))
                        } else {
                            onsets.append("never")
                        }
                    }
                    continue
                }
                // Windows at a start or end of sound, or 150 ms after a level change, aren't judged.
                if next <= 0.003 || abs(20 * log10(Double(max(next, 1e-6) / source))) > 3 { continue }
                if gainAt.contains(where: { $0.0 > t - 0.15 && $0.0 <= t + 0.1 }) { continue }
                let percent = gainAt.last(where: { $0.0 <= t })?.1 ?? 25
                total += 1
                let got = rms(out, t, t + 0.1) ?? 0
                if percent == 100 {
                    // No rig at 100 %: the app plays as is, and Tutto's output must be silent.
                    if got < source * 0.1 { good += 1 } else { off += 1 }
                    run = 0
                    continue
                }
                let expected = source * VolumeCurve.gain(percent: percent)
                if got < 0.0005 || got < expected * 0.1 {
                    silent += 1; run += 1; longestSilent = max(longestSilent, run)
                } else if abs(20 * log10(Double(got / max(expected, 1e-9)))) > 2 {
                    off += 1; run = 0
                    if offNotes.count < 3 { offNotes.append(String(format: "%.1f s: %+.1f dB", t - from, 20 * log10(Double(got / expected)))) }
                } else {
                    good += 1; run = 0
                }
            }
            let pct = { (n: Int) in total == 0 ? 0 : Int((Double(n) / Double(total) * 100).rounded()) }
            say("\(name): \(total) steady windows · right \(pct(good)) % · not through Tutto \(pct(silent)) % (longest \(longestSilent * 100) ms) · off level \(pct(off)) %\(offNotes.isEmpty ? "" : " (" + offNotes.joined(separator: ", ") + ")") · starts: \(onsets.isEmpty ? "–" : onsets.joined(separator: ", "))")
        }

        func scenario(_ name: String) -> Bool { only.isEmpty || only.contains(name) }

        // 1. A new player starts playing (the rig is made once its sound process appears).
        if scenario("new"), let player = launch(["play:3"]) {
            let start = now()
            follow(player)
            player.waitUntilExit()
            check("new player, 3 s", from: start, to: now())
        }
        // 2. Pause and play, three times (the same process stops and starts its output).
        if scenario("pause"), let player = launch(["play:1.5", "stop:1.5", "play:1.5", "stop:1.5", "play:1.5"]) {
            let start = now()
            follow(player)
            player.waitUntilExit()
            check("pause and play ×3", from: start + 1.5, to: now())
        }
        // 3. The output switched to another device and back while playing.
        if scenario("output"), let speakers = originalOutput, let speakersUID = AudioDevices.uid(of: speakers) {
            // Another real output (the built-in speakers, or whatever else plays), else a stand-in.
            var test = otherOutput(than: speakers) ?? AudioObjectID(kAudioObjectUnknown)
            var madeTest = false
            if test == kAudioObjectUnknown {
                let composition: [String: Any] = [
                    kAudioAggregateDeviceNameKey: "Tutto test output",
                    kAudioAggregateDeviceUIDKey: "ca.bryanyao.Tutto.testoutput.\(UUID().uuidString)",
                    kAudioAggregateDeviceMainSubDeviceKey: speakersUID,
                    kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: speakersUID]],
                ]
                madeTest = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &test) == noErr
            }
            say("other output: \(AudioDevices.uid(of: test) ?? "none")")
            if test != kAudioObjectUnknown, let player = launch(["play:7"]) {
                let start = now()
                follow(player)
                wait(1.5)
                say(String(format: "switch to the test output: %d", setDefaultOutput(test)))
                let switched = now()
                wait(2.5)
                say(String(format: "switch back: %d", setDefaultOutput(speakers)))
                let back = now()
                player.waitUntilExit()
                check("before the switch", from: start, to: switched)
                check("on the other output", from: switched, to: back)
                check("back on the first output", from: back, to: now())
                if madeTest { AudioHardwareDestroyAggregateDevice(test) }
            } else {
                say("no other output, or the player didn't start")
            }
            if let originalOutput, AudioDevices.defaultOutputID() != originalOutput { _ = setDefaultOutput(originalOutput) }
        }
        // 4. The output's sample rate changed and back (Bluetooth headsets and displays do this).
        if scenario("rate"), let current = originalOutput {
            // Bluetooth outputs won't change rate on request: use the built-in speakers then.
            let speakers = otherOutput(than: current).flatMap { setNominalRate($0, nominalRate($0) ?? 48_000) == noErr ? $0 : nil } ?? current
            if speakers != current { say(String(format: "rate test on %@: %d", AudioDevices.uid(of: speakers) ?? "?", setDefaultOutput(speakers))); wait(0.5) }
            let rate = nominalRate(speakers) ?? 48_000
            let other: Double = rate == 48_000 ? 44_100 : 48_000
            if let player = launch(["play:6"]) {
                let start = now()
                follow(player)
                wait(1.5)
                say(String(format: "rate %.0f → %.0f: %d", rate, other, setNominalRate(speakers, other)))
                let changed = now()
                wait(2)
                say(String(format: "rate back to %.0f: %d", rate, setNominalRate(speakers, rate)))
                let back = now()
                player.waitUntilExit()
                check("before the rate change", from: start, to: changed)
                check("at the other rate", from: changed, to: back)
                check("rate back", from: back, to: now())
            }
            if nominalRate(speakers) != rate { _ = setNominalRate(speakers, rate) }
            if speakers != current { _ = setDefaultOutput(current) }
        }
        // 9. A rig made "muted" while the app already plays (never starts by itself): the start
        // check must catch it and make it again.
        if scenario("stuck") {
            setLevel(100)
            if let player = launch(["play:4"]) {
                let start = now()
                follow(player)
                wait(1)
                SoundModule.probeForceMuted = true
                setLevel(25)
                player.waitUntilExit()
                check("stuck rig rescued", from: start + 1, to: now())
            }
            setLevel(25)
        }
        // 8. The common case: the app is open and quiet, then plays (its rig is already there).
        if scenario("open"), let player = launch(["stop:1.5", "play:2", "stop:1", "play:2"]) {
            let start = now()
            follow(player)
            player.waitUntilExit()
            check("open app starts playing", from: start, to: now())
        }
        // 5. The player restarts (a new process for the same app).
        if scenario("restart") {
            if let first = launch(["play:1.5"]) { follow(first); first.waitUntilExit() }
            wait(0.4)
            if let second = launch(["play:2.5"]) {
                let start = now()
                follow(second)
                second.waitUntilExit()
                check("player restarted (new process)", from: start, to: now())
            }
        }
        // 6. A wake from sleep while playing.
        if scenario("wake"), let player = launch(["play:4"]) {
            let start = now()
            follow(player)
            wait(1.5)
            module.simulateWake()
            player.waitUntilExit()
            check("wake while playing", from: start, to: now())
        }
        // 7. The level moved while playing: 60 %, 25 %, 100 % and back to 25 %, 200 %.
        if scenario("levels"), let player = launch(["play:6"]) {
            let start = now()
            follow(player)
            wait(1); setLevel(60)
            wait(1); setLevel(25)
            wait(1); setLevel(100)
            wait(1); setLevel(25)
            wait(1); setLevel(200)
            player.waitUntilExit()
            check("level moved while playing", from: start, to: now())
            setLevel(25)
        }
        players.forEach { $0.recorder.stop() }
        out?.stop()
        module.stop()
        if let originalOutput, AudioDevices.defaultOutputID() != originalOutput { _ = setDefaultOutput(originalOutput) }
        suite.removePersistentDomain(forName: "ca.bryanyao.Tutto.soundprobe")
        say("done; output \(AudioDevices.defaultOutputID().flatMap(AudioDevices.uid(of:)) ?? "?")")
        return true
    }

    /// An output device other than `device` that plays sound (built-in speakers first).
    static func otherOutput(than device: AudioObjectID) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids)
        let outputs = ids.filter { $0 != device && AudioDevices.streamCount(of: $0, scope: kAudioObjectPropertyScopeOutput) > 0 }
        func transport(_ id: AudioObjectID) -> UInt32 {
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
            return value
        }
        return outputs.first { transport($0) == kAudioDeviceTransportTypeBuiltIn } ?? outputs.first {
            transport($0) != kAudioDeviceTransportTypeAggregate && transport($0) != kAudioDeviceTransportTypeVirtual
        }
    }

    static func setDefaultOutput(_ device: AudioObjectID) -> OSStatus {
        var value = device
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &value)
    }

    static func nominalRate(_ device: AudioObjectID) -> Double? {
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr ? rate : nil
    }

    static func setNominalRate(_ device: AudioObjectID, _ rate: Double) -> OSStatus {
        var value = Float64(rate)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float64>.size), &value)
    }
}
#endif

#if DEBUG
/// `Tutto --live-volume-check DIR BUNDLEID PERCENT`: records an app's own sound and the installed
/// Tutto's output for 5 s and says whether its level is applied (Tutto's level ÷ the app's).
@available(macOS 14.2, *)
enum LiveVolumeCheck {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--live-volume-check"), args.count > flag + 3,
              let percent = Double(args[flag + 3]) else { return false }
        let dir = URL(fileURLWithPath: args[flag + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var lines: [String] = []
        func say(_ line: String) {
            lines.append(line)
            try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent("live.txt"), atomically: true, encoding: .utf8)
        }
        let bundleID = args[flag + 2]
        let processes = AudioProcessList.read()
        let app = processes.filter { $0.bundleID == bundleID }.map(\.objectID)
        let tuttoPID = NSRunningApplication.runningApplications(withBundleIdentifier: "ca.bryanyao.Tutto")
            .first { $0.processIdentifier != getpid() }?.processIdentifier
        guard !app.isEmpty, let tuttoPID, let tutto = processes.first(where: { $0.pid == tuttoPID })?.objectID else {
            say("not found: app processes \(app.count), Tutto \(tuttoPID.map(String.init) ?? "none")"); return true
        }
        let direct = TapMeter(CATapDescription(stereoMixdownOfProcesses: app))
        let out = TapMeter(CATapDescription(stereoMixdownOfProcesses: [tutto]))
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        _ = direct.takeDB(); _ = out.takeDB()
        var rows: [String] = []
        for _ in 0..<10 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            let a = direct.takeDB() ?? -999, b = out.takeDB() ?? -999
            rows.append(String(format: "%.1f/%.1f", a, b))
        }
        let expected = 20 * log10(Double(VolumeCurve.gain(percent: percent)))
        say("app dBFS / Tutto dBFS every 0.5 s: \(rows.joined(separator: "  "))")
        say(String(format: "expected Tutto = app %+.1f dB", expected))
        direct.stop(); out.stop()
        return true
    }
}
#endif
