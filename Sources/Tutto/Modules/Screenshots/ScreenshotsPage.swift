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
                       subtitle: "Capture straight to the clipboard, or into an editor to draw, crop, pick colors and copy text. Record the screen to MP4.",
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
                .background(Color.wash, in: RoundedRectangle(cornerRadius: Radius.of(12), style: .continuous))
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
                LabeledRow("Area to editor", detail: "Draw, crop, copy text (T), pick a color (Tab), save (⌘S, where you choose below). Esc copies and closes.") {
                    ShortcutRecorder(action: .captureAreaEdit, model: model)
                }
            }
            RecordingSettings(recorder: screenshots.recorder, model: model)
            InkGroup("While selecting") {
                tip("Drag", "select an area; the pointer shows its position, then the size, in pixels")
                tip("Click", "a window takes just that window; the desktop takes the whole screen")
                tip("Shift", "square selection · Space + drag moves it")
                tip("Tab", "copies the color under the crosshair")
                tip("Esc", "cancels")
            }
            InkGroup("Saving") {
                LabeledRow("When you save in the editor",
                           detail: screenshots.askWhereToSave
                               ? "⌘S and Save open the save window: pick the folder, rename it, add tags, PNG or JPEG. ⇧⌘S saves straight to the folder below."
                               : "⌘S and Save put it in the folder below, named with the date and time. ⇧⌘S opens the save window.") {
                    InkSegmented(selection: $screenshots.askWhereToSave, options: [(true, "Ask where"), (false, "Save to folder")])
                        .fixedSize()
                }
                Hairline().opacity(0.6)
                LabeledRow(screenshots.askWhereToSave ? "Folder" : "Save to",
                           detail: screenshots.saveFolderPath.replacingOccurrences(of: NSHomeDirectory(), with: "~")
                               + (screenshots.askWhereToSave ? " · for ⇧⌘S and quick captures; the save window opens where you last saved" : "")) {
                    Button("Choose…") { chooseFolder() }
                        .buttonStyle(OutlineButtonStyle(compact: true))
                }
                Hairline().opacity(0.6)
                LabeledRow("Format") {
                    InkSegmented(selection: $screenshots.format, options: [(.png, "PNG"), (.jpeg, "JPEG")])
                }
                Hairline().opacity(0.6)
                LabeledRow("Also save quick captures", detail: "Keep a file of every ⌘⇧` / ⌘⇧2 capture in the folder above (never asks), not just the clipboard copy.") {
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
            Text(key.uppercased()).font(.geist(10, weight: .semibold)).foregroundStyle(Color.ink2).frame(width: 52, alignment: .leading)
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


/// Screen recording: its key, what goes into the movie, and the file it makes.
private struct RecordingSettings: View {
    @Bindable var recorder: ScreenRecorder
    @Bindable var model: AppModel

    var body: some View {
        InkGroup("Screen recording") {
            LabeledRow("Record", detail: ScreenRecorder.isSupported
                       ? "Pick an area, a window or the whole screen; a 3-2-1, then it records. Press the keys again, or Stop in the menu bar, to finish: an MP4 lands in the screenshots folder."
                       : "Needs macOS 15 or later.") {
                ShortcutRecorder(action: .recordScreen, model: model)
            }
            Hairline().opacity(0.6)
            LabeledRow("The Mac's sound", detail: "What apps play while you record (not Tutto's own sounds).") {
                InkSwitch(isOn: $recorder.recordSystemAudio, label: "Record the Mac's sound")
            }
            Hairline().opacity(0.6)
            LabeledRow("The microphone", detail: "Your voice over the recording. macOS asks the first time.") {
                InkSwitch(isOn: $recorder.recordMicrophone, label: "Record the microphone")
            }
            Hairline().opacity(0.6)
            LabeledRow("Show clicks", detail: "A ring where you click, so viewers can follow along.") {
                InkSwitch(isOn: $recorder.showClicks, label: "Show clicks")
            }
            Hairline().opacity(0.6)
            LabeledRow("Show the pointer") {
                InkSwitch(isOn: $recorder.showPointer, label: "Show the pointer")
            }
            Hairline().opacity(0.6)
            LabeledRow("Video", detail: recorder.codec == .h264
                       ? "MP4, H.264: plays everywhere (messages, browsers, Windows)."
                       : "MP4, HEVC: about half the size at the same quality; most current devices play it.") {
                InkSegmented(selection: $recorder.codec, options: RecordingCodec.allCases.map { ($0, $0.title) })
                    .fixedSize()
            }
            Hairline().opacity(0.6)
            LabeledRow("Frames per second", detail: "60 for smooth scrolling and motion; 30 makes smaller files.") {
                InkSegmented(selection: $recorder.framesPerSecond, options: [(30, "30"), (60, "60")])
                    .fixedSize()
            }
            Hairline().opacity(0.6)
            LabeledRow("Countdown", detail: "Time to get ready before it starts.") {
                InkSegmented(selection: $recorder.countdownSeconds, options: [(0, "Off"), (3, "3 s"), (5, "5 s")])
                    .fixedSize()
            }
        }
    }
}
