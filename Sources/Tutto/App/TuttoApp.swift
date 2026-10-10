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

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isRunningTests else { return }
        #if DEBUG
        if Snapshots.runIfRequested() { return NSApp.terminate(nil) }
        #endif
        let model = AppModel.shared
        let launchedAtLogin = Self.wasLaunchedAsLoginItem()
        model.launch()
        if !model.hasCompletedOnboarding {
            OnboardingWindowController.shared.show()
        } else if !launchedAtLogin && !CommandLine.arguments.contains("--background") {
            // Opened from Spotlight, Finder or the Dock: show the app.
            MainWindowController.shared.show()
        }
    }

    /// Opening Tutto again (Spotlight, Finder, Raycast) brings up the main window.
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
        for request in requests { ArchiveRequests.handle(request, model: model) }
        if !files.isEmpty { ArchiveRequests.open(files, model: model) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()  // returns fans to automatic, removes the event tap
    }

    /// True when macOS started Tutto as a login item, so it should stay in the menu bar.
    private static func wasLaunchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == kAEOpenApplication,
              let property = event.paramDescriptor(forKeyword: keyAEPropData) else { return false }
        return property.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
