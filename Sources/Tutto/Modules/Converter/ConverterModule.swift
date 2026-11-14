//
//  ConverterModule.swift
//  Tutto
//
//  Convert and compress files on this Mac. Four ways in:
//    • the Convert & Compress card in the menu bar panel: drop files to compress (or zip), convert, resize or crop;
//    • the Convert window (⌃⇧K): drop files on it, pick a format, a size or a shape, or set how
//      hard Compress works and run it;
//    • while dragging files anywhere, tap ⇧: a wheel of formats opens at the pointer; drop on one;
//    • Finder's right-click menu › Convert;
//    • tutto://convert?to=png&path=… for scripts.
//  Results go beside the originals (never over them); a pill shows progress and a card says how
//  much smaller things got, with Undo, Half, Crop and Show in Finder. Nothing is compressed
//  unless you ask (Bryan, 2026-11-13: compressing new screenshots by itself "doesn't make sense").
//  Resize and Crop bring pictures and video to fewer pixels or another shape.
//
//  At rest: the wheel's two event monitors (a mouse press and a modifier key, each an integer
//  compare), nothing else.
//

import AppKit
import ImageIO
import os
import SwiftUI
import TuttoKit

private let log = Logger(subsystem: "ca.bryanyao.Tutto", category: "convert")

@MainActor
@Observable
final class ConverterModule: ModuleController {
    struct Made: Identifiable {
        let id = UUID()
        /// The file as it is now.
        var url: URL
        var before: Int
        var after: Int
        var action: ConvertAction
        var date = Date()
    }

    var settings: CompressionSettings { didSet { save() } }
    /// Tap ⇧ while dragging files to open the wheel.
    var wheelEnabled: Bool {
        didSet {
            defaults.set(wheelEnabled, forKey: Keys.wheel)
            if wheelEnabled { wheel.start(module: self) } else { wheel.stop() }
        }
    }
    /// Open a Finder window on the results when a job finishes (otherwise the card offers it).
    var revealWhenDone: Bool { didSet { defaults.set(revealWhenDone, forKey: Keys.reveal) } }
    /// What dropping on the panel's card does, and with which format, size or shape.
    var panelMode: PanelDropMode { didSet { defaults.set(panelMode.rawValue, forKey: Keys.panelMode) } }
    var panelFormat: OutputFormat { didSet { defaults.set(panelFormat.rawValue, forKey: Keys.panelFormat) } }
    var panelResize: ResizeSpec { didSet { defaults.set(panelResize.code, forKey: Keys.panelResize) } }
    var panelCrop: CropSpec { didSet { defaults.set(panelCrop.code, forKey: Keys.panelCrop) } }
    /// Compress on the panel makes one .zip of what's dropped instead of smaller copies.
    var panelZip: Bool { didSet { defaults.set(panelZip, forKey: Keys.panelZip) } }

    /// What was made lately, newest first (the panel's card and the window list it).
    private(set) var made: [Made] = []
    /// Bytes saved by compressing, ever (the panel's card shows it).
    private(set) var savedBytes: Int64 { didSet { if persists { defaults.set(savedBytes, forKey: Keys.saved) } } }
    /// What's being done, while it is.
    private(set) var working: String?
    private(set) var progress = 0.0

    @ObservationIgnored private let defaults = UserDefaults.standard
    /// Off for snapshots' made-up totals.
    @ObservationIgnored private var persists = true
    @ObservationIgnored let wheel = DragWheel()
    @ObservationIgnored private let pill = ProgressPill()
    @ObservationIgnored private var queue: [Job] = []
    @ObservationIgnored private var running = false

    /// One piece of work: an action on files, beside them (a copy), or on a result in place.
    private struct Job {
        var action: ConvertAction
        var files: [URL]
        /// The result this changes again, in place (the card's Half or Crop).
        var result: UUID?
    }

    enum PanelDropMode: String, CaseIterable {
        case compress, convert, resize, crop

        var title: String { rawValue.capitalized }
    }

