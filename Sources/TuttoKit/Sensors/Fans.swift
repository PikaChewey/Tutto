//
//  Fans.swift
//  Tutto
//
//  Fan readings from the SMC (no root needed) and the commands the app sends to
//  TuttoHelper to change them.
//

import Foundation

/// Who is driving the fan.
public enum FanMode: String, Sendable, Codable {
    /// The system controls the speed. Includes SMC mode 3 ("system", thermal mitigation).
    case auto
    /// Forced to a target speed (by Tutto or another fan utility).
    case manual
    /// No mode key, or a mode value we do not recognise.
    case unknown

    /// Maps the raw SMC mode byte (`F<n>md` / `F<n>Md`).
    public init(smcMode: UInt8?) {
        switch smcMode {
        case 0, 3: self = .auto
        case 1: self = .manual
        default: self = .unknown
        }
    }
}

public struct FanReading: Identifiable, Sendable, Equatable {
    public var id: Int { index }
    public let index: Int
    /// Measured speed. 0 when the fan is stopped (Apple silicon fans stop when cool).
    public let currentRPM: Double
    public let minRPM: Double
    public let maxRPM: Double
    /// The SMC's target speed, or nil if this Mac has no target key. 0 on automatic
    /// when the system has the fan stopped.
    public let targetRPM: Double?
    public let mode: FanMode

    public init(index: Int, currentRPM: Double, minRPM: Double, maxRPM: Double, targetRPM: Double?, mode: FanMode) {
        self.index = index
        self.currentRPM = currentRPM
        self.minRPM = minRPM
        self.maxRPM = maxRPM
        self.targetRPM = targetRPM
        self.mode = mode
    }

    public var isStopped: Bool { currentRPM < 1 }

    /// Current speed as a fraction of the fan's range: 0 at or below min, 1 at max.
    public var fractionOfRange: Double {
        guard maxRPM > minRPM else { return 0 }
        return min(max((currentRPM - minRPM) / (maxRPM - minRPM), 0), 1)
    }
}

public enum Fans {
    /// Number of fans the SMC reports (`FNum`). 0 on fanless Macs.
    public static var count: Int { count(using: SMCDevice.shared) }

    /// Reads every fan. Empty on fanless Macs or when there is no SMC.
    public static func read() -> [FanReading] { read(using: SMCDevice.shared) }

    /// The mode key that exists for this fan (`F0md` on M5, `F0Md` on older Macs), or nil.
    public static func modeKey(for index: Int) -> String? {
        FanSMC.modeKey(for: index, keyExists: { SMCDevice.shared.read($0) != nil })
    }

    // MARK: Testable core

    static func count(using smc: SMCAccess) -> Int {
        let raw = Int(smc.read(FanSMC.countKey)?.doubleValue ?? 0)
        return min(max(raw, 0), FanSMC.maxFans)
    }

    static func read(using smc: SMCAccess) -> [FanReading] {
        (0..<count(using: smc)).compactMap { index in
            guard let minimum = smc.read(FanSMC.minimumKey(index))?.doubleValue,
                  let maximum = smc.read(FanSMC.maximumKey(index))?.doubleValue
            else { return nil }
            let current = smc.read(FanSMC.actualKey(index))?.doubleValue ?? 0
            let target = smc.read(FanSMC.targetKey(index))?.doubleValue
            let modeKey = FanSMC.modeKey(for: index, keyExists: { smc.read($0) != nil })
            let mode: FanMode
            if let modeKey {
                mode = FanMode(smcMode: smc.read(modeKey)?.bytes.first)
            } else if let forced = smc.read("FS! "), forced.bytes.count >= 2 {
                // Intel without a per-fan mode key: one "forced" bit per fan.
                let mask = UInt16(forced.bytes[0]) << 8 | UInt16(forced.bytes[1])
                mode = mask & (1 << index) != 0 ? .manual : .auto
            } else {
                mode = .unknown
            }
            return FanReading(index: index, currentRPM: max(current, 0), minRPM: minimum, maxRPM: maximum,
                              targetRPM: target, mode: mode)
        }
    }
}

/// What the user asked a fan to do. The app turns it into a `setFan` call on the helper.
public enum FanCommand: Codable, Sendable, Equatable {
    case auto
    case rpm(Double)
    case maximum

    /// The command with any RPM clamped into [minRPM, maxRPM]. A NaN speed, or a fan
    /// without a usable range, falls back to `.auto`, which is always safe.
    public func clamped(minRPM: Double, maxRPM: Double) -> FanCommand {
        switch self {
        case .auto, .maximum:
            return self
        case .rpm(let rpm):
            guard let value = FanSMC.clamp(rpm, minimum: minRPM, maximum: maxRPM), maxRPM > 0 else { return .auto }
            return .rpm(value)
        }
    }

    public func clamped(for fan: FanReading) -> FanCommand { clamped(minRPM: fan.minRPM, maxRPM: fan.maxRPM) }

    /// Arguments for `TuttoFanHelperProtocol.setFan(_:mode:rpm:reply:)`, already clamped.
    /// The helper clamps again against the SMC; it never trusts the client.
    public func helperArguments(minRPM: Double, maxRPM: Double) -> (mode: Int, rpm: Double) {
        switch clamped(minRPM: minRPM, maxRPM: maxRPM) {
        case .auto: return (TuttoFanHelper.modeAutomatic, 0)
        case .maximum: return maxRPM > 0 ? (TuttoFanHelper.modeManual, maxRPM) : (TuttoFanHelper.modeAutomatic, 0)
        case .rpm(let rpm): return (TuttoFanHelper.modeManual, rpm)
        }
    }

    public func helperArguments(for fan: FanReading) -> (mode: Int, rpm: Double) {
        helperArguments(minRPM: fan.minRPM, maxRPM: fan.maxRPM)
    }
}
