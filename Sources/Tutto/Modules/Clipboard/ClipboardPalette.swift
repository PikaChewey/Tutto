//
//  ClipboardPalette.swift
//  Tutto
//
//  ⌃⇧V. Search on top, history on the left, a preview on the right, keys in the footer.
//  Opens instantly (keyboard surfaces don't animate) and never activates Tutto, so ↩
//  pastes straight into the app you were using.
//

import AppKit
import Carbon.HIToolbox
import ImageIO
import SwiftUI
import TuttoKit

@MainActor
@Observable
final class ClipboardPaletteModel {
    var query = "" { didSet { refresh(keepSelection: false) } }
    var filter: ClipFilter = .all { didSet { refresh(keepSelection: false) } }
    var selection: UUID?
    private(set) var results: [ClipItem] = []
    var targetName: String?

    let module: ClipboardModule
    let thumbnails = ThumbnailCache()

    init(module: ClipboardModule) {
        self.module = module
        refresh(keepSelection: false)
    }

    var selected: ClipItem? { results.first { $0.id == selection } ?? results.first }

    func refresh(keepSelection: Bool = true) {
        results = module.store?.search(query, filter: filter) ?? []
        if !keepSelection || !results.contains(where: { $0.id == selection }) {
            selection = results.first?.id
        }
    }

    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        let index = results.firstIndex { $0.id == selection } ?? 0
        selection = results[min(max(index + delta, 0), results.count - 1)].id
    }

    func cycleFilter(backwards: Bool = false) {
        let all = ClipFilter.allCases
        let index = all.firstIndex(of: filter) ?? 0
        filter = all[(index + (backwards ? all.count - 1 : 1)) % all.count]
    }
}

@MainActor
final class ClipboardPaletteController: NSObject, NSWindowDelegate {
    private weak var module: ClipboardModule?
    private var panel: FloatingPanel?
    private var keyMonitor: Any?
    private var target: NSRunningApplication?
    private var model: ClipboardPaletteModel?

    init(module: ClipboardModule) {
        self.module = module
    }

    func show(target: NSRunningApplication?) {
        guard let module else { return }
        if let panel, panel.isVisible {
            close()  // pressing the shortcut again closes it
            return
        }
        self.target = target?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : target
        let model = ClipboardPaletteModel(module: module)
        model.targetName = self.target?.localizedName
        self.model = model

        let panel = FloatingPanel(size: NSSize(width: 780, height: 480))
        panel.contentMinSize = NSSize(width: 620, height: 360)
        panel.delegate = self
        panel.onResignKey = { [weak self] in self?.close() }
        let hosting = NSHostingView(rootView: ClipboardPaletteView(model: model, actions: self))
        panel.contentView = hosting
        panel.positionOnActiveScreen()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        installKeys()
    }

    func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        guard let panel else { return }
        self.panel = nil
        panel.onResignKey = nil
        panel.orderOut(nil)
        panel.contentView = nil
        model = nil
        module?.paletteDidClose()
    }

    func windowWillClose(_ notification: Notification) { close() }

    // MARK: Actions

    func paste(_ item: ClipItem?, plainText: Bool = false) {
        guard let item, let module else { return }
        let target = self.target
        close()
        module.paste(item, into: target, plainText: plainText)
    }

    func copyOnly(_ item: ClipItem?) {
        guard let item, let module else { return }
        close()
        if module.copy(item) { Toast.shared.show("Copied", detail: item.title) }
    }

    func togglePin(_ item: ClipItem?) {
        guard let item, let module else { return }
        module.setPinned(item, !item.pinned)
        model?.refresh()
    }

    func delete(_ item: ClipItem?) {
        guard let item, let module, let model else { return }
        let index = model.results.firstIndex(of: item) ?? 0
        module.remove(item)
        model.refresh()
        if !model.results.isEmpty {
            model.selection = model.results[min(index, model.results.count - 1)].id
        }
    }

    // MARK: Keys

    private func installKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let model = self.model, event.window === self.panel else { return event }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            switch Int(event.keyCode) {
            case kVK_DownArrow: model.move(flags.contains(.command) ? 1000 : 1); return nil
            case kVK_UpArrow: model.move(flags.contains(.command) ? -1000 : -1); return nil
            case kVK_Return, kVK_ANSI_KeypadEnter:
                if flags.contains(.command) { copyOnly(model.selected) }
                else { paste(model.selected, plainText: flags.contains(.shift)) }
                return nil
            case kVK_Escape: close(); return nil
            case kVK_Tab: model.cycleFilter(backwards: flags.contains(.shift)); return nil
            case kVK_Delete where flags.contains(.command), kVK_ForwardDelete where flags.contains(.command):
                delete(model.selected); return nil
            case kVK_ANSI_P where flags == [.command, .shift]: togglePin(model.selected); return nil
            default:
                // ⌘1…⌘9 paste the nth item (digit key codes aren't contiguous, hence the map).
                if flags == [.command], let n = Self.digit(for: Int(event.keyCode)), n <= model.results.count {
                    paste(model.results[n - 1])
                    return nil
                }
                return event
            }
        }
    }

    private static func digit(for keyCode: Int) -> Int? {
        [kVK_ANSI_1: 1, kVK_ANSI_2: 2, kVK_ANSI_3: 3, kVK_ANSI_4: 4, kVK_ANSI_5: 5, kVK_ANSI_6: 6, kVK_ANSI_7: 7,
         kVK_ANSI_8: 8, kVK_ANSI_9: 9][keyCode]
    }
}

