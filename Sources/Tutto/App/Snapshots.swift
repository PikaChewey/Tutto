//
//  Snapshots.swift
//  Tutto
//
//  Debug-only: `Tutto --snapshot <dir> [page …]` renders the menu bar panel and main
//  window pages offscreen to PNGs (light and dark) with live readings, then quits.
//  Used for design review and the README without putting windows on screen.
//

#if DEBUG
import AppKit
import SwiftUI
import TuttoKit

@MainActor
enum Snapshots {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--snapshot"), args.count > flag + 1 else { return false }
        let dir = URL(fileURLWithPath: args[flag + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let only = Set(args.dropFirst(flag + 2))

        let model = AppModel.shared
        model.launch(quietly: true)
        model.system?.begin([.stats, .volumes, .energyProcesses, .cpuProcesses, .memoryProcesses])
        model.cornerClick?.beginWatching()
        // Let readings and the first `top` samples arrive.
        RunLoop.main.run(until: Date().addingTimeInterval(only.contains("fast") ? 1.5 : 5.5))
        model.cornerClick?.applyPreview(contacts: [Contact(id: 1, x: 0.86, y: 0.14)])

        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            if only.isEmpty || only.contains("panel") {
                render(MenuPanel(model: model).background(PanelMaterialStandIn()), appearance: appearance,
                       to: dir.appendingPathComponent("panel-\(name).png"))
            }
            for page in MainPage.allCases where only.isEmpty || only.contains(page.rawValue) {
                MainWindowController.shared.navigation.page = page
                render(MainView(model: model, navigation: MainWindowController.shared.navigation)
                        .frame(width: 960, height: 680),
                       appearance: appearance, to: dir.appendingPathComponent("page-\(page.rawValue)-\(name).png"))
            }
            for extra in SnapshotExtras.all where only.contains(extra.name) || (only.isEmpty && extra.inDefaultSet) {
                render(extra.view(model), appearance: appearance, to: dir.appendingPathComponent("\(extra.name)-\(name).png"))
            }
        }
        model.shutdown()
        return true
    }

    static func render(_ view: some View, appearance: NSAppearance.Name, to url: URL) {
        let host = NSHostingView(rootView: AnyView(view))
        host.appearance = NSAppearance(named: appearance)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("snapshot:", url.lastPathComponent, size)
    }
}

/// The menu bar window's material doesn't render offscreen; this approximates it.
private struct PanelMaterialStandIn: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Color(white: scheme == .dark ? 0.16 : 0.93)
    }
}

/// Extra surfaces modules register for snapshots (palettes, editor, onboarding).
@MainActor
struct SnapshotExtras {
    var name: String
    var inDefaultSet = true
    var view: (AppModel) -> AnyView

    static var all: [SnapshotExtras] = []
}
#endif
