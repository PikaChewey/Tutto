//
//  ArchiveBrowser.swift
//  Tutto
//
//  Looking inside an archive without unpacking it: its folders and files with their sizes and
//  dates, a path to click back along, search. Double-click a folder to go in, an archive inside
//  the archive to open it in place, anything else to open it; space shows it in Quick Look. Take
//  out only what you pick (Extract, or drag it to Finder); add files by dropping them in or with
//  Add, remove them with Remove or ⌫, in zip, 7z and tar archives (the old one goes to the
//  Trash). RAR and the rest are read only, and say why.
//
//  Each archive gets a window of its own. What's taken out to show or open goes to a temporary
//  folder of the window's, removed when the window closes (files opened in other apps live in
//  one that's cleared the next time Tutto starts).
//

import AppKit
import Quartz
import SwiftUI
import TuttoKit
import UniformTypeIdentifiers

// MARK: - Windows

@MainActor
final class ArchiveBrowserWindows {
    static let shared = ArchiveBrowserWindows()
    private var controllers: [ArchiveBrowserController] = []

    /// Opens a window on `url` (the one already open on it comes forward instead).
    func open(_ url: URL) {
        let first = ArchiveVolumes.firstVolume(for: url)
        if let open = controllers.first(where: { $0.model.rootURL == first }) {
            open.present()
            return
        }
        let controller = ArchiveBrowserController(url: first) { [weak self] closed in
            self?.controllers.removeAll { $0 === closed }
        }
        controllers.append(controller)
        controller.present()
    }

    /// Where opened files go (cleared at launch: other apps may still have them open until then).
    static let openedFolder = FileManager.default.temporaryDirectory.appendingPathComponent("Tutto-Archives/Opened", isDirectory: true)

    static func clearOldFiles() {
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("Tutto-Archives"))
    }
}

@MainActor
final class ArchiveBrowserController: NSObject, NSWindowDelegate {
    let model: ArchiveBrowserModel
    private let window: NSWindow
    private let onClose: (ArchiveBrowserController) -> Void

    init(url: URL, onClose: @escaping (ArchiveBrowserController) -> Void) {
        model = ArchiveBrowserModel(url: url)
        self.onClose = onClose
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.title = url.lastPathComponent
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 560, height: 360)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = AppActivation.windowBehavior
        window.contentView = NSHostingView(rootView: ArchiveBrowserView(model: model) { [weak window] in window?.performClose(nil) })
        window.delegate = self
        window.center()
        model.load()
    }

    func present() {
        AppActivation.bringForward()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.cleanUp()
        window.contentView = nil
        onClose(self)
    }
}

// MARK: - Model

@MainActor
@Observable
final class ArchiveBrowserModel {
    struct Level {
        var url: URL
        var name: String
        var tree: ArchiveTree
        /// Why it can't be changed (nil: Add and Remove work).
        var readOnly: String?
        var password: String?
        /// The folder in view ("" for the top, else ending in "/").
        var folder = ""
        var format: String
    }

    let rootURL: URL
    private(set) var levels: [Level] = []
    private(set) var loading = true
    /// What went wrong, shown until the next action.
    var notice: String?
    /// A change or an extraction under way ("Adding 3 items…").
    private(set) var busy: String?
    private(set) var fraction: Double = 0
    var selection: Set<String> = []
    var search = "" { didSet { selection.removeAll() } }
    var sortOrder: [KeyPathComparator<ArchiveNode>] = [KeyPathComparator(\.name, comparator: .localizedStandard)]

    @ObservationIgnored private let workFolder: URL

    init(url: URL) {
        rootURL = url
        workFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Tutto-Archives/\(UUID().uuidString)", isDirectory: true)
    }

    var level: Level? { levels.last }

    /// The rows in view: the folder's contents, or every match while searching; folders first.
    var rows: [ArchiveNode] {
        guard let level else { return [] }
        let nodes = search.isEmpty ? level.tree.children(of: level.folder) : level.tree.search(search)
        let sorted = nodes.sorted(using: sortOrder)
        return sorted.filter(\.isDirectory) + sorted.filter { !$0.isDirectory }
    }