    init() {
        let d = UserDefaults.standard
        settings = d.data(forKey: Keys.settings).flatMap { try? JSONDecoder().decode(CompressionSettings.self, from: $0) } ?? CompressionSettings()
        // Compressing by itself is gone; its settings go with it.
        d.removeObject(forKey: "convert.auto")
        wheelEnabled = d.object(forKey: Keys.wheel) as? Bool ?? true
        revealWhenDone = d.bool(forKey: Keys.reveal)
        panelMode = d.string(forKey: Keys.panelMode).flatMap(PanelDropMode.init(rawValue:)) ?? .compress
        panelFormat = d.string(forKey: Keys.panelFormat).flatMap(OutputFormat.init(rawValue:)) ?? .jpeg
        panelResize = d.string(forKey: Keys.panelResize).flatMap(ResizeSpec.init(code:)) ?? .scale(0.5)
        panelCrop = d.string(forKey: Keys.panelCrop).flatMap(CropSpec.init(code:)) ?? .aspect(16, 9)
        panelZip = d.bool(forKey: Keys.panelZip)
        savedBytes = Int64(d.integer(forKey: Keys.saved))
    }

    func start() {
        if wheelEnabled { wheel.start(module: self) }
        WorkFolder.clearLeftovers()
    }

    func stop() {
        wheel.stop()
        ConvertWindowController.shared.close()
        ResultCard.shared.dismiss()
        queue.removeAll()
        pill.hide()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Keys.settings) }
    }

    // MARK: Jobs

    /// Converts, compresses, resizes or crops these files (folders and missing files are skipped),
    /// after any job already running. The results go beside the originals.
    func run(_ action: ConvertAction, on urls: [URL]) {
        let files = Self.files(urls)
        guard !files.isEmpty else {
            Toast.shared.show("Nothing to convert", detail: "Choose files rather than folders")
            return
        }
        queue.append(Job(action: action, files: files))
        if !running { next() }
    }

    /// Changes a result again, in place (the card's Half and Crop): it's Tutto's own copy, so the
    /// file it was made from stays as it is.
    func change(_ result: Made, _ action: ConvertAction) {
        guard FileManager.default.fileExists(atPath: result.url.path) else {
            Toast.shared.show("It's gone", detail: "\(result.url.lastPathComponent) was moved or deleted")
            return
        }
        queue.append(Job(action: action, files: [result.url], result: result.id))
        if !running { next() }
    }

    private static func files(_ urls: [URL]) -> [URL] {
        urls.filter { url in
            var folder: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &folder) && !folder.boolValue
        }
    }

    private func next() {
        guard !queue.isEmpty else {
            running = false
            working = nil
            pill.hide()
            return
        }
        running = true
        let job = queue.removeFirst()
        let label = job.action.working
        working = job.files.count == 1 ? "\(label): \(job.files[0].lastPathComponent)" : "\(label): \(job.files.count) files"
        progress = 0
        pill.show(title: working ?? label, progress: 0)
        let settings = self.settings
        let started = Date()
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in
                guard let self, fraction - self.progress >= 0.01 || fraction >= 1 else { return }
                self.progress = fraction
                self.pill.update(fraction)
            }
        }
        Task { @MainActor in
            do {
                if job.result != nil {
                    try await runInPlace(job, settings: settings, progress: report)
                } else {
                    try await runBeside(job, settings: settings, progress: report)
                }
                log.notice("\(job.action.title, privacy: .public): \(job.files.count) file(s) in \(Date().timeIntervalSince(started), format: .fixed(precision: 2)) s")
            } catch {
                log.error("\(job.action.title, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                Toast.shared.show("Couldn't \(job.action.verb)", detail: error.localizedDescription, duration: 4)
            }
            next()
        }
    }

    /// Copies beside the originals.
    private func runBeside(_ job: Job, settings: CompressionSettings, progress: @escaping @Sendable (Double) -> Void) async throws {
        let before = job.files.reduce(0) { $0 + Self.size(of: $1) }
        let outputs = try await ConvertEngine.run(job.action, on: job.files, settings: settings, progress: progress)
        let after = outputs.reduce(0) { $0 + Self.size(of: $1) }
        var latest: Made?
        for (index, output) in outputs.enumerated().reversed() {
            let source = outputs.count == job.files.count ? job.files[index] : nil
            let made = Made(url: output, before: source.map(Self.size(of:)) ?? (outputs.count == 1 ? before : 0),
                            after: Self.size(of: output), action: job.action)
            add(made)
            latest = latest ?? made
        }
        if job.action == .compress, after < before { savedBytes += Int64(before - after) }
        if revealWhenDone { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
        if let first = made.first, outputs.count == 1 {
            ResultCard.shared.show(first, module: self)
        } else if let latest {
            ResultCard.shared.show(latest, module: self, count: outputs.count, totalBefore: before, totalAfter: after)
        }
    }

    /// In place, on a result Tutto made: the new version takes its place (a rename on the same disk).
    private func runInPlace(_ job: Job, settings: CompressionSettings, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let file = job.files.first, FileManager.default.fileExists(atPath: file.path) else { return }
        let work = try WorkFolder.make()
        defer { try? FileManager.default.removeItem(at: work) }
        let before = Self.size(of: file)
        let outputs = try await ConvertEngine.run(job.action, on: [file], settings: settings, into: work, progress: progress)
        guard let output = outputs.first else { return }
        let after = Self.size(of: output)
        if job.action == .compress, !CompressRules.worthKeeping(before: before, after: after) {
            Toast.shared.show("Already small", detail: "\(file.lastPathComponent) couldn't get much smaller, so it's as it was")
            return
        }
        // The new version takes the file's place, under its name (its own extension if it changed).
        let fm = FileManager.default
        var final = file
        if output.pathExtension.lowercased() == file.pathExtension.lowercased() {
            _ = try fm.replaceItemAt(file, withItemAt: output)
        } else {
            final = OutputNames.unique(file.deletingPathExtension().lastPathComponent, ext: output.pathExtension,
                                       in: file.deletingLastPathComponent(), exists: ConvertEngine.exists)
            try fm.moveItem(at: output, to: final)
            try? fm.removeItem(at: file)
        }
        let afterFinal = Self.size(of: final)
        if let id = job.result, let index = made.firstIndex(where: { $0.id == id }) {
            // A second change of a result: the same card.
            made[index].url = final
            made[index].after = afterFinal
            made[index].action = job.action
            made[index].date = Date()
            ResultCard.shared.show(made[index], module: self)
        } else {
            let result = Made(url: final, before: before, after: afterFinal, action: job.action)
            add(result)
            ResultCard.shared.show(result, module: self)
        }
    }

    private func add(_ result: Made) {
        made.insert(result, at: 0)
        if made.count > 12 { made.removeLast(made.count - 12) }
    }

    /// Takes a result back: the copy goes to the Trash (the file it was made from is untouched).
    func undo(_ result: Made) {
        made.removeAll { $0.id == result.id }
        if result.action == .compress { savedBytes = max(savedBytes - Int64(max(result.before - result.after, 0)), 0) }
        do {
            try FileManager.default.trashItem(at: result.url, resultingItemURL: nil)
            Toast.shared.show("Moved to the Trash", detail: result.url.lastPathComponent)
        } catch {
            Toast.shared.show("Couldn't undo", detail: error.localizedDescription, duration: 3)
        }
    }

    /// A file's size, or a folder's (PDF pages land in one).
    static func size(of url: URL) -> Int {
        var folder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &folder) else { return 0 }
        guard folder.boolValue else { return ConvertEngine.size(url) }
        let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + ConvertEngine.size($1) }
    }

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    /// The action the panel's card runs on files dropped on it (nil: they need the window).
    func panelAction(for files: [URL], mode: PanelDropMode? = nil) -> ConvertAction? {
        let kinds = files.map(FileKind.of)
        let action: ConvertAction = switch mode ?? panelMode {
        case .compress: .compress
        case .convert: .convert(panelFormat)
        case .resize: .resize(panelResize)
        case .crop: .crop(panelCrop)
        }
        return action.applies(to: kinds) ? action : nil
    }

    /// Whether Compress on the panel zips (the archives module is on and Zip is chosen).
    var zips: Bool { panelZip && AppModel.shared.archives != nil }

    /// Files dropped on the panel's card (on one of its actions) or on the menu bar icon (the last
    /// action used). Zip makes one archive; archives that the action doesn't take are unpacked; files
    /// that don't fit it, or ⌥ held, open the Convert window with every option.
    func panelDrop(_ files: [URL], mode: PanelDropMode? = nil) {
        guard !files.isEmpty else { return }
        let mode = mode ?? panelMode
        panelMode = mode
        let window = { @MainActor [self] in
            PanelController.shared.close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                MainActor.assumeIsolated { ConvertWindowController.shared.show(module: self, files: files) }
            }
        }
        if NSEvent.modifierFlags.contains(.option) { return window() }
        if mode == .compress, zips, let archives = AppModel.shared.archives {
            archives.compress(files)
            return
        }
        if let action = panelAction(for: files, mode: mode) {
            run(action, on: files)
        } else if files.allSatisfy({ ArchiveNames.isArchive($0.lastPathComponent) }), let archives = AppModel.shared.archives {
            archives.extract(files, mode: .preferred)
        } else {
            window()
        }
    }

    #if DEBUG
    /// Snapshots: a result under the card, and a total saved.
    func previewDemo() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Screenshot 2026-11-13 at 09.41.12.png")
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: Data(count: 410_000)) }
        persists = false
        made = [Made(url: file, before: 2_380_000, after: 410_000, action: .compress)]
        savedBytes = 412_000_000
    }
    #endif

    // MARK: Links and Finder

    /// `tutto://convert?path=…&to=png`, `…&compress=1`, `…&resize=50%`, `…&crop=16:9`, or
    /// `…&open=1` (the window, with the files).
    func handle(_ request: URL) {
        let items = URLComponents(url: request, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let files = items.filter { $0.name == "path" }.compactMap { $0.value }.map { URL(fileURLWithPath: $0) }
        let value = { (name: String) in items.first { $0.name == name }?.value }
        if let to = value("to"), let format = OutputFormat(rawValue: to) {
            run(.convert(format), on: files)
        } else if value("compress") == "1" {
            run(.compress, on: files)
        } else if let code = value("resize"), let spec = ResizeSpec(code: code) {
            run(.resize(spec), on: files)
        } else if let code = value("crop"), let spec = CropSpec(code: code) {
            run(.crop(spec), on: files)
        } else {
            ConvertWindowController.shared.show(module: self, files: files)
        }
    }

    private enum Keys {
        static let settings = "convert.settings"
        static let wheel = "convert.wheel"
        static let reveal = "convert.reveal"
        static let saved = "convert.savedBytes"
        static let panelMode = "convert.panelMode"
        static let panelFormat = "convert.panelFormat"
        static let panelResize = "convert.panelResize"
        static let panelCrop = "convert.panelCrop"
        static let panelZip = "convert.panelZip"
    }
}

