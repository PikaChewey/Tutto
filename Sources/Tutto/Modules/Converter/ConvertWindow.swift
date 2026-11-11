//
//  ConvertWindow.swift
//  Tutto
//
//  The Convert window (the panel's Convert tile, ⌃⇧K, Finder's Convert › More…): drop files or
//  choose them; the formats they can all become are one click each; Compress shows the settings
//  for the kinds present (quality and size for pictures, quality, size and codec for video, how
//  hard for PDFs, the bit rate for sound). What was just made is listed to drag out or show.
//

import AppKit
import SwiftUI
import TuttoKit
import UniformTypeIdentifiers

@MainActor
@Observable
final class ConvertSelection {
    var files: [URL] = []
    var kinds: [FileKind] { files.map(FileKind.of) }
}

@MainActor
final class ConvertWindowController: NSObject, NSWindowDelegate {
    static let shared = ConvertWindowController()

    private var window: NSPanel?
    private let selection = ConvertSelection()

    func show(module: ConverterModule, files: [URL] = []) {
        if !files.isEmpty { selection.files = files }
        if window == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 560),
                                styleMask: [.titled, .closable, .fullSizeContentView, .utilityWindow], backing: .buffered, defer: false)
            panel.title = "Convert"
            panel.titlebarAppearsTransparent = true
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
            panel.delegate = self
            let host = NSHostingView(rootView: ConvertView(module: module, selection: selection))
            host.sizingOptions = [.preferredContentSize]
            panel.contentView = host
            panel.center()
            window = panel
        }
        AppActivation.present(window!)
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        selection.files = []
        DispatchQueue.main.async { MainActor.assumeIsolated { AppActivation.update() } }
    }
}

struct ConvertView: View {
    @Bindable var module: ConverterModule
    @Bindable var selection: ConvertSelection
    @State private var targeted = false
    @State private var targetText = ""

