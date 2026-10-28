//
//  TuttoApp.swift
//  Tutto
//
//  Every Mac utility you actually use, in one quiet menu bar app.
//

import AppKit
import SwiftUI

@main
struct TuttoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuPanel(model: model)
        } label: {
            Image(nsImage: MenuBarGlyph.image())
        }
        .menuBarExtraStyle(.window)
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
        if SwitcherLab.runIfRequested() { return NSApp.terminate(nil) }
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
///   actions: capture-area capture-screen capture-edit clipboard windows word-counter mute-front-app quit
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
        case "clipboard": .clipboardHistory
        case "windows": .windowPalette
        case "word-counter": .wordCounter
        case "mute-front-app": .muteFrontApp
        default: nil
        }
        if name == "quit" {
            NSApp.terminate(nil)  // runs the normal shutdown (fans back to automatic, tap removed)
            return
        }
        if let action { model.perform(action) }
    }
}
