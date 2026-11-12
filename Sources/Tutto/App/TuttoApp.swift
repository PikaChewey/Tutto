//
//  TuttoApp.swift
//  Tutto
//
//  Every Mac utility you actually use, in one quiet menu bar app.
//

import AppKit
import SwiftUI
import TuttoKit

@main
struct TuttoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuPanel(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu bar icon; while Stay Awake runs, the time left beside it; while the auto clicker
/// clicks, its symbol, so a running clicker is never forgotten.
private struct MenuBarLabel: View {
    var model: AppModel

    var body: some View {
        let awake = model.awake?.menuBarText
        let agents = model.awake?.isAgentSession == true
        let clicking = model.clicker?.isOn == true
        let recording = model.screenshots?.recorder.recordingSince
        if awake != nil || clicking || agents || recording != nil {
            HStack(spacing: 3) {
                Image(nsImage: MenuBarGlyph.image())
                if let recording {
                    // The time, a tick a second, only while recording.
                    TimelineView(.periodic(from: recording, by: 1)) { context in
                        HStack(spacing: 3) {
                            Image(systemName: "record.circle")
                            Text(RecordingRules.elapsed(context.date.timeIntervalSince(recording))).monospacedDigit()
                        }
                    }
                }
                if agents { Image(systemName: "cup.and.heat.waves") }
                if clicking { Image(systemName: "cursorarrow.click.2") }
                if let awake { Text(awake).monospacedDigit() }
            }
            .accessibilityLabel(["Tutto", recording != nil ? "recording the screen" : nil, agents ? "staying awake while agents work" : nil,
                                 clicking ? "auto clicker on" : nil, awake.map { "staying awake, \($0) left" }]
                .compactMap { $0 }.joined(separator: ", "))
        } else {
            Image(nsImage: MenuBarGlyph.image())
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private var terminationSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        PerfLog.startWatchdog()
        guard !isRunningTests else { return }
        // `kill` (SIGTERM) quits properly too: fans back to automatic, every window the strip
        // moved back on screen.
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termination.setEventHandler { NSApp.terminate(nil) }
        termination.resume()
        terminationSignal = termination
        #if DEBUG
        if Snapshots.runIfRequested() { return NSApp.terminate(nil) }
        if AudioProbe.runIfRequested() { return NSApp.terminate(nil) }
        if #available(macOS 14.2, *), VolumeProbe.runIfRequested() { return NSApp.terminate(nil) }
        if RecordingProbe.runIfRequested() { return NSApp.terminate(nil) }
        if RecordingProbe.runScrollProbeIfRequested() { return NSApp.terminate(nil) }
        if RecordingProbe.runScrollEventsProbeIfRequested() { return NSApp.terminate(nil) }
        if RecordingProbe.runScrollFadeProbeIfRequested() { return NSApp.terminate(nil) }
        if ConvertProbe.runIfRequested() { return NSApp.terminate(nil) }
        if ConvertProbe.runCleanupIfRequested() { return NSApp.terminate(nil) }
        if SwitcherLab.runIfRequested() { return NSApp.terminate(nil) }
        if MemoryLab.runIfRequested() { return NSApp.terminate(nil) }
        #endif
        let model = AppModel.shared
        let launchedAtLogin = Self.wasLaunchedAsLoginItem()
        // `--no-shortcuts`: for measurement runs alongside other apps that own the same keys.
        model.launch(quietly: CommandLine.arguments.contains("--no-shortcuts"))
        AppActivation.followSpaceSwitchesOnActivation()
        // Once the menu bar has settled, see whether the icon ended up behind the notch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            MainActor.assumeIsolated {
                model.checkMenuBarIconVisibility()
                if model.menuBarIconHidden && model.hasCompletedOnboarding {
                    Toast.shared.show("Tutto's menu bar icon is behind the notch",
                                      detail: "Quit a menu bar app you don't need or ⌘-drag icons to make room. Click for details.",
                                      duration: 6) { MainWindowController.shared.show(page: .overview) }
                }
            }
        }
        #if DEBUG
        // `--page <name>`: open the main window on that page (live tests of a page).
        if let index = CommandLine.arguments.firstIndex(of: "--page"), CommandLine.arguments.count > index + 1,
           let page = MainPage(rawValue: CommandLine.arguments[index + 1]) {
            return MainWindowController.shared.show(page: page)
        }
        if CommandLine.arguments.contains("--strip-only") { return }
        #endif
        if !model.hasCompletedOnboarding {
            OnboardingWindowController.shared.show()
        } else if !launchedAtLogin && !CommandLine.arguments.contains("--background") {
            // Opened from Spotlight, Finder or the Dock: show the app.
            MainWindowController.shared.show()
        }
    }

    /// Opening Tutto again (Spotlight, Finder, the Dock) brings up the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindowController.shared.show()
        return false
    }

    /// Archives opened with Tutto (double-click, Open With, dropped on the icon) and
    /// `tutto://` requests from the Finder extension.
    func application(_ application: NSApplication, open urls: [URL]) {
        let model = AppModel.shared
        let files = urls.filter(\.isFileURL)
        let requests = urls.filter { $0.scheme == "tutto" }
        for request in requests {
            switch request.host {
            case "archive": ArchiveRequests.handle(request, model: model)
            case "convert":
                if let converter = model.converter {
                    converter.handle(request)
                } else {
                    Toast.shared.show("Convert is off", detail: "Switch it on in Tutto › General", duration: 3)
                }
            case "open", "do": DeepLinks.handle(request, model: model)
            default: break
            }
        }
        if !files.isEmpty { ArchiveRequests.open(files, model: model) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()  // returns fans to automatic, removes the event tap
    }

    /// True when macOS started Tutto as a login item, so it should stay in the menu bar.
    /// Uses macOS's login-item flag, and as a fallback treats a launch within three minutes
    /// of boot as a login launch (a window popping up at every startup would be worse).
    private static func wasLaunchedAsLoginItem() -> Bool {
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventID == kAEOpenApplication,
           let property = event.paramDescriptor(forKeyword: keyAEPropData),
           property.enumCodeValue == keyAELaunchedAsLogInItem {
            return true
        }
        return ProcessInfo.processInfo.systemUptime < 180
    }
}