    var selectedNodes: [ArchiveNode] {
        guard let level else { return [] }
        return selection.compactMap { level.tree.node($0) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    // MARK: Loading

    func load() {
        loading = true
        list(rootURL, name: rootURL.lastPathComponent, password: nil, nested: false) { [weak self] level in
            self?.levels = [level]
        }
    }

    /// Lists an archive in the background; asks for its password when its names are locked.
    private func list(_ url: URL, name: String, password: String?, nested: Bool, then: @escaping (Level) -> Void) {
        loading = true
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                var options = ArchiveExtractionOptions()
                options.password = password
                let entries = try ArchiveExtractor(url: url).listEntries(options: options)
                let readOnly = nested
                    ? "Archives inside archives can be looked through and extracted, not changed."
                    : ArchiveEditor.readOnlyReason(url)
                let level = Level(url: url, name: name, tree: ArchiveTree(entries: entries), readOnly: readOnly,
                                  password: password, format: Self.formatName(url))
                await MainActor.run {
                    self?.loading = false
                    self?.notice = nil
                    then(level)
                }
            } catch let error as ArchiveError where error == .passwordRequired || error == .wrongPassword {
                await MainActor.run {
                    PasswordPrompt.ask(archiveName: name, wrong: error == .wrongPassword) { given in
                        guard let self else { return }
                        if let given { self.list(url, name: name, password: given, nested: nested, then: then) } else { self.loading = false }
                    }
                }
            } catch {
                await MainActor.run {
                    self?.loading = false
                    self?.notice = ArchiveModule.describe(error)
                }
            }
        }
    }

    nonisolated static func formatName(_ url: URL) -> String {
        let name = url.lastPathComponent.lowercased()
        for compound in ["tar.gz", "tar.bz2", "tar.xz"] where name.hasSuffix("." + compound) { return compound }
        let ext = url.pathExtension
        return ext.isEmpty ? "Archive" : ext.uppercased()
    }

    // MARK: Moving around

    /// A folder goes in, an archive opens in place, anything else opens in its app.
    func open(_ node: ArchiveNode) {
        guard var level else { return }
        if node.isDirectory {
            level.folder = node.path + "/"
            levels[levels.count - 1] = level
            search = ""
            selection.removeAll()
        } else if ArchiveNames.isArchive(node.name) {
            openNested(node)
        } else {
            take([node], into: ArchiveBrowserWindows.openedFolder.appendingPathComponent(UUID().uuidString)) { urls in
                urls.forEach { NSWorkspace.shared.open($0) }
            }
        }
    }

    /// Back to a level and a folder in it (the path at the top).
    func go(toLevel index: Int, folder: String) {
        guard levels.indices.contains(index) else { return }
        levels.removeLast(levels.count - index - 1)
        levels[index].folder = folder
        search = ""
        selection.removeAll()
    }

    func goUp() {
        guard let level else { return }
        if !level.folder.isEmpty {
            let trail = ArchiveTree.trail(to: level.folder)
            go(toLevel: levels.count - 1, folder: trail.count > 1 ? trail[trail.count - 2] + "/" : "")
        } else if levels.count > 1 {
            go(toLevel: levels.count - 2, folder: levels[levels.count - 2].folder)
        }
    }

    private func openNested(_ node: ArchiveNode) {
        take([node], into: workFolder.appendingPathComponent("nested-\(UUID().uuidString)")) { [weak self] urls in
            guard let self, let inner = urls.first else { return }
            self.list(inner, name: node.name, password: nil, nested: true) { level in
                self.levels.append(level)
                self.search = ""
                self.selection.removeAll()
            }
        }
    }

    // MARK: Taking things out

