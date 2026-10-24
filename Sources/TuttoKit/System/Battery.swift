//
//  Battery.swift
//  Tutto
//
//  Battery health and power straight from the smart battery's IORegistry entry.
//
//  Health is macOS's own "Maximum Capacity" (System Settings › Battery › Battery Health),
//  read from system_profiler and kept between launches. It is not NominalChargeCapacity ÷
//  DesignCapacity: that ratio follows every gas-gauge recalibration and wanders up and
//  down by a percent or so through the day (93.9 %, then 93.3 %, while macOS said 94 %
//  throughout). macOS's figure is a whole percent that only moves as the battery ages.
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
    /// mAh the gas gauge estimates a full charge holds today. Recalibrates as the battery is used.
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

    /// macOS's "Maximum Capacity", whole percent, when it could be read.
    public var reportedHealth: Int? = nil

    /// Battery health in whole percent, exactly as System Settings shows it. Only if macOS's
    /// figure can't be read does it fall back to the gauge's estimate ÷ design, rounded.
    public var healthPercent: Int {
        if let reportedHealth { return reportedHealth }
        guard designCapacity > 0 else { return 0 }
        return Int((Double(maxCapacity) / Double(designCapacity) * 100).rounded())
    }

    /// `healthPercent` as a fraction.
    public var health: Double { Double(healthPercent) / 100 }

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
        if let report = BatteryHealthCache.shared.value(for: info.serial) {
            info.reportedHealth = report.maximumCapacity
            if let condition = report.condition { info.condition = condition }
        }
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

// MARK: - macOS's health figure

/// The "Maximum Capacity" macOS shows under System Settings › Battery › Battery Health.
/// Apple publishes no API for it; system_profiler is the supported way to read it.
public struct BatteryHealthReport: Equatable, Sendable {
    /// Whole percent, as System Settings shows it.
    public var maximumCapacity: Int
    /// "Normal" or macOS's own wording ("Service Recommended"), as System Settings shows it.
    /// The power-sources API can disagree (it said "Check Battery" while Settings said Normal).
    public var condition: String?

    public init(maximumCapacity: Int, condition: String?) {
        self.maximumCapacity = maximumCapacity
        self.condition = condition
    }

    /// Runs system_profiler (about 70 ms). Blocks, so call it off the main thread.
    public static func fetch() -> BatteryHealthReport? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPPowerDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return parse(data)
    }

    /// Exposed for tests: pulls "94%" and "Good" out of `system_profiler SPPowerDataType -json`.
    public static func parse(_ json: Data) -> BatteryHealthReport? {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let entries = root["SPPowerDataType"] as? [[String: Any]] else { return nil }
        for entry in entries {
            guard let health = entry["sppower_battery_health_info"] as? [String: Any],
                  let text = health["sppower_battery_health_maximum_capacity"] as? String,
                  let value = Int(text.filter(\.isNumber)), (1...150).contains(value) else { continue }
            let verdict = health["sppower_battery_health"] as? String
            return BatteryHealthReport(maximumCapacity: value, condition: verdict.map { $0 == "Good" ? "Normal" : $0 })
        }
        return nil
    }
}

/// macOS's health figure, remembered between launches (keyed to the battery's serial, so a
/// replaced battery starts fresh) and re-read in the background at most once an hour.
public final class BatteryHealthCache: @unchecked Sendable {
    public static let shared = BatteryHealthCache()

    private static let defaultsKey = "battery.reportedHealth"
    private static let maxAge: TimeInterval = 3600

    private let lock = NSLock()
    private var value: BatteryHealthReport?
    private var serial: String?
    private var fetchedAt: Date?
    private var isFetching = false

    private init() {
        if let stored = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) {
            if let capacity = stored["value"] as? Int {
                value = BatteryHealthReport(maximumCapacity: capacity, condition: stored["condition"] as? String)
            }
            serial = stored["serial"] as? String
        }
    }

    /// The last figure macOS gave for this battery. Starts a background refresh when it's an
    /// hour old. The very first time (nothing remembered yet) it reads synchronously, once,
    /// so the number on screen never switches from an estimate to macOS's figure.
    public func value(for batterySerial: String?) -> BatteryHealthReport? {
        lock.lock()
        if serial != batterySerial { value = nil; fetchedAt = nil }
        let known = value
        let stale = fetchedAt.map { -$0.timeIntervalSinceNow > Self.maxAge } ?? true
        let firstEver = known == nil && fetchedAt == nil
        let startBackground = stale && !isFetching && !firstEver
        if startBackground || firstEver { isFetching = true }
        lock.unlock()

        if firstEver {
            store(BatteryHealthReport.fetch(), serial: batterySerial)
            lock.lock(); defer { lock.unlock() }
            return value
        }
        if startBackground {
            DispatchQueue.global(qos: .utility).async { [self] in
                store(BatteryHealthReport.fetch(), serial: batterySerial)
            }
        }
        return known
    }

    private func store(_ fetched: BatteryHealthReport?, serial batterySerial: String?) {
        lock.lock()
        defer { lock.unlock() }
        isFetching = false
        fetchedAt = Date()
        // A failed read keeps the last good figure rather than dropping back to an estimate.
        guard let fetched else { return }
        value = fetched
        serial = batterySerial
        var stored: [String: Any] = ["value": fetched.maximumCapacity]
        if let condition = fetched.condition { stored["condition"] = condition }
        if let batterySerial { stored["serial"] = batterySerial }
        UserDefaults.standard.set(stored, forKey: Self.defaultsKey)
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
