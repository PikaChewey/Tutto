//
//  AwakeCore.swift
//  Tutto
//
//  Stay Awake's root half: keeps the Mac from sleeping, lid closed included, until a deadline,
//  turns on Low Power Mode for the battery while the lid is shut, and puts back exactly what it
//  changed. TuttoHelper runs it as root; tests drive it with a fake `pmset` and fake processes.
//
//  Everything it is about to change goes into a journal first, and an entry leaves the journal
//  only once it has been undone, so a helper that is killed half way finds its work at the next
//  start. It only undoes its own changes: a SleepDisabled that was already on, or a battery Low
//  Power Mode that was already on, is left as it was found.
//
//  This file is compiled into BOTH TuttoKit and TuttoHelper (symlink in
//  Sources/TuttoHelper/Shared/). Keep it Foundation-only.
//

import Foundation

public enum AwakeLimits {
    /// The longest session. The helper caps any deadline it's given at this much from now.
    public static let longest: TimeInterval = 7 * 86_400
    /// The helper ends a session this long after the app's own end, in case the app is hung.
    public static let grace: TimeInterval = 60
    /// Unattended (no app connected), the helper ends the session below this charge on battery.
    public static let unattendedBatteryFloor = 5
}

// MARK: - pmset output

public enum PMSetOutput {
    /// `SleepDisabled` from `pmset -g` (the "System-wide power settings:" block). Nil when it's
    /// not there.
    public static func sleepDisabled(_ text: String) -> Bool? {
        for line in text.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 2, parts[0] == "SleepDisabled", let value = Int(parts[1]) { return value != 0 }
        }
        return nil
    }

    /// `lowpowermode` per power source, from `pmset -g custom`.
    public static func lowPowerModes(_ text: String) -> (battery: Int?, ac: Int?) {
        var battery: Int?, ac: Int?
        var section = ""
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix(":") && !line.hasPrefix(" ") {
                section = trimmed
                continue
            }
            let parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2, parts[0] == "lowpowermode", let value = Int(parts[1]) else { continue }
            switch section {
            case "Battery Power:": battery = value
            case "AC Power:": ac = value
            default: break
            }
        }
        return (battery, ac)
    }
}

// MARK: - What the controller acts on

/// Runs `/usr/bin/pmset` with these arguments. The real one is `SystemPMSet`.
protocol PowerCommands: AnyObject {
    func pmset(_ arguments: [String]) -> (status: Int32, output: String)
}

/// A process Stay Awake paused (SIGSTOP), identified by its start time and owner as well as
/// its pid, so a pid the system has since given to another process is never signalled.
public struct PausedProcess: Codable, Equatable, Hashable, Sendable {
    public var pid: Int32
    /// Seconds since 1970, from the kernel (`p_starttime`).
    public var startTime: Double
    public var uid: UInt32

    public init(pid: Int32, startTime: Double, uid: UInt32) {
        self.pid = pid
        self.startTime = startTime
        self.uid = uid
    }
}

/// Process lookups and signals. The real one is `SystemProcesses`.
protocol ProcessSignals: AnyObject {
    /// The start time and owner of a live pid, or nil when it's gone.
    func identity(of pid: Int32) -> (startTime: Double, uid: UInt32)?
    func send(_ signal: Int32, to pid: Int32) -> Bool
}

/// What the helper changed and has yet to put back. Written before each change.
struct AwakeJournal: Codable, Equatable {
    var deadline: Date
    /// SleepDisabled was off and Stay Awake turned it on.
    var sleepDisabledByUs: Bool
    /// The battery profile's `lowpowermode` before Stay Awake turned it on; nil when it hasn't.
    var lowPowerBefore: Int?
    /// Processes the app paused, so the helper can resume them if the app goes away.
    var paused: [PausedProcess]
    /// An end was asked for and hasn't finished (a restore failed): retried until it does.
    var ending: Bool? = nil
}

public struct AwakeResult: Equatable, Sendable {
    public var status: Int32
    public var message: String?