    /// Extracts `nodes` (each named from its own folder) into `folder`, then hands over the URLs.
    func take(_ nodes: [ArchiveNode], into folder: URL, done: @escaping @MainActor ([URL]) -> Void) {
        guard let level, !nodes.isEmpty else { return }
        let url = level.url
        let password = level.password
        let groups = Dictionary(grouping: nodes, by: \.parent)
        busy = nodes.count == 1 ? "Taking out \(nodes[0].name)…" : "Taking out \(nodes.count) items…"
        fraction = 0
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var items: [URL] = []
                for (base, group) in groups {
                    var options = ArchiveExtractionOptions(folderRule: .never, password: password)
                    options.selection = ArchiveSelection(paths: group.map(\.path), base: base)
                    let result = try ArchiveExtractor(url: url).extract(to: folder, options: options, progress: { progress in
                        Task { @MainActor in self?.fraction = progress.fraction }
                    })
                    items += result.items
                }
                await MainActor.run {
                    self?.busy = nil
                    done(items)
                }
            } catch let error as ArchiveError where error == .passwordRequired || error == .wrongPassword {
                await MainActor.run {
                    guard let self else { return }
                    self.busy = nil
                    PasswordPrompt.ask(archiveName: level.name, wrong: error == .wrongPassword) { given in
                        guard let given, !self.levels.isEmpty else { return }
                        self.levels[self.levels.count - 1].password = given
                        self.take(nodes, into: folder, done: done)
                    }
                }
            } catch {
                await MainActor.run {
                    self?.busy = nil
                    self?.notice = ArchiveModule.describe(error)
                }
            }
        }
    }

    /// The selection (or everything, with nothing selected) into a folder you pick.
    func extractChosen(all: Bool) {
        guard let level else { return }
        let nodes = all || selection.isEmpty ? level.tree.children(of: "") : selectedNodes
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Extract Here"
        panel.message = nodes.count == 1 ? "Where should “\(nodes[0].name)” go?" : "Where should these \(nodes.count) items go?"
        panel.directoryURL = rootURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        take(nodes, into: folder) { urls in
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    /// Quick Look on the selected files (space).
    func quickLook() {
        let files = selectedNodes.filter { !$0.isDirectory }
        guard !files.isEmpty else { return }
        take(files, into: workFolder.appendingPathComponent("preview-\(UUID().uuidString)")) { urls in
            ArchivePreview.shared.show(urls)
        }
    }

    /// For dragging a row to Finder: the file is taken out only when it's dropped.
    nonisolated func itemProvider(for node: ArchiveNode, url: URL, password: String?, folder: URL) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = node.name
        let type: UTType = node.isDirectory ? .folder : (UTType(filenameExtension: node.fileExtension) ?? .data)
        let path = node.path, base = node.parent
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let destination = folder.appendingPathComponent("drag-\(UUID().uuidString)")
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                    var options = ArchiveExtractionOptions(folderRule: .never, password: password)
                    options.selection = ArchiveSelection(paths: [path], base: base)
                    let result = try ArchiveExtractor(url: url).extract(to: destination, options: options)
                    completion(result.items.first, false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return nil
        }
        return provider
    }

    func provider(for node: ArchiveNode) -> NSItemProvider {
        guard let level else { return NSItemProvider() }
        return itemProvider(for: node, url: level.url, password: level.password, folder: workFolder)
    }

    // MARK: Changing the archive

    var canEdit: Bool { level?.readOnly == nil && busy == nil && !loading }

    /// Removes the selection; the archive is written again without it.
    func removeSelected() {
        let paths = selectedNodes.map(\.path)
        guard canEdit, !paths.isEmpty else { return }
        change(removing: paths, adding: [], message: paths.count == 1 ? "Removing \(selectedNodes[0].name)…" : "Removing \(paths.count) items…")
    }

    /// Adds files (dropped, or picked with Add) to the folder in view.
    func add(_ urls: [URL]) {
        guard canEdit, let level, !urls.isEmpty else { return }
        let additions = urls.map { ArchiveAddition(source: $0, folder: level.folder) }
        change(removing: [], adding: additions, message: urls.count == 1 ? "Adding \(urls[0].lastPathComponent)…" : "Adding \(urls.count) items…")
    }

    func chooseFilesToAdd() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "Add"
        panel.message = "Add to “\(level?.folder.isEmpty == false ? String(level!.folder.dropLast()) : rootURL.lastPathComponent)”"
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    private func change(removing: [String], adding: [ArchiveAddition], message: String) {
        guard let level else { return }
        let url = level.url
        let folder = level.folder
        busy = message
        fraction = 0
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try ArchiveEditor.update(url, removing: removing, adding: adding, progress: { progress in
                    Task { @MainActor in self?.fraction = progress.fraction }
                })
                await MainActor.run {
                    guard let self else { return }
                    self.busy = nil
                    self.selection.removeAll()
                    self.list(url, name: level.name, password: level.password, nested: false) { fresh in
                        var fresh = fresh
                        fresh.folder = fresh.tree.node(folder)?.isDirectory == true ? folder : ""
                        if !self.levels.isEmpty { self.levels[self.levels.count - 1] = fresh }
                    }
                    Toast.shared.show(removing.isEmpty ? "Added" : "Removed",
                                      detail: "The old copy of \(url.lastPathComponent) is in the Trash")
                }
            } catch {
                await MainActor.run {
                    self?.busy = nil
                    self?.notice = ArchiveModule.describe(error)
                }
            }
        }
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: workFolder)
    }
}