/// `tutto://open/<page>` shows a page of the app; `tutto://do/<action>` runs an action, for
/// automation (Shortcuts, scripts, Stream Deck…).
///   pages:   overview battery cpu gpu memory disk network sensors clipboard windows switcher strip screenshots archives corner wordCounter sound shortcuts permissions general
///   actions: capture-area capture-screen capture-edit record-screen scrolling-capture clean-up clipboard windows word-counter mute-front-app quit
///            stay-awake?for=2h30 (starts, or adds time)  stay-awake-end  agent-busy (an agent is working)
///            plugin?name=<name> (runs one of your plugins; or ?id=<uuid>)
///            clicker (starts or stops; ?cps=20&button=left|right|middle&double=1&at=x,y|pointer&for=30&clicks=100)
@MainActor
enum DeepLinks {
    static func handle(_ url: URL, model: AppModel) {
        let name = url.pathComponents.dropFirst().first ?? ""
        if url.host == "open" {
            MainWindowController.shared.show(page: MainPage(rawValue: name) ?? .overview)
            return
        }
        let action: ShortcutAction? = switch name {
        case "capture-area": .captureArea
        case "capture-screen": .captureScreen
        case "capture-edit": .captureAreaEdit
        case "record-screen": .recordScreen
        case "scrolling-capture": .scrollingCapture
        case "clean-up": .cleanUp
        case "clipboard": .clipboardHistory
        case "windows": .windowPalette
        case "word-counter": .wordCounter
        case "mute-front-app": .muteFrontApp
        default: nil
        }
        if name == "stay-awake" {
            let typed = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "for" }?.value
                ?? url.pathComponents.dropFirst(2).first ?? "1h"
            if let seconds = AwakeDuration.seconds(from: typed) { model.awake?.start(for: seconds) }
            return
        }
        if name == "agent-busy" { return model.awake?.noteAgentWork() ?? () }
        if name == "plugin" {
            // ?name=Plain Text Clipboard (any case) or ?id=<uuid>. The folder is read again first,
            // so a plugin added or edited by hand runs as it is now.
            model.plugins.load()
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let wanted = items.first { $0.name == "name" }?.value ?? url.pathComponents.dropFirst(2).first
            if let id = items.first(where: { $0.name == "id" })?.value.flatMap(UUID.init(uuidString:)) {
                model.plugins.run(id, reason: .link)
            } else if let wanted, let plugin = model.plugins.plugin(named: wanted) {
                model.plugins.run(plugin, reason: .link)
            } else {
                Toast.shared.show("No plugin called “\(wanted ?? "")”", detail: "See Tutto › Plugins.", duration: 2.5)
            }
            return
        }
        if name == "theme" {
            // ?name=Midnight: a built-in theme or one of your theme files (from a script or a plugin's schedule).
            let wanted = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "name" }?.value ?? ""
            let theme = ThemeStore.shared
            theme.loadFiles()
            guard let spec = (ThemeSpec.builtIn + theme.files.map(\.spec))
                .first(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) else {
                return Toast.shared.show("No theme called “\(wanted)”", detail: "See Tutto › Appearance.", duration: 2.5)
            }
            return theme.apply(spec)
        }
        if name == "event" {
            // ?name=build-done&info=… : runs the plugins with a custom-event trigger of that name.
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard let event = items.first(where: { $0.name == "name" })?.value else { return }
            return model.plugins.host.fireCustom(name: event, info: items.first { $0.name == "info" }?.value)
        }
        if name == "clicker" {
            // Optional settings first: ?cps=20&button=right&double=1&at=640,400 (or at=pointer)&for=30 (seconds)&clicks=100
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if !items.isEmpty { model.clicker?.apply(items) }
            return model.clicker?.toggle() ?? ()
        }
        if name == "stay-awake-end" { return model.awake?.endNow() ?? () }
        if name == "lid-closed" || name == "lid-open" { return model.awake?.simulateLid(closed: name == "lid-closed") ?? () }
        if name == "quit" {
            NSApp.terminate(nil)  // runs the normal shutdown (fans back to automatic, tap removed)
            return
        }
        if let action { model.perform(action) }
    }
}
