//
//  ConverterPage.swift
//  Tutto
//
//  Tools › Convert: compressing by itself (which folders, which kinds, the clipboard, how long
//  originals are kept), the ways in (the panel's card, the window, the wheel, Finder), how hard
//  Compress works by default, and where results go.
//

import SwiftUI
import TuttoKit

struct ConverterPage: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Convert",
                       subtitle: "Pictures, video, PDFs and sound smaller, in other formats, resized or cropped, on this Mac; new screenshots and copied pictures compressed by themselves.",
                       module: .converter)
            if let converter = model.converter {
                ConverterSettings(converter: converter, model: model)
            } else {
                ModuleOffView(module: .converter, model: model)
            }
        }
    }
}

private struct ConverterSettings: View {
    @Bindable var converter: ConverterModule
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            AutoCompressGroup(converter: converter)
            InkGroup("Ways in") {
                LabeledRow("The panel's Convert & Compress card", detail: "Drop files on Compress, Convert, Resize or Crop (the card opens while you drag from Finder, and the panel stays open), or click one to choose files; drop on Tutto's menu bar icon for the one used last. Compress can make a .zip instead; archives dropped on it are unpacked. ⌥ when you drop opens the window instead.") {
                    EmptyView()
                }
                Hairline().opacity(0.6)
                LabeledRow("Convert window", detail: "Drop files, pick a format, a size or a shape, or Compress with its settings.") {
                    HStack(spacing: 8) {
                        Button("Open") { ConvertWindowController.shared.show(module: converter) }
                            .buttonStyle(OutlineButtonStyle(compact: true))
                        ShortcutRecorder(action: .convertFiles, model: model)
                    }
                }
                Hairline().opacity(0.6)
                LabeledRow("Tap ⇧ while dragging files",
                           detail: "A wheel of formats opens at the pointer, Compress in the middle; drop on one. Tap ⇧ again, or drop anywhere else, and it closes.") {
                    InkSwitch(isOn: $converter.wheelEnabled, label: "Wheel while dragging")
                }
                Hairline().opacity(0.6)
                LabeledRow("Finder", detail: "Right-click files › Convert: the formats they can become, Compress, Resize, Crop, and More… for this window.") {
                    EmptyView()
                }
            }
            InkGroup("Compress, by default") {
                LabeledRow("Picture quality", detail: "JPEG, HEIC and AVIF. PNGs become palette PNGs when that looks the same.") {
                    HStack(spacing: 8) {
                        Slider(value: Binding(get: { converter.settings.imageQuality }, set: { converter.settings.imageQuality = ($0 * 20).rounded() / 20 }),
                               in: 0.1...1)
                            .frame(width: 140)
                        Text("\(Int((converter.settings.imageQuality * 100).rounded())) %")
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                Hairline().opacity(0.6)
                LabeledRow("Pictures' longest side") {
                    Picker("", selection: Binding(get: { converter.settings.imageMaxSide ?? 0 }, set: { converter.settings.imageMaxSide = $0 == 0 ? nil : $0 })) {
                        ForEach(CompressionSettings.imageSides, id: \.self) { side in Text(side.map { "\(String($0)) px" } ?? "As it is").tag(side ?? 0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Hairline().opacity(0.6)
                LabeledRow("Remove location and camera details", detail: "From compressed pictures (the picture is turned upright first).") {
                    InkSwitch(isOn: $converter.settings.removeImageDetails, label: "Remove location and camera details")
                }
                Hairline().opacity(0.6)
                LabeledRow("Video") {
                    HStack(spacing: 8) {
                        InkSegmented(selection: $converter.settings.videoQuality,
                                     options: CompressionSettings.VideoQuality.allCases.map { ($0, $0.title) })
                            .fixedSize()
                        Picker("", selection: Binding(get: { converter.settings.videoMaxHeight ?? 0 }, set: { converter.settings.videoMaxHeight = $0 == 0 ? nil : $0 })) {
                            ForEach(CompressionSettings.videoHeights, id: \.self) { height in
                                Text(height.map { $0 == 2160 ? "4K" : "\(String($0))p" } ?? "As it is").tag(height ?? 0)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                Hairline().opacity(0.6)
                LabeledRow("Video codec", detail: converter.settings.videoCodec == .h264 ? "H.264 plays everywhere." : "HEVC is about half the size; most current devices play it.") {
                    InkSegmented(selection: $converter.settings.videoCodec, options: CompressionSettings.VideoCodec.allCases.map { ($0, $0.title) })
                        .fixedSize()
                }
                Hairline().opacity(0.6)
                LabeledRow("PDFs", detail: converter.settings.pdfLevel == .light
                           ? "Light: pictures inside become JPEG at full resolution; prints as before."
                           : "Strong: pictures inside also come down to screen resolution; for email.") {
                    InkSegmented(selection: $converter.settings.pdfLevel, options: CompressionSettings.PDFLevel.allCases.map { ($0, $0.title) })
                        .fixedSize()
                }
                Hairline().opacity(0.6)
                LabeledRow("Sound", detail: "Compressed sound becomes AAC in an M4A file.") {
                    Picker("", selection: $converter.settings.audioKbps) {
                        ForEach(CompressionSettings.audioRates, id: \.self) { rate in Text("\(rate) kbps").tag(rate) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            InkGroup("When it's done") {
                LabeledRow("Show the results in Finder", detail: "Otherwise a note says what was made; click it to show them.") {
                    InkSwitch(isOn: $converter.revealWhenDone, label: "Show results in Finder")
                }
            }
            InkGroup("What it can make") {
                ForEach(FileKind.allCases.filter { $0 != .other }, id: \.self) { kind in
                    LabeledRow(kind.title, detail: ConvertPlanner.targets(for: kind).map(\.title).joined(separator: ", ")
                               + (ConvertPlanner.canCompress(kind) ? " · Compress" : "")) { EmptyView() }
                    if kind != .subtitles { Hairline().opacity(0.6) }
                }
            }
        }
    }
}

/// Compressing by itself: on or off, where, what, and how long originals are kept to undo.
private struct AutoCompressGroup: View {
    @Bindable var converter: ConverterModule

    var body: some View {
        InkGroup("Compress by itself") {
            LabeledRow("New files and copied pictures",
                       detail: "Screenshots, screen recordings and PDFs that appear in the folders below, Tutto's own screenshots, and pictures copied to the clipboard are made smaller in place. A card shows how much, with Undo; the original is kept \(converter.auto.keepOriginalsDays) days. Batches (an export, a download of many) are left alone.") {
                InkSwitch(isOn: $converter.auto.isOn, label: "Compress by itself")
            }
            if converter.auto.isOn {
                Hairline().opacity(0.6)
                LabeledRow("Watched folders", detail: folderDetail) {
                    HStack(spacing: 8) {
                        if !converter.auto.folders.isEmpty {
                            Button("Desktop Only") { converter.auto.folders = [] }
                                .buttonStyle(OutlineButtonStyle(compact: true))
                                .help("Back to the Desktop (and where macOS saves screenshots)")
                        }
                        Button("Add Folder…") { addFolder() }
                            .buttonStyle(OutlineButtonStyle(compact: true))
                    }
                }
                ForEach(converter.auto.folders, id: \.self) { path in
                    HStack(spacing: 8) {
                        Image(systemName: "folder").foregroundStyle(Color.ink3)
                        Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.system(size: 12))
                            .foregroundStyle(Color.ink2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Remove") { converter.auto.folders.removeAll { $0 == path } }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.ink3)
                    }
                    .padding(.leading, 4)
                }
                Hairline().opacity(0.6)
                LabeledRow("What", detail: "Pictures keep their format (PNG screenshots become palette PNGs when that looks the same); videos are re-encoded as set below; PDFs as set below. Signed PDFs are left alone.") {
                    HStack(spacing: 12) {
                        Toggle("Pictures", isOn: $converter.auto.images)
                        Toggle("Videos", isOn: $converter.auto.videos)
                        Toggle("PDFs", isOn: $converter.auto.pdfs)
                    }
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                }
                Hairline().opacity(0.6)
                LabeledRow("Copied pictures", detail: "A picture copied on its own (a screenshot copied with ⌃⇧⌘4, say) is made smaller before you paste it. Copies that carry text, a link or a file, and HEIC, stay as they are.") {
                    InkSwitch(isOn: $converter.auto.clipboard, label: "Compress copied pictures")
                }
                Hairline().opacity(0.6)
                LabeledRow("Retina screenshots at half size", detail: "Half the pixels of a screenshot from a Retina screen: it looks the same on most screens people see it on, at about a quarter of the size.") {
                    InkSwitch(isOn: $converter.auto.halveRetinaScreenshots, label: "Retina screenshots at half size")
                }
                Hairline().opacity(0.6)
                LabeledRow("Keep originals", detail: "To undo a compress. Older ones are cleared, and the oldest once they pass 4 GB.") {
                    HStack(spacing: 8) {
                        Picker("", selection: $converter.auto.keepOriginalsDays) {
                            ForEach(AutoCompressSettings.keepChoices, id: \.self) { days in Text(days == 1 ? "1 day" : "\(days) days").tag(days) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Button("Show") {
                            try? FileManager.default.createDirectory(at: OriginalsStore.folder, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(OriginalsStore.folder)
                        }
                        .buttonStyle(OutlineButtonStyle(compact: true))
                    }
                }
            }
            if converter.savedBytes > 0 {
                Hairline().opacity(0.6)
                LabeledRow("Saved so far", detail: "Bytes Tutto's compressing has saved, by hand and by itself.") {
                    Text(SavedBytes.text(converter.savedBytes))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color.ink)
                }
            }
        }
    }

    private var folderDetail: String {
        let folders = converter.watching.isEmpty ? WatchedFolders.resolve(converter.auto) : converter.watching
        let list = folders.map { $0.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }.joined(separator: ", ")
        return converter.auto.folders.isEmpty ? "\(list) (the Desktop, and where macOS saves screenshots)" : list
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Watch"
        panel.message = "New pictures, videos and PDFs in these folders are compressed by themselves"
        guard panel.runModal() == .OK else { return }
        var folders = converter.auto.folders.isEmpty ? WatchedFolders.defaults.map(\.path) : converter.auto.folders
        for url in panel.urls where !folders.contains(url.path) { folders.append(url.path) }
        converter.auto.folders = folders
    }
}
