//
//  BluetoothBatteries.swift
//  Tutto
//
//  The charge of AirPods, keyboards, mice and other Bluetooth devices: reading the values the
//  system exposes, merging the two places they come from into one list, and how a level is
//  written. Pure logic here; the reads themselves (which need IOBluetooth) live in the app.
//
//  Two sources, as open-source battery widgets use them:
//  - Apple audio devices: IOBluetoothDevice's key-value properties batteryPercentLeft, Right,
//    Case and Single. They use 0 for "no reading", so 0 means unknown there.
//  - Keyboards, mice, trackpads and other HID devices: the IORegistry "BatteryPercent" property
//    on AppleDeviceManagementHIDEventService entries, with their "Product" name. Here 0 is a
//    real (empty) level.
//

import Foundation
import IOKit

public enum BluetoothDeviceKind: String, Equatable, Sendable, CaseIterable {
    case headphones, keyboard, mouse, trackpad, other

    /// The SF Symbol drawn beside the device.
    public var symbol: String {
        switch self {
        case .headphones: "headphones"
        case .keyboard: "keyboard"
        case .mouse: "computermouse"
        case .trackpad: "trackpad"
        case .other: "dot.radiowaves.left.and.right"
        }
    }

    /// Where the kind sorts in the list: what you wear first, then what you type and point with.
    var order: Int {
        switch self {
        case .headphones: 0
        case .keyboard: 1
        case .mouse: 2
        case .trackpad: 3
        case .other: 4
        }
    }
}

/// What a device reports, in whole percent. A pair of earbuds reports left, right and the case;
/// most other things report one figure.
public struct BluetoothBatteryLevels: Equatable, Sendable {
    public var single: Int?
    public var left: Int?
    public var right: Int?
    public var caseLevel: Int?

    public init(single: Int? = nil, left: Int? = nil, right: Int? = nil, caseLevel: Int? = nil) {
        self.single = single
        self.left = left
        self.right = right
        self.caseLevel = caseLevel
    }

    public var isEmpty: Bool { single == nil && left == nil && right == nil && caseLevel == nil }

    /// Fills what this lacks from `other` (what this has wins).
    public func filled(from other: BluetoothBatteryLevels) -> BluetoothBatteryLevels {
        BluetoothBatteryLevels(single: single ?? other.single, left: left ?? other.left,
                               right: right ?? other.right, caseLevel: caseLevel ?? other.caseLevel)
    }

    /// The lowest level the device reports.
    public var lowest: Int? { [single, left, right, caseLevel].compactMap { $0 }.min() }
}

/// One piece of a device's reading: "L", 80, and whether it is low.
public struct BluetoothBatteryPart: Equatable, Sendable {
    /// "L", "R" or "Case"; empty for a single figure.
    public var label: String
    public var percent: Int
    public var isLow: Bool
}

public struct BluetoothBatteryDevice: Equatable, Identifiable, Sendable {
    /// The device's address when it has one, else its name (lowercased).
    public var id: String
    public var name: String
    public var kind: BluetoothDeviceKind
    public var levels: BluetoothBatteryLevels

    public init(id: String, name: String, kind: BluetoothDeviceKind, levels: BluetoothBatteryLevels) {
        self.id = id
        self.name = name
        self.kind = kind
        self.levels = levels
    }

    public var parts: [BluetoothBatteryPart] { BluetoothBatteryRules.parts(levels) }
    public var text: String { BluetoothBatteryRules.text(levels) }
    public var isLow: Bool { parts.contains { $0.isLow } }
}

public enum BluetoothBatteryRules {
    /// A level at or under this is shown as low.
    public static let lowLevel = 20

    // MARK: Reading

