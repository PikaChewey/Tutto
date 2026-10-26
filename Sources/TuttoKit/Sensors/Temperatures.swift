//
//  Temperatures.swift
//  Tutto
//
//  Temperature sensors, readable without root:
//  - IOHID (CBridges `TSensorsRead`): SoC die, PMU, battery and SSD sensors, named by
//    the system ("PMU tdie3", "gas gauge battery", "NAND CH0 temp" …).
//  - SMC keys for CPU and GPU, only where published open-source SMC key tables document
//    what a key means for this chip generation.
//
//  Honesty rules (FAN-1/FAN-4):
//  - Readings outside −20…130 °C are dropped (this M5 has an IOHID sensor stuck at −9201 °C).
//  - Apple documents none of these names. A sensor is only called "CPU" or "GPU" when
//    its name says so (M1/M2 IOHID) or a published key table maps its SMC key. Everything else keeps a
//    neutral label.
//
//  Verified on a MacBook Pro 14" M5 (macOS 26.5.2) by loading the CPU and GPU separately:
//  - The documented M5 GPU keys (Tg0U…Tg1g) rose 22–26 °C under a Metal compute load, more than any
//    other sensor. Under a CPU-only load they rose least.
//  - The documented M5 CPU keys (Tp00…Tp0y) rose 10–15 °C within 2 s of a 4-thread Super-core load
//    and did not move under an Efficiency-core-only load. The tables call some of them
//    "performance core", but the base M5 has no performance cores, so Tutto labels them
//    plainly "CPU n" and does not claim a per-core mapping.
//  - IOHID "PMU tdie*" rose under both CPU and GPU load, so Tutto groups them as SoC die.
//    "PMU2 tdie*" barely moved under either load (about +1 °C), so they are not grouped
//    as SoC.
//  The M1–M4 SMC tables below come from those published tables and are unverified here.
//

import CBridges
import Foundation

// MARK: - Model

public enum TemperatureGroup: String, Sendable, Codable, CaseIterable {
    /// Only for sensors whose name or documented SMC key says CPU.
    case cpu
    /// SoC die sensors that are not attributable to CPU or GPU.
    case soc
    case gpu
    case battery
    case storage
    case ambient
    case other

    public var title: String {
        switch self {
        case .cpu: return "CPU"
        case .soc: return "SoC"
        case .gpu: return "GPU"
        case .battery: return "Battery"
        case .storage: return "SSD"
        case .ambient: return "Ambient"
        case .other: return "Other"
        }
    }

    var sortIndex: Int { Self.allCases.firstIndex(of: self) ?? Self.allCases.count }
}

public enum TemperatureSource: String, Sendable, Codable {
    case hid
    case smc
}

public struct TemperatureReading: Identifiable, Sendable, Equatable {
    /// Stable across reads: "hid:<name>" or "smc:<key>".
    public let id: String
    /// The raw IOHID product name or SMC key.
    public let name: String
    /// Human label, e.g. "SoC die 3", "CPU 2", "Battery".
    public let label: String
    public let group: TemperatureGroup
    public let celsius: Double
    public let source: TemperatureSource
    /// How many IOHID services with this exact name were averaged into this reading.
    public let sampleCount: Int

    public init(id: String? = nil, name: String, label: String, group: TemperatureGroup, celsius: Double,
                source: TemperatureSource = .hid, sampleCount: Int = 1) {
        self.id = id ?? "\(source.rawValue):\(name)"
        self.name = name
        self.label = label
        self.group = group
        self.celsius = celsius
        self.source = source
        self.sampleCount = sampleCount
    }
}

/// Headline numbers for the panel. Nil means "this Mac has no such sensor". Nothing is estimated.
public struct TemperatureSummary: Sendable, Equatable {
    public let cpuAverage: Double?
    public let cpuHottest: Double?
    public let gpuAverage: Double?
    public let gpuHottest: Double?
    public let socAverage: Double?
    public let socHottest: Double?
    public let batteryAverage: Double?
    /// Hottest storage sensor.
    public let ssd: Double?

