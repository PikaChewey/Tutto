//
//  ScreenshotModule.swift
//  Tutto
//
//  Shottr's workflow, as used on this Mac:
//   ⌘⇧2  select an area → straight to the clipboard (no editor to dismiss)
//   ⌘⇧1  the whole screen under the pointer → clipboard
//   ⌘⇧`  select an area → the editor (draw, crop, copy text, pick colors, save)
//  Nothing runs between captures; the shortcuts wait in the system.
//

import AppKit
import Observation
import TuttoKit

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
    var format: ScreenshotFormat { didSet { defaults.set(format.rawValue, forKey: Keys.format) } }
    var playSound: Bool { didSet { defaults.set(playSound, forKey: Keys.sound) } }
    /// Also save a file for ⌘⇧1 / ⌘⇧2 captures (off: clipboard only, like the spec asks).
    var alsoSaveQuickCaptures: Bool { didSet { defaults.set(alsoSaveQuickCaptures, forKey: Keys.alsoSave) } }

    private(set) var isCapturing = false
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
    }

    var saveFolder: URL { URL(fileURLWithPath: saveFolderPath, isDirectory: true) }

    func start() {}

    func stop() {
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
            switch mode {
            case .screenToClipboard:
                guard let shot = shots.first else { return }
                deliver(shot.image, toEditor: false)
            case .areaToClipboard, .areaToEditor:
                let overlay = SelectionOverlay()
                self.overlay = overlay
                overlay.begin(shots: shots) { [weak self] selection in
                    guard let self else { return }
                    self.overlay = nil
                    guard let selection, let image = selection.shot.image.cropping(to: selection.rect) else {
                        overlay.restoreFocus()
                        return
                    }
                    if mode == .areaToClipboard { overlay.restoreFocus() }
                    self.deliver(image, toEditor: mode == .areaToEditor)
                }
            }
        }
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
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let rep = NSBitmapImageRep(cgImage: image)
        if let png = rep.representation(using: .png, properties: [:]) {
            pasteboard.declareTypes([.png, .tiff], owner: nil)
            pasteboard.setData(png, forType: .png)
            if let tiff = rep.tiffRepresentation { pasteboard.setData(tiff, forType: .tiff) }
        }
    }

    /// Saves into the screenshot folder with a Finder-style name. Returns the file, or nil.
    @discardableResult
    func save(_ image: CGImage, to folder: URL? = nil) -> URL? {
        let folder = folder ?? saveFolder
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = "Screenshot \(formatter.string(from: Date()))"
        var url = folder.appendingPathComponent(base).appendingPathExtension(format.fileExtension)
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(counter)").appendingPathExtension(format.fileExtension)
            counter += 1
        }
        guard let data = format == .png ? image.pngData : image.jpegData() else { return nil }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            Toast.shared.show("Couldn't save", detail: error.localizedDescription, duration: 3)
            return nil
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
    }
}