extension ArchiveNode {
    /// For sorting by date (undated entries last).
    var sortDate: Date { modified ?? .distantPast }

    var kindText: String {
        if isDirectory { return "Folder" }
        if isSymlink { return "Alias" }
        let text = UTType(filenameExtension: fileExtension)?.localizedDescription ?? "Document"
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

/// Quick Look's panel, on files taken out of an archive.
@MainActor
final class ArchivePreview: NSObject, QLPreviewPanelDataSource {
    static let shared = ArchivePreview()
    private var items: [URL] = []

    func show(_ urls: [URL]) {
        items = urls
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { items.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { items.indices.contains(index) ? items[index] as NSURL : nil }
    }
}

// MARK: - Views

struct ArchiveBrowserView: View {
    @Bindable var model: ArchiveBrowserModel
    var close: () -> Void
    @State private var confirmRemove = false
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            ZStack {
                content
                if dropTargeted && model.canEdit {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.themeAccent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.themeAccent.opacity(0.06)))
                        .overlay(Text("Drop to add to “\(folderName)”").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.themeAccent))
                        .padding(10)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in drop(providers) }
            Hairline()
            footer
        }
        .ignoresSafeArea(.container, edges: .top)   // the toolbar shares the title bar's row
        .frame(minWidth: 560, minHeight: 360)
        .background(Color(nsColor: .windowBackgroundColor))
        .background {
            // ⌘W closes the window (Tutto has no menu bar of its own).
            Button("Close", action: close).keyboardShortcut("w").hidden()
        }
        .confirmationDialog(removeTitle, isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { model.removeSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The archive is written again without them. The old copy goes to the Trash, so you can get it back.")
        }
    }

    private var folderName: String {
        guard let level = model.level else { return "" }
        return level.folder.isEmpty ? level.name : String(level.folder.dropLast().split(separator: "/").last ?? "")
    }

    private var removeTitle: String {
        let nodes = model.selectedNodes
        return nodes.count == 1 ? "Remove “\(nodes[0].name)” from the archive?" : "Remove \(nodes.count) items from the archive?"
    }

    // MARK: Header: the path, search, the actions