    /// The hottest processor or graphics sensor: what "running hot" means.
    public var hottest: Double? { [cpuHottest, gpuHottest, socHottest].compactMap { $0 }.max() }

    public init(_ readings: [TemperatureReading]) {
        func values(_ group: TemperatureGroup) -> [TemperatureReading] { readings.filter { $0.group == group } }
        func average(_ list: [TemperatureReading]) -> Double? {
            let weight = list.reduce(0) { $0 + max($1.sampleCount, 1) }
            guard weight > 0 else { return nil }
            return list.reduce(0) { $0 + $1.celsius * Double(max($1.sampleCount, 1)) } / Double(weight)
        }
        let cpu = values(.cpu), gpu = values(.gpu), soc = values(.soc)
        cpuAverage = average(cpu)
        cpuHottest = cpu.map(\.celsius).max()
        gpuAverage = average(gpu)
        gpuHottest = gpu.map(\.celsius).max()
        socAverage = average(soc)
        socHottest = soc.map(\.celsius).max()
        batteryAverage = average(values(.battery))
        ssd = values(.storage).map(\.celsius).max()
    }

    /// One number for the menu bar: hottest CPU sensor, else hottest SoC die sensor.
    public var headline: Double? { cpuHottest ?? socHottest }
}

public extension Array where Element == TemperatureReading {
    var summary: TemperatureSummary { TemperatureSummary(self) }
}

// MARK: - Reading

public enum TemperatureSensors {
    /// Anything outside this range is junk (e.g. −9201 °C) and is dropped.
    public static let plausibleRange: ClosedRange<Double> = -20...130

    public static func isPlausible(_ celsius: Double) -> Bool {
        celsius.isFinite && plausibleRange.contains(celsius)
    }

    /// Every valid sensor: SMC CPU/GPU keys where a documented mapping exists, then IOHID.
    /// Sorted by group, then naturally by label. Call from one queue at a time; about 1 Hz is fine.
    public static func read() -> [TemperatureReading] {
        sorted(readSMC() + readHID())
    }

    /// IOHID sensors only, filtered and deduplicated.
    public static func readHID() -> [TemperatureReading] {
        makeHIDReadings(rawHIDReadings())
    }

    /// SMC CPU/GPU sensors for this chip (empty when no mapping applies).
    public static func readSMC() -> [TemperatureReading] {
        presentSMCKeys.compactMap { entry in
            guard let celsius = SMCDevice.shared.readDouble(entry.key), celsius != 0, isPlausible(celsius) else { return nil }
            return TemperatureReading(name: entry.key, label: entry.label, group: entry.group, celsius: celsius, source: .smc)
        }
    }

    /// Frees the IOHID event-system client. The next read creates a new one.
    /// Call when the sensors page closes and after wake.
    public static func release() {
        hidLock.lock()
        TSensorsRelease()
        hidLock.unlock()
    }

    /// The chip name and where the CPU/GPU labels come from, for an "about these sensors" note.
    public static var mappingDescription: String {
        guard let chip = currentChip else { return "No CPU/GPU SMC mapping for this Mac; showing system sensors only." }
        let name = "Apple M\(chip.generation)\(chip.variant.isEmpty ? "" : " " + chip.variant)"
        if presentSMCKeys.isEmpty { return "\(name): no documented CPU/GPU SMC keys found." }
        let verified = chip.generation == 5 && chip.variant.isEmpty
            ? "checked under CPU and GPU load on an M5 MacBook Pro"
            : "not verified on this chip"
        return "\(name): CPU/GPU labels from published SMC key tables (\(verified))."
    }

    // MARK: IOHID

    private static let hidLock = NSLock()

    static func rawHIDReadings() -> [(name: String, celsius: Double)] {
        let capacity = Int(TSENSOR_MAX)
        var buffer = [TSensorReading](repeating: TSensorReading(), count: capacity)
        hidLock.lock()
        let count = buffer.withUnsafeMutableBufferPointer { TSensorsRead($0.baseAddress, Int32(capacity)) }
        hidLock.unlock()
        return buffer.prefix(Int(max(count, 0))).map { reading in
            var raw = reading
            let name = withUnsafeBytes(of: &raw.name) { bytes -> String in
                let end = bytes.firstIndex(of: 0) ?? bytes.count
                return String(decoding: bytes[..<end], as: UTF8.self)
            }
            return (name.trimmingCharacters(in: .whitespaces), reading.celsius)
        }
    }

