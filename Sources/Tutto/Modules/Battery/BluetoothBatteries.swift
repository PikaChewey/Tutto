//
//  BluetoothBatteries.swift
//  Tutto
//
//  Battery levels of AirPods and other Bluetooth devices. (Scaffold; to be built.)
//

import SwiftUI

@MainActor
@Observable
final class BluetoothBatteries {
    static let shared = BluetoothBatteries()
}

/// The Battery page's connected devices.
struct BluetoothDevicesSection: View {
    var model: AppModel
    var body: some View { EmptyView() }
}
