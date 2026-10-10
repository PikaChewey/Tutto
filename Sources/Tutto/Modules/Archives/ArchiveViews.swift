//
//  ArchiveViews.swift
//  Tutto
//
//  The progress panel and the Archives page.
//

import AppKit
import SwiftUI
import TuttoKit
import UniformTypeIdentifiers

@MainActor
final class ArchiveProgressController {
    private weak var module: ArchiveModule?
    private var panel: NSPanel?

    init(module: ArchiveModule) {
        self.module = module
    }

    func show() {
        guard let module else { return }
        if let panel {
            panel.orderFrontRegardless()
            return
        }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 120),
                            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        // Each job has its own × ; window buttons would only add clutter.
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach { panel.standardWindowButton($0)?.isHidden = true }
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let hosting = NSHostingView(rootView: ArchiveProgressView(module: module))
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentView = hosting
        if let visible = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: visible.maxX - 400, y: visible.maxY - 20))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func close() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }
}

private struct ArchiveProgressView: View {
    var module: ArchiveModule

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(module.jobs) { job in
                JobRow(job: job)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 16)
        .frame(width: 380)
        .animation(Motion.snappy, value: module.jobs.map(\.id))
    }
}

private struct JobRow: View {
    var job: ArchiveJob

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: job.kind == .extract ? "archivebox" : "doc.zipper")
                    .foregroundStyle(Color.ink2)
                Text(job.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if job.state == .running {
                    Button {
                        job.cancelFlag.cancel()
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.ink3)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel")
                    .accessibilityLabel("Cancel")
                }
            }
            Meter(value: job.state == .running ? job.fraction : 1, height: 2, alert: isFailure)
            Text(status)
                .font(.mono(10.5))
                .foregroundStyle(isFailure ? Color.alert : Color.ink3)
                .lineLimit(2)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
        }
        // Contain, don't combine: the Cancel button must stay reachable with VoiceOver.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(job.name)
    }

    private var isFailure: Bool {
        if case .failed = job.state { return true }
        return false
    }

    private var status: String {
        switch job.state {
        case .running: "\(Int(job.fraction * 100))% · \(job.detail)"
        case .done(let message): message
        case .failed(let message): message
        case .cancelled: "Cancelled"
        }
    }
}

// MARK: - Page

struct ArchivesPage: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Archives",
                       subtitle: "Open RAR, 7z, zip, tar, ISO, CAB and more — from Finder's right-click menu or by double-clicking.",
                       module: .archives)
            if let archives = model.archives {
                ArchiveSettings(archives: archives, model: model)
            } else {
                ModuleOffView(module: .archives, model: model)
            }
        }
    }
}

