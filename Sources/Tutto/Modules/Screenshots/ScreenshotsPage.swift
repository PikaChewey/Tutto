//
//  ScreenshotsPage.swift
//  Tutto
//

import AppKit
import SwiftUI

struct ScreenshotsPage: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Screenshots",
                       subtitle: "Capture straight to the clipboard, or into an editor to draw, crop, pick colors and copy text.",
                       module: .screenshots)
            if let screenshots = model.screenshots {
                ScreenshotSettings(screenshots: screenshots, model: model)
            } else {
                ModuleOffView(module: .screenshots, model: model)
            }
        }
    }
}

private struct ScreenshotSettings: View {
    @Bindable var screenshots: ScreenshotModule
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if !model.permissions.screenRecording {
                HStack(spacing: 12) {
                    Image(systemName: "lock").foregroundStyle(Color.ink2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Screen Recording is off").font(.system(size: 13, weight: .semibold))
                        Text("macOS needs your OK before any app can capture the screen. Tutto only captures when you press a shortcut.")
                            .font(.system(size: 11.5)).foregroundStyle(Color.ink3).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Allow") { model.permissions.request(.screenRecording) }
                        .buttonStyle(InkButtonStyle(compact: true))
                }
                .padding(14)
                .background(Color.wash, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            InkGroup("Shortcuts") {
                LabeledRow("Area to clipboard", detail: "Select, release, it's copied. No editor.") {
                    ShortcutRecorder(action: .captureArea, model: model)
                }
                Hairline().opacity(0.6)
                LabeledRow("Full screen to clipboard", detail: "The display under the pointer.") {
                    ShortcutRecorder(action: .captureScreen, model: model)
                }
                Hairline().opacity(0.6)
                LabeledRow("Area to editor", detail: "Draw, crop, copy text (T), pick a color (Tab), save (⌘S). Esc copies and closes.") {
                    ShortcutRecorder(action: .captureAreaEdit, model: model)
                }
            }
            InkGroup("While selecting") {
                tip("Drag", "select an area; the pointer shows its position, then the size, in pixels")
                tip("Click", "a window takes just that window; the desktop takes the whole screen")
                tip("Shift", "square selection · Space + drag moves it")
                tip("Tab", "copies the color under the crosshair")
                tip("Esc", "cancels")
            }
            InkGroup("Saving") {
                LabeledRow("Save to", detail: screenshots.saveFolderPath.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                    Button("Choose…") { chooseFolder() }
                        .buttonStyle(OutlineButtonStyle(compact: true))
                }
                Hairline().opacity(0.6)
                LabeledRow("Format") {
                    InkSegmented(selection: $screenshots.format, options: [(.png, "PNG"), (.jpeg, "JPEG")])
                }
                Hairline().opacity(0.6)
                LabeledRow("Also save quick captures", detail: "Keep a file of every ⌘⇧1 / ⌘⇧2 capture, not just the clipboard copy.") {
                    InkSwitch(isOn: $screenshots.alsoSaveQuickCaptures, label: "Also save quick captures")
                }
                Hairline().opacity(0.6)
                LabeledRow("Shutter sound") {
                    InkSwitch(isOn: $screenshots.playSound, label: "Shutter sound")
                }
            }
        }
    }

    private func tip(_ key: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(key.uppercased()).font(.mono(10, weight: .semibold)).foregroundStyle(Color.ink2).frame(width: 52, alignment: .leading)
            Text(text).font(.system(size: 12)).foregroundStyle(Color.ink2)
            Spacer()
        }
        .padding(.vertical, 7)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = screenshots.saveFolder
        if panel.runModal() == .OK, let url = panel.url { screenshots.saveFolderPath = url.path }
    }
}