// MARK: - View

struct ClipboardPaletteView: View {
    @Bindable var model: ClipboardPaletteModel
    var actions: ClipboardPaletteController
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Hairline()
            HStack(spacing: 0) {
                list
                    .frame(width: 300)
                Hairline(vertical: true)
                preview
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Hairline()
            footer
        }
        .background(PaletteBackground())
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.hairline))
        .onAppear { searchFocused = true }
        .onChange(of: model.module.revision) { _, _ in model.refresh() }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.ink3)
            TextField("Search clipboard history", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused($searchFocused)
            FilterPills(selection: $model.filter)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if model.results.isEmpty {
                        Text(model.query.isEmpty ? "Copy something and it shows up here." : "Nothing matches “\(model.query)”.")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.ink3)
                            .padding(16)
                    }
                    let firstUnpinned = model.results.firstIndex { !$0.pinned }
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { index, item in
                        if index == 0 && item.pinned { sectionLabel("Pinned") }
                        if index == firstUnpinned && firstUnpinned != 0 { sectionLabel("Recent") }
                        ClipRow(item: item, selected: item.id == model.selected?.id, index: index,
                                thumbnail: model.thumbnails.thumbnail(for: item, store: model.module.store))
                            .id(item.id)
                            .onTapGesture(count: 2) { actions.paste(item) }
                            .onTapGesture { model.selection = item.id }
                    }
                }
                .padding(6)
            }
            .onChange(of: model.selection) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Caption(text)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    @ViewBuilder
    private var preview: some View {
        if let item = model.selected {
            VStack(alignment: .leading, spacing: 0) {
                ClipPreview(item: item, store: model.module.store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Hairline()
                ClipMetadata(item: item)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "list.clipboard").font(.system(size: 26, weight: .light)).foregroundStyle(Color.ink4)
                Text("No history yet").font(.system(size: 12)).foregroundStyle(Color.ink3)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint("Paste to \(model.targetName ?? "the active app")", "↩")
            hint("Copy", "⌘↩")
            hint(model.selected?.pinned == true ? "Unpin" : "Pin", "⌘⇧P")
            hint("Delete", "⌘⌫")
            Spacer()
            hint("Type", "⇥")
        }
        .padding(.horizontal, 16)
        .frame(height: 32)
    }

    private func hint(_ title: String, _ keys: String) -> some View {
        HStack(spacing: 5) {
            Text(title).font(.system(size: 11)).foregroundStyle(Color.ink2).lineLimit(1)
            Text(keys).font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundStyle(Color.ink3)
        }
    }
}

