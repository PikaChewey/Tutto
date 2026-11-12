//
//  BluetoothBatteries.swift
//  Tutto
//
//  Battery levels of AirPods, keyboards, mice and other Bluetooth devices, for the menu bar
//  panel and the Battery page. Nothing runs unless one of them is on screen: then it reads once,
//  again every 30 s, and when a device connects or disconnects. No process is started.
//
//  Two reads (the pure parts are in TuttoKit):
//  - IOBluetooth's paired, connected devices, for the values Apple audio devices expose
//    (batteryPercentLeft, Right, Case, Single). macOS asks once for Bluetooth access before it
//    allows this, so Tutto only reads it after it's allowed; until then the Battery page offers
//    to ask. The key-value reads check that the device answers the property first, since asking
//    for one it doesn't have would raise an exception.
//  - The IORegistry's BatteryPercent, for Apple keyboards, mice and trackpads. No access needed.
//

import CoreBluetooth
import IOBluetooth
import SwiftUI
import TuttoKit

@MainActor
@Observable
final class BluetoothBatteries {
    static let shared = BluetoothBatteries()

    /// Every device that reports a level, in the order the panel lists them.
    private(set) var devices: [BluetoothBatteryDevice] = []

    enum Access { case allowed, notAsked, blocked }
    /// Whether macOS lets Tutto read paired devices (kept as of the last read).
    private(set) var access: Access = BluetoothBatteries.currentAccess()

    /// A card on the panel needs at least one level to show.
    var hasDevices: Bool { !devices.isEmpty }

    @ObservationIgnored private var watchers = 0
    @ObservationIgnored private var timer: DispatchSourceTimer?
    @ObservationIgnored private var connectNote: IOBluetoothUserNotification?
    @ObservationIgnored private var disconnectNotes: [IOBluetoothUserNotification] = []
    @ObservationIgnored private var observer: Listener?
    @ObservationIgnored private var pending: DispatchWorkItem?
    @ObservationIgnored private var isPreview = false

    private static func currentAccess() -> Access {
        switch CBManager.authorization {
        case .allowedAlways: .allowed
        case .notDetermined: .notAsked
        default: .blocked
        }
    }

    // MARK: Watching