private struct ArchiveSettings: View {
    @Bindable var archives: ArchiveModule
    @Bindable var model: AppModel
    @State private var isDefault = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            InkGroup("Finder") {
                LabeledRow("Right-click menu",
                           detail: model.permissions.finderExtension == true
                            ? "On. Right-click an archive for Extract Here, Extract to “Name”, Extract to…; right-click anything for Compress."
                            : "Turn on Tutto under System Settings › General › Login Items & Extensions › Extensions (Finder).") {
                    if model.permissions.finderExtension == true {
                        Text("On").font(.system(size: 12)).foregroundStyle(Color.ink2)
                    } else {
                        Button("Turn On") { model.permissions.request(.finderExtension) }
                            .buttonStyle(InkButtonStyle(compact: true))
                    }
                }
                Hairline().opacity(0.6)
                LabeledRow("Open archives with Tutto", detail: isDefault ? "Double-clicking an archive extracts it with Tutto." : "Make Tutto the app that opens archives when you double-click them.") {
                    if isDefault {
                        Text("Default").font(.system(size: 12)).foregroundStyle(Color.ink2)
                    } else {
                        Button("Make Default") { makeDefault() }
                            .buttonStyle(OutlineButtonStyle(compact: true))
                    }
                }
                Hairline().opacity(0.6)
                LabeledRow("Extract or compress files…", detail: "Pick files here instead of in Finder.") {
                    HStack {
                        Button("Extract…") { pick(extract: true) }.buttonStyle(OutlineButtonStyle(compact: true))
                        Button("Compress…") { pick(extract: false) }.buttonStyle(OutlineButtonStyle(compact: true))
                    }
                }
            }
            InkGroup("Extracting") {
                LabeledRow("Extract to", detail: archives.destination == .fixed ? archives.fixedFolderPath.replacingOccurrences(of: NSHomeDirectory(), with: "~") : nil) {
                    HStack(spacing: 8) {
                        if archives.destination == .fixed {
                            Button("Choose…") { chooseFolder() }.buttonStyle(OutlineButtonStyle(compact: true))
                        }
                        InkSegmented(selection: $archives.destination,
                                     options: ArchiveDestination.allCases.map { ($0, $0.title) })
                    }
                }
                Hairline().opacity(0.6)
                LabeledRow("Create a folder", detail: "“Smart” makes one only when the archive has more than one item at the top.") {
                    InkSegmented(selection: $archives.folderRule,
                                 options: [(.smart, "Smart"), (.always, "Always"), (.never, "Never")])
                }
                Hairline().opacity(0.6)
                LabeledRow("Move the archive to the Trash afterwards") {
                    InkSwitch(isOn: $archives.trashAfterExtracting, label: "Move archive to Trash after extracting")
                }
                Hairline().opacity(0.6)
                LabeledRow("Show the extracted files in Finder") {
                    InkSwitch(isOn: $archives.revealAfterExtracting, label: "Reveal extracted files")
                }
                Hairline().opacity(0.6)
                LabeledRow("Filename encoding", detail: "Archives made on older or non-English systems often store names in a legacy encoding. Tutto detects it; override only if names still look wrong.") {
                    Picker("Filename encoding", selection: $archives.encodingOverride) {
                        Text("Detect automatically").tag(UInt?.none)
                        Divider()
                        ForEach(EncodingChoice.all, id: \.value) { choice in
                            Text(choice.name).tag(Optional(choice.value))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
            }
            InkGroup("Formats") {
                Text("Extracts zip, RAR (including RAR5 and multi-part), 7z, tar, gzip, bzip2, xz, lzma, ISO, CAB, LHA/LZH, XAR/pkg, cpio, ar/deb and more through the libarchive built into macOS. Password-protected zip files are supported; encrypted RAR and 7z files and zstd/lz4 compression are not (macOS's libarchive can't decrypt or decode them). Compresses to zip.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 8)
            }
        }
        .onAppear { refreshDefault() }
        .background(VisibilityReader { visible in if visible { model.permissions.refreshFinderExtension() } })
    }

    private func refreshDefault() {
        if let url = NSWorkspace.shared.urlForApplication(toOpen: .init(filenameExtension: "rar") ?? .archive) {
            isDefault = Bundle(url: url)?.bundleIdentifier == Bundle.main.bundleIdentifier
        }
    }

    private func makeDefault() {
        let types = ["rar", "7z", "zip", "tar", "gz", "tgz", "bz2", "xz", "lzma", "iso", "cab", "lzh", "lha", "cpio", "xar", "zipx"]
            .compactMap { UTType(filenameExtension: $0) }
        let group = DispatchGroup()
        for type in Set(types) {
            group.enter()
            NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: type) { _ in group.leave() }
        }
        group.notify(queue: .main) { refreshDefault() }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { archives.fixedFolderPath = url.path }
    }

    private func pick(extract: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = !extract
        panel.prompt = extract ? "Extract" : "Compress"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        if extract { archives.extract(panel.urls, mode: .preferred) } else { archives.compress(panel.urls) }
    }
}

private struct EncodingChoice {
    var name: String
    var value: UInt

    static let all: [EncodingChoice] = {
        let list: [(String, CFStringEncoding)] = [
            ("Japanese (Shift JIS)", CFStringEncoding(CFStringEncodings.shiftJIS.rawValue)),
            ("Chinese Simplified (GB 18030)", CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)),
            ("Chinese Traditional (Big 5)", CFStringEncoding(CFStringEncodings.big5.rawValue)),
            ("Korean (EUC-KR)", CFStringEncoding(CFStringEncodings.EUC_KR.rawValue)),
            ("Cyrillic (Windows-1251)", CFStringEncoding(CFStringEncodings.windowsCyrillic.rawValue)),
            ("Cyrillic (DOS 866)", CFStringEncoding(CFStringEncodings.dosRussian.rawValue)),
            ("Western (DOS 437)", CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)),
            ("Western (Windows-1252)", CFStringBuiltInEncodings.windowsLatin1.rawValue),
        ]
        return list.map { EncodingChoice(name: $0.0, value: UInt(CFStringConvertEncodingToNSStringEncoding($0.1))) }
    }()
}
