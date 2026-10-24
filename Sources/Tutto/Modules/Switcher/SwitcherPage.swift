//
//  SwitcherPage.swift
//  Tutto
//
//  The Window Switcher page: what triggers it, what it includes, its keys, the names you've
//  given windows, and apps to leave out.
//

import AppKit
import SwiftUI
import TuttoKit

struct SwitcherPage: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: "Window Switcher",
                       subtitle: "Hold ⌘ and press Tab to see every window, not just every app. Each Firefox window gets its own card. Let go to switch.",
                       module: .switcher)
            if let switcher = model.switcher {
                SwitcherSettings(switcher: switcher, model: model)
            } else {
                ModuleOffView(module: .switcher, model: model)
            }
        }
    }
}

private struct SwitcherSettings: View {
    @Bindable var switcher: SwitcherModule
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if !switcher.isListening {
                InkGroup {
                    LabeledRow("Allow Accessibility to use the switcher",
                               detail: "Until then ⌘Tab stays with macOS. Privacy & Security › Accessibility.") {
                        Button("Allow") { model.permissions.request(.accessibility) }
                            .buttonStyle(InkButtonStyle(compact: true))
                    }
                }
            }
            InkGroup {
                LabeledRow("Open with", detail: switcher.trigger == .command
                           ? "⌘Tab shows windows. macOS's app switcher comes back if you turn this off or quit Tutto."
                           : "⌥Tab shows windows; ⌘Tab stays macOS's app switcher.") {
                    InkSegmented(selection: $switcher.trigger,
                                 options: [(SwitcherKeyTap.Trigger.command, "⌘ Tab"), (.option, "⌥ Tab")])
                }
                Hairline().opacity(0.6)
                LabeledRow("\(switcher.trigger == .command ? "⌘" : "⌥")` shows the front app's windows",
                           detail: "Just the windows of the app you're in, like all your Firefox windows.") {
                    InkSwitch(isOn: $switcher.appWindowsKey, label: "Key above Tab shows the front app's windows")
                }
                Hairline().opacity(0.6)
                LabeledRow("Windows from", detail: "Every Space and full-screen app, or only the Space you're on.") {
                    InkSegmented(selection: $switcher.scope, options: [(SwitcherModule.Scope.allSpaces, "All Spaces"),
                                                                       (.currentSpace, "This Space")])
                }
            }
            InkGroup("Show") {
                toggle("Window pictures", detail: model.permissions.screenRecording
                       ? "A live look at each window. Taken only while the switcher is open."
                       : "Needs Screen Recording (Permissions). Without it, cards show the app's icon.",
                       isOn: $switcher.showPreviews)
                Hairline().opacity(0.6)
                toggle("Minimized windows", detail: "Dimmed; picking one brings it back.", isOn: $switcher.includeMinimized)
                Hairline().opacity(0.6)
                toggle("Hidden apps", detail: "Windows of apps hidden with ⌘H; picking one unhides the app.", isOn: $switcher.includeHidden)
                Hairline().opacity(0.6)
                toggle("Apps with no windows open", detail: "After the windows, so apps like Finder stay one key away.",
                       isOn: $switcher.includeWindowless)
                Hairline().opacity(0.6)
                toggle("Key hints", detail: "The row of keys along the bottom of the switcher.", isOn: $switcher.showHints)
            }
            InkGroup("Keys while it's open") {
                keys([("Tab · ⇧Tab · ← →", "Next and previous window"),
                      ("1 – 9", "Switch to that card straight away"),
                      ("Let go of \(switcher.trigger == .command ? "⌘" : "⌥") · ↩ · click", "Switch to the selected window"),
                      ("`", "Only the selected app's windows (press again for all)"),
                      ("W · M · Q · H", "Close the window, minimize it, quit its app, hide its app"),
                      ("F · C · N", "Fill the screen, centre, or move to the next display, then switch"),
                      ("R", "Rename the window (an empty name puts its title back)"),
                      ("/ or S", "Search by name, title or app"),
                      ("Esc", "Close without switching")])
            }
            if !switcher.names.isEmpty {
                InkGroup("Renamed windows") {
                    ForEach(Array(switcher.names.enumerated()), id: \.offset) { index, name in
                        LabeledRow(name.name, detail: "\(AppNames.appName(for: name.bundleID)) · \(name.title.isEmpty ? "untitled" : name.title)") {
                            Button("Forget") { switcher.forgetName(name) }
                                .buttonStyle(OutlineButtonStyle(compact: true))
                        }
                        if index < switcher.names.count - 1 { Hairline().opacity(0.6) }
                    }
                }
            }
            InkGroup("Leave out", trailing: AnyView(addAppMenu)) {
                if switcher.excluded.isEmpty {
                    Text("Every app's windows are shown. Leave out an app with Add.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.ink3)
                        .padding(.vertical, Metrics.rowPadding)
                }
                ForEach(Array(switcher.excluded.enumerated()), id: \.element) { index, bundleID in
                    LabeledRow(AppNames.appName(for: bundleID)) {
                        Button("Show Again") { switcher.include(bundleID) }
                            .buttonStyle(OutlineButtonStyle(compact: true))
                    }
                    if index < switcher.excluded.count - 1 { Hairline().opacity(0.6) }
                }
            }
            Text("While you type in a password field, macOS keeps keystrokes private from every app, so ⌘Tab shows macOS's own switcher there.")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var addAppMenu: some View {
        Menu("Add") {
            ForEach(runningApps, id: \.bundleIdentifier) { app in
                Button(app.localizedName ?? app.bundleIdentifier ?? "App") {
                    if let id = app.bundleIdentifier { switcher.exclude(id) }
                }
            }
        }
        .menuStyle(.button)
        .buttonStyle(OutlineButtonStyle(compact: true))
        .fixedSize()
    }

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && !switcher.excluded.contains($0.bundleIdentifier!) }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func toggle(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        LabeledRow(title, detail: detail) {
            InkSwitch(isOn: isOn, label: title)
        }
    }

    private func keys(_ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(row.0)
                        .font(.geist(11, weight: .semibold))
                        .foregroundStyle(Color.ink)
                        .frame(width: 170, alignment: .leading)
                    Text(row.1)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 8)
                if index < rows.count - 1 { Hairline().opacity(0.6) }
            }
        }
    }
}

/// An app's name from its bundle id, whether or not it's running.
enum AppNames {
    static func appName(for bundleID: String) -> String {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName { return running }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}