    public static let ok = AwakeResult(status: FanStatus.success, message: nil)
    static func failed(_ message: String, _ status: Int32 = FanStatus.error) -> AwakeResult {
        AwakeResult(status: status, message: message)
    }
    public var succeeded: Bool { status == FanStatus.success }
}

// MARK: - Controller

/// Not thread-safe: TuttoHelper calls it from one serial queue.
final class AwakeController {
    private let commands: PowerCommands
    private let processes: ProcessSignals
    private let journalURL: URL
    private let now: () -> Date

    private(set) var journal: AwakeJournal?

    init(commands: PowerCommands, processes: ProcessSignals, journalURL: URL, now: @escaping () -> Date = Date.init) {
        self.commands = commands
        self.processes = processes
        self.journalURL = journalURL
        self.now = now
        if let data = try? Data(contentsOf: journalURL) {
            journal = try? JSONDecoder().decode(AwakeJournal.self, from: data)
        }
    }

    var isActive: Bool { journal != nil }
    /// An end is under way and still owes a restore.
    var isEnding: Bool { journal?.ending == true }
    var deadline: Date? { journal?.deadline }
    var lowPowerClaimed: Bool { journal?.lowPowerBefore != nil }

    /// Starts a session, or moves the end of the one running.
    func begin(until requested: Date) -> AwakeResult {
        let deadline = min(requested, now().addingTimeInterval(AwakeLimits.longest))
        guard deadline > now() else { return .failed("That end time has already passed.", FanStatus.badArgument) }
        if var journal {
            journal.deadline = deadline
            journal.ending = nil  // a new session takes over one still being ended
            return save(journal)
        }
        let state = commands.pmset(["-g"])
        guard state.status == 0, let alreadyOff = PMSetOutput.sleepDisabled(state.output) else {
            return .failed("Couldn't read the sleep setting (pmset -g exited \(state.status)).")
        }
        let fresh = AwakeJournal(deadline: deadline, sleepDisabledByUs: !alreadyOff, lowPowerBefore: nil, paused: [])
        let saved = save(fresh)
        guard saved.succeeded else { return saved }
        guard !alreadyOff else { return .ok }  // something else already keeps the Mac awake; leave it to them
        let result = commands.pmset(["-a", "disablesleep", "1"])
        guard result.status == 0 else {
            removeJournal()
            return .failed("macOS refused to keep the Mac awake (pmset exited \(result.status)).")
        }
        return .ok
    }

    /// Low Power Mode for the battery on (lid closed, low battery, heat) or back as it was.
    func setLowPower(_ on: Bool) -> AwakeResult {
        guard var journal else { return .failed("No session is running.", FanStatus.notPermitted) }
        if on {
            guard journal.lowPowerBefore == nil else { return .ok }
            let custom = commands.pmset(["-g", "custom"])
            guard custom.status == 0, let before = PMSetOutput.lowPowerModes(custom.output).battery else {
                return .failed("Couldn't read Low Power Mode (pmset -g custom exited \(custom.status)).")
            }
            journal.lowPowerBefore = before
            let saved = save(journal)
            guard saved.succeeded else { return saved }
            guard before != 1 else { return .ok }
            let result = commands.pmset(["-b", "lowpowermode", "1"])
            if result.status != 0 {
                journal.lowPowerBefore = nil
                _ = save(journal)
                return .failed("macOS refused Low Power Mode (pmset exited \(result.status)).")
            }
            return .ok
        }
        guard let before = journal.lowPowerBefore else { return .ok }
        if before != 1 {
            let result = commands.pmset(["-b", "lowpowermode", "\(before)"])
            guard result.status == 0 else {
                return .failed("Couldn't put Low Power Mode back (pmset exited \(result.status)).")
            }
        }
        journal.lowPowerBefore = nil
        return save(journal)
    }

