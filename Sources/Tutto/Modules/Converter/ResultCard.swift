//
//  ResultCard.swift
//  Tutto
//
//  What a compress, convert, resize or crop made, in the bottom corner of the screen for a few
//  seconds: a picture of it, how much smaller it got, and what to do next: Undo (the copy to the
//  Trash), Half (half the pixels), Crop (to a shape), Show in Finder.
//  Drag the picture out to put the file anywhere. It stays while the pointer is over it and goes
//  by itself after 12 seconds.
//

import AppKit
import AVFoundation
import QuickLookThumbnailing
import SwiftUI
import TuttoKit

@MainActor
final class ResultCard {
    static let shared = ResultCard()

    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private let state = ResultCardState()

    /// A file made or changed.
    func show(_ result: ConverterModule.Made, module: ConverterModule, count: Int = 1, totalBefore: Int = 0, totalAfter: Int = 0) {
        state.content = .file(result, count: count, totalBefore: totalBefore, totalAfter: totalAfter)
        state.module = module
        state.thumbnail = nil
        state.dimensions = count == 1 ? Self.dimensions(of: result.url) : nil
        present(duration: 12)
        if count == 1, FileKind.of(result.url) == .video {
            Task { @MainActor [weak self] in
                guard let track = try? await AVURLAsset(url: result.url).loadTracks(withMediaType: .video).first,
                      let size = try? await track.load(.naturalSize), let transform = try? await track.load(.preferredTransform) else { return }
                let upright = CGRect(origin: .zero, size: size).applying(transform).standardized
                guard let self, case .file(let shown, _, _, _)? = self.state.content, shown.id == result.id else { return }
                self.state.dimensions = "\(Int(upright.width.rounded())) × \(Int(upright.height.rounded()))"
            }
        }
        let size = CGSize(width: 92, height: 92)
        let request = QLThumbnailGenerator.Request(fileAt: result.url, size: size, scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                   representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] thumbnail, _ in
            let image = thumbnail?.nsImage
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, case .file(let shown, _, _, _)? = self.state.content, shown.id == result.id else { return }
                    self.state.thumbnail = image
                }
            }
        }
    }

    func dismiss() {
        hideWork?.cancel()
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                panel.contentView = nil
            }
        })
    }

    /// Keeps it up while the pointer is over it; after, it goes in a few seconds.
    fileprivate func hovering(_ inside: Bool) {
        hideWork?.cancel()
        if !inside { scheduleHide(after: 4) }
    }

    private func present(duration: TimeInterval) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let size = panel.contentView?.fittingSize ?? NSSize(width: 340, height: 120)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrame(NSRect(x: visible.maxX - size.width - 12, y: visible.minY + 12, width: size.width, height: size.height).integral,
                           display: true)
        }
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.1 : 0.2
                panel.animator().alphaValue = 1
            }
        }
        state.appeared &+= 1
        scheduleHide(after: duration)
    }

    private func scheduleHide(after seconds: TimeInterval) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 120), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = !ThemeStore.liquid
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let host = NSHostingView(rootView: ResultCardView(state: state, card: self).fixedSize())
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        return panel
    }

    /// "1920 × 1080" for a picture (nil for anything else).
    private static func dimensions(of url: URL) -> String? {
        guard FileKind.of(url) == .image, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = properties[kCGImagePropertyPixelWidth] as? Int, let h = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let turned = (properties[kCGImagePropertyOrientation] as? Int).map { $0 >= 5 } ?? false
        return turned ? "\(h) × \(w)" : "\(w) × \(h)"
    }
}

@MainActor
@Observable
final class ResultCardState {
    enum Content {
        case file(ConverterModule.Made, count: Int, totalBefore: Int, totalAfter: Int)
    }

    var content: Content?
    var thumbnail: NSImage?
    var dimensions: String?
    var appeared = 0
    weak var module: ConverterModule?
}

