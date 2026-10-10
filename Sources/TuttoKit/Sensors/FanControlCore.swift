//
//  FanControlCore.swift
//  Tutto
//
//  Fan key names, SMC value encoding, and the write sequence TuttoHelper runs as root.
//
//  This file is compiled into BOTH TuttoKit (where tests drive it with a fake SMC) and
//  TuttoHelper (where it drives the real one), via a symlink in Sources/TuttoHelper/Shared/.
//  Keep it Foundation-only.
//

import Foundation

// MARK: - Status codes

/// IOKit `IOReturn` values used across the helper boundary. IOReturn.h defines them
/// with function-like macros, which Swift does not import.
public enum FanStatus {
    public static let success: Int32 = 0
    public static let error = Int32(bitPattern: 0xe000_02bc)          // kIOReturnError
    public static let notPrivileged = Int32(bitPattern: 0xe000_02c1)  // kIOReturnNotPrivileged
    public static let badArgument = Int32(bitPattern: 0xe000_02c2)    // kIOReturnBadArgument
    public static let unsupported = Int32(bitPattern: 0xe000_02c7)    // kIOReturnUnsupported
    public static let notOpen = Int32(bitPattern: 0xe000_02cd)        // kIOReturnNotOpen
    public static let timeout = Int32(bitPattern: 0xe000_02d6)        // kIOReturnTimeout
    public static let notPermitted = Int32(bitPattern: 0xe000_02e2)   // kIOReturnNotPermitted
    public static let notFound = Int32(bitPattern: 0xe000_02f0)       // kIOReturnNotFound

    public static func describe(_ status: Int32) -> String {
        switch status {
        case success: return "success"
        case notPrivileged: return "not privileged (SMC writes need root)"
        case badArgument: return "bad argument"
        case unsupported: return "unsupported on this Mac"
        case notOpen: return "SMC not available"
        case timeout: return "timed out"
        case notPermitted: return "not permitted"
        case notFound: return "SMC key not found"
        case error: return "SMC rejected the write"
        default: return String(format: "IOReturn 0x%08x", UInt32(bitPattern: status))
        }
    }
}

// MARK: - SMC access

/// A raw SMC value: its four-character type ("flt ", "ui8 ", "fpe2" …) and bytes.
public struct SMCRawValue: Equatable, Sendable {
    public var type: String
    public var bytes: [UInt8]

    public init(type: String, bytes: [UInt8]) {
        self.type = type
        self.bytes = bytes
    }

    /// The value as a number, for the types fans and temperatures use. Nil for other types
    /// and for non-finite floats.
    public var doubleValue: Double? { FanSMC.decode(self) }
}

/// What the fan logic needs from the SMC. `SMCDevice` is the real one; tests use fakes.
protocol SMCAccess: AnyObject {
    /// Nil when the key does not exist on this Mac.
    func read(_ key: String) -> SMCRawValue?
    /// Returns an IOReturn (0 = success).
    func write(_ key: String, _ bytes: [UInt8]) -> Int32
}

// MARK: - Keys and encoding

public enum FanSMC {
    /// Number of fans (`ui8`).
    public static let countKey = "FNum"
    /// Older Apple silicon (M1–M4 on recent firmware) must set this to 1 before the mode
    /// key accepts "manual". It does not exist on the M5.
    public static let unlockKey = "Ftst"
    /// Fan keys have a single-digit index.
    public static let maxFans = 10

    public static func actualKey(_ fan: Int) -> String { "F\(fan)Ac" }
    public static func minimumKey(_ fan: Int) -> String { "F\(fan)Mn" }
    public static func maximumKey(_ fan: Int) -> String { "F\(fan)Mx" }
    public static func targetKey(_ fan: Int) -> String { "F\(fan)Tg" }

    /// Mode key candidates in order of preference: lowercase `F0md` (M5 and some
    /// earlier Apple silicon), then `F0Md` (older Apple silicon and T2 Intel Macs).
    public static func modeKeyCandidates(_ fan: Int) -> [String] { ["F\(fan)md", "F\(fan)Md"] }

    /// The mode key that exists for this fan, probed with `keyExists`, or nil.
    public static func modeKey(for fan: Int, keyExists: (String) -> Bool) -> String? {
        guard (0..<maxFans).contains(fan) else { return nil }
        return modeKeyCandidates(fan).first(where: keyExists)
    }

    /// Clamps an RPM into [minimum, maximum]. Infinite values pin to the nearest end.
    /// Returns nil for NaN or an empty range.
    public static func clamp(_ rpm: Double, minimum: Double, maximum: Double) -> Double? {
        guard !rpm.isNaN, minimum.isFinite, maximum.isFinite, minimum <= maximum else { return nil }
        return Swift.min(Swift.max(rpm, minimum), maximum)
    }