    /// The processes the app has paused. Only the caller's own processes, as they are now, are
    /// kept: a pid that's gone or belongs to someone else is dropped.
    func setPaused(_ list: [PausedProcess], ownedBy uid: UInt32) -> AwakeResult {
        guard var journal else { return list.isEmpty ? .ok : .failed("No session is running.", FanStatus.notPermitted) }
        journal.paused = list.filter { process in
            guard process.uid == uid, let identity = processes.identity(of: process.pid) else { return false }
            return identity.uid == uid && abs(identity.startTime - process.startTime) < 0.001
        }
        return save(journal)
    }

    /// SIGCONT for every journaled process that is still the one that was paused. Returns how
    /// many were resumed.
    @discardableResult
    func resumePaused() -> Int {
        guard var journal, !journal.paused.isEmpty else { return 0 }
        var resumed = 0
        for process in journal.paused {
            guard let identity = processes.identity(of: process.pid),
                  identity.uid == process.uid, abs(identity.startTime - process.startTime) < 0.001 else { continue }
            if processes.send(SIGCONT, to: process.pid) { resumed += 1 }
        }
        journal.paused = []
        _ = save(journal)
        return resumed
    }

    /// Ends the session: paused processes resumed, Low Power Mode and sleep put back. The journal
    /// goes once all of it has; on a failure what's left stays journaled for the next try.
    func end() -> AwakeResult {
        guard var ending = journal else { return .ok }
        if ending.ending != true {
            ending.ending = true
            _ = save(ending)
        }
        resumePaused()
        let lowPower = setLowPower(false)
        guard var journal else { return lowPower }
        if journal.sleepDisabledByUs {
            let result = commands.pmset(["-a", "disablesleep", "0"])
            guard result.status == 0 else {
                return .failed("Couldn't let the Mac sleep again (pmset exited \(result.status)); trying again shortly.")
            }
            journal.sleepDisabledByUs = false
            _ = save(journal)
        }
        guard lowPower.succeeded else { return lowPower }
        removeJournal()
        return .ok
    }

    /// True when the session's time (plus the app's grace) is up.
    func isOverdue(graceAfterDeadline grace: TimeInterval = AwakeLimits.grace) -> Bool {
        guard let deadline else { return false }
        return now() >= deadline.addingTimeInterval(grace)
    }

    // MARK: Journal

    private func save(_ journal: AwakeJournal) -> AwakeResult {
        do {
            let directory = journalURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(journal).write(to: journalURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
            self.journal = journal
            return .ok
        } catch {
            return .failed("Couldn't write the session journal: \(error.localizedDescription)")
        }
    }

    private func removeJournal() {
        try? FileManager.default.removeItem(at: journalURL)
        journal = nil
    }
}

// MARK: - The real pmset and processes

final class SystemPMSet: PowerCommands {
    /// pmset normally answers at once; this only guards against a hang.
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 15) { self.timeout = timeout }

    func pmset(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // Both set up before the run: a pmset that exits at once must still be seen, and the
        // output is read on its own so a hung pmset can't block the timeout.
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        let output = OutputBox()
        let read = DispatchSemaphore(value: 0)
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        DispatchQueue.global(qos: .utility).async {
            output.data = pipe.fileHandleForReading.readDataToEndOfFile()
            read.signal()
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return (-2, "pmset timed out")
        }
        _ = read.wait(timeout: .now() + 2)
        return (process.terminationStatus, String(decoding: output.data, as: UTF8.self))
    }

    private final class OutputBox: @unchecked Sendable {
        var data = Data()
    }
}

public final class SystemProcesses: ProcessSignals {
    public init() {}

    public func identity(of pid: Int32) -> (startTime: Double, uid: UInt32)? {
        Self.identity(of: pid)
    }

    func send(_ signal: Int32, to pid: Int32) -> Bool {
        pid > 1 && kill(pid, signal) == 0
    }

    /// From `sysctl(KERN_PROC_PID)`: when the process started and whose it is.
    public static func identity(of pid: Int32) -> (startTime: Double, uid: UInt32)? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let start = info.kp_proc.p_starttime
        return (Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000, info.kp_eproc.e_ucred.cr_uid)
    }
}