    /// Drops junk and unnamed sensors, averages services that share a name (this M5 has six
    /// "gas gauge battery" services), and labels each one.
    static func makeHIDReadings(_ raw: [(name: String, celsius: Double)]) -> [TemperatureReading] {
        var order: [String] = []
        var sums: [String: (total: Double, count: Int)] = [:]
        for (name, celsius) in raw where !name.isEmpty && isPlausible(celsius) {
            if sums[name] == nil { order.append(name) }
            let current = sums[name] ?? (0, 0)
            sums[name] = (current.total + celsius, current.count + 1)
        }
        return sorted(order.compactMap { name in
            guard let sum = sums[name], sum.count > 0 else { return nil }
            let (label, group) = classifyHID(name)
            return TemperatureReading(name: name, label: label, group: group, celsius: sum.total / Double(sum.count),
                                      source: .hid, sampleCount: sum.count)
        })
    }

    /// Human label and group for an IOHID sensor name. Unknown names keep their raw name in `.other`.
    static func classifyHID(_ name: String) -> (label: String, group: TemperatureGroup) {
        // Recent Apple silicon (M3 and later): everything hangs off the power-management units.
        if let n = number(in: name, after: "PMU tdie") { return ("SoC die \(n)", .soc) }
        if let n = number(in: name, after: "PMU2 tdie") { return ("PMU2 die \(n)", .other) }
        if let n = number(in: name, after: "PMU tdev") { return ("PMU sensor \(n)", .other) }
        if let n = number(in: name, after: "PMU2 tdev") { return ("PMU2 sensor \(n)", .other) }
        if name == "PMU tcal" { return ("PMU calibration", .other) }
        if name == "PMU2 tcal" { return ("PMU2 calibration", .other) }

        // M1/M2 name the block outright.
        if let n = number(in: name, after: "pACC MTR Temp Sensor") { return ("CPU performance cluster \(n)", .cpu) }
        if let n = number(in: name, after: "eACC MTR Temp Sensor") { return ("CPU efficiency cluster \(n)", .cpu) }
        if let n = number(in: name, after: "GPU MTR Temp Sensor") { return ("GPU \(n)", .gpu) }
        if let n = number(in: name, after: "SOC MTR Temp Sensor") { return ("SoC \(n)", .soc) }
        if let n = number(in: name, after: "PMGR SOC Die Temp Sensor") { return ("SoC power manager \(n)", .soc) }
        if let n = number(in: name, after: "ANE MTR Temp Sensor") { return ("Neural Engine \(n)", .soc) }
        if let n = number(in: name, after: "ISP MTR Temp Sensor") { return ("Image processor \(n)", .soc) }

        let lower = name.lowercased()
        if lower.hasPrefix("nand") {
            if let range = name.range(of: #"CH\d+"#, options: .regularExpression) {
                return ("SSD (NAND channel \(name[range].dropFirst(2)))", .storage)
            }
            return ("SSD", .storage)
        }
        if lower.contains("battery") { return ("Battery", .battery) }
        if lower.contains("ambient") { return ("Ambient", .ambient) }
        return (name, .other)
    }

    /// The decimal number right after `prefix` (optionally after one space), if the name is exactly that.
    private static func number(in name: String, after prefix: String) -> Int? {
        guard name.hasPrefix(prefix) else { return nil }
        let rest = name.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty, rest.allSatisfy(\.isASCII), let value = Int(rest), value >= 0 else { return nil }
        return value
    }

    static func sorted(_ readings: [TemperatureReading]) -> [TemperatureReading] {
        readings.sorted { a, b in
            if a.group != b.group { return a.group.sortIndex < b.group.sortIndex }
            if a.source != b.source { return a.source == .smc }
            return a.label.localizedStandardCompare(b.label) == .orderedAscending
        }
    }

