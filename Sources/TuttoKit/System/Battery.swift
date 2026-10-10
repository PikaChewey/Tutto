//
//  Battery.swift
//  Tutto
//
//  Battery health and power straight from the smart battery's IORegistry entry.
//  "Maximum capacity" follows macOS's own definition (System Settings and
//  system_profiler): NominalChargeCapacity ÷ DesignCapacity.
//

import Foundation
import IOKit
import IOKit.ps

public struct BatteryInfo: Equatable, Sendable {
    /// 0…100, as shown in the menu bar.
    public var percent: Int
    public var isCharging: Bool
    public var isPluggedIn: Bool
    public var isFullyCharged: Bool
    public var cycleCount: Int
    public var designCycleCount: Int?
    /// mAh.
    public var designCapacity: Int
    /// mAh the battery holds when full today (macOS's definition of maximum capacity).
    public var maxCapacity: Int
    /// mAh as the gas gauge measures it, before macOS's smoothing.
    public var rawMaxCapacity: Int?
    public var currentCharge: Int?
    public var temperature: Double?
    public var voltage: Double?
    /// Amps; negative while discharging.
    public var amperage: Double?
    /// Watts the whole Mac is drawing right now (from the power telemetry), if reported.
    public var systemPower: Double?
    /// Watts coming from the adapter, if plugged in.
    public var adapterInput: Double?
    public var adapterWatts: Int?
    public var adapterName: String?
    /// Minutes, when macOS has an estimate.
    public var minutesToEmpty: Int?
    public var minutesToFull: Int?
    /// macOS's verdict ("Normal", "Service Recommended"), from IOPowerSources.
    public var condition: String?
    public var serial: String?

    /// Battery health as a percentage, like System Settings.
    public var health: Double { designCapacity > 0 ? Double(maxCapacity) / Double(designCapacity) : 0 }

    /// Watts into (positive) or out of (negative) the battery, from the power telemetry when
    /// reported (consistent with `systemPower`), else voltage × current.
    public var batteryPower: Double? {
        if let telemetryBatteryPower { return telemetryBatteryPower }
        guard let voltage, let amperage else { return nil }
        return voltage * amperage
    }

    public var telemetryBatteryPower: Double?

    /// The single number most people mean by "power": what the Mac is using.
    public var powerDraw: Double? {
        if let systemPower, systemPower > 0 { return systemPower }
        if let batteryPower, !isPluggedIn { return abs(batteryPower) }
        return nil
    }

    public var stateText: String {
        if isFullyCharged && isPluggedIn { return "Charged" }
        if isCharging { return "Charging" }
        if isPluggedIn { return "Not charging" }
        return "On battery"
    }
}

public enum BatteryReader {
    public static func read() -> BatteryInfo? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = properties?.takeRetainedValue() as? [String: Any] else { return nil }
        var info = parse(dict)
        addPowerSourceDetails(to: &info)
        return info
    }

    /// Exposed for tests: builds the model from a registry dictionary.
    public static func parse(_ d: [String: Any]) -> BatteryInfo {
        func int(_ key: String) -> Int? { (d[key] as? NSNumber)?.intValue }
        func bool(_ key: String) -> Bool { (d[key] as? NSNumber)?.boolValue ?? false }
        /// Amperage is reported as an unsigned 64-bit value that is really signed.
        func signed(_ key: String) -> Int? {
            guard let number = d[key] as? NSNumber else { return nil }
            return Int(truncatingIfNeeded: number.int64Value)
        }

        let design = int("DesignCapacity") ?? 0
        let nominal = int("NominalChargeCapacity")
        let raw = int("AppleRawMaxCapacity")
        // On Apple silicon MaxCapacity is a percentage (100); on Intel it is mAh.
        let legacyMax = int("MaxCapacity").flatMap { $0 > 100 ? $0 : nil }
        let maxCapacity = nominal ?? raw ?? legacyMax ?? 0

        let current = int("CurrentCapacity") ?? 0
        let percent: Int
        if let legacyMax, legacyMax > 0 {
            percent = Int((Double(current) / Double(legacyMax) * 100).rounded())
        } else {
            percent = current
        }

        let telemetry = d["PowerTelemetryData"] as? [String: Any]
        let systemLoad = (telemetry?["SystemLoad"] as? NSNumber)?.doubleValue
        let systemIn = (telemetry?["SystemPowerIn"] as? NSNumber)?.doubleValue
        let batteryTelemetry = (telemetry?["BatteryPower"] as? NSNumber).map { Double(Int64(truncatingIfNeeded: $0.int64Value)) / 1000 }
        let adapter = d["AdapterDetails"] as? [String: Any]
        let plugged = bool("ExternalConnected")
        let voltage = int("Voltage").map { Double($0) / 1000 }
        let amps = (signed("InstantAmperage") ?? signed("Amperage")).map { Double($0) / 1000 }

        return BatteryInfo(
            percent: min(max(percent, 0), 100),
            isCharging: bool("IsCharging"),
            isPluggedIn: plugged,
            isFullyCharged: bool("FullyCharged"),
            cycleCount: int("CycleCount") ?? 0,
            designCycleCount: int("DesignCycleCount9C"),
            designCapacity: design,
            maxCapacity: maxCapacity,
            rawMaxCapacity: raw,
            currentCharge: int("AppleRawCurrentCapacity"),
            temperature: int("Temperature").map { Double($0) / 100 },
            voltage: voltage,
            amperage: amps,
            systemPower: systemLoad.flatMap { $0 > 0 ? $0 / 1000 : nil },
            adapterInput: plugged ? systemIn.flatMap { $0 > 0 ? $0 / 1000 : nil } : nil,
            adapterWatts: plugged ? (adapter?["Watts"] as? NSNumber)?.intValue : nil,
            adapterName: plugged ? (adapter?["Name"] as? String)?.trimmingCharacters(in: .whitespaces) : nil,
            minutesToEmpty: nil,
            minutesToFull: nil,
            condition: nil,
            serial: d["Serial"] as? String,
            telemetryBatteryPower: telemetry == nil ? nil : batteryTelemetry
        )
    }

    /// Time estimates and health condition come from the power sources API, the same as the menu bar.
    private static func addPowerSourceDetails(to info: inout BatteryInfo) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            if let empty = description[kIOPSTimeToEmptyKey] as? Int, empty > 0, !info.isPluggedIn {
                info.minutesToEmpty = empty
            }
            if let full = description[kIOPSTimeToFullChargeKey] as? Int, full > 0, info.isCharging {
                info.minutesToFull = full
            }
            if let health = description["BatteryHealth"] as? String {
                info.condition = health == "Good" ? "Normal" : health
            }
        }
    }
}

/// Calls back whenever macOS reports a power source change (plug, unplug, percent).
/// Event-driven: nothing runs between changes.
public final class PowerSourceObserver {
    private var source: CFRunLoopSource?
    private let handler: () -> Void

    public init(handler: @escaping () -> Void) {
        self.handler = handler
        let context = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<PowerSourceObserver>.fromOpaque(context).takeUnretainedValue().handler()
        }, context)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode) }
    }

    deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
    }
}
