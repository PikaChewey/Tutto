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
        // `toast-size`: the sizes a short and a long toast get (nothing shown on screen).
        if only.contains("toast-size") {
            for detail in ["Copied 42 characters",
                           "Executed 318 tests, with 0 failures (0 unexpected) in 8.214 (8.253) seconds and the rest of a long line"] {
                let size = Toast.size(for: Toast.Content(title: "3 lines copied", detail: detail))
                print("toast:", Int(size.width), "x", Int(size.height), "for", detail.count, "characters")
            }
        }
        // Tutto's own theme, or `theme:Paper` for a built-in one; renders don't change the theme kept.
        let themeName = only.first(where: { $0.hasPrefix("theme:") }).map { String($0.dropFirst(6)) } ?? "Tutto"
        let spec = (ThemeSpec.builtIn + [.liquidGlass]).first { $0.name.caseInsensitiveCompare(themeName) == .orderedSame } ?? .tutto
        ThemeStore.shared.apply(spec, remember: false)
        model.system?.begin([.load, .volumes, .apps, .energyProcesses, .cpuProcesses, .memoryProcesses])
        model.sensors?.begin()
        model.sound?.begin()   // lists apps and reads which play; mutes nothing
        // Let readings and the first `top` samples arrive.
        RunLoop.main.run(until: Date().addingTimeInterval(only.contains("fast") ? 1.5 : 5.5))
        model.corner?.applyPreview(contacts: [Contact(id: 1, x: 0.86, y: 0.14)])
        // `awake-running` / `awake-closed` / `awake-nohelper`: the Stay Awake card mid-session.
        if only.contains("awake-running") { model.awake?.previewSession(remaining: 2 * 3600 + 14 * 60 + 7, lidSafe: true) }
        if only.contains("awake-closed") {
            model.awake?.previewSession(remaining: 47 * 60 + 12, lidSafe: true,
                                        lastClosed: .init(darkened: true, mute: .init(deviceUID: "x", wasMuted: false), pausedNames: ["Chat", "Game"]))
        }
        if only.contains("clicker-on") { model.clicker?.previewClicking() }
        // `bluetooth-devices`: the panel and the Battery page with sample devices (none are read).
        if only.contains("bluetooth-devices") {
            BluetoothBatteries.shared.previewDevices([
                BluetoothBatteryDevice(id: "a", name: "Bryan's AirPods Pro", kind: .headphones, levels: BluetoothBatteryLevels(left: 80, right: 18, caseLevel: 50)),
                BluetoothBatteryDevice(id: "b", name: "Magic Keyboard", kind: .keyboard, levels: BluetoothBatteryLevels(single: 64)),
                BluetoothBatteryDevice(id: "c", name: "Magic Mouse", kind: .mouse, levels: BluetoothBatteryLevels(single: 12)),
            ])
        }
        // `cleanup-scan`: the Clean Up page after a real (read-only) scan of this Mac.
        if only.contains("cleanup-scan"), let cleaner = model.cleaner {
            cleaner.scan()
            let deadline = Date().addingTimeInterval(60)
            while cleaner.state != .ready, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        }
        if only.contains("clicker-open") { ClickerRow.startsExpanded = true }
        // `compress-demo`: the Convert & Compress card with a result under it and a total saved.
        if only.contains("compress-demo") { model.converter?.previewDemo() }
        // `agents-demo`: the Agents card and page with sessions, limits and leftovers.
        if only.contains("agents-demo") { model.agents?.previewDemo() }
        // `convert-open`: the Convert & Compress card open (it starts closed).
        if only.contains("convert-open") { ConvertCard.startsOpen = true }
        if only.contains("convert-closed") { ConvertCard.startsClosed = true }
        if only.contains("scroll-line") { ThinScrollStage.shown = true }
        if only.contains("scroll-wide") { ThinScrollStage.shown = true; ThinScrollStage.wide = true }
        if only.contains("scroll-mid") { ThinScrollStage.middle = true }
        if let hover = only.first(where: { $0.hasPrefix("hover:") }) {
            LensStage.forced = Set(hover.dropFirst(6).split(separator: ",").map(String.init))
        }
        if let limit = only.first(where: { $0.hasPrefix("scroll-limit:") }).flatMap({ Double($0.dropFirst(13)) }) { ThinScrollStage.limit = limit }
        // `convert-drag`: as while files are dragged over the panel (the card opens, its actions dashed).
        if only.contains("convert-drag") { PanelDrag.shared.files = true }
        ToolsCard.startsHovered = only.first(where: { $0.hasPrefix("tool-hover:") }).map { String($0.dropFirst(11)) }
        // `sound-levels`: the Sound card's levels open, with some apps turned down and up.
        if only.contains("sound-levels"), let sound = model.sound {
            SoundCard.startsShowingLevels = true
            let ids = sound.apps.map(\.bundleID)
            var levels: [String: Double] = [:]
            if ids.count > 0 { levels[ids[0]] = 180 }
            if ids.count > 1 { levels[ids[1]] = 45 }
            sound.previewVolumes(levels)
        }
        if let ids = only.first(where: { $0.hasPrefix("sound-muted:") }), let sound = model.sound {
            sound.previewMuted(Set(ids.dropFirst(12).split(separator: ",").map(String.init)))
        }
        // `clicker-long`: the longest labels, a time limit, and a run 18 s into it.
        if only.contains("clicker-long") {
            model.clicker?.previewSettings {
                $0.button = .middle
                $0.double = true
                $0.target = .point(x: 640, y: 360)
                $0.stop = .afterSeconds(60)
            }
            if only.contains("clicker-on") { model.clicker?.previewClicking(since: 18) }
        }
        // `windows-pinned`: the Windows page's Keep on top list with two windows in it.
        if only.contains("windows-pinned") {
            model.windows?.pins.previewPins([("TextEdit", "Shopping list.txt"), ("Terminal", "~ — zsh — 120×40")])
        }
        if only.contains("awake-nohelper") { model.awake?.previewSession(remaining: 3600, lidSafe: false) }
        // `charge-held` / `charge-nohelper`: the charge limit on (Battery page and panel), nothing sent to the helper.
        if only.contains("charge-held") { ChargeLimitController.shared.previewHolding() }
        if only.contains("charge-nohelper") { ChargeLimitController.shared.previewHolding(percent: 64, helper: .requiresApproval) }

        // `glass-stage wall-dark:<image> wall-light:<image>`: Liquid Glass can't be drawn offscreen, so the
        // panel is put on screen over a wallpaper, one window per appearance; each window's number is
        // written to stage-<appearance>.window and it stays up until stage-<appearance>.window.done exists.
        if let dim = only.first(where: { $0.hasPrefix("sheet-dim:") }).flatMap({ Double($0.dropFirst(10)) }) { GlassSheet.darkDim = dim }
        if let veil = only.first(where: { $0.hasPrefix("sheet-veil:") }).flatMap({ Double($0.dropFirst(11)) }) { GlassSheet.lightVeil = veil }
        if let sheen = only.first(where: { $0.hasPrefix("sheet-sheen:") }).flatMap({ Double($0.dropFirst(12)) }) { GlassSheet.sheen = sheen }
        if let rim = only.first(where: { $0.hasPrefix("sheet-rim:") }).flatMap({ Double($0.dropFirst(10)) }) { GlassSheet.rim = rim }
        if let tint = only.first(where: { $0.hasPrefix("sheet-tint:") }).flatMap({ Double($0.dropFirst(11)) }) { GlassSheet.tint = tint }
        if only.contains("flat-cards") { GlassSheet.flatCards = true }
        if let value = only.first(where: { $0.hasPrefix("sheet-glass:") }).flatMap({ Double($0.dropFirst(12)) }) { GlassSheet.glassOpacity = value }
        if let value = only.first(where: { $0.hasPrefix("sheet-frost:") }).flatMap({ Double($0.dropFirst(12)) }) { GlassSheet.frost = value }
        if let value = only.first(where: { $0.hasPrefix("card-dim:") }).flatMap({ Double($0.dropFirst(9)) }) { GlassSheet.cardDim = value }
        if only.contains("glass-cards") { GlassSheet.glassCardsOnSheet = true }
        if let look = only.first(where: { $0.hasPrefix("glass-look:") }).flatMap({ GlassLook(rawValue: String($0.dropFirst(11))) }) {
            GlassLook.current = look
        }
        let materials: [String: NSVisualEffectView.Material] = ["fullscreen": .fullScreenUI, "hud": .hudWindow, "under": .underWindowBackground,
                                                                "popover": .popover, "menu": .menu, "sheet": .sheet, "header": .headerView]
        if let name = only.first(where: { $0.hasPrefix("frost:") }).map({ String($0.dropFirst(6)) }), let material = materials[name] {
            FrostedFrame.material = material
        }
        if only.contains("glass-stage") {
            if only.contains(where: { $0.hasPrefix("wall-") }) { FrostedFrame.blending = .withinWindow }
            // `behind:<image>`: the panel's window stays clear, over a second window showing the image,
            // the way the real panel sits over other apps (the glass reads what's behind its window).
            let behind = only.first { $0.hasPrefix("behind:") }.flatMap { NSImage(contentsOfFile: String($0.dropFirst(7))) }
            for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                let prefix = "wall-\(name):"
                let wallpaper = only.first { $0.hasPrefix(prefix) }.flatMap { NSImage(contentsOfFile: String($0.dropFirst(prefix.count))) }
                stage(model: model, appearance: appearance, wallpaper: wallpaper, behind: behind, toasts: only.contains("toast-studies"),
                      marker: dir.appendingPathComponent("stage-\(name).window"))
            }
            model.shutdown()
            return true
        }
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            if only.isEmpty || only.contains("panel") {
                render(MenuPanel(model: model).background(PanelMaterialStandIn()), appearance: appearance,
                       to: dir.appendingPathComponent("panel-\(name).png"))
            }
            for page in MainPage.allCases where only.isEmpty || only.contains(page.rawValue) {
                MainWindowController.shared.navigation.page = page
                render(MainView(model: model, navigation: MainWindowController.shared.navigation)
                        .frame(width: 960, height: only.contains("tall") ? 1500 : 680),
                       appearance: appearance, to: dir.appendingPathComponent("page-\(page.rawValue)-\(name).png"))
            }
            for extra in SnapshotExtras.all where only.contains(extra.name) || (only.isEmpty && extra.inDefaultSet) {
                render(extra.view(model), appearance: appearance, to: dir.appendingPathComponent("\(extra.name)-\(name).png"))
            }
        }
        model.shutdown()
        return true
    }

    static func stage(model: AppModel, appearance: NSAppearance.Name, wallpaper: NSImage?, behind: NSImage? = nil, toasts: Bool = false, marker: URL) {
        // As tall as the screen allows: the panel with every card is taller than it was.
        let height = min(1_100, ((NSScreen.main?.visibleFrame.height) ?? 900) - 16)
        let size = NSSize(width: toasts ? 1_440 : 700, height: height)
        let view = GlassStage(wallpaper: wallpaper, size: size) {
            if toasts { ToastStudyBoard() } else { MenuPanel(model: model, preview: true, glassRoot: true) }
        }
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: appearance)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        // No wallpaper: a clear window over whatever is on screen, the way the panel really sits.
        window.isOpaque = wallpaper != nil
        window.backgroundColor = wallpaper != nil ? .black : .clear
        window.level = .floating
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.contentView = host
        if let screen = NSScreen.main {
            let area = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: area.maxX - size.width - 12, y: max(area.maxY - size.height - 8, area.minY)))
        }
        var backdrop: NSWindow?
        if let behind {
            let under = NSWindow(contentRect: window.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            let image = NSImageView(frame: NSRect(origin: .zero, size: window.frame.size))
            image.image = behind
            image.imageScaling = .scaleAxesIndependently
            under.contentView = image
            under.level = .floating
            under.isReleasedWhenClosed = false
            under.ignoresMouseEvents = true
            under.orderFrontRegardless()
            backdrop = under
        }
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(2))
        // With a backdrop, the capture is of both windows: write "<panel> <backdrop>".
        try? "\(window.windowNumber)\(backdrop.map { " \($0.windowNumber)" } ?? "")".write(to: marker, atomically: true, encoding: .utf8)
        print("stage:", marker.lastPathComponent, window.windowNumber)
        let done = marker.appendingPathExtension("done")
        let deadline = Date().addingTimeInterval(20)
        while !FileManager.default.fileExists(atPath: done.path), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        window.orderOut(nil)
        backdrop?.orderOut(nil)
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

