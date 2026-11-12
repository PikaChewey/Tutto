//
//  ChargeLimit.swift
//  Tutto
//
//  Battery charge limit (stop charging at 80 %). (Scaffold; to be built.)
//

import SwiftUI

@MainActor
@Observable
final class ChargeLimitController {
    static let shared = ChargeLimitController()
    /// A few words for the panel's battery card while the limit is holding the charge, else nil.
    var panelNote: String? { nil }
    func start(model: AppModel) {}
    /// At quit: charging always back on.
    func stop() {}
}

/// The Battery page's charge limit settings.
struct ChargeLimitSection: View {
    var model: AppModel
    var body: some View { EmptyView() }
}
