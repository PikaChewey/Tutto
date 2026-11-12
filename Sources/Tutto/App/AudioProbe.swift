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
        default:
            say("unknown command")
        }
        say("done")
        return true
    }

    private static func others(than pid: pid_t, in processes: [AudioProcess]) -> [NSNumber] {
        processes.filter { $0.pid != pid }.map { NSNumber(value: $0.objectID) }
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