/// A wallpaper with the panel floating over it near the top right, as under the menu bar.
private struct GlassStage<Panel: View>: View {
    var wallpaper: NSImage?
    var size: NSSize
    @ViewBuilder var panel: Panel

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let wallpaper {
                Image(nsImage: wallpaper).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
            } else {
                Color.clear
            }
            panel
                .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
                .padding(.top, 24)
                .padding(.trailing, 44)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }
}

/// The menu bar window's material doesn't render offscreen; this approximates it.
struct PanelMaterialStandIn: View {
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
        // The pill while the auto clicker counts down, clicks (corner on, then held), and with no shortcut.
        extras.append(SnapshotExtras(name: "clicker-pill", inDefaultSet: false) { model in
            let keys = model.shortcuts.shortcut(for: .toggleClicker)
            @MainActor func pill(_ text: String, _ keys: KeyShortcut?, _ detail: String, live: Bool) -> some View {
                let state = ClickerHUDModel()
                state.text = text
                state.keys = keys
                state.detail = detail
                state.live = live
                return ClickerPill(model: state).fixedSize()
            }
            return AnyView(VStack(alignment: .leading, spacing: 10) {
                pill("Starts in 2", keys, "cancels", live: false)
                pill("Auto clicker", keys, ClickerRules.howToStop(hasShortcut: true, holding: false, corner: true), live: true)
                pill("Auto clicker", keys, ClickerRules.howToStop(hasShortcut: true, holding: true, corner: true), live: true)
                pill("Auto clicker", nil, ClickerRules.howToStop(hasShortcut: false, holding: false, corner: true), live: true)
            }
            .padding(20)
            .background(Color(white: 0.45)))
        })
        // The keyboard cleaning screen, 27 s into a 30 s lock.
        extras.append(SnapshotExtras(name: "keyboard-clean", inDefaultSet: false) { _ in
            let state = CleaningState()
            state.total = 30
            state.secondsLeft = 26.6
            return AnyView(CleaningOverlay(state: state).frame(width: 900, height: 560).background(Color(white: 0.6)))
        })
        // The drag wheel for pictures, PNG lit.
        extras.append(SnapshotExtras(name: "convert-wheel", inDefaultSet: false) { _ in
            let items = ConvertPlanner.targets(for: .image).map { WheelView.Item(title: $0.title, action: .convert($0)) }
            return AnyView(WheelSnapshot(items: items).frame(width: 300, height: 300).padding(20).background(Color(white: 0.5)))
        })
        // The Convert window with files chosen (TUTTO_SNAPSHOT_FILES: paths joined by ":").
        extras.append(SnapshotExtras(name: "convert-window", inDefaultSet: false) { model in
            guard let converter = model.converter else { return AnyView(EmptyView()) }
            let selection = ConvertSelection()
            selection.files = (ProcessInfo.processInfo.environment["TUTTO_SNAPSHOT_FILES"] ?? "")
                .split(separator: ":").map { URL(fileURLWithPath: String($0)) }
            return AnyView(ConvertView(module: converter, selection: selection).frame(height: 760))
        })
        // Menu Bar Icons' settings, tucked away and showing (no status item is made), and the notice
        // for Tutto's own icon on the wrong side of the divider.
        for (suffix, collapsed, order) in [("hidden", true, MenuBarOrder.fine), ("showing", false, .fine), ("wrong-side", false, .tuttoWouldBeTucked)] {
            extras.append(SnapshotExtras(name: "menu-bar-icons-\(suffix)", inDefaultSet: false) { model in
                let module = MenuBarItemsModule()
                module.previewState(collapsed: collapsed, order: order)
                return AnyView(MenuBarItemsSettings(module: module, model: model)
                    .frame(width: 680, height: order == .fine ? 440 : 540, alignment: .top).padding(20)
                    .background(Color.paper))
            })
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
        // The palette with "top" typed: Keep on Top among the actions that start with "Top".
        extras.append(SnapshotExtras(name: "window-palette-top", inDefaultSet: false) { model in
            guard let windows = model.windows else { return AnyView(EmptyView()) }
            let palette = WindowPaletteModel(module: windows)
            palette.appName = "TextEdit"
            palette.query = "top"
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
        for (name, template) in [("plugin-editor", "Uppercase Clipboard"), ("plugin-editor-card", "Git Changes"),
                                 ("plugin-editor-automation", "Battery Low Notice")] {
            extras.append(SnapshotExtras(name: name, inDefaultSet: false) { model in
                var plugin = ScriptPlugin.templates.first { $0.name == template } ?? ScriptPlugin.templates[0]
                plugin.id = UUID()
                return AnyView(PluginEditor(model: model, draft: PluginDraft(plugin: plugin, isNew: true)) {}
                    .background(Color(nsColor: .windowBackgroundColor)))
            })
        }
        // Clean Up's disk map after a scan of TUTTO_SNAPSHOT_FOLDER (default: the current folder).
        // `disk-map-in`: the same, one folder down (the biggest).
        for name in ["disk-map", "disk-map-in"] {
            extras.append(SnapshotExtras(name: name, inDefaultSet: false) { _ in
                let map = DiskMapModel()
                map.previewScan(ProcessInfo.processInfo.environment["TUTTO_SNAPSHOT_FOLDER"] ?? FileManager.default.currentDirectoryPath)
                if name == "disk-map-in", let inner = map.root?.children.first(where: \.canOpen) { map.show(inner) }
                return AnyView(DiskMapView(map: map, fullDiskAccess: false).padding(24).frame(width: 760)
                    .background(Color(nsColor: .windowBackgroundColor)))
            })
        }
        // The Agents card's design options side by side (with `agents-demo`).
        // The Agents card and page on their own (with `agents-demo`).
        extras.append(SnapshotExtras(name: "agents-card", inDefaultSet: false) { model in
            guard let agents = model.agents else { return AnyView(EmptyView()) }
            return AnyView(AgentsCard(agents: agents).frame(width: PanelGrid.content).padding(PanelGrid.outer)
                .background(PanelMaterialStandIn()))
        })
        extras.append(SnapshotExtras(name: "agents-page", inDefaultSet: false) { model in
            guard let agents = model.agents else { return AnyView(EmptyView()) }
            return AnyView(AgentsDashboard(agents: agents).padding(32).frame(width: 760)
                .background(Color(nsColor: .windowBackgroundColor)))
        })
        // Shorter-panel studies (Bryan, 2026-11-20), each at rest and after one click; the board is
        // put together from these. `study-original` is today's panel, whole, without scrolling.
        func study(_ name: String, levels: Bool = false, _ view: @escaping @MainActor (AppModel) -> some View) {
            extras.append(SnapshotExtras(name: "study-\(name)", inDefaultSet: false) { model in
                ThinScrollStage.limit = name == "original" ? 5_000 : nil
                SoundCard.startsShowingLevels = levels
                print("study: screen", NSScreen.main?.visibleFrame.height ?? 0)
                return AnyView(view(model))
            })
        }
        study("original") { MenuPanel(model: $0).background(PanelMaterialStandIn()) }
        // The shipped panel (layout A), at full height, at rest and with a control open.
        for (name, open, levels) in [("panel", nil, false), ("panel-sound", "sound", true), ("panel-clicker", "clicker", false)] as [(String, String?, Bool)] {
            extras.append(SnapshotExtras(name: name, inDefaultSet: false) { model in
                ThinScrollStage.limit = 5_000
                SoundCard.startsShowingLevels = levels
                ControlStripView.startsOpen = open
                // The clicker render also shows the Fan chip under the pointer.
                LensStage.forced = name == "panel-clicker" ? ["chip.fan", "Memory", "Battery"] : []
                return AnyView(MenuPanel(model: model).background(PanelMaterialStandIn()))
            })
        }
        study("glance") { StudyGlance(model: $0, open: nil) }
        study("glance-open") { StudyGlance(model: $0, open: "sound") }
        study("modules") { StudyModules(model: $0, open: nil) }
        study("modules-open") { StudyModules(model: $0, open: "agents") }
        study("wide") { StudyWide(model: $0) }
        study("wide-open", levels: true) { StudyWide(model: $0) }
        study("list") { StudyList(model: $0, open: nil) }
        study("list-open") { StudyList(model: $0, open: "agents") }
        extras.append(SnapshotExtras(name: "network-tiles", inDefaultSet: false) { _ in
            AnyView(PreviewNetworkTiles().background(PanelMaterialStandIn()))
        })
        extras.append(SnapshotExtras(name: "panel-states", inDefaultSet: false) { _ in
            let glances = [Glance("On battery", "4 h 9 min left"), Glance("Working hard", "CPU 91%", level: .notice),
                           Glance("Battery low", "18 min left", level: .alert)]
            let icon = NSWorkspace.shared.icon(for: .applicationBundle)
            let app = SoundApp(bundleID: "sample", name: "Sample", pid: 0, icon: icon)
            return AnyView(VStack(spacing: 8) {
                ForEach(glances, id: \.title) { glance in
                    VerdictLine(glance: glance)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: Radius.of(12), style: .continuous).fill(Color.primary.opacity(0.055)))
                }
                HStack(spacing: 0) {
                    ForEach(Array([(false, false), (false, true), (true, false)].enumerated()), id: \.offset) { _, state in
                        SoundAppButton(app: app, muted: state.0, usingAudio: state.1, size: 30) {}
                            .frame(width: 34.5, alignment: .leading)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: Radius.of(12), style: .continuous).fill(Color.primary.opacity(0.055)))
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
/// The drag wheel as a view, for snapshots.
private struct WheelSnapshot: NSViewRepresentable {
    var items: [WheelView.Item]
    func makeNSView(context: Context) -> WheelView {
        WheelView(frame: NSRect(x: 0, y: 0, width: 300, height: 300), items: items, center: .compress, highlighted: 1) { _, _ in }
    }
    func updateNSView(_ view: WheelView, context: Context) {}
}

#endif
