//
//  ChargeLimitRules.swift
//  Tutto
//
//  Charge limit's decisions, with no I/O: whether to hold charging off, given the charge, the
//  adapter, the limit and "charge to 100 % once"; and the words the Battery page and the
//  panel show. The app's `ChargeLimitController` feeds it power-source changes.
//

import Foundation
import IOKit.ps

public enum ChargeLimitRules {
    public static let levels = Array(stride(from: 50, through: 100, by: 5))
    public static let defaultLevel = 80
    /// Charging starts again once the charge is this far below the limit.
    public static let resumeGap = 5

    /// A level from settings, snapped to 50…100 in steps of 5.
    public static func normalize(_ level: Int) -> Int {
        let snapped = Int((Double(level) / 5).rounded()) * 5
        return Swift.min(Swift.max(snapped, 50), 100)
    }

    public struct Input: Equatable, Sendable {
        public var percent: Int
        public var pluggedIn: Bool
        public var limit: Int
        /// "Charge to 100 % once" is on.
        public var topUp: Bool
        /// Charging is held off right now.
        public var inhibiting: Bool

        public init(percent: Int, pluggedIn: Bool, limit: Int, topUp: Bool, inhibiting: Bool) {
            self.percent = percent
            self.pluggedIn = pluggedIn
            self.limit = limit
            self.topUp = topUp
            self.inhibiting = inhibiting
        }
    }

    public struct Decision: Equatable, Sendable {
        /// Hold charging off.
        public var inhibit: Bool
        /// What "charge to 100 % once" should be now (it clears itself).
        public var topUp: Bool

        public init(inhibit: Bool, topUp: Bool) {
            self.inhibit = inhibit
            self.topUp = topUp
        }
    }

    /// Stop at the limit; start again below limit − 5; in between, keep doing what it was doing.
    /// Unplugged there's nothing to hold (and "once" ends). "Once" charges to 100 % and then ends.
    public static func decide(_ input: Input) -> Decision {
        let limit = normalize(input.limit)
        let percent = Swift.min(Swift.max(input.percent, 0), 100)
        guard input.pluggedIn else { return Decision(inhibit: false, topUp: false) }
        var topUp = input.topUp
        if topUp && percent >= 100 { topUp = false }
        if topUp { return Decision(inhibit: false, topUp: true) }
        guard limit < 100 else { return Decision(inhibit: false, topUp: false) }
        if percent >= limit { return Decision(inhibit: true, topUp: false) }
        if percent < limit - resumeGap { return Decision(inhibit: false, topUp: false) }
        return Decision(inhibit: input.inhibiting, topUp: false)
    }

    // MARK: Words

    /// The Battery page's one status line.
    public static func status(percent: Int, pluggedIn: Bool, charging: Bool, limit: Int,
                              topUp: Bool, inhibiting: Bool) -> String {
        let limit = normalize(limit)
        if !pluggedIn { return "On battery. Charging stops at \(limit) % when plugged in." }
        if inhibiting { return "Holding at \(percent) %, running on the adapter" }
        if topUp && percent < 100 { return "Charging to 100 % once, then back to \(limit) %" }
        if charging { return "Charging to \(limit) %" }
        return "Plugged in at \(percent) %, not charging right now"
    }

    /// A few words for the panel's battery card, or nil when there's nothing worth saying.
    public static func panelNote(percent: Int, pluggedIn: Bool, topUp: Bool, inhibiting: Bool) -> String? {
        guard pluggedIn else { return nil }
        if inhibiting { return "Held at \(percent) %" }
        if topUp && percent < 100 { return "Charging to 100 % once" }
        return nil
    }
}

/// The few power-source facts the charge limit needs, from one IOPowerSources read (no registry
/// walk, no health report).
public struct ChargeReading: Equatable, Sendable {
    public var percent: Int
    public var pluggedIn: Bool
    public var charging: Bool

    public init(percent: Int, pluggedIn: Bool, charging: Bool) {
        self.percent = percent
        self.pluggedIn = pluggedIn
        self.charging = charging
    }

    /// Nil on a Mac with no internal battery.
    public static func read() -> ChargeReading? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let reading = parse(description) else { continue }
            return reading
        }
        return nil
    }

    /// Exposed for tests: one power source's description, if it's the internal battery.
    public static func parse(_ description: [String: Any]) -> ChargeReading? {
        guard description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
              let current = description[kIOPSCurrentCapacityKey] as? Int,
              let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { return nil }
        let state = description[kIOPSPowerSourceStateKey] as? String
        return ChargeReading(percent: Swift.min(Swift.max(current * 100 / maximum, 0), 100),
                             pluggedIn: state == kIOPSACPowerValue,
                             charging: description[kIOPSIsChargingKey] as? Bool ?? false)
    }
}

/// What this Mac supports, read (never written) from the SMC.
public enum ChargeControl {
    /// Nil when this Mac's SMC has no charging control key.
    public static func supportedMethod() -> ChargeSMC.Method? {
        ChargeSMC.method(keyExists: { SMCDevice.shared.read($0) != nil })
    }

    /// Whether the SMC says charging is held off right now (by anyone). Read-only.
    public static func smcSaysInhibited() -> Bool {
        guard let method = supportedMethod() else { return false }
        return ChargeSMC.keys(for: method, keyExists: { SMCDevice.shared.read($0) != nil })
            .contains { SMCDevice.shared.read($0).map(ChargeSMC.isInhibited) ?? false }
    }
}
