//
//  DiskNetwork.swift
//  Tutto
//
//  Volumes and their free space, disk throughput from the block storage drivers'
//  cumulative counters, and network throughput from the interfaces' byte counters.
//  Rates are differences between two reads; nothing is sampled in between.
//

import Darwin
import Foundation
import IOKit

// MARK: - Disk

public struct VolumeStats: Identifiable, Equatable, Sendable {
    public var id: String { url.path }
    public var name: String
    public var url: URL
    public var total: Int64
    /// Space available for things people actually save (includes purgeable space macOS will free).
    public var available: Int64
    public var isInternal: Bool
    public var isRoot: Bool

    public var used: Int64 { max(total - available, 0) }
    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

public struct DiskCounters: Equatable, Sendable {
    public var bytesRead: UInt64
    public var bytesWritten: UInt64
}

public enum DiskReader {
    public static func volumes() -> [VolumeStats] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                      .volumeAvailableCapacityKey, .volumeIsInternalKey, .volumeIsRootFileSystemKey,
                                      .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsBrowsable ?? true,
                  let total = values.volumeTotalCapacity, total > 0 else { return nil }
            let important = values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)
            return VolumeStats(name: values.volumeName ?? url.lastPathComponent, url: url, total: Int64(total),
                               available: important, isInternal: values.volumeIsInternal ?? false,
                               isRoot: values.volumeIsRootFileSystem ?? false)
        }
        .sorted { ($0.isRoot ? 0 : 1, $0.name) < ($1.isRoot ? 0 : 1, $1.name) }
    }

    /// The startup volume, for one-line summaries.
    public static func rootVolume() -> VolumeStats? {
        volumes().first(where: \.isRoot) ?? volumes().first
    }

    /// Bytes read and written by every disk since boot.
    public static func counters() -> DiskCounters {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else {
            return DiskCounters(bytesRead: 0, bytesWritten: 0)
        }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0, written: UInt64 = 0
        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            read &+= (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            written &+= (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return DiskCounters(bytesRead: read, bytesWritten: written)
    }
}

// MARK: - Network

public struct NetworkCounters: Equatable, Sendable {
    public var received: UInt64
    public var sent: UInt64
}

public struct NetworkInterfaceInfo: Equatable, Sendable {
    public var name: String
    public var address: String?
}

public enum NetworkReader {
    /// Bytes in and out across physical interfaces (Wi-Fi, Ethernet), since boot.
    /// Read per interface from the interface MIB, the same exact 64-bit counters `netstat -ib`
    /// prints. The `getifaddrs` and `NET_RT_IFLIST2` copies are rounded and cut to 32 bits, so
    /// they wrapped every 4 GB and blanked the rate for a second mid-download.
    public static func counters() -> NetworkCounters {
        var received: UInt64 = 0, sent: UInt64 = 0
        guard let list = if_nameindex() else { return NetworkCounters(received: 0, sent: 0) }
        defer { if_freenameindex(list) }
        var entry = list
        while entry.pointee.if_index != 0, let cName = entry.pointee.if_name {
            defer { entry += 1 }
            guard String(cString: cName).hasPrefix("en") else { continue }  // skip loopback, tunnels, bridges
            var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, Int32(entry.pointee.if_index), IFDATA_GENERAL]
            var data = ifmibdata()
            var size = MemoryLayout<ifmibdata>.size
            guard sysctl(&mib, u_int(mib.count), &data, &size, nil, 0) == 0 else { continue }
            received &+= data.ifmd_data.ifi_ibytes
            sent &+= data.ifmd_data.ifi_obytes
        }
        return NetworkCounters(received: received, sent: sent)
    }

    /// The first active physical interface with an IPv4 address (local only; nothing is fetched).
    public static func primaryInterface() -> NetworkInterfaceInfo? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            return NetworkInterfaceInfo(name: name, address: String(cString: host))
        }
        return nil
    }
}

// MARK: - Rates

/// Turns two cumulative counters into a per-second rate.
public struct RateMeter: Sendable {
    private var last: (value: UInt64, time: TimeInterval)?

    public init() {}

    public mutating func rate(_ value: UInt64, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Double? {
        defer { last = (value, time) }
        guard let last, time > last.time, value >= last.value else { return nil }
        return Double(value - last.value) / (time - last.time)
    }

    public mutating func reset() { last = nil }
}
