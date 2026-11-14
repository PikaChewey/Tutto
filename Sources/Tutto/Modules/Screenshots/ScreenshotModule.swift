//
//  ScreenshotModule.swift
//  Tutto
//
//  Three capture shortcuts:
//   ⌘⇧2  select an area → straight to the clipboard (no editor to dismiss)
//   ⌘⇧`  the whole screen under the pointer → clipboard
//   ⌘⇧1  select an area → the editor (draw, crop, copy text, pick colors, save)
//  Nothing runs between captures; the shortcuts wait in the system.
//

import AppKit
import Observation
import os
import TuttoKit

/// Capture timings, readable with: log show --predicate 'subsystem == "ca.bryanyao.Tutto"' --last 5m
let capturePerf = Logger(subsystem: "ca.bryanyao.Tutto", category: "capture")

enum CaptureMode {
    case areaToClipboard, screenToClipboard, areaToEditor
}

enum ScreenshotFormat: String, CaseIterable {
    case png, jpeg

    var fileExtension: String { self == .png ? "png" : "jpg" }
}

@MainActor
@Observable
final class ScreenshotModule: ModuleController {
    /// Where ⌘S saves. Downloads unless the user picks another folder.
    var saveFolderPath: String { didSet { defaults.set(saveFolderPath, forKey: Keys.folder) } }
    /// ⌘S and Save open the save window (folder, name, tags, format) instead of saving straight to
    /// the folder (Bryan, 2026-11-10: "give me the option where it ... i can choose where the
    /// screenshot is saved and i can rename the screenshot ... something i can turn off in settings").
    var askWhereToSave: Bool { didSet { defaults.set(askWhereToSave, forKey: Keys.ask) } }
    /// Where the save window opens: the folder last saved to through it.
    var lastAskedFolderPath: String? { didSet { defaults.set(lastAskedFolderPath, forKey: Keys.lastAsked) } }
    var format: ScreenshotFormat { didSet { defaults.set(format.rawValue, forKey: Keys.format) } }
    var playSound: Bool { didSet { defaults.set(playSound, forKey: Keys.sound) } }
    /// Also save a file for ⌘⇧` / ⌘⇧2 captures (off: clipboard only, like the spec asks).
    var alsoSaveQuickCaptures: Bool { didSet { defaults.set(alsoSaveQuickCaptures, forKey: Keys.alsoSave) } }

    private(set) var isCapturing = false
    /// Screen recording (⌃⇧R), with its own settings.
    let recorder = ScreenRecorder()
    /// Scrolling screenshots (⌃⇧S).
    let scrolling = ScrollCapture()
    private(set) var lastLatency: TimeInterval?

    private weak var model: AppModel?
    private let defaults = UserDefaults.standard
    private var overlay: SelectionOverlay?
    private var editors: [EditorWindowController] = []

    init(model: AppModel) {
        self.model = model
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory()
        saveFolderPath = defaults.string(forKey: Keys.folder) ?? downloads
        format = ScreenshotFormat(rawValue: defaults.string(forKey: Keys.format) ?? "") ?? .png
        playSound = defaults.bool(forKey: Keys.sound)
        alsoSaveQuickCaptures = defaults.bool(forKey: Keys.alsoSave)
        askWhereToSave = defaults.object(forKey: Keys.ask) as? Bool ?? true
        lastAskedFolderPath = defaults.string(forKey: Keys.lastAsked)
        recorder.module = self
        scrolling.module = self
    }

    var saveFolder: URL { URL(fileURLWithPath: saveFolderPath, isDirectory: true) }

    /// The save window's starting folder: the last one used there, if it's still around.
    var askFolder: URL {
        if let path = lastAskedFolderPath, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return saveFolder
    }

    func start() {}

    func stop() {
        if recorder.recordingSince != nil { recorder.stop() } else { recorder.cancel() }
        scrolling.cancel()
        editors.forEach { $0.close() }
        editors.removeAll()
        overlay = nil
    }

    // MARK: Capturing

