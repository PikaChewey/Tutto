//
//  Glance.swift
//  TuttoKit
//
//  The menu bar panel's one line: the thing worth knowing about the Mac right now, in plain
//  words, from measurements only. A problem comes first (battery about to run out, heat,
//  memory at its limit, a full disk, a busy processor); otherwise the battery's state, or
//  "All good". Elevated memory pressure is everyday on a busy Mac, so only critical speaks.
//

import Foundation

public struct Glance: Equatable, Sendable {
    public enum Level: Equatable, Sendable {
        case calm
        /// Worth a look (a ⚠︎ ahead of the title).
        case notice
        /// Act soon (the ⚠︎ and the detail in red).
        case alert
    }

    public var title: String
    public var detail: String?
    public var level: Level

    public init(_ title: String, _ detail: String? = nil, level: Level = .calm) {
        self.title = title
        self.detail = detail
        self.level = level
    }

    /// `cpu` 0…1; `hottest` the hottest temperature sensor in °C; `diskUsed` 0…1.
    public static func make(battery: BatteryInfo?, cpu: Double, memoryPressure: MemoryPressure?, hottest: Double?,
                            diskFree: Int64?, diskUsed: Double?) -> Glance {
        if let battery, !battery.isPluggedIn, battery.percent <= 10 {
            return Glance("Battery low", battery.minutesToEmpty.flatMap(duration).map { "\($0) left" } ?? "\(battery.percent)%", level: .alert)
        }
        if let hottest, hottest >= 95 { return Glance("Running hot", "\(Int(hottest.rounded()))°", level: .alert) }
        if memoryPressure == .critical { return Glance("Memory is full", "Pressure critical", level: .alert) }
        if let diskUsed, diskUsed >= 0.95 {
            return Glance("Disk almost full", diskFree.map { "\(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)) free" }, level: .notice)
        }
        if cpu >= 0.85 { return Glance("Working hard", "CPU \(Int((cpu * 100).rounded()))%", level: .notice) }
        guard let battery else { return Glance("All good") }
        if battery.isCharging { return Glance("Charging", battery.minutesToFull.flatMap(duration).map { "Full in \($0)" } ?? "\(battery.percent)%") }
        if battery.isPluggedIn { return battery.isFullyCharged ? Glance("Fully charged", "On power") : Glance("On power", "Not charging") }
        return Glance("On battery", battery.minutesToEmpty.flatMap(duration).map { "\($0) left" })
    }

    /// "4 h 9 min", "45 min"; nil for nothing or a number that isn't a real estimate yet.
    static func duration(_ minutes: Int) -> String? {
        guard minutes > 0, minutes < 60 * 48 else { return nil }
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }
}