private struct FilterPills: View {
    @Binding var selection: ClipFilter

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ClipFilter.allCases, id: \.self) { filter in
                Button {
                    selection = filter
                } label: {
                    Text(filter.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(selection == filter ? Color.paper : Color.ink2)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(Capsule().fill(selection == filter ? Color.ink : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == filter ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.wash))
        .overlay(Capsule().strokeBorder(Color.hairline))
        .help("Filter by type (⇥)")
    }
}

private struct ClipRow: View {
    var item: ClipItem
    var selected: Bool
    var index: Int
    var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 24, height: 24)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selected ? Color.paper.opacity(0.85) : Color.ink3)
                }
            }
            .frame(width: 24, height: 24)
            Text(item.title)
                .font(.system(size: 12.5))
                .foregroundStyle(selected ? Color.paper : Color.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            if item.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(selected ? Color.paper.opacity(0.7) : Color.ink4)
            }
            Text(RelativeTime.short(item.lastCopied))
                .font(.mono(10))
                .foregroundStyle(selected ? Color.paper.opacity(0.7) : Color.ink3)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? Color.ink : .clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.kind.title): \(item.title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var symbol: String {
        switch item.kind {
        case .text: "text.alignleft"
        case .link: "link"
        case .image: "photo"
        case .file: "doc"
        }
    }
}

private struct ClipPreview: View {
    var item: ClipItem
    var store: ClipboardStore?

    var body: some View {
        switch item.kind {
        case .text:
            ScrollView {
                Text(item.text ?? "")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        case .link:
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "link").font(.system(size: 22, weight: .light)).foregroundStyle(Color.ink3)
                Text(URL(string: item.text ?? "")?.host() ?? "Link")
                    .font(.system(size: 20, weight: .semibold))
                Text(item.text ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.ink2)
                    .textSelection(.enabled)
                    .lineLimit(6)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .image:
            if let store, let url = store.imageURL(for: item), let image = ThumbnailCache.downsample(url, maxPixel: 1400) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(16)
            } else {
                Text("Image unavailable").font(.system(size: 12)).foregroundStyle(Color.ink3)
            }
        case .file:
            VStack(alignment: .leading, spacing: 10) {
                let paths = item.filePaths ?? []
                if let first = paths.first {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: first))
                        .resizable()
                        .frame(width: 56, height: 56)
                }
                ForEach(paths.prefix(8), id: \.self) { path in
                    VStack(alignment: .leading, spacing: 1) {
                        Text((path as NSString).lastPathComponent).font(.system(size: 13, weight: .medium))
                        Text((path as NSString).deletingLastPathComponent)
                            .font(.system(size: 11)).foregroundStyle(Color.ink3).lineLimit(1).truncationMode(.middle)
                    }
                }
                if paths.count > 8 { Caption("and \(paths.count - 8) more", uppercase: false) }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private struct ClipMetadata: View {
    var item: ClipItem

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            GridRow {
                field("Source", item.sourceName ?? "—")
                field("Type", item.kind.title)
            }
            GridRow {
                field("Size", size)
                field("Copied", "\(RelativeTime.long(item.lastCopied))\(item.copyCount > 1 ? " · \(item.copyCount)×" : "")")
            }
        }
    }

    private var size: String {
        switch item.kind {
        case .text, .link: "\((item.text ?? "").count.formatted()) characters"
        case .image: "\(item.imageWidth ?? 0) × \(item.imageHeight ?? 0) px"
        case .file: "\(item.filePaths?.count ?? 0) item\(item.filePaths?.count == 1 ? "" : "s")"
        }
    }

    private func field(_ caption: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Caption(caption).frame(width: 58, alignment: .leading)
            Text(value).font(.system(size: 11.5)).foregroundStyle(Color.ink2).lineLimit(1)
        }
    }
}

// MARK: - Helpers

enum RelativeTime {
    static func short(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        if seconds < 86_400 * 7 { return "\(Int(seconds / 86_400))d" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    static func long(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }
}

/// Small thumbnails for list rows, decoded at their display size and dropped with the palette.
@MainActor
final class ThumbnailCache {
    private var cache: [UUID: NSImage] = [:]
    private var fileIcons: [String: NSImage] = [:]

    func thumbnail(for item: ClipItem, store: ClipboardStore?) -> NSImage? {
        if let cached = cache[item.id] { return cached }
        var image: NSImage?
        switch item.kind {
        case .image:
            if let url = store?.imageURL(for: item) { image = Self.downsample(url, maxPixel: 64) }
        case .file:
            if let path = item.filePaths?.first {
                let ext = (path as NSString).pathExtension.lowercased()
                if let icon = fileIcons[ext] { return icon }
                image = NSWorkspace.shared.icon(forFile: path)
                fileIcons[ext] = image
                return image
            }
        default:
            return nil
        }
        cache[item.id] = image
        return image
    }

    nonisolated static func downsample(_ url: URL, maxPixel: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
