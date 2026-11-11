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
private final class TapMeter: @unchecked Sendable {
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