extension ConvertAction {
    var formatTitle: String {
        if case .convert(let format) = self { return format.title }
        return ""
    }

    /// "Compressed", "Converted to PNG", "Resized to Half", "Cropped to 16:9".
    var done: String {
        switch self {
        case .convert(let format): "Converted to \(format.title)"
        case .compress: "Compressed"
        case .resize(let spec): "Resized to \(spec.title)"
        case .crop(let spec): "Cropped to \(spec.title)"
        }
    }

    /// "compress", "convert", "resize", "crop".
    var verb: String {
        switch self {
        case .convert: "convert"
        case .compress: "compress"
        case .resize: "resize"
        case .crop: "crop"
        }
    }
}

// MARK: - Progress

/// A small pill at the bottom of the screen while a job runs: what it is and how far along.
@MainActor
final class ProgressPill {
    private var panel: NSPanel?
    private let model = ProgressPillModel()

    func show(title: String, progress: Double) {
        model.title = title
        model.progress = progress
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let size = panel.contentView?.fittingSize ?? NSSize(width: 300, height: 44)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.minY + 120, width: size.width, height: size.height).integral, display: true)
        }
        panel.orderFrontRegardless()
    }

    func update(_ progress: Double) { model.progress = progress }

    func hide() { panel?.orderOut(nil) }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 44), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: ProgressPillView(model: model).fixedSize())
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        return panel
    }
}

@MainActor
@Observable
final class ProgressPillModel {
    var title = ""
    var progress = 0.0
}

private struct ProgressPillView: View {
    var model: ProgressPillModel

    var body: some View {
        HStack(spacing: 10) {
            ProgressView(value: min(max(model.progress, 0), 1))
                .progressViewStyle(.circular)
                .controlSize(.small)
            Text(model.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 320, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(Color.hairline))
        .padding(4)
    }
}