    private var targets: [OutputFormat] { ConvertPlanner.targets(for: selection.kinds) }
    private var compressible: Bool { selection.kinds.contains(where: ConvertPlanner.canCompress) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Convert")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.ink)
                    Text("On this Mac, beside the originals, which stay as they are.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.ink3)
                }
                files
                if !selection.files.isEmpty {
                    if targets.isEmpty && !compressible {
                        Text("Tutto can't convert these yet. Pictures, video, sound, PDFs, documents and subtitles it can.")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.ink3)
                    }
                    if !targets.isEmpty { convertSection }
                    if compressible { compressSection }
                }
                if !module.made.isEmpty { madeSection }
            }
            .padding(.horizontal, 20)
            .padding(.top, 34)
            .padding(.bottom, 20)
        }
        .frame(width: 440)
        .frame(minHeight: 300, idealHeight: 560, maxHeight: 760)
        .background(Color.surface)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            load(providers)
            return true
        }
        .onAppear { targetText = module.settings.imageTargetBytes.map { ConverterModule.bytes($0) } ?? "" }
    }

    // MARK: Files

    @ViewBuilder
    private var files: some View {
        if selection.files.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(targeted ? Color.themeAccent : Color.ink3)
                Text("Drop files here")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.ink)
                Text("Or drag files anywhere and tap ⇧ for the wheel")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.ink3)
                Button("Choose Files…") { choose() }
                    .buttonStyle(OutlineButtonStyle(compact: true))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 170)
            .background(RoundedRectangle(cornerRadius: Radius.of(12), style: .continuous)
                .strokeBorder(targeted ? Color.themeAccent : Color.ink.opacity(0.18), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(summary)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.ink2)
                    Spacer()
                    Button("Add…") { choose() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.ink3)
                    Button("Clear") { selection.files = [] }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.ink3)
                }
                ForEach(selection.files.prefix(4), id: \.self) { url in
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                            .resizable()
                            .frame(width: 22, height: 22)
                        Text(url.lastPathComponent)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 6)
                        Text(ConverterModule.bytes(ConverterModule.size(of: url)))
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(Color.ink3)
                    }
                }
                if selection.files.count > 4 {
                    Text("and \(selection.files.count - 4) more")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.ink3)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: Radius.of(12), style: .continuous).fill(Color.ink.opacity(targeted ? 0.09 : 0.045)))
        }
    }

    private var summary: String {
        let kinds = Dictionary(grouping: selection.kinds, by: { $0 })
        return kinds.sorted { $0.value.count > $1.value.count }.map { kind, list in kind.count(list.count) }.joined(separator: ", ")
    }

    // MARK: Convert

    private var convertSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Convert to")
            FlowLayout(spacing: 6) {
                ForEach(targets, id: \.self) { format in
                    Button {
                        module.run(.convert(format), on: selection.files)
                    } label: {
                        Text(chipTitle(format))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.ink)
                            .padding(.horizontal, 11)
                            .frame(height: 28)
                            .background(RoundedRectangle(cornerRadius: Radius.of(8), style: .continuous).fill(Color.ink.opacity(0.07)))
                    }
                    .buttonStyle(PressStyle())
                    .help(help(format))
                }
            }
        }
    }

    private func chipTitle(_ format: OutputFormat) -> String {
        ConvertPlanner.combines(selection.kinds, into: format) ? "One PDF" : format.title
    }

    private func help(_ format: OutputFormat) -> String {
        if ConvertPlanner.combines(selection.kinds, into: format) { return "All of them into one PDF, a page each, in this order" }
        if selection.kinds.allSatisfy({ $0 == .pdf }), format != .txt { return "Every page as a picture at 300 dpi" }
        if selection.kinds.allSatisfy({ $0 == .video }), format == .gif { return "The first 30 seconds as an animated GIF" }
        if selection.kinds.allSatisfy({ $0 == .video }), format == .m4a { return "Just the sound" }
        return "A \(format.title) copy beside each original"
    }

    // MARK: Compress

    private var compressSection: some View {
        let kinds = Set(selection.kinds)
        return VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Compress")
            VStack(alignment: .leading, spacing: 10) {
                if kinds.contains(.image) { imageSettings }
                if kinds.contains(.video) { videoSettings }
                if kinds.contains(.pdf) { pdfSettings }
                if kinds.contains(.audio) { audioSettings }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: Radius.of(12), style: .continuous).fill(Color.ink.opacity(0.045)))
            Button {
                module.run(.compress, on: selection.files.filter { ConvertPlanner.canCompress(FileKind.of($0)) })
            } label: {
                Text(selection.files.count == 1 ? "Compress" : "Compress \(selection.files.filter { ConvertPlanner.canCompress(FileKind.of($0)) }.count) Files")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(InkButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
    }

    private var imageSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            kindLabel("Pictures")
            row("Quality") {
                HStack(spacing: 8) {
                    Slider(value: Binding(get: { module.settings.imageQuality }, set: { module.settings.imageQuality = ($0 * 20).rounded() / 20 }),
                           in: 0.1...1)
                        .frame(width: 150)
                    Text("\(Int((module.settings.imageQuality * 100).rounded())) %")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(Color.ink2)
                        .frame(width: 40, alignment: .trailing)
                }
            }
            row("Longest side") {
                Picker("", selection: Binding(get: { module.settings.imageMaxSide ?? 0 }, set: { module.settings.imageMaxSide = $0 == 0 ? nil : $0 })) {
                    ForEach(CompressionSettings.imageSides, id: \.self) { side in
                        Text(side.map { "\(String($0)) px" } ?? "As it is").tag(side ?? 0)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            row("At most") {
                HStack(spacing: 6) {
                    TextField("No limit", text: $targetText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 96)
                        .onSubmit(applyTarget)
                        .onChange(of: targetText) { _, _ in applyTarget() }
                    if !targetText.isEmpty && ByteSizeText.bytes(targetText) == nil {
                        Text("like 500 KB")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.ink3)
                    }
                }
            }
            Toggle("Remove location and camera details", isOn: $module.settings.removeImageDetails)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
        }
    }

    private func applyTarget() {
        module.settings.imageTargetBytes = ByteSizeText.bytes(targetText)
    }

    private var videoSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            kindLabel("Video")
            row("Quality") {
                InkSegmented(selection: $module.settings.videoQuality,
                             options: CompressionSettings.VideoQuality.allCases.map { ($0, $0.title) })
                    .fixedSize()
            }
            row("Size") {
                Picker("", selection: Binding(get: { module.settings.videoMaxHeight ?? 0 }, set: { module.settings.videoMaxHeight = $0 == 0 ? nil : $0 })) {
                    ForEach(CompressionSettings.videoHeights, id: \.self) { height in
                        Text(height.map { $0 == 2160 ? "4K" : "\(String($0))p" } ?? "As it is").tag(height ?? 0)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            row("Codec") {
                InkSegmented(selection: $module.settings.videoCodec,
                             options: CompressionSettings.VideoCodec.allCases.map { ($0, $0.title) },
                             help: { $0 == .h264 ? "Plays everywhere" : "About half the size; most current devices play it" })
                    .fixedSize()
            }
        }
    }

    private var pdfSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            kindLabel("PDFs")
            row("How hard") {
                InkSegmented(selection: $module.settings.pdfLevel, options: CompressionSettings.PDFLevel.allCases.map { ($0, $0.title) })
                    .fixedSize()
            }
            Text(module.settings.pdfLevel == .light
                 ? "Pictures inside become JPEG at full resolution: prints as before."
                 : "Pictures inside are also brought to screen resolution: for email and sharing.")
                .font(.system(size: 11))
                .foregroundStyle(Color.ink3)
        }
    }

    private var audioSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            kindLabel("Sound")
            row("Bit rate") {
                Picker("", selection: $module.settings.audioKbps) {
                    ForEach(CompressionSettings.audioRates, id: \.self) { rate in Text("\(rate) kbps").tag(rate) }
                }
                .labelsHidden()
                .fixedSize()
            }
            Text("Becomes AAC in an M4A file.")
                .font(.system(size: 11))
                .foregroundStyle(Color.ink3)
        }
    }

    private func kindLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(Color.ink2)
    }

    private func row<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Color.ink2)
                .frame(width: 92, alignment: .leading)
            control()
            Spacer(minLength: 0)
        }
    }

    // MARK: Made

    private var madeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionLabel("Just made")
                Spacer()
                if let working = module.working {
                    Text(working)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.ink3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            ForEach(module.made.prefix(6)) { made in
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: made.url.path))
                        .resizable()
                        .frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(made.url.lastPathComponent)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(change(made))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Color.ink3)
                    }
                    Spacer(minLength: 6)
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([made.url])
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.ink3)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help("Show in Finder")
                }
                .contentShape(Rectangle())
                .onDrag { NSItemProvider(contentsOf: made.url) ?? NSItemProvider() }
                .help("Drag into any app")
            }
        }
    }

    private func change(_ made: ConverterModule.Made) -> String {
        guard made.before > 0 else { return ConverterModule.bytes(made.after) }
        let percent = Int(((1 - Double(made.after) / Double(made.before)) * 100).rounded())
        let arrow = "\(ConverterModule.bytes(made.before)) → \(ConverterModule.bytes(made.after))"
        return percent > 0 ? "\(arrow) · \(percent) % smaller" : arrow
    }

    // MARK: Getting files

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    private func load(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { add([url]) } }
            }
        }
    }

    private func add(_ urls: [URL]) {
        for url in urls where !selection.files.contains(url) { selection.files.append(url) }
    }
}

/// A small uppercase label over a group, as the app's pages have.
private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.geist(10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Color.ink3)
    }
}

/// Chips that wrap onto as many lines as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
        }
        return CGSize(width: width, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}
