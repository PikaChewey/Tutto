//
//  MenuBarItemsModule.swift
//  Tutto
//
//  Menu Bar Icons: tuck away the menu bar icons you rarely use. (Scaffold; to be built.)
//

import AppKit
import SwiftUI
import TuttoKit

@MainActor
@Observable
final class MenuBarItemsModule: ModuleController {
    func start() {}
    func stop() {}
    /// Shows the tucked-away icons, or tucks them away again.
    func toggle() {}
}

struct MenuBarItemsPage: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Menu Bar Icons", subtitle: ModuleID.menuBarItems.summary, module: .menuBarItems)
            if model.menuBarItems == nil {
                ModuleOffView(module: .menuBarItems, model: model)
            }
        }
    }
}