    /// A level out of whatever a property holds: a number, or text like "80" or "80%". Anything
    /// outside 0–100 isn't a level. With `zeroMeansUnknown`, 0 isn't one either.
    public static func level(from value: Any?, zeroMeansUnknown: Bool) -> Int? {
        var number: Int?
        switch value {
        case let n as NSNumber:
            // A Bool is an NSNumber too, and never a level.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            number = Int(exactly: n.doubleValue.rounded())
        case let s as String:
            let digits = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")
            number = Int(digits.trimmingCharacters(in: .whitespaces))
        default:
            return nil
        }
        guard let number, (0...100).contains(number) else { return nil }
        if zeroMeansUnknown && number == 0 { return nil }
        return number
    }

    /// An Apple audio device's reading from its key-value properties (keys without a value are
    /// simply absent from `values`).
    public static func audioLevels(_ values: [String: Any]) -> BluetoothBatteryLevels {
        func get(_ key: String) -> Int? { level(from: values[key], zeroMeansUnknown: true) }
        var levels = BluetoothBatteryLevels(single: get("batteryPercentSingle"), left: get("batteryPercentLeft"),
                                            right: get("batteryPercentRight"), caseLevel: get("batteryPercentCase"))
        // Some devices report only a combined figure.
        if levels.isEmpty { levels.single = get("batteryPercentCombined") }
        return levels
    }

    /// The property names read from an IOBluetoothDevice.
    public static let audioKeys = ["batteryPercentSingle", "batteryPercentLeft", "batteryPercentRight",
                                   "batteryPercentCase", "batteryPercentCombined"]

    /// A device from its IOBluetooth description, or nil when it reports no level.
    public static func audioDevice(name: String?, address: String?, majorClass: Int, minorClass: Int,
                                   values: [String: Any]) -> BluetoothBatteryDevice? {
        let levels = audioLevels(values)
        guard !levels.isEmpty else { return nil }
        let shown = displayName(name, address: address)
        return BluetoothBatteryDevice(id: identity(address: address, name: shown), name: shown,
                                      kind: kind(name: shown, majorClass: majorClass, minorClass: minorClass), levels: levels)
    }

    /// A device from an IORegistry entry's properties (BatteryPercent, Product, DeviceAddress).
    public static func hidDevice(_ properties: [String: Any]) -> BluetoothBatteryDevice? {
        guard let percent = level(from: properties["BatteryPercent"], zeroMeansUnknown: false) else { return nil }
        let address = properties["DeviceAddress"] as? String
        let name = displayName(properties["Product"] as? String, address: address)
        return BluetoothBatteryDevice(id: identity(address: address, name: name), name: name,
                                      kind: kind(name: name, majorClass: nil, minorClass: nil),
                                      levels: BluetoothBatteryLevels(single: percent))
    }

    // MARK: Naming and kinds

