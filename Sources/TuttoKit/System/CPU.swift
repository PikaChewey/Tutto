//
//  CPU.swift
//  Tutto
//
//  CPU load from the kernel's per-core tick counters. Reading them costs a few
//  microseconds and nothing runs between reads: usage is the difference between
//  two snapshots, so callers decide how often (and whether) to look.
//

import Darwin
import Foundation
import IOKit

public struct CPUTicks: Equatable, Sendable {
    public var user: UInt64
    public var system: UInt64
    public var idle: UInt64
    public var nice: UInt64

    var busy: UInt64 { user &+ system &+ nice }
    var total: UInt64 { busy &+ idle }
}

public struct CPUUsage: Equatable, Sendable {
    /// 0…1 across all cores.
    public var total: Double
    public var user: Double
    public var system: Double
    /// 0…1 per logical core, in kernel order.
    public var perCore: [Double]

    public static let zero = CPUUsage(total: 0, user: 0, system: 0, perCore: [])
}

public enum CoreKind: String, Sendable {
    case efficiency = "E"
    case performance = "P"
}

public struct CPUTopology: Sendable {
    /// Kind of each logical core, in kernel order.
    public var kinds: [CoreKind]
    /// What macOS calls the performance cores on this chip ("Super" on M5, "Performance" before).
    public var performanceName: String
    public var efficiencyName: String
    public var brand: String

    public var performanceCount: Int { kinds.filter { $0 == .performance }.count }
    public var efficiencyCount: Int { kinds.filter { $0 == .efficiency }.count }
}

public enum CPUReader {
    /// One snapshot of every core's tick counters.
    public static func ticks() -> [CPUTicks] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        var result: [CPUTicks] = []
        result.reserveCapacity(Int(cpuCount))
        for core in 0..<Int(cpuCount) {
            let base = core * Int(CPU_STATE_MAX)
            func value(_ state: Int32) -> UInt64 { UInt64(UInt32(bitPattern: info[base + Int(state)])) }
            result.append(CPUTicks(user: value(CPU_STATE_USER), system: value(CPU_STATE_SYSTEM),
                                   idle: value(CPU_STATE_IDLE), nice: value(CPU_STATE_NICE)))
        }
        return result
    }

    /// Usage between two snapshots. Counters are 32-bit and can wrap; wrapping subtraction handles it.
    public static func usage(from old: [CPUTicks], to new: [CPUTicks]) -> CPUUsage {
        guard old.count == new.count, !new.isEmpty else { return .zero }
        var perCore: [Double] = []
        perCore.reserveCapacity(new.count)
        var busy: UInt64 = 0, user: UInt64 = 0, system: UInt64 = 0, total: UInt64 = 0
        for (a, b) in zip(old, new) {
            let dUser = (b.user &- a.user) & 0xFFFF_FFFF
            let dSystem = (b.system &- a.system) & 0xFFFF_FFFF
            let dNice = (b.nice &- a.nice) & 0xFFFF_FFFF
            let dIdle = (b.idle &- a.idle) & 0xFFFF_FFFF
            let dBusy = dUser + dSystem + dNice
            let dTotal = dBusy + dIdle
            perCore.append(dTotal > 0 ? Double(dBusy) / Double(dTotal) : 0)
            busy += dBusy
            user += dUser + dNice
            system += dSystem
            total += dTotal
        }
        guard total > 0 else { return CPUUsage(total: 0, user: 0, system: 0, perCore: perCore) }
        return CPUUsage(total: Double(busy) / Double(total), user: Double(user) / Double(total),
                        system: Double(system) / Double(total), perCore: perCore)
    }

    /// Which cores are efficiency and which are performance, read once from the device tree.
    public static let topology: CPUTopology = {
        let count = Int(sysctlInt("hw.logicalcpu") ?? 0)
        var kinds = [CoreKind](repeating: .performance, count: max(count, 0))
        var found = false
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        if cpus != IO_OBJECT_NULL {
            var iterator: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &iterator) == KERN_SUCCESS {
                while case let child = IOIteratorNext(iterator), child != IO_OBJECT_NULL {
                    defer { IOObjectRelease(child) }
                    guard let type = registryData(child, "cluster-type"),
                          let id = registryInt(child, "logical-cpu-id"),
                          id >= 0, id < kinds.count else { continue }
                    kinds[id] = type.first == UInt8(ascii: "E") ? .efficiency : .performance
                    found = true
                }
                IOObjectRelease(iterator)
            }
            IOObjectRelease(cpus)
        }
        if !found, let efficiency = sysctlInt("hw.perflevel1.physicalcpu"), efficiency > 0 {
            // Apple silicon numbers its efficiency cores first.
            for i in 0..<min(Int(efficiency), kinds.count) { kinds[i] = .efficiency }
        }
        return CPUTopology(kinds: kinds,
                           performanceName: sysctlString("hw.perflevel0.name") ?? "Performance",
                           efficiencyName: sysctlString("hw.perflevel1.name") ?? "Efficiency",
                           brand: sysctlString("machdep.cpu.brand_string") ?? "Apple silicon")
    }()

    public static func loadAverage() -> [Double] {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) == 3 ? loads : []
    }

    public static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

// MARK: - sysctl / registry helpers

func sysctlInt(_ name: String) -> Int64? {
    var value: Int64 = 0
    var size = MemoryLayout<Int64>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    if size == 4 { return Int64(Int32(truncatingIfNeeded: value)) }
    return value
}

func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    return String(cString: buffer)
}

func registryData(_ entry: io_registry_entry_t, _ key: String) -> Data? {
    IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data
}

func registryInt(_ entry: io_registry_entry_t, _ key: String) -> Int? {
    let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    if let number = value as? NSNumber { return number.intValue }
    if let data = value as? Data, data.count >= 4 {
        return Int(data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
    }
    return nil
}
