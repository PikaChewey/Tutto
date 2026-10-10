//
//  EditorWindow.swift
//  Tutto
//
//  The screenshot editor (⌘⇧`). Only screenshot things live here: tools, colors,
//  thickness, copy text, copy, save. Esc copies and closes, like Shottr.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class EditorWindowController: NSObject, NSWindowDelegate {
    let document: EditorDocument
    private weak var module: ScreenshotModule?
    private var window: NSPanel?
    private let canvas: EditorCanvas

    init(image: CGImage, module: ScreenshotModule) {
        document = EditorDocument(image: image)
        self.module = module
        canvas = EditorCanvas(document: document)
        super.init()
        canvas.onEscape = { [weak self] in self?.copyAndClose() }
        canvas.onCopy = { [weak self] in self?.copy() }
        canvas.onSave = { [weak self] choose in self?.save(choosingLocation: choose) }
        canvas.onRecognizeText = { [weak self] in self?.recognizeText() }
        canvas.onCopyColor = { [weak self] in self?.copyColor() }
        canvas.onClose = { [weak self] in self?.close() }
    }

    func show() {
        let hosting = NSHostingView(rootView: EditorView(document: document, canvas: canvas, actions: self))
        hosting.sizingOptions = []  // the window decides its size; SwiftUI must not move or resize it
        // A panel that takes keyboard focus without needing macOS to activate Tutto (activation
        // after a global shortcut isn't guaranteed on macOS 14+), so Esc, Tab and T always work.
        let window = EditorPanel(contentRect: .zero,
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        window.isFloatingPanel = false
        window.level = .normal
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Screenshot"
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.delegate = self
        window.minSize = NSSize(width: 860, height: 420)
        window.collectionBehavior = [.fullScreenPrimary]
        window.animationBehavior = .documentWindow

        // Natural size (one image pixel per screen pixel) plus chrome, within 85 % of the screen.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let backing = screen?.backingScaleFactor ?? 2
        let natural = NSSize(width: document.size.width / backing + 56, height: document.size.height / backing + 46 + 28 + 56)
        let size = NSSize(width: min(max(natural.width, 860), visible.width * 0.85),
                          height: min(max(natural.height, 420), visible.height * 0.85))
        window.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                               width: size.width, height: size.height).integral, display: false)
        self.window = window
        AppActivation.bringForward()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
        AppActivation.update()
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
        window = nil
        module?.editorDidClose(self)
        DispatchQueue.main.async {
            MainActor.assumeIsolated { AppActivation.update() }
        }
    }

    #if DEBUG
    func snapshotView() -> some View { EditorView(document: document, canvas: canvas, actions: self) }
    #endif

    func focusCanvas() {
        window?.makeFirstResponder(canvas)
    }

    // MARK: Actions

    func copyAndClose() {
        guard let image = document.render() else { return close() }
        module?.copyToClipboard(image)
        close()
        Toast.shared.show("Copied", detail: "\(image.width) × \(image.height)")
    }

    func copy() {
        guard let image = document.render() else { return }
        module?.copyToClipboard(image)
        Toast.shared.show("Copied", detail: "\(image.width) × \(image.height)\(document.selection == nil ? "" : " selection")")
    }

    func save(choosingLocation: Bool) {
        guard let image = document.render(), let module else { return }
        if choosingLocation {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [module.format == .png ? .png : .jpeg]
            panel.directoryURL = module.saveFolder
            panel.nameFieldStringValue = "Screenshot.\(module.format.fileExtension)"
            guard let window else { return }
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                MainActor.assumeIsolated {
                    if let saved = module.save(image, to: url.deletingLastPathComponent()) {
                        try? FileManager.default.moveItem(at: saved, to: url)
                        Toast.shared.show("Saved", detail: url.lastPathComponent)
                    }
                }
            }
            return
        }
        if let url = module.save(image) {
            Toast.shared.show("Saved to \(url.deletingLastPathComponent().lastPathComponent)", detail: url.lastPathComponent,
                              image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    func recognizeText() {
        Task { @MainActor in
            let result = await document.recognizeText()
            focusCanvas()
            let pasteboard = NSPasteboard.general
            if !result.text.isEmpty {
                pasteboard.clearContents()
                pasteboard.setString(result.text, forType: .string)
                let codeNote = result.codes.isEmpty ? "" : " · QR code found, click to copy it"
                Toast.shared.show("\(result.lineCount) line\(result.lineCount == 1 ? "" : "s") copied",
                                  detail: String(result.text.prefix(80)).replacingOccurrences(of: "\n", with: " ") + codeNote,
                                  duration: result.codes.isEmpty ? 1.8 : 4) {
                    if let code = result.codes.first {
                        pasteboard.clearContents()
                        pasteboard.setString(code, forType: .string)
                        Toast.shared.show("QR code copied", detail: code)
                    }
                }
            } else if let code = result.codes.first {
                pasteboard.clearContents()
                pasteboard.setString(code, forType: .string)
                Toast.shared.show("QR code copied", detail: code)
            } else {
                Toast.shared.show("No text found", detail: document.selection == nil ? "in this screenshot" : "in the selection")
            }
            try? await Task.sleep(for: .milliseconds(900))
            document.textBoxes = []
        }
    }

    func copyColor() {
        guard let hover = document.hover else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hover.color.hexString, forType: .string)
        Toast.shared.show("Color copied", detail: hover.color.hexString, swatch: hover.color)
    }
}