    /// Encodes an RPM for a key of the given SMC type and size: `flt ` is a little-endian
    /// IEEE-754 float (Apple silicon), `fpe2` is big-endian unsigned 14.2 fixed point (Intel).
    public static func encode(rpm: Double, type: String, size: Int) -> [UInt8]? {
        guard rpm.isFinite, rpm >= 0 else { return nil }
        switch type {
        case "flt ":
            guard size == 4 else { return nil }
            let bits = Float(rpm).bitPattern.littleEndian
            return withUnsafeBytes(of: bits) { Array($0) }
        case "fpe2":
            guard size == 2, rpm <= 16383.75 else { return nil }
            let raw = UInt16((rpm * 4).rounded())
            return [UInt8(raw >> 8), UInt8(raw & 0xff)]
        default:
            return nil
        }
    }

    /// Decodes the numeric SMC types used by fans and temperatures.
    public static func decode(_ value: SMCRawValue) -> Double? {
        let b = value.bytes
        switch value.type {
        case "flt ":
            guard b.count >= 4 else { return nil }
            let bits = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
            let f = Float(bitPattern: bits)
            return f.isFinite ? Double(f) : nil
        case "fpe2":
            guard b.count >= 2 else { return nil }
            return Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4
        case "sp78":
            guard b.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256
        case "ui8 ":
            guard b.count >= 1 else { return nil }
            return Double(b[0])
        case "ui16":
            guard b.count >= 2 else { return nil }
            return Double(UInt16(b[0]) << 8 | UInt16(b[1]))
        case "ui32":
            guard b.count >= 4 else { return nil }
            return Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        case "si8 ":
            guard b.count >= 1 else { return nil }
            return Double(Int8(bitPattern: b[0]))
        case "si16":
            guard b.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1])))
        default:
            return nil
        }
    }

    /// A one-byte value padded to the key's size (mode and unlock keys are `ui8`).
    static func byteValue(_ value: UInt8, size: Int) -> [UInt8] {
        [value] + [UInt8](repeating: 0, count: Swift.max(0, size - 1))
    }
}

// MARK: - Write sequence (runs as root inside TuttoHelper)

/// Puts fans into manual mode at a target RPM, and back to automatic.
///
/// Sequence (the known-good write order for Apple silicon SMCs):
/// - Manual: write mode key = 1. On M5 this works directly. If it fails and `Ftst`
///   exists (M3/M4), write `Ftst` = 1, wait about 3 s for thermalmonitord to yield,
///   then retry the mode write. Then write the target (`F<n>Tg`) clamped to [Mn, Mx].
/// - Automatic: write mode key = 0 and, on Apple silicon (`flt` target), target = 0.
///   Once no fan is manual, clear `Ftst` if it exists and is set.
///
/// Not thread-safe: TuttoHelper calls it from one serial queue.
final class FanController {
    struct Result: Equatable {
        var status: Int32
        var message: String?

        static let ok = Result(status: FanStatus.success, message: nil)
    }

    private let smc: SMCAccess
    private let pause: (TimeInterval) -> Void

    /// Fans this controller has put in manual mode and not yet released.
    private(set) var manualFans = Set<Int>()

    init(smc: SMCAccess, pause: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.smc = smc
        self.pause = pause
    }

    var fanCount: Int {
        let count = Int(smc.read(FanSMC.countKey)?.doubleValue ?? 0)
        return Swift.min(Swift.max(count, 0), FanSMC.maxFans)
    }

    func modeKey(for fan: Int) -> String? {
        FanSMC.modeKey(for: fan, keyExists: { smc.read($0) != nil })
    }

    /// `mode` 0 = automatic, 1 = manual at `rpm` (clamped to the fan's range).
    func setFan(_ fan: Int, mode: Int, rpm: Double) -> Result {
        let count = fanCount
        guard (0..<count).contains(fan) else {
            return Result(status: FanStatus.badArgument, message: "No fan \(fan); this Mac reports \(count).")
        }
        switch mode {
        case TuttoFanHelper.modeAutomatic: return setAutomatic(fan)
        case TuttoFanHelper.modeManual: return setManual(fan, rpm: rpm)
        default: return Result(status: FanStatus.badArgument, message: "Unknown fan mode \(mode).")
        }
    }

    /// Every fan back to automatic. Returns the first failure, or success.
    @discardableResult
    func resetAll() -> Int32 {
        var first = FanStatus.success
        for fan in 0..<fanCount {
            let result = setAutomatic(fan)
            if first == FanStatus.success { first = result.status }
        }
        // Also clears an Ftst left set by an earlier helper instance that crashed.
        let cleared = clearUnlockIfIdle()
        return first == FanStatus.success ? cleared : first
    }

    /// True when no fan is in manual mode (by this controller or according to the SMC).
    var allAutomatic: Bool {
        guard manualFans.isEmpty else { return false }
        for fan in 0..<fanCount {
            if let key = modeKey(for: fan), smc.read(key)?.bytes.first == 1 { return false }
        }
        return true
    }

    // MARK: Manual