    func capture(_ mode: CaptureMode) {
        guard !isCapturing, overlay == nil else { return }
        guard CGPreflightScreenCaptureAccess() else {
            model?.permissions.request(.screenRecording)
            Toast.shared.show("Screen Recording needed", detail: "Switch on Tutto in System Settings, then try again", duration: 3)
            return
        }
        isCapturing = true
        let started = ProcessInfo.processInfo.systemUptime
        let wanted: Set<CGDirectDisplayID>? = mode == .screenToClipboard ? [Self.displayUnderPointer()] : nil
        Task { @MainActor in
            defer { isCapturing = false }
            let shots: [DisplayShot]
            do {
                shots = try await ScreenCapturer.capture(displays: wanted)
            } catch {
                Toast.shared.show("Couldn't capture", detail: error.localizedDescription, duration: 3)
                return
            }
            lastLatency = ProcessInfo.processInfo.systemUptime - started
            capturePerf.notice("captured \(shots.count, privacy: .public) display(s) in \(Int((self.lastLatency ?? 0) * 1000), privacy: .public) ms")
            switch mode {
            case .screenToClipboard:
                guard let shot = shots.first else { return }
                deliver(shot.image, toEditor: false)
                capturePerf.notice("shortcut → full screen on clipboard in \(Int((ProcessInfo.processInfo.systemUptime - started) * 1000), privacy: .public) ms")
            case .areaToClipboard, .areaToEditor:
                let overlay = SelectionOverlay()
                self.overlay = overlay
                defer {
                    capturePerf.notice("shortcut → overlay on screen in \(Int((ProcessInfo.processInfo.systemUptime - started) * 1000), privacy: .public) ms")
                }
                overlay.begin(shots: shots) { [weak self] selection in
                    let released = ProcessInfo.processInfo.systemUptime
                    defer {
                        capturePerf.notice("selection → delivered in \(Int((ProcessInfo.processInfo.systemUptime - released) * 1000), privacy: .public) ms")
                    }
                    guard let self else { return }
                    self.overlay = nil
                    guard let selection, let image = Self.detachedCrop(of: selection.shot.image, to: selection.rect) else {
                        overlay.restoreFocus()
                        return
                    }
                    if mode == .areaToClipboard { overlay.restoreFocus() }
                    self.deliver(image, toEditor: mode == .areaToEditor)
                }
            }
        }
    }

    /// The selected part as an image of its own. A crop made with `cropping(to:)` shares the whole
    /// frozen screen's pixels (about 23 MB on a Retina display) and would keep all of them alive
    /// while the editor or the toast holds it; a copy costs a millisecond or two. A crop of most of
    /// the screen keeps sharing (copying it would only add a second full screen of pixels).
    nonisolated static func detachedCrop(of image: CGImage, to rect: CGRect) -> CGImage? {
        guard let crop = image.cropping(to: rect) else { return nil }
        guard crop.width * crop.height * 2 < image.width * image.height,
              let space = crop.colorSpace, space.supportsOutput,
              let context = CGContext(data: nil, width: crop.width, height: crop.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return crop
        }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        return context.makeImage() ?? crop
    }

    private func deliver(_ image: CGImage, toEditor: Bool) {
        if playSound { NSSound(named: "Grab")?.play() }
        if toEditor {
            openEditor(with: image)
            return
        }
        copyToClipboard(image)
        let thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        if alsoSaveQuickCaptures { _ = save(image) }
        Toast.shared.show("Copied", detail: "\(image.width) × \(image.height)", image: thumbnail) { [weak self] in
            self?.openEditor(with: image)
        }
    }

    func openEditor(with image: CGImage) {
        let editor = EditorWindowController(image: image, module: self)
        editors.append(editor)
        editor.show()
    }

    func editorDidClose(_ editor: EditorWindowController) {
        editors.removeAll { $0 === editor }
    }

    // MARK: Output

    func copyToClipboard(_ image: CGImage) {
        guard let png = image.pngData else { return }
        PasteboardImage.write(png: png)
    }

    /// Saves into the screenshot folder with a Finder-style name. Returns the file, or nil.
    @discardableResult
    func save(_ image: CGImage, to folder: URL? = nil) -> URL? {
        let folder = folder ?? saveFolder
        let url = ScreenshotNames.unique(ScreenshotNames.base(at: Date()), ext: format.fileExtension, in: folder) {
            FileManager.default.fileExists(atPath: $0.path)
        }
        guard write(image, to: url, as: format) else { return nil }
        return url
    }

    /// Writes the image to exactly this file (the save window already asked about replacing one).
    @discardableResult
    func write(_ image: CGImage, to url: URL, as format: ScreenshotFormat) -> Bool {
        guard let data = format == .png ? image.pngData : image.jpegData() else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            Toast.shared.show("Couldn't save", detail: error.localizedDescription, duration: 3)
            return false
        }
    }

    private static func displayUnderPointer() -> CGDirectDisplayID {
        let mouse = NSEvent.mouseLocation
        return (NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main)?.displayID ?? CGMainDisplayID()
    }

    private enum Keys {
        static let folder = "screenshots.folder"
        static let format = "screenshots.format"
        static let sound = "screenshots.sound"
        static let alsoSave = "screenshots.alsoSaveQuick"
        static let ask = "screenshots.askWhereToSave"
        static let lastAsked = "screenshots.lastAskedFolder"
    }
}