    private var header: some View {
        HStack(spacing: 10) {
            Button { model.goUp() } label: {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold)).frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .foregroundStyle(canGoUp ? Color.ink2 : Color.ink4)
            .disabled(!canGoUp)
            .help("Up a folder")
            breadcrumbs
                .layoutPriority(1)
            Spacer(minLength: 8)
            searchField
            Button { model.chooseFilesToAdd() } label: { Label("Add", systemImage: "plus") }
                .buttonStyle(OutlineButtonStyle(compact: true))
                .disabled(!model.canEdit)
                .help(model.level?.readOnly ?? "Add files to the folder in view (or drop them in)")
            Button { confirmRemove = true } label: { Label("Remove", systemImage: "trash") }
                .buttonStyle(OutlineButtonStyle(compact: true))
                .disabled(!model.canEdit || model.selection.isEmpty)
                .help(model.level?.readOnly ?? "Remove the selected items from the archive")
            Button { model.extractChosen(all: false) } label: {
                Label(model.selection.isEmpty ? "Extract All" : "Extract", systemImage: "arrow.down.doc")
            }
            .buttonStyle(InkButtonStyle(compact: true))
            .disabled(model.level == nil || model.busy != nil)
            .help(model.selection.isEmpty ? "Take everything out, into a folder you pick" : "Take out the selected items, into a folder you pick")
        }
        .labelStyle(.titleAndIcon)
        .padding(.leading, 78)   // past the window's buttons
        .padding(.trailing, 12)
        .frame(height: 52)
    }

    private var canGoUp: Bool {
        guard let level = model.level else { return false }
        return !level.folder.isEmpty || model.levels.count > 1
    }

    private var breadcrumbs: some View {
        HStack(spacing: 3) {
            ForEach(Array(model.levels.enumerated()), id: \.offset) { index, level in
                if index > 0 { chevron }
                crumb(level.name, symbol: "archivebox", current: index == model.levels.count - 1 && level.folder.isEmpty) {
                    model.go(toLevel: index, folder: "")
                }
                ForEach(ArchiveTree.trail(to: level.folder), id: \.self) { folder in
                    chevron
                    crumb(String(folder.split(separator: "/").last ?? ""), symbol: nil,
                          current: index == model.levels.count - 1 && folder + "/" == level.folder) {
                        model.go(toLevel: index, folder: folder + "/")
                    }
                }
            }
        }
        .lineLimit(1)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.ink4)
    }

    private func crumb(_ title: String, symbol: String?, current: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11)) }
                Text(title).font(.system(size: 12.5, weight: current ? .semibold : .medium))
            }
            .foregroundStyle(current ? Color.ink : Color.ink2)
            .padding(.horizontal, 5)
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .truncationMode(.middle)
        .layoutPriority(current ? 2 : 1)
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Color.ink3)
            TextField("Search", text: $model.search)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !model.search.isEmpty {
                Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Color.ink3) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(minWidth: 110, idealWidth: 170, maxWidth: 170)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.ink.opacity(0.06)))
    }

    // MARK: The contents

    @ViewBuilder
    private var content: some View {
        if model.loading && model.level == nil {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Reading \(model.rootURL.lastPathComponent)…").font(.system(size: 12)).foregroundStyle(Color.ink3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.level == nil {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 24)).foregroundStyle(Color.ink3)
                Text(model.notice ?? "It couldn't be opened.").font(.system(size: 12.5)).foregroundStyle(Color.ink2)
                    .multilineTextAlignment(.center).frame(maxWidth: 380)
                Button("Try Again") { model.load() }.buttonStyle(OutlineButtonStyle(compact: true))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            table
        }
    }

    private var table: some View {
        Table(of: ArchiveNode.self, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { node in
                NameCell(node: node, showsFolder: !model.search.isEmpty)
            }
            .width(min: 200, ideal: 360)
            TableColumn("Size", value: \.size) { node in
                Text(sizeText(node)).monospacedDigit().foregroundStyle(Color.ink2)
            }
            .width(min: 64, ideal: 90, max: 130)
            TableColumn("Modified", value: \.sortDate) { node in
                Text(node.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—").foregroundStyle(Color.ink2)
            }
            .width(min: 100, ideal: 160, max: 200)
            TableColumn("Kind") { node in
                Text(node.kindText).foregroundStyle(Color.ink3)
            }
            .width(min: 70, ideal: 120, max: 200)
        } rows: {
            ForEach(model.rows) { node in
                TableRow(node).itemProvider { model.provider(for: node) }
            }
        }
        .alternatingRowBackgrounds(.disabled)
        .contextMenu(forSelectionType: String.self) { ids in
            if !ids.isEmpty {
                Button("Open") { openFirst(of: ids) }
                Button("Quick Look") { model.quickLook() }.disabled(model.selectedNodes.allSatisfy(\.isDirectory))
                Button("Extract…") { model.extractChosen(all: false) }
                Divider()
                Button("Remove…") { confirmRemove = true }.disabled(!model.canEdit)
            }
        } primaryAction: { ids in
            openFirst(of: ids)
        }
        .onKeyPress(.space) {
            model.quickLook()
            return .handled
        }
        .onKeyPress(.return) {
            openFirst(of: model.selection)
            return .handled
        }
        .onDeleteCommand {
            if model.canEdit && !model.selection.isEmpty { confirmRemove = true }
        }
        .overlay {
            if model.rows.isEmpty {
                Text(model.search.isEmpty ? "This folder is empty" : "Nothing called “\(model.search)”")
                    .font(.system(size: 12.5)).foregroundStyle(Color.ink3)
            }
        }
    }

    private func openFirst(of ids: Set<String>) {
        guard let level = model.level else { return }
        let nodes = ids.compactMap { level.tree.node($0) }
        if nodes.count == 1 { model.open(nodes[0]) } else if let folder = nodes.first(where: \.isDirectory) { model.open(folder) }
    }

    private func sizeText(_ node: ArchiveNode) -> String {
        if node.isDirectory {
            return node.fileCount == 0 ? "—" : ByteCountFormatter.string(fromByteCount: node.size, countStyle: .file)
        }
        return ByteCountFormatter.string(fromByteCount: node.size, countStyle: .file)
    }

    // MARK: Footer: what's here, the format, what's happening

    private var footer: some View {
        HStack(spacing: 10) {
            if let level = model.level {
                let nodes = model.selection.isEmpty ? model.rows : model.selectedNodes
                let size = nodes.reduce(Int64(0)) { $0 + $1.size }
                Text(model.selection.isEmpty
                     ? "\(nodes.count) item\(nodes.count == 1 ? "" : "s") · \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))"
                     : "\(nodes.count) selected · \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
                    .monospacedDigit()
                    .foregroundStyle(Color.ink2)
                let total = level.tree.root.fileCount
                Text("\(total) file\(total == 1 ? "" : "s") in all").foregroundStyle(Color.ink3)
            }
            Spacer(minLength: 8)
            if let busy = model.busy {
                ProgressView(value: model.fraction).controlSize(.small).frame(width: 90)
                Text(busy).foregroundStyle(Color.ink2).lineLimit(1)
            } else if let notice = model.notice, model.level != nil {
                Label(notice, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.alert).lineLimit(1)
                    .onTapGesture { model.notice = nil }
            } else if let level = model.level {
                if let readOnly = level.readOnly {
                    Label("Read only", systemImage: "lock").foregroundStyle(Color.ink3).help(readOnly)
                }
                Text(level.format).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.ink3)
                    .padding(.horizontal, 6).frame(height: 18)
                    .background(Capsule().fill(Color.ink.opacity(0.07)))
            }
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 14)
        .frame(height: 30)
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        guard model.canEdit else { return false }
        let group = DispatchGroup()
        let collected = URLCollector()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { collected.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated { model.add(collected.urls) }
        }
        return true
    }
}

private final class URLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [URL] = []
    var urls: [URL] { lock.withLock { list } }
    func append(_ url: URL) { lock.withLock { list.append(url) } }
}

private struct NameCell: View {
    var node: ArchiveNode
    /// While searching: where it is, under the name.
    var showsFolder: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(node.name).lineLimit(1).truncationMode(.middle)
                if showsFolder, !node.parent.isEmpty {
                    Text(String(node.parent.dropLast())).font(.system(size: 10.5)).foregroundStyle(Color.ink3).lineLimit(1)
                }
            }
            if node.isEncrypted {
                Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(Color.ink3).help("Encrypted: needs the password")
            }
        }
    }

    private var icon: NSImage {
        if node.isDirectory { return NSWorkspace.shared.icon(for: .folder) }
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: node.fileExtension) ?? .data)
    }
}