    static func displayName(_ name: String?, address: String?) -> String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        return address.flatMap { $0.isEmpty ? nil : $0 } ?? "Bluetooth device"
    }

    /// A name for tight room: "Bryan's AirPods Pro" is "AirPods Pro" (your own devices are the
    /// only ones listed, so whose they are goes without saying).
    public static func shortName(_ name: String) -> String {
        for mark in ["'s ", "\u{2019}s "] {
            if let range = name.range(of: mark), !name[..<range.lowerBound].contains(" ") {
                let rest = name[range.upperBound...].trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { return rest }
            }
        }
        return name
    }

    /// The same device from either source gets the same id: its address without separators, or
    /// its name in lowercase.
    public static func identity(address: String?, name: String) -> String {
        if let address {
            let cleaned = address.lowercased().filter { $0.isHexDigit }
            if cleaned.count == 12 { return cleaned }
        }
        return name.lowercased()
    }

    /// Name first (a Magic Trackpad is a pointing device to Bluetooth, a trackpad to you), then
    /// the Bluetooth device class when there is one: 4 is audio, 5 is a keyboard or pointer.
    public static func kind(name: String, majorClass: Int?, minorClass: Int?) -> BluetoothDeviceKind {
        let n = name.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { n.contains($0) } }
        if has(["trackpad", "touchpad"]) { return .trackpad }
        if has(["keyboard"]) { return .keyboard }
        if has(["mouse", "mx master", "mx anywhere"]) { return .mouse }
        if has(["airpods", "headphone", "headset", "earbud", "earphone", "buds", "beats", "powerbeats", "wh-1000", "wf-1000", "quietcomfort"]) {
            return .headphones
        }
        if majorClass == 4 { return .headphones }
        if majorClass == 5, let minor = minorClass {
            let pointing = minor & 0x20 != 0
            let keys = minor & 0x10 != 0
            if keys && !pointing { return .keyboard }
            if pointing && !keys { return (minor & 0x0F) == 0x05 ? .trackpad : .mouse }
        }
        return .other
    }

    // MARK: Merging

    /// Both sources as one list: a device in both has its levels combined, the first source's
    /// winning where both report one. Only devices with a level are kept, headphones first,
    /// then keyboards, mice and trackpads, each group by name.
    public static func merge(_ sources: [[BluetoothBatteryDevice]]) -> [BluetoothBatteryDevice] {
        var byID: [String: BluetoothBatteryDevice] = [:]
        var firstSeen: [String] = []
        for device in sources.joined() where !device.levels.isEmpty {
            if var existing = byID[device.id] {
                existing.levels = existing.levels.filled(from: device.levels)
                // A kind the first source couldn't tell wins from the second.
                if existing.kind == .other { existing.kind = device.kind }
                byID[device.id] = existing
            } else {
                byID[device.id] = device
                firstSeen.append(device.id)
            }
        }
        return firstSeen.compactMap { byID[$0] }.sorted {
            if $0.kind.order != $1.kind.order { return $0.kind.order < $1.kind.order }
            let byName = $0.name.localizedCaseInsensitiveCompare($1.name)
            return byName == .orderedSame ? $0.id < $1.id : byName == .orderedAscending
        }
    }

    // MARK: Writing a level

    /// The pieces of a reading in the order they're written: a single figure, then L, R, Case.
    public static func parts(_ levels: BluetoothBatteryLevels) -> [BluetoothBatteryPart] {
        func part(_ label: String, _ value: Int?) -> BluetoothBatteryPart? {
            value.map { BluetoothBatteryPart(label: label, percent: $0, isLow: isLow($0)) }
        }
        return [part("", levels.single), part("L", levels.left), part("R", levels.right), part("Case", levels.caseLevel)]
            .compactMap { $0 }
    }

    public static func isLow(_ percent: Int) -> Bool { percent <= lowLevel }

    /// "64 %", or "L 80 % · R 82 % · Case 50 %".
    public static func text(_ levels: BluetoothBatteryLevels) -> String {
        parts(levels).map { $0.label.isEmpty ? "\($0.percent) %" : "\($0.label) \($0.percent) %" }.joined(separator: " · ")
    }

    /// For VoiceOver: "left 80 percent, right 82 percent, case 50 percent".
    public static func spoken(_ levels: BluetoothBatteryLevels) -> String {
        parts(levels).map { part in
            let label = ["L": "left", "R": "right", "Case": "case"][part.label]
            return label.map { "\($0) \(part.percent) percent" } ?? "\(part.percent) percent"
        }.joined(separator: ", ")
    }
}

/// Keyboards, mice and trackpads that report a charge through the registry (no Bluetooth
/// access needed; nothing is started).
public enum HIDBatteryReader {
    public static func read() -> [BluetoothBatteryDevice] {
        var devices: [BluetoothBatteryDevice] = []
        for className in ["AppleDeviceManagementHIDEventService", "AppleBluetoothHIDKeyboard", "BNBMouseDevice", "BNBTrackpadDevice"] {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }
            while case let service = IOIteratorNext(iterator), service != 0 {
                defer { IOObjectRelease(service) }
                var unmanaged: Unmanaged<CFMutableDictionary>?
                guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                      let properties = unmanaged?.takeRetainedValue() as? [String: Any],
                      let device = BluetoothBatteryRules.hidDevice(properties) else { continue }
                devices.append(device)
            }
        }
        return devices
    }
}