private struct ResultCardView: View {
    var state: ResultCardState
    var card: ResultCard
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                picture
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 6) {
                        Text(sizes)
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(Color.ink2)
                        if !saving.isEmpty {
                            Text(saving)
                                .font(.system(size: 12, weight: .bold).monospacedDigit())
                                .foregroundStyle(Color.themeAccent)
                        }
                    }
                    .lineLimit(1)
                    Text(caption)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.ink3)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
            }
            actions
        }
        .padding(12)
        .frame(width: 340, alignment: .leading)
        .background { ResultSurface() }
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button { card.dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.ink2)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.ink.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .padding(8)
                .help("Close")
                .transition(.opacity)
            }
        }
        .padding(6)
        .onHover { inside in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { hovering = inside }
            card.hovering(inside)
        }
        .id(state.appeared)
        .transition(.opacity)
    }

    // MARK: Parts

    private var picture: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return Group {
            if let image = state.thumbnail {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else if case .file(let made, _, _, _)? = state.content {
                Image(nsImage: NSWorkspace.shared.icon(forFile: made.url.path)).resizable().padding(4)
            }
        }
        .frame(width: 46, height: 46)
        .background(shape.fill(Color.ink.opacity(0.06)))
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.ink.opacity(0.12)))
        .onDrag {
            if case .file(let made, _, _, _)? = state.content, let provider = NSItemProvider(contentsOf: made.url) { return provider }
            return NSItemProvider()
        }
        .help(dragHelp)
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 6) {
            switch state.content {
            case .file(let made, let count, _, _)?:
                if count == 1 {
                    chip("Undo", "arrow.uturn.backward", help: "Move this copy to the Trash") {
                        state.module?.undo(made)
                        card.dismiss()
                    }
                    if ConvertPlanner.canResize(FileKind.of(made.url)) {
                        chip("Half", "arrow.down.right.and.arrow.up.left", help: "Half the width and half the height") {
                            state.module?.change(made, .resize(.scale(0.5)))
                        }
                    }
                    if ConvertPlanner.canCrop(FileKind.of(made.url)) {
                        chip("Crop", "crop", help: "Cut it to a shape, around what's in it") {
                            let module = state.module
                            ChoiceMenu.show(ChoiceMenu.crops(pdf: FileKind.of(made.url) == .pdf) { spec in module?.change(made, .crop(spec)) })
                        }
                    }
                }
                Spacer(minLength: 0)
                chip("Show", "folder", help: "Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([made.url])
                    card.dismiss()
                }
            case nil:
                EmptyView()
            }
        }
    }

    private func chip(_ title: String, _ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { chipLabel(title, symbol) }
            .buttonStyle(PressStyle())
            .help(help)
    }

    private func chipLabel(_ title: String, _ symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold))
            Text(title).font(.system(size: 11.5, weight: .semibold))
        }
        .foregroundStyle(Color.ink)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background {
            if ThemeStore.liquid {
                LiquidFill(shape: Capsule())
            } else {
                Capsule().fill(Color.ink.opacity(0.08))
            }
        }
        .contentShape(Capsule())
    }

    // MARK: Words

    private var title: String {
        switch state.content {
        case .file(let made, let count, _, _)?: count > 1 ? "\(count) files" : made.url.lastPathComponent
        case nil: ""
        }
    }

    private var sizes: String {
        switch state.content {
        case .file(let made, let count, let before, let after)?:
            if count > 1 { return "\(ConverterModule.bytes(before)) → \(ConverterModule.bytes(after))" }
            switch made.action {
            case .resize, .crop:
                return [ConverterModule.bytes(made.after), state.dimensions].compactMap { $0 }.joined(separator: " · ")
            default:
                return made.before > 0 ? "\(ConverterModule.bytes(made.before)) → \(ConverterModule.bytes(made.after))" : ConverterModule.bytes(made.after)
            }
        case nil:
            return ""
        }
    }

    private var saving: String {
        switch state.content {
        case .file(let made, let count, let before, let after)?:
            if count > 1 { return SavedBytes.percent(before: before, after: after) }
            return made.before > 0 ? SavedBytes.percent(before: made.before, after: made.after) : ""
        case nil:
            return ""
        }
    }

    private var caption: String {
        switch state.content {
        case .file(let made, let count, _, _)?:
            if count > 1 { return made.action.title }
            return "\(made.action.done) · beside the original"
        case nil:
            return ""
        }
    }

    private var dragHelp: String {
        if case .file? = state.content { return "Drag it into a message, a page or a folder" }
        return ""
    }
}

/// The card's surface: glass in the Liquid Glass look, the system's material otherwise.
private struct ResultSurface: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        if ThemeStore.liquid {
            Color.clear
                .prototypeGlass(shape)
                .overlay(GlassRim(shape: shape))
        } else {
            shape.fill(.regularMaterial)
                .overlay(shape.strokeBorder(Color.hairline))
                .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
        }
    }
}

/// A native pop-up menu at the pointer, for choices on a chip (a SwiftUI Menu drops the chip's own
/// background in a borderless style).
@MainActor
enum ChoiceMenu {
    struct Item {
        var title: String
        var detail = ""
        /// A section title before this item.
        var section: String?
        var checked = false
        var action: () -> Void
    }

    static func show(_ items: [Item]) {
        let menu = NSMenu()
        for item in items {
            if let section = item.section {
                if menu.numberOfItems > 0 { menu.addItem(.separator()) }
                menu.addItem(.sectionHeader(title: section))
            }
            let entry = NSMenuItem(title: item.title, action: #selector(Target.run), keyEquivalent: "")
            let target = Target(item.action)
            entry.target = target
            entry.representedObject = target
            entry.state = item.checked ? .on : .off
            if !item.detail.isEmpty {
                let text = NSMutableAttributedString(string: item.title, attributes: [.font: NSFont.menuFont(ofSize: 0)])
                text.append(NSAttributedString(string: "  \(item.detail)", attributes: [.font: NSFont.menuFont(ofSize: 0),
                                                                                       .foregroundColor: NSColor.secondaryLabelColor]))
                entry.attributedTitle = text
            }
            menu.addItem(entry)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// The shapes and sizes a crop offers (shapes only for PDFs).
    static func crops(pdf: Bool, current: CropSpec? = nil, _ pick: @escaping (CropSpec) -> Void) -> [Item] {
        var items = CropSpec.aspects.enumerated().map { index, spec in
            Item(title: spec.title, detail: spec.detail, section: index == 0 ? "Shape" : nil, checked: spec == current) { pick(spec) }
        }
        if !pdf {
            items += CropSpec.sizes.enumerated().map { index, spec in
                Item(title: spec.title, detail: spec.detail, section: index == 0 ? "Size" : nil, checked: spec == current) { pick(spec) }
            }
        }
        return items
    }

    private final class Target: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func run() { action() }
    }
}
