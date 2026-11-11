//
//  ConverterPage.swift
//  Tutto
//
//  Tools › Convert: the ways in (window, wheel, Finder), how hard Compress works by default, and
//  where results go.
//

import SwiftUI
import TuttoKit

struct ConverterPage: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Convert",
                       subtitle: "Pictures, video, sound, PDFs, documents and subtitles into other formats, or smaller, on this Mac. The originals stay as they are.",
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
            InkGroup("Ways in") {
                LabeledRow("Convert window", detail: "Drop files, pick a format or Compress. Also the Convert tile in the menu bar panel.") {
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
                LabeledRow("Finder", detail: "Right-click files › Convert: the formats they can become, Compress, and More… for this window.") {
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
