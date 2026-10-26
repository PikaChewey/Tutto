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
        AppModel.rendersOffscreen = true
        model.launch(quietly: true)
        model.system?.begin([.load, .volumes, .energyProcesses, .cpuProcesses, .memoryProcesses])
        model.sensors?.begin()
        model.sound?.begin()   // lists apps and reads which play; mutes nothing
        // Let readings and the first `top` samples arrive.
        RunLoop.main.run(until: Date().addingTimeInterval(only.contains("fast") ? 1.5 : 5.5))
        model.corner?.applyPreview(contacts: [Contact(id: 1, x: 0.86, y: 0.14)])

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

    static var all: [SnapshotExtras] {
        var extras: [SnapshotExtras] = OnboardingStep.allCases.map { step in
            SnapshotExtras(name: "onboarding-\(step.label.lowercased().replacingOccurrences(of: " ", with: "-"))") { model in
                AnyView(OnboardingView(model: model, start: step, close: {}))
            }
        }
        extras.append(SnapshotExtras(name: "clipboard-palette") { model in
            guard let clipboard = model.clipboard else { return AnyView(EmptyView()) }
            let palette = ClipboardPaletteModel(module: clipboard)
            palette.targetName = "Safari"
            return AnyView(ClipboardPaletteView(model: palette, actions: ClipboardPaletteController(module: clipboard))
                .frame(width: 780, height: 480))
        })
        extras.append(SnapshotExtras(name: "window-palette") { model in
            guard let windows = model.windows else { return AnyView(EmptyView()) }
            let palette = WindowPaletteModel(module: windows)
            palette.appName = "Safari"
            palette.query = "half"
            return AnyView(WindowPaletteView(model: palette, perform: { _ in }).frame(width: 560, height: 420))
        })
        extras.append(SnapshotExtras(name: "word-counter") { model in
            guard let counter = model.wordCounter else { return AnyView(EmptyView()) }
            let sample = """
            The quick brown fox jumps over the lazy dog. It's a well-known pangram, used to show every letter.

            Paste anything here and the counts update as you type.
            """
            let editor = NSTextView.scrollableTextView()
            (editor.documentView as? NSTextView)?.string = sample
            (editor.documentView as? NSTextView)?.font = .systemFont(ofSize: 14)
            (editor.documentView as? NSTextView)?.textContainerInset = NSSize(width: 14, height: 14)
            editor.drawsBackground = false
            (editor.documentView as? NSTextView)?.drawsBackground = false
            let state = WordCounterModel()
            state.stats = TextStats.measure(sample)
            state.isEmpty = false
            state.selection = TextStats.measure("well-known pangram")
            return AnyView(WordCounterView(model: state, module: counter, editor: editor).frame(width: 720, height: 440))
        })
        // Real windows and pictures of them: for checking the look, not for publishing.
        extras.append(SnapshotExtras(name: "switcher", inDefaultSet: false) { model in
            guard let switcher = model.switcher else { return AnyView(EmptyView()) }
            let session = SwitcherSession()
            session.all = switcher.buildItems()
            session.showPreviews = CGPreflightScreenCaptureAccess()
            session.showHints = true
            session.refilter(keepSelection: false)
            session.selection = min(1, max(session.visible.count - 1, 0))
            for item in session.visible.prefix(7) {
                if let id = item.windowID, let image = WindowServer.capture(id).flatMap({ ThumbnailStore.scaled($0, to: ThumbnailStore.pixelSize) }) {
                    session.thumbnails[id] = NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2))
                }
            }
            let width = min(CGFloat(session.visible.count), 6) * 222 - 14 + 44
            return AnyView(SwitcherView(session: session, actions: SwitcherActions(
                select: { _ in }, commit: { _ in }, saveRename: {}, cancelRename: {}, searchCommit: {}, searchCancel: {},
                searchStep: { _ in }, clickedOutside: {})).frame(width: width, height: 286))
        })
        extras.append(SnapshotExtras(name: "editor") { model in
            guard let screenshots = model.screenshots, let image = sampleImage() else { return AnyView(EmptyView()) }
            let editor = EditorWindowController(image: image, module: screenshots)
            editor.document.selection = CGRect(x: 120, y: 90, width: 520, height: 300)
            editor.document.add(Annotation(shape: .arrow(CGPoint(x: 900, y: 600), CGPoint(x: 660, y: 420)),
                                           color: EditorPalette.colors[0], width: 6))
            editor.document.add(Annotation(shape: .stroke([CGPoint(x: 700, y: 120), CGPoint(x: 760, y: 150), CGPoint(x: 840, y: 130),
                                                           CGPoint(x: 900, y: 170)]), color: EditorPalette.colors[4], width: 6))
            return AnyView(editor.snapshotView().frame(width: 1100, height: 760))
        })
        // States live readings rarely show: the stats card's title calm, worth a look and alarmed,
        // and an app icon as it is, playing and muted.
        extras.append(SnapshotExtras(name: "panel-states", inDefaultSet: false) { _ in
            let glances = [Glance("On battery", "4 h 9 min left"), Glance("Working hard", "CPU 91%", level: .notice),
                           Glance("Battery low", "18 min left", level: .alert)]
            let icon = NSWorkspace.shared.icon(for: .applicationBundle)
            let app = SoundApp(bundleID: "sample", name: "Sample", pid: 0, icon: icon)
            return AnyView(VStack(spacing: 8) {
                ForEach(glances, id: \.title) { glance in
                    VerdictLine(glance: glance)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.055)))
                }
                HStack(spacing: 0) {
                    ForEach(Array([(false, false), (false, true), (true, false)].enumerated()), id: \.offset) { _, state in
                        SoundAppButton(app: app, muted: state.0, usingAudio: state.1, size: 30) {}
                            .frame(width: 34.5, alignment: .leading)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.055)))
            }
            .padding(10)
            .frame(width: 320)
            .background(PanelMaterialStandIn()))
        })
        return extras
    }

    /// A screenshot-like picture for editor renders: the menu bar panel drawn offscreen.
    static func sampleImage() -> CGImage? {
        let host = NSHostingView(rootView: MainView(model: AppModel.shared, navigation: MainWindowController.shared.navigation)
            .frame(width: 960, height: 640))
        host.frame = NSRect(x: 0, y: 0, width: 960, height: 640)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.cgImage
    }
}
#endif
