//
//  ConverterModule.swift
//  Tutto
//
//  Convert and compress files on this Mac. Four ways in:
//    • the Compress card in the menu bar panel: drop files to compress, convert, resize or crop;
//    • the Convert window (⌃⇧K): drop files on it, pick a format, a size or a shape, or set how
//      hard Compress works and run it;
//    • while dragging files anywhere, tap ⇧: a wheel of formats opens at the pointer; drop on one;
//    • Finder's right-click menu › Convert;
//    • tutto://convert?to=png&path=… for scripts.
//  Results go beside the originals (never over them); a pill shows progress and a card says how
//  much smaller things got, with Undo, Half, Crop and Show in Finder. Compressing by itself
//  (AutoCompress.swift) changes new files in place instead, keeping their originals to undo.
//  Resize and Crop bring pictures and video to fewer pixels or another shape.
//
//  At rest: the wheel's two event monitors (a mouse press and a modifier key, each an integer
//  compare), the watched folders' FSEvents stream, nothing else.
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
        /// For a file changed in place: its original, kept for a few days, to undo.
        var original: URL?
        /// Made by the automatic compressor.
        var auto = false
        var date = Date()

        var changedInPlace: Bool { original != nil }
    }

    var settings: CompressionSettings { didSet { save() } }
    /// Compressing by itself: new files in the watched folders, and the clipboard.
    var auto: AutoCompressSettings {
        didSet {
            if let data = try? JSONEncoder().encode(auto) { defaults.set(data, forKey: Keys.auto) }
            applyAuto()
        }
    }
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

    /// What was made lately, newest first (the panel's card and the window list it).
    private(set) var made: [Made] = []
    /// The last picture compressed on the clipboard (to put back as it was).
    private(set) var clipboardDone: ClipboardShrinker.Done?
    /// Bytes saved by compressing, ever (the panel's card shows it).
    private(set) var savedBytes: Int64 { didSet { if persists { defaults.set(savedBytes, forKey: Keys.saved) } } }
    /// What's being done, while it is.
    private(set) var working: String?
    private(set) var progress = 0.0
    /// The folders being watched now.
    private(set) var watching: [URL] = []

    @ObservationIgnored private let defaults = UserDefaults.standard
    /// Off for snapshots' made-up totals.
    @ObservationIgnored private var persists = true
    @ObservationIgnored let wheel = DragWheel()
    @ObservationIgnored private let pill = ProgressPill()
    @ObservationIgnored private let watcher = FolderWatcher()
    @ObservationIgnored private var queue: [Job] = []
    @ObservationIgnored private var running = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var clipboardTimer: DispatchSourceTimer?
    @ObservationIgnored private var lastClipboard = NSPasteboard.general.changeCount
    @ObservationIgnored private var clipboardTicks = 0

    /// One piece of work: an action on files, beside them (a copy) or in place.
    private struct Job {
        var action: ConvertAction
        var files: [URL]
        var inPlace = false
        var auto = false
        /// Keep the file as it was before this change (off for a second change of a result, whose
        /// first original is kept already, and for Tutto's own copies).
        var keepOriginal = true
        /// The result this changes again (the card's Half or Crop).
        var result: UUID?
    }

    enum PanelDropMode: String, CaseIterable {
        case compress, convert, resize, crop

        var title: String { rawValue.capitalized }
    }

    init() {
        let d = UserDefaults.standard
        settings = d.data(forKey: Keys.settings).flatMap { try? JSONDecoder().decode(CompressionSettings.self, from: $0) } ?? CompressionSettings()
        auto = d.data(forKey: Keys.auto).flatMap { try? JSONDecoder().decode(AutoCompressSettings.self, from: $0) } ?? AutoCompressSettings()
        wheelEnabled = d.object(forKey: Keys.wheel) as? Bool ?? true
        revealWhenDone = d.bool(forKey: Keys.reveal)
        panelMode = d.string(forKey: Keys.panelMode).flatMap(PanelDropMode.init(rawValue:)) ?? .compress
        panelFormat = d.string(forKey: Keys.panelFormat).flatMap(OutputFormat.init(rawValue:)) ?? .jpeg
        panelResize = d.string(forKey: Keys.panelResize).flatMap(ResizeSpec.init(code:)) ?? .scale(0.5)
        panelCrop = d.string(forKey: Keys.panelCrop).flatMap(CropSpec.init(code:)) ?? .aspect(16, 9)
        savedBytes = Int64(d.integer(forKey: Keys.saved))
    }

    func start() {
        started = true
        if wheelEnabled { wheel.start(module: self) }
        watcher.onFiles = { [weak self] files in self?.autoCompress(files) }
        applyAuto()
        OriginalsStore.prune(keepDays: auto.keepOriginalsDays)
    }

    func stop() {
        started = false
        wheel.stop()
        watcher.stop()
        watching = []
        stopClipboardTimer()
        ConvertWindowController.shared.close()
        ResultCard.shared.dismiss()
        queue.removeAll()
        pill.hide()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Keys.settings) }
    }

    // MARK: Compressing by itself

    private func applyAuto() {
        guard started else { return }
        watcher.settings = auto
        if auto.isOn, auto.images || auto.videos || auto.pdfs {
            watching = WatchedFolders.resolve(auto)
            #if DEBUG
            // A lab copy watches the folder it's given instead (`--watch <folder>`), never the Desktop.
            if let index = CommandLine.arguments.firstIndex(of: "--watch"), CommandLine.arguments.indices.contains(index + 1) {
                watching = [URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)]
            }
            #endif
            watcher.watch(watching)
        } else {
            watcher.stop()
            watching = []
        }
        updateClipboardTimer()
    }

    /// Whether pictures copied to the clipboard are compressed.
    var shrinksClipboard: Bool {
        #if DEBUG
        // A lab copy (`--watch`) leaves the clipboard alone: it's the person's, and the installed Tutto's.
        if CommandLine.arguments.contains("--watch") { return false }
        #endif
        return auto.isOn && auto.clipboard
    }

    /// New files the watcher accepted.
    private func autoCompress(_ files: [URL]) {
        for file in files {
            queue.append(Job(action: .compress, files: [file], inPlace: true, auto: true))
        }
        if !running { next() }
    }

    /// A screenshot Tutto just saved.
    func compressOwnCapture(_ url: URL) {
        guard auto.isOn, auto.images, !watching.contains(where: { $0.standardizedFileURL == url.deletingLastPathComponent().standardizedFileURL }) else { return }
        autoCompress([url])
    }

    /// The clipboard changed (the clipboard history calls this; without it, a timer of its own).
    /// Returns true when it takes the picture on: the history then records it once it's smaller.
    @discardableResult
    func clipboardChanged() -> Bool {
        let pasteboard = NSPasteboard.general
        lastClipboard = pasteboard.changeCount
        guard shrinksClipboard, ClipboardShrinker.wants(pasteboard) else { return false }
        let halve = auto.halveRetinaScreenshots
        ClipboardShrinker.shrink(halve: halve) { [weak self] done in
            guard let self else { return }
            self.lastClipboard = NSPasteboard.general.changeCount
            if let done {
                self.clipboardDone = done
                self.savedBytes += Int64(done.before - done.after)
                log.notice("clipboard picture: \(done.before) → \(done.after) bytes")
                ResultCard.shared.show(clipboard: done, module: self)
            }
            // The history records what's there now (the smaller picture, or the one copied).
            AppModel.shared.clipboard?.recapture()
        }
        return true
    }

    /// Puts the copied picture back as it was.
    func undoClipboard() {
        guard let done = clipboardDone else { return }
        ClipboardShrinker.restore(done)
        lastClipboard = NSPasteboard.general.changeCount
        savedBytes = max(savedBytes - Int64(done.before - done.after), 0)
        clipboardDone = nil
        AppModel.shared.clipboard?.recapture()
    }

    /// With the clipboard history off, the clipboard's change counter is read here instead: about
    /// once a second while you're at the Mac (leeway lets macOS fold it into other wake-ups), every
    /// few seconds when you're away.
    private func updateClipboardTimer() {
        if shrinksClipboard, started, AppModel.shared.clipboard == nil {
            guard clipboardTimer == nil else { return }
            lastClipboard = NSPasteboard.general.changeCount
            scheduleClipboardTimer(every: 1)
        } else {
            stopClipboardTimer()
        }
    }

    /// The clipboard history was switched on or off.
    func clipboardHistoryChanged() { updateClipboardTimer() }

    private func scheduleClipboardTimer(every interval: TimeInterval) {
        clipboardTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(Int(interval * 500)))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if NSPasteboard.general.changeCount != self.lastClipboard { self.clipboardChanged() }
                self.clipboardTicks += 1
                if self.clipboardTicks % 5 == 0 {
                    let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
                    let wanted: TimeInterval = idle < 60 ? 1 : 4
                    if wanted != interval { self.scheduleClipboardTimer(every: wanted) }
                }
            }
        }
        timer.resume()
        clipboardTimer = timer
    }

    private func stopClipboardTimer() {
        clipboardTimer?.cancel()
        clipboardTimer = nil
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

    /// Changes a result again, in place (the card's Half and Crop): its first original stays kept.
    func change(_ result: Made, _ action: ConvertAction) {
        guard FileManager.default.fileExists(atPath: result.url.path) else {
            Toast.shared.show("It's gone", detail: "\(result.url.lastPathComponent) was moved or deleted")
            return
        }
        queue.append(Job(action: action, files: [result.url], inPlace: true, auto: result.auto, keepOriginal: false, result: result.id))
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
        // A picture done by itself takes a moment: no pill for it, only the card after.
        let quiet = job.auto && job.files.allSatisfy { FileKind.of($0) != .video }
        if !quiet { pill.show(title: working ?? label, progress: 0) }
        let settings = self.settings
        let started = Date()
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in
                guard let self, fraction - self.progress >= 0.01 || fraction >= 1 else { return }
                self.progress = fraction
                if !quiet { self.pill.update(fraction) }
            }
        }
        Task { @MainActor in
            do {
                if job.inPlace {
                    try await runInPlace(job, settings: settings, progress: report)
                } else {
                    try await runBeside(job, settings: settings, progress: report)
                }
                log.notice("\(job.action.title, privacy: .public): \(job.files.count) file(s) in \(Date().timeIntervalSince(started), format: .fixed(precision: 2)) s")
            } catch {
                log.error("\(job.action.title, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                // A file done by itself that couldn't be: say nothing (it's as it was).
                if !job.auto {
                    Toast.shared.show("Couldn't \(job.action.verb)", detail: error.localizedDescription, duration: 4)
                }
            }
            next()
        }
    }

    /// Copies beside the originals.
    private func runBeside(_ job: Job, settings: CompressionSettings, progress: @escaping @Sendable (Double) -> Void) async throws {
        let before = job.files.reduce(0) { $0 + Self.size(of: $1) }
        let outputs = try await ConvertEngine.run(job.action, on: job.files, settings: settings, progress: progress)
        let after = outputs.reduce(0) { $0 + Self.size(of: $1) }
        for output in outputs {
            DoneMark.set(output)
            watcher.noteOwn(output)
        }
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

    /// In place: the result takes the file's place (a rename on the same disk); its original goes to
    /// the kept originals (when it's the person's file), and the file is marked done.
    private func runInPlace(_ job: Job, settings: CompressionSettings, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let file = job.files.first, FileManager.default.fileExists(atPath: file.path) else { return }
        let work = try OriginalsStore.workFolder()
        defer { try? FileManager.default.removeItem(at: work) }
        let before = Self.size(of: file)
        var halve = false
        if job.auto, auto.halveRetinaScreenshots, FileKind.of(file) == .image {
            let source = CGImageSourceCreateWithURL(file as CFURL, nil)
            let properties = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] } ?? [:]
            halve = AutoCompressRules.isRetinaScreenshot(name: file.lastPathComponent, dpi: properties.isEmpty ? nil : ConvertEngine.dpi(properties))
        }
        let outputs = try await ConvertEngine.run(job.action, on: [file], settings: settings, into: work, halve: halve, progress: progress)
        guard let output = outputs.first else { return }
        let after = Self.size(of: output)
        if job.action == .compress, !AutoCompressRules.worthKeeping(before: before, after: after) {
            DoneMark.set(file)
            if !job.auto { Toast.shared.show("Already small", detail: "\(file.lastPathComponent) couldn't get much smaller, so it's as it was") }
            return
        }
        // The result takes the file's place, under the file's name (its own extension if it changed).
        let fm = FileManager.default
        var kept: URL?
        var final = file
        let sameType = output.pathExtension.lowercased() == file.pathExtension.lowercased()
        if sameType {
            let backupName = ".Tutto-original-\(UUID().uuidString.prefix(8))-\(file.lastPathComponent)"
            let backup = file.deletingLastPathComponent().appendingPathComponent(backupName)
            watcher.noteOwn(file)
            _ = try fm.replaceItemAt(file, withItemAt: output, backupItemName: backupName, options: [.withoutDeletingBackupItem])
            if fm.fileExists(atPath: backup.path) {
                if job.keepOriginal {
                    kept = try? OriginalsStore.keep(backup, name: file.lastPathComponent)
                }
                if kept == nil { try? fm.removeItem(at: backup) }
            }
        } else {
            final = OutputNames.unique(file.deletingPathExtension().lastPathComponent, ext: output.pathExtension,
                                       in: file.deletingLastPathComponent(), exists: ConvertEngine.exists)
            watcher.noteOwn(final)
            try fm.moveItem(at: output, to: final)
            if job.keepOriginal {
                kept = try OriginalsStore.keep(file, name: file.lastPathComponent)
            } else {
                try? fm.removeItem(at: file)
            }
        }
        DoneMark.set(final)
        let afterFinal = Self.size(of: final)
        if let id = job.result, let index = made.firstIndex(where: { $0.id == id }) {
            // A second change of a result: the same card, the first original still kept.
            made[index].url = final
            made[index].after = afterFinal
            made[index].action = job.action
            made[index].date = Date()
            ResultCard.shared.show(made[index], module: self)
        } else {
            let result = Made(url: final, before: before, after: afterFinal, action: job.action, original: kept, auto: job.auto)
            add(result)
            if job.action == .compress { savedBytes += Int64(max(before - afterFinal, 0)) }
            ResultCard.shared.show(result, module: self)
        }
        if job.auto { OriginalsStore.prune(keepDays: auto.keepOriginalsDays) }
    }

    private func add(_ result: Made) {
        made.insert(result, at: 0)
        if made.count > 12 { made.removeLast(made.count - 12) }
    }

    /// Takes a result back: a file changed in place gets its original back; a copy made beside
    /// the original goes to the Trash.
    func undo(_ result: Made) {
        let fm = FileManager.default
        defer {
            made.removeAll { $0.id == result.id }
            if result.action == .compress { savedBytes = max(savedBytes - Int64(max(result.before - result.after, 0)), 0) }
        }
        guard let original = result.original else {
            do {
                try fm.trashItem(at: result.url, resultingItemURL: nil)
                Toast.shared.show("Moved to the Trash", detail: result.url.lastPathComponent)
            } catch {
                Toast.shared.show("Couldn't undo", detail: error.localizedDescription, duration: 3)
            }
            return
        }
        guard fm.fileExists(atPath: original.path) else {
            Toast.shared.show("The original is gone", detail: "Kept originals are cleared after \(auto.keepOriginalsDays) days", duration: 3)
            return
        }
        do {
            let restored: URL
            if fm.fileExists(atPath: result.url.path), result.url.pathExtension.lowercased() == original.pathExtension.lowercased() {
                watcher.noteOwn(result.url)
                _ = try fm.replaceItemAt(result.url, withItemAt: original)
                restored = result.url
            } else {
                if fm.fileExists(atPath: result.url.path) { try? fm.trashItem(at: result.url, resultingItemURL: nil) }
                restored = OutputNames.unique(original.deletingPathExtension().lastPathComponent, ext: original.pathExtension,
                                              in: result.url.deletingLastPathComponent(), exists: ConvertEngine.exists)
                watcher.noteOwn(restored)
                try fm.moveItem(at: original, to: restored)
            }
            DoneMark.set(restored, "restored")
            OriginalsStore.forget(original)
            Toast.shared.show("Back as it was", detail: restored.lastPathComponent)
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
    func panelAction(for files: [URL]) -> ConvertAction? {
        let kinds = files.map(FileKind.of)
        let action: ConvertAction = switch panelMode {
        case .compress: .compress
        case .convert: .convert(panelFormat)
        case .resize: .resize(panelResize)
        case .crop: .crop(panelCrop)
        }
        return action.applies(to: kinds) ? action : nil
    }

    #if DEBUG
    /// Snapshots: a result under the card, and a total saved.
    func previewDemo() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Screenshot 2026-11-13 at 09.41.12.png")
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: Data(count: 410_000)) }
        persists = false
        made = [Made(url: file, before: 2_380_000, after: 410_000, action: .compress, original: file, auto: true)]
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
        static let auto = "convert.auto"
        static let wheel = "convert.wheel"
        static let reveal = "convert.reveal"
        static let saved = "convert.savedBytes"
        static let panelMode = "convert.panelMode"
        static let panelFormat = "convert.panelFormat"
        static let panelResize = "convert.panelResize"
        static let panelCrop = "convert.panelCrop"
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