    private func setManual(_ fan: Int, rpm: Double) -> Result {
        guard !rpm.isNaN else { return Result(status: FanStatus.badArgument, message: "RPM is not a number.") }
        guard let modeKey = modeKey(for: fan) else {
            return Result(status: FanStatus.unsupported, message: "Fan \(fan) has no mode key (F\(fan)md / F\(fan)Md).")
        }
        guard let minimum = smc.read(FanSMC.minimumKey(fan))?.doubleValue,
              let maximum = smc.read(FanSMC.maximumKey(fan))?.doubleValue,
              maximum > 0,
              let clamped = FanSMC.clamp(rpm, minimum: minimum, maximum: maximum)
        else {
            return Result(status: FanStatus.unsupported, message: "Fan \(fan) has no readable min/max speed.")
        }
        let targetKey = FanSMC.targetKey(fan)
        guard let target = smc.read(targetKey),
              let bytes = FanSMC.encode(rpm: clamped, type: target.type, size: target.bytes.count)
        else {
            return Result(status: FanStatus.unsupported, message: "\(targetKey) has an unsupported type.")
        }

        let unlocked = unlockManualMode(fan, modeKey: modeKey)
        guard unlocked == FanStatus.success else {
            _ = clearUnlockIfIdle()  // do not leave Ftst set after a failed attempt
            return Result(status: unlocked, message: "Could not switch fan \(fan) to manual: \(FanStatus.describe(unlocked)).")
        }
        manualFans.insert(fan)

        let written = writeWithRetry(targetKey, bytes, attempts: 10, delay: 0.05)
        guard written == FanStatus.success else {
            _ = setAutomatic(fan)  // never leave a fan manual at an unknown speed
            return Result(status: written, message: "Could not set fan \(fan) speed: \(FanStatus.describe(written)).")
        }
        return .ok
    }

    private func unlockManualMode(_ fan: Int, modeKey: String) -> Int32 {
        guard let current = smc.read(modeKey) else { return FanStatus.notFound }
        if current.bytes.first == 1 { return FanStatus.success }
        let manual = FanSMC.byteValue(1, size: current.bytes.count)

        let direct = smc.write(modeKey, manual)
        // Without root nothing below can succeed either, so report it as is.
        if direct == FanStatus.success || direct == FanStatus.notPrivileged { return direct }

        guard let unlock = smc.read(FanSMC.unlockKey) else { return direct }
        if unlock.bytes.first != 1 {
            let status = writeWithRetry(FanSMC.unlockKey, FanSMC.byteValue(1, size: unlock.bytes.count), attempts: 20, delay: 0.05)
            guard status == FanStatus.success else { return status }
            pause(3)  // thermalmonitord needs a moment to hand over
        }
        return writeWithRetry(modeKey, manual, attempts: 100, delay: 0.1)
    }

    // MARK: Automatic

    /// Resets a fan that this controller put in manual mode or that the SMC reports as
    /// manual (mode 1). A fan already on automatic is left untouched: no writes.
    private func setAutomatic(_ fan: Int) -> Result {
        let modeKey = modeKey(for: fan)
        let mode = modeKey.flatMap { smc.read($0) }
        var status = FanStatus.success

        if manualFans.contains(fan) || mode?.bytes.first == 1 {
            if let modeKey, let mode, mode.bytes.first != 0 {
                status = writeWithRetry(modeKey, FanSMC.byteValue(0, size: mode.bytes.count), attempts: 10, delay: 0.05)
            }
            // Apple silicon: drop the manual target too (Intel's fpe2 target is owned by the SMC).
            let targetKey = FanSMC.targetKey(fan)
            if let target = smc.read(targetKey), target.type == "flt ", target.doubleValue != 0,
               let zero = FanSMC.encode(rpm: 0, type: target.type, size: target.bytes.count) {
                let cleared = writeWithRetry(targetKey, zero, attempts: 10, delay: 0.05)
                if status == FanStatus.success { status = cleared }
            }
            if status == FanStatus.success {
                manualFans.remove(fan)
                status = clearUnlockIfIdle()
            }
        }
        return status == FanStatus.success
            ? .ok
            : Result(status: status, message: "Could not return fan \(fan) to automatic: \(FanStatus.describe(status)).")
    }

    /// Clears `Ftst` once no fan is manual (only where the key exists and is set).
    private func clearUnlockIfIdle() -> Int32 {
        guard manualFans.isEmpty, let unlock = smc.read(FanSMC.unlockKey), unlock.bytes.first == 1 else {
            return FanStatus.success
        }
        return writeWithRetry(FanSMC.unlockKey, FanSMC.byteValue(0, size: unlock.bytes.count), attempts: 10, delay: 0.05)
    }

    private func writeWithRetry(_ key: String, _ bytes: [UInt8], attempts: Int, delay: TimeInterval) -> Int32 {
        var status = FanStatus.error
        for attempt in 0..<Swift.max(1, attempts) {
            status = smc.write(key, bytes)
            if status == FanStatus.success || status == FanStatus.notPrivileged { return status }
            if attempt < attempts - 1 { pause(delay) }
        }
        return status
    }
}