final class EditorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - SwiftUI chrome

private struct EditorView: View {
    @Bindable var document: EditorDocument
    let canvas: EditorCanvas
    let actions: EditorWindowController

    var body: some View {
        VStack(spacing: 0) {
            EditorToolbar(document: document, actions: actions)
                .frame(height: 46)
            Hairline()
            CanvasHost(canvas: canvas)
                .background(Color.canvasBackdrop)
            Hairline()
            EditorStatus(document: document)
                .frame(height: 28)
        }
        .ignoresSafeArea()
        .background(Color.canvas)
    }
}

private struct CanvasHost: NSViewRepresentable {
    let canvas: EditorCanvas
    func makeNSView(context: Context) -> EditorCanvas { canvas }
    func updateNSView(_ view: EditorCanvas, context: Context) {}
}

private struct EditorToolbar: View {
    @Bindable var document: EditorDocument
    let actions: EditorWindowController
    @Namespace private var toolPill

    var body: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 64)  // traffic lights
            HStack(spacing: 2) {
                ForEach(EditorTool.allCases) { tool in
                    Button {
                        withAnimation(Motion.micro) { document.tool = tool }
                        actions.focusCanvas()
                    } label: {
                        Image(systemName: tool.symbol)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(document.tool == tool ? Color.paper : Color.ink2)
                            .frame(width: 30, height: 26)
                            .background {
                                if document.tool == tool {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.ink)
                                        .matchedGeometryEffect(id: "tool", in: toolPill)
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .help("\(tool.title) (\(tool.key))")
                    .accessibilityLabel(tool.title)
                    .accessibilityAddTraits(document.tool == tool ? .isSelected : [])
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.wash))

            Hairline(vertical: true).frame(height: 22)
            if document.tool != .select && document.tool != .pixelate {
                drawingOptions
                    .transition(.opacity)
                Hairline(vertical: true).frame(height: 22)
            }
            Button {
                actions.recognizeText()
            } label: {
                Label("Text", systemImage: "text.viewfinder")
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize()
            }
            .buttonStyle(OutlineButtonStyle(compact: true))
            .focusable(false)
            .help("Copy all text\(document.selection == nil ? "" : " in the selection") (T)")

            Spacer(minLength: 8)

            IconButton(symbol: "arrow.uturn.backward", help: "Undo (⌘Z)", size: 26) { document.undo(); actions.focusCanvas() }
                .disabled(!document.canUndo)
                .opacity(document.canUndo ? 1 : 0.35)
            IconButton(symbol: "arrow.uturn.forward", help: "Redo (⇧⌘Z)", size: 26) { document.redo(); actions.focusCanvas() }
                .disabled(!document.canRedo)
                .opacity(document.canRedo ? 1 : 0.35)

            if document.tool == .select {
                Text(verbatim: "\(Int(document.size.width)) × \(Int(document.size.height))")
                    .font(.mono(11, weight: .medium))
                    .foregroundStyle(Color.ink2)
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.hairline))
                    .help("Image size in pixels")
                    .transition(.opacity)
            }
            Button("Save") { actions.save(choosingLocation: false) }
                .buttonStyle(OutlineButtonStyle(compact: true))
                .fixedSize()
                .focusable(false)
                .help("Save to your screenshot folder (⌘S) · ⇧⌘S to choose")
            Button("Copy") { actions.copy() }
                .buttonStyle(InkButtonStyle(compact: true))
                .fixedSize()
                .focusable(false)
                .help("Copy (⌘C) · Esc copies and closes")
        }
        .padding(.trailing, 12)
        .animation(Motion.micro, value: document.tool)
    }

    /// Colors and line thickness, shown while a drawing tool is active.
    private var drawingOptions: some View {
        HStack(spacing: 10) {
            HStack(spacing: 3) {
                ForEach(Array(EditorPalette.colors.enumerated()), id: \.offset) { _, color in
                    Swatch(color: color, selected: document.color == color) {
                        document.color = color
                        if document.tool == .select { document.tool = .pen }
                        actions.focusCanvas()
                    }
                }
                CustomColorButton(document: document)
            }
            HStack(spacing: 2) {
                ForEach(EditorDocument.Thickness.allCases, id: \.self) { thickness in
                    Button {
                        document.thickness = thickness
                        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                        actions.focusCanvas()
                    } label: {
                        Circle()
                            .fill(document.thickness == thickness ? Color.ink : Color.ink4)
                            .frame(width: 4 + thickness.rawValue * 0.7, height: 4 + thickness.rawValue * 0.7)
                            .frame(width: 20, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .help("\(thickness.title) line ([ and ] to change)")
                    .accessibilityLabel("\(thickness.title) line")
                }
            }
        }
    }
}

private struct Swatch: View {
    var color: NSColor
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(nsColor: color))
                .overlay(Circle().strokeBorder(Color.ink.opacity(0.2), lineWidth: 1))
                .frame(width: 14, height: 14)
                .padding(3)
                .overlay(Circle().strokeBorder(selected ? Color.ink : .clear, lineWidth: 1.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityLabel("Color \(color.hexString)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A "+" swatch that opens the system color panel for any other color.
private struct CustomColorButton: View {
    var document: EditorDocument
    @State private var target = ColorPanelTarget()

    var body: some View {
        let isCustom = !EditorPalette.colors.contains(document.color)
        Button {
            target.document = document
            let panel = NSColorPanel.shared
            panel.showsAlpha = false
            panel.color = document.color
            panel.setTarget(target)
            panel.setAction(#selector(ColorPanelTarget.colorChanged(_:)))
            panel.orderFront(nil)
        } label: {
            ZStack {
                Circle()
                    .fill(isCustom ? Color(nsColor: document.color) : Color.clear)
                    .overlay(Circle().strokeBorder(Color.ink.opacity(isCustom ? 0.2 : 0.35), style: StrokeStyle(lineWidth: 1, dash: isCustom ? [] : [2, 2])))
                    .frame(width: 14, height: 14)
                if !isCustom {
                    Image(systemName: "plus").font(.system(size: 7, weight: .bold)).foregroundStyle(Color.ink2)
                }
            }
            .padding(3)
            .overlay(Circle().strokeBorder(isCustom ? Color.ink : .clear, lineWidth: 1.5))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help("Another color…")
        .accessibilityLabel("Custom color")
    }
}

@MainActor
final class ColorPanelTarget: NSObject {
    weak var document: EditorDocument?

    @objc func colorChanged(_ sender: NSColorPanel) {
        guard let document else { return }
        document.color = sender.color.usingColorSpace(.sRGB) ?? sender.color
        if document.tool == .select { document.tool = .pen }
    }
}

private struct EditorStatus: View {
    var document: EditorDocument

    var body: some View {
        HStack(spacing: 14) {
            if let hover = document.hover {
                Text("X \(Int(hover.point.x - document.crop.minX))  Y \(Int(hover.point.y - document.crop.minY))")
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(Color(nsColor: hover.color))
                    .overlay(RoundedRectangle(cornerRadius: 2.5).strokeBorder(Color.hairline))
                    .frame(width: 11, height: 11)
                Text(hover.color.hexString)
            } else {
                Text("X —  Y —")
            }
            Text("\(document.zoomPercent)%")
            Spacer()
            Text("TAB COPY COLOR · ↩ CROP · T TEXT · ESC COPY & CLOSE")
                .tracking(0.6)
                .foregroundStyle(Color.ink3)
        }
        .font(.mono(10.5, weight: .medium))
        .foregroundStyle(Color.ink2)
        .padding(.horizontal, 14)
    }
}

extension Color {
    /// Behind the picture in the editor: a step darker than the window, so the image edge reads.
    static let canvasBackdrop = Color(nsColor: NSColor(name: "canvasBackdrop") { appearance in
        appearance.isDark ? NSColor(white: 0.07, alpha: 1) : NSColor(white: 0.90, alpha: 1)
    })
}