    // MARK: SMC CPU/GPU map

    struct SMCTemperatureKey: Equatable {
        let key: String
        let group: TemperatureGroup
        let label: String
    }

    struct Chip: Equatable {
        let generation: Int
        /// "", "Pro", "Max" or "Ultra".
        let variant: String
    }

    /// Parses `machdep.cpu.brand_string`, e.g. "Apple M5", "Apple M4 Pro".
    static func parseChip(_ brand: String) -> Chip? {
        guard let match = brand.range(of: #"Apple M(\d+)( (Pro|Max|Ultra))?"#, options: .regularExpression) else { return nil }
        let parts = brand[match].split(separator: " ")
        guard parts.count >= 2, let generation = Int(parts[1].dropFirst()) else { return nil }
        return Chip(generation: generation, variant: parts.count >= 3 ? String(parts[2]) : "")
    }

    static var currentChip: Chip? {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0) == 0 else { return nil }
        return parseChip(String(cString: bytes))
    }

    /// Documented CPU/GPU keys for a chip, with Tutto's labels. Empty for unknown chips.
    static func smcCandidates(for chip: Chip) -> [SMCTemperatureKey] {
        func list(_ keys: [String], _ group: TemperatureGroup, _ prefix: String) -> [(String, TemperatureGroup, String)] {
            keys.map { ($0, group, prefix) }
        }
        let entries: [(String, TemperatureGroup, String)]
        switch chip.generation {
        case 1:
            entries = list(["Tp09", "Tp0T"], .cpu, "CPU efficiency core")
                + list(["Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"], .cpu, "CPU performance core")
                + list(["Tg05", "Tg0D", "Tg0L", "Tg0T"], .gpu, "GPU")
        case 2:
            entries = list(["Tp1h", "Tp1t", "Tp1p", "Tp1l"], .cpu, "CPU efficiency core")
                + list(["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"], .cpu, "CPU performance core")
                + list(["Tg0f", "Tg0j"], .gpu, "GPU")
        case 3:
            entries = list(["Te05", "Te0L", "Te0P", "Te0S"], .cpu, "CPU efficiency core")
                + list(["Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"],
                       .cpu, "CPU performance core")
                + list(["Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"], .gpu, "GPU")
        case 4:
            let gpuFirst = chip.variant.isEmpty ? ["Tg0G", "Tg0H"] : ["Tg1U", "Tg1k"]
            entries = list(["Te05", "Te0S", "Te09", "Te0H"], .cpu, "CPU efficiency core")
                + list(["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"], .cpu, "CPU performance core")
                + list(gpuFirst + ["Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k"], .gpu, "GPU")
        case 5:
            // Published tables split these into "super core" (first six) and "performance core" (rest).
            // The base M5 has Super + Efficiency cores and all of these follow Super-core load,
            // so they get a neutral "CPU n".
            entries = list(["Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K", "Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a",
                            "Tp0d", "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y"], .cpu, "CPU")
                + list(["Tg0U", "Tg0X", "Tg0d", "Tg0g", "Tg0j", "Tg1Y", "Tg1c", "Tg1g"], .gpu, "GPU")
        default:
            entries = []
        }
        return entries.map { SMCTemperatureKey(key: $0.0, group: $0.1, label: $0.2) }
    }

    /// Keeps the candidates that exist and numbers them per label: "CPU 1", "CPU 2" …
    static func presentKeys(_ candidates: [SMCTemperatureKey], keyExists: (String) -> Bool) -> [SMCTemperatureKey] {
        var counters: [String: Int] = [:]
        return candidates.filter { keyExists($0.key) }.map { entry in
            let n = (counters[entry.label] ?? 0) + 1
            counters[entry.label] = n
            return SMCTemperatureKey(key: entry.key, group: entry.group, label: "\(entry.label) \(n)")
        }
    }

    /// Probed once per launch.
    static let presentSMCKeys: [SMCTemperatureKey] = {
        guard let chip = currentChip else { return [] }
        return presentKeys(smcCandidates(for: chip), keyExists: { SMCDevice.shared.read($0) != nil })
    }()
}