    /// Something that shows devices came on screen.
    func begin() {
        watchers += 1
        guard timer == nil, !isPreview else { return }
        refresh()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(3))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.resume()
        self.timer = timer
        listenForChanges()
    }

    /// It went off screen; with nothing left showing, everything is released.
    func end() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        stop()
    }

    /// Releases everything (also when the app quits).
    func stop() {
        watchers = 0
        timer?.cancel()
        timer = nil
        pending?.cancel()
        pending = nil
        connectNote?.unregister()
        connectNote = nil
        disconnectNotes.forEach { $0.unregister() }
        disconnectNotes.removeAll()
        observer = nil
    }

    // MARK: Reading

    func refresh() {
        guard !isPreview else { return }
        access = Self.currentAccess()
        let audio = access == .allowed ? Self.readPairedDevices() : []
        let merged = BluetoothBatteryRules.merge([audio, HIDBatteryReader.read()])
        if merged != devices { devices = merged }
        if timer != nil { listenForDisconnects() }
    }

    /// Asks macOS for Bluetooth access (it shows its own prompt, once), then reads.
    func requestAccess() {
        // Listing the paired devices is what makes macOS ask.
        _ = IOBluetoothDevice.pairedDevices()
        refresh()
    }

    private static func readPairedDevices() -> [BluetoothBatteryDevice] {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return paired.compactMap { device in
            guard device.isConnected() else { return nil }
            var values: [String: Any] = [:]
            for key in BluetoothBatteryRules.audioKeys where device.responds(to: NSSelectorFromString(key)) {
                if let value = device.value(forKey: key) { values[key] = value }
            }
            return BluetoothBatteryRules.audioDevice(name: device.name, address: device.addressString,
                                                     majorClass: Int(device.deviceClassMajor),
                                                     minorClass: Int(device.deviceClassMinor), values: values)
        }
    }

    // MARK: Connecting and disconnecting

    /// A device that connects reports its levels a moment later; one that goes leaves the list.
    private func listenForChanges() {
        guard access == .allowed, connectNote == nil else { return }
        let listener = Listener { [weak self] in self?.changed() }
        observer = listener
        connectNote = IOBluetoothDevice.register(forConnectNotifications: listener, selector: #selector(Listener.deviceChanged(_:device:)))
        listenForDisconnects()
    }

    private func listenForDisconnects() {
        guard let observer, access == .allowed else { return }
        disconnectNotes.forEach { $0.unregister() }
        disconnectNotes = ((IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? [])
            .filter { $0.isConnected() }
            .compactMap { $0.register(forDisconnectNotification: observer, selector: #selector(Listener.deviceChanged(_:device:))) }
    }

    private func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        pending = work
        // The levels of a device that just connected arrive a moment after it does.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private final class Listener: NSObject {
        private let onChange: @MainActor () -> Void
        init(onChange: @escaping @MainActor () -> Void) { self.onChange = onChange }
        @objc func deviceChanged(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
            MainActor.assumeIsolated { onChange() }
        }
    }

    // MARK: Previews

    /// Debug snapshots: shows these devices without reading any.
    func previewDevices(_ devices: [BluetoothBatteryDevice]) {
        isPreview = true
        self.devices = devices
    }
}

extension View {
    /// Keeps the Bluetooth readings live while this view is on screen.
    func watchingBluetoothBatteries() -> some View {
        background(VisibilityReader { visible in
            if visible { BluetoothBatteries.shared.begin() } else { BluetoothBatteries.shared.end() }
        })
    }
}

// MARK: - Battery page

/// The Battery page's connected devices: a row each, hidden when none report a level. Before
/// macOS has been asked for Bluetooth access it offers to ask.
struct BluetoothDevicesSection: View {
    var model: AppModel

    var body: some View {
        let batteries = BluetoothBatteries.shared
        Group {
            if batteries.hasDevices || batteries.access == .notAsked {
                InkGroup("Bluetooth devices") {
                    ForEach(batteries.devices) { device in
                        BluetoothDeviceRow(device: device)
                            .overlay(alignment: .bottom) { Hairline().opacity(0.6) }
                    }
                    if batteries.access == .notAsked {
                        HStack(spacing: 12) {
                            Text("Show the charge of AirPods and other headphones.")
                                .font(.system(size: 12.5))
                                .foregroundStyle(Color.ink2)
                            Spacer(minLength: 12)
                            Button("Allow Bluetooth") { batteries.requestAccess() }
                                .controlSize(.small)
                        }
                        .frame(minHeight: 36)
                    }
                }
            }
        }
        // Reading starts when this page is on screen, even while it has nothing to show.
        .watchingBluetoothBatteries()
    }
}

private struct BluetoothDeviceRow: View {
    var device: BluetoothBatteryDevice

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.kind.symbol)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.ink3)
                .frame(width: 18)
            Text(device.name)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.ink2)
                .lineLimit(1)
            Spacer(minLength: 12)
            BluetoothLevelsText(parts: device.parts, size: 12.5)
        }
        .frame(minHeight: 32)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(device.name)
        .accessibilityValue(BluetoothBatteryRules.spoken(device.levels))
    }
}

/// "L 80 % · R 82 % · Case 50 %", with any level at or under 20 % in the alert colour.
struct BluetoothLevelsText: View {
    var parts: [BluetoothBatteryPart]
    var size: CGFloat

    var body: some View {
        parts.enumerated().reduce(Text("")) { text, item in
            let part = item.element
            let label = part.label.isEmpty ? "" : "\(part.label) "
            var piece = Text(label + "\(part.percent) %")
            piece = part.isLow ? piece.foregroundColor(Color.alert) : piece.foregroundColor(Color.ink)
            let separator = Text(item.offset == 0 ? "" : " · ").foregroundColor(Color.ink3)
            return text + separator + piece
        }
        .font(.system(size: size, weight: .medium).monospacedDigit())
        .lineLimit(1)
    }
}
