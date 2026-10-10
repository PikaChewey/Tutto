//
//  GPUMemory.swift
//  Tutto
//
//  GPU load from the accelerator driver's own statistics, and memory from the
//  kernel's VM counters. Both are single cheap reads with no setup.
//

import Darwin
import Foundation
import IOKit

// MARK: - GPU

public struct GPUStats: Equatable, Sendable {
    public var model: String
    public var cores: Int?
    /// 0…1. "Device" is what Activity Monitor's GPU History shows.
    public var utilization: Double?
    public var renderer: Double?
    public var tiler: Double?
    /// Unified memory the GPU is using right now.
    public var memoryInUse: UInt64?
}

public enum GPUReader {
    public static func read() -> [GPUStats] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var result: [GPUStats] = []
        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = properties?.takeRetainedValue() as? [String: Any] else { continue }
            let stats = dict["PerformanceStatistics"] as? [String: Any] ?? [:]
            func percent(_ key: String) -> Double? {
                (stats[key] as? NSNumber).map { min(max($0.doubleValue / 100, 0), 1) }
            }
            result.append(GPUStats(
                model: dict["model"] as? String ?? "GPU",
                cores: (dict["gpu-core-count"] as? NSNumber)?.intValue,
                utilization: percent("Device Utilization %"),
                renderer: percent("Renderer Utilization %"),
                tiler: percent("Tiler Utilization %"),
                memoryInUse: (stats["In use system memory"] as? NSNumber)?.uint64Value
            ))
        }
        return result
    }
}

// MARK: - Memory

public enum MemoryPressure: Int, Sendable {
    case normal = 1, warning = 2, critical = 4

    public var label: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Elevated"
        case .critical: "High"
        }
    }
}

public struct MemoryStats: Equatable, Sendable {
    public var total: UInt64
    /// What Activity Monitor calls "Memory Used": app + wired + compressed.
    public var used: UInt64
    public var app: UInt64
    public var wired: UInt64
    public var compressed: UInt64
    /// File cache macOS can drop at any time.
    public var cached: UInt64
    public var free: UInt64
    public var swapUsed: UInt64
    public var swapTotal: UInt64
    public var pressure: MemoryPressure

    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

public enum MemoryReader {
    public static func read() -> MemoryStats? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_kernel_page_size)
        let total = UInt64(sysctlInt("hw.memsize") ?? 0)
        // Same arithmetic as Activity Monitor.
        let app = (UInt64(stats.internal_page_count) &- UInt64(stats.purgeable_count)) * page
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        let cached = (UInt64(stats.external_page_count) + UInt64(stats.purgeable_count)) * page
        let used = app + wired + compressed

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)

        let level = Int(sysctlInt("kern.memorystatus_vm_pressure_level") ?? 1)
        return MemoryStats(
            total: total, used: min(used, total), app: app, wired: wired, compressed: compressed,
            cached: cached, free: total > used + cached ? total - used - cached : 0,
            swapUsed: swap.xsu_used, swapTotal: swap.xsu_total,
            pressure: MemoryPressure(rawValue: level) ?? .normal
        )
    }
}
