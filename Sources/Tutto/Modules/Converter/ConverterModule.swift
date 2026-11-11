//
//  ConverterModule.swift
//  Tutto
//
//  Convert and compress files on this Mac. Four ways in:
//    • the Convert tile in the menu bar panel (⌃⇧K): a small window to drop files on, pick a
//      format, or set how hard Compress works and run it;
//    • while dragging files anywhere, tap ⇧: a wheel of formats opens at the pointer; drop on one;
//    • Finder's right-click menu › Convert;
//    • tutto://convert?to=png&path=… for scripts.
//  Results go beside the originals (never over them); a pill shows progress and a toast says how
//  much smaller things got, with Show in Finder.
//
//  At rest: the wheel's two event monitors (a mouse press and a modifier key, each an integer
//  compare), nothing else.
//

import AppKit
import os
import SwiftUI
import TuttoKit

private let log = Logger(subsystem: "ca.bryanyao.Tutto", category: "convert")

@MainActor
@Observable
final class ConverterModule: ModuleController {
    struct Made: Identifiable {
        let id = UUID()
        let url: URL
        let before: Int
        let after: Int
        let action: ConvertAction
    }

    var settings: CompressionSettings { didSet { save() } }
    /// Tap ⇧ while dragging files to open the wheel.
    var wheelEnabled: Bool {
        didSet {
            defaults.set(wheelEnabled, forKey: Keys.wheel)
            if wheelEnabled { wheel.start(module: self) } else { wheel.stop() }
        }
    }
    /// Open a Finder window on the results when a job finishes (otherwise the toast offers it).
    var revealWhenDone: Bool { didSet { defaults.set(revealWhenDone, forKey: Keys.reveal) } }

    /// What was made lately, newest first (the window lists it).
    private(set) var made: [Made] = []
    /// What's being done, while it is.
    private(set) var working: String?
    private(set) var progress = 0.0

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored let wheel = DragWheel()
    @ObservationIgnored private let pill = ProgressPill()
    @ObservationIgnored private var queue: [(ConvertAction, [URL])] = []
    @ObservationIgnored private var running = false

    init() {
        let d = UserDefaults.standard
        settings = d.data(forKey: Keys.settings).flatMap { try? JSONDecoder().decode(CompressionSettings.self, from: $0) } ?? CompressionSettings()
        wheelEnabled = d.object(forKey: Keys.wheel) as? Bool ?? true
        revealWhenDone = d.bool(forKey: Keys.reveal)
    }

    func start() {
        if wheelEnabled { wheel.start(module: self) }
    }

    func stop() {
        wheel.stop()
        ConvertWindowController.shared.close()
        queue.removeAll()
        pill.hide()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Keys.settings) }
    }

    // MARK: Jobs

    /// Converts or compresses these files (folders and missing files are skipped), after any job
    /// already running.
    func run(_ action: ConvertAction, on urls: [URL]) {
        let files = urls.filter { url in
            var folder: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &folder) && !folder.boolValue
        }
        guard !files.isEmpty else {
            Toast.shared.show("Nothing to convert", detail: "Choose files rather than folders")
            return
        }
        queue.append((action, files))
        if !running { next() }
    }

    private func next() {
        guard !queue.isEmpty else {
            running = false
            working = nil
            pill.hide()
            return
        }
        running = true
        let (action, files) = queue.removeFirst()
        let label = action == .compress ? "Compressing" : "Converting to \(action.formatTitle)"
        working = files.count == 1 ? "\(label): \(files[0].lastPathComponent)" : "\(label): \(files.count) files"
        progress = 0
        pill.show(title: working ?? label, progress: 0)
        let settings = self.settings
        let started = Date()
        Task { @MainActor in
            let before = files.reduce(0) { $0 + Self.size(of: $1) }
            do {
                let outputs = try await ConvertEngine.run(action, on: files, settings: settings) { [weak self] fraction in
                    Task { @MainActor in
                        guard let self, fraction - self.progress >= 0.01 || fraction >= 1 else { return }
                        self.progress = fraction
                        self.pill.update(fraction)
                    }
                }
                let after = outputs.reduce(0) { $0 + Self.size(of: $1) }
                log.notice("\(action.title, privacy: .public): \(files.count) in, \(outputs.count) out, \(before) → \(after) bytes in \(Date().timeIntervalSince(started), format: .fixed(precision: 2)) s")
                for output in outputs.reversed() {
                    made.insert(Made(url: output, before: outputs.count == 1 ? before : 0, after: Self.size(of: output), action: action), at: 0)
                }
                if made.count > 12 { made.removeLast(made.count - 12) }
                finished(action, files: files, outputs: outputs, before: before, after: after)
            } catch {
                log.error("\(action.title, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                Toast.shared.show(action == .compress ? "Couldn't compress" : "Couldn't convert", detail: error.localizedDescription, duration: 4)
            }
            next()
        }
    }

    private func finished(_ action: ConvertAction, files: [URL], outputs: [URL], before: Int, after: Int) {
        if revealWhenDone { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
        let reveal = { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
        let count = outputs.count == 1 ? outputs[0].lastPathComponent : "\(outputs.count) files"
        switch action {
        case .compress:
            let saved = before > 0 ? Int((1 - Double(after) / Double(before)) * 100) : 0
            Toast.shared.show(saved > 0 ? "\(saved) % smaller" : "Compressed",
                              detail: "\(Self.bytes(before)) → \(Self.bytes(after)) · \(count) · Click to show", duration: 4, onClick: reveal)
        case .convert(let format):
            Toast.shared.show("Converted to \(format.title)", detail: "\(count) · Click to show", duration: 4, onClick: reveal)
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

    // MARK: Links and Finder

    /// `tutto://convert?path=…&to=png`, `…&compress=1`, or `…&open=1` (the window, with the files).
    func handle(_ request: URL) {
        let items = URLComponents(url: request, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let files = items.filter { $0.name == "path" }.compactMap { $0.value }.map { URL(fileURLWithPath: $0) }
        let value = { (name: String) in items.first { $0.name == name }?.value }
        if let to = value("to"), let format = OutputFormat(rawValue: to) {
            run(.convert(format), on: files)
        } else if value("compress") == "1" {
            run(.compress, on: files)
        } else {
            ConvertWindowController.shared.show(module: self, files: files)
        }
    }

    private enum Keys {
        static let settings = "convert.settings"
        static let wheel = "convert.wheel"
        static let reveal = "convert.reveal"
    }
}

extension ConvertAction {
    var formatTitle: String {
        if case .convert(let format) = self { return format.title }
        return ""
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
