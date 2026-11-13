//
//  ArchiveModule.swift
//  Tutto
//
//  Archives: open RAR, 7z, zip, tar, ISO, CAB and friends from Finder's
//  right-click menu or by double-clicking, with filenames in any language decoded
//  correctly. Extraction runs off the main thread; a small progress panel appears only
//  if a job takes longer than 400 ms. Nothing runs between jobs.
//

import AppKit
import Observation
import TuttoKit

/// What double-clicking an archive (with Tutto as its app) does.
enum ArchiveOpenAction: String, CaseIterable {
    /// A window on what's inside, nothing unpacked.
    case browse
    /// Extract it straight away, as before.
    case extract
}

enum ArchiveDestination: String, CaseIterable {
    case sameFolder, ask, fixed

    var title: String {
        switch self {
        case .sameFolder: "Same folder"
        case .ask: "Ask each time"
        case .fixed: "Chosen folder"
        }
    }
}

@MainActor
@Observable
final class ArchiveJob: Identifiable {
    enum Kind { case extract, compress }
    enum State: Equatable { case running, done(String), failed(String), cancelled }

    let id = UUID()
    let kind: Kind
    let name: String
    var fraction: Double = 0
    var detail = ""
    var state: State = .running
    let cancelFlag = CancelFlag()

    init(kind: Kind, name: String) {
        self.kind = kind
        self.name = name
    }
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.withLock { value } }
    func cancel() { lock.withLock { value = true } }
}

@MainActor
@Observable
final class ArchiveModule: ModuleController {
    var destination: ArchiveDestination { didSet { defaults.set(destination.rawValue, forKey: Keys.destination) } }
    var fixedFolderPath: String { didSet { defaults.set(fixedFolderPath, forKey: Keys.fixedFolder) } }
    var folderRule: ArchiveFolderRule { didSet { defaults.set(folderRule.rawValue, forKey: Keys.folderRule) } }
    var trashAfterExtracting: Bool { didSet { defaults.set(trashAfterExtracting, forKey: Keys.trash) } }
    var revealAfterExtracting: Bool { didSet { defaults.set(revealAfterExtracting, forKey: Keys.reveal) } }
    var openAction: ArchiveOpenAction { didSet { defaults.set(openAction.rawValue, forKey: Keys.openAction) } }
    /// nil = detect automatically.
    var encodingOverride: UInt? { didSet { defaults.set(encodingOverride.map { Int($0) } ?? 0, forKey: Keys.encoding) } }

    private(set) var jobs: [ArchiveJob] = []
    private weak var model: AppModel?
    private let defaults = UserDefaults.standard
    private var progress: ArchiveProgressController?

    init(model: AppModel) {
        self.model = model
        destination = ArchiveDestination(rawValue: defaults.string(forKey: Keys.destination) ?? "") ?? .sameFolder
        fixedFolderPath = defaults.string(forKey: Keys.fixedFolder)
            ?? (FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory())
        folderRule = ArchiveFolderRule(rawValue: defaults.string(forKey: Keys.folderRule) ?? "") ?? .smart
        trashAfterExtracting = defaults.bool(forKey: Keys.trash)
        revealAfterExtracting = defaults.bool(forKey: Keys.reveal)
        openAction = ArchiveOpenAction(rawValue: defaults.string(forKey: Keys.openAction) ?? "") ?? .browse
        let encoding = defaults.integer(forKey: Keys.encoding)
        encodingOverride = encoding == 0 ? nil : UInt(encoding)
    }

    // MARK: ModuleController

    /// Registers the Finder extension once per build of Tutto (two `pluginkit` runs), not at every
    /// launch: macOS keeps the registration until the app changes.
    func start() {
        ArchiveBrowserWindows.clearOldFiles()
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        guard defaults.string(forKey: Keys.registeredBuild) != build else { return }
        model?.permissions.setFinderExtension(enabled: true)
        defaults.set(build, forKey: Keys.registeredBuild)
    }

    func stop() {
        jobs.filter { $0.state == .running }.forEach { $0.cancelFlag.cancel() }
        progress?.close()
        progress = nil
        model?.permissions.setFinderExtension(enabled: false)
        defaults.removeObject(forKey: Keys.registeredBuild)
    }

    // MARK: Requests

    enum ExtractMode { case here, ownFolder, choose, preferred }

    /// Extracts each archive (split archives once, from their first part).
    func extract(_ urls: [URL], mode: ExtractMode) {
        var seen = Set<String>()
        let archives = urls.map { ArchiveVolumes.firstVolume(for: $0) }.filter { seen.insert($0.path).inserted }
        guard !archives.isEmpty else { return }

        var resolvedMode = mode
        var chosenFolder: URL?
        if mode == .preferred {
            switch destination {
            case .sameFolder: resolvedMode = .here
            case .fixed: chosenFolder = URL(fileURLWithPath: fixedFolderPath, isDirectory: true); resolvedMode = .here
            case .ask: resolvedMode = .choose
            }
        }
        if resolvedMode == .choose {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = "Extract Here"
            panel.message = archives.count == 1 ? "Where should “\(archives[0].lastPathComponent)” go?" : "Where should these \(archives.count) archives go?"
            panel.directoryURL = archives[0].deletingLastPathComponent()
            AppActivation.bringForward()
            guard panel.runModal() == .OK, let url = panel.url else { return }
            chosenFolder = url
        }
        for archive in archives {
            var options = ArchiveExtractionOptions()
            options.folderRule = resolvedMode == .ownFolder ? .always : folderRule
            options.encodingOverride = encodingOverride.map { String.Encoding(rawValue: $0) }
            let destination = chosenFolder ?? archive.deletingLastPathComponent()
            run(extract: archive, to: destination, options: options)
        }
    }

    func compress(_ urls: [URL], format: ArchiveCompressionFormat = .zip) {
        guard let first = urls.first else { return }
        let folder = first.deletingLastPathComponent()
        let base = urls.count == 1 ? first.deletingPathExtension().lastPathComponent : "Archive"
        let ext = switch format {
        case .zip: "zip"
        case .sevenZip: "7z"
        case .tarGzip: "tar.gz"
        case .tarXz: "tar.xz"
        }
        let output = ArchiveNaming.uniqueURL(for: folder.appendingPathComponent("\(base).\(ext)"))
        let job = ArchiveJob(kind: .compress, name: output.lastPathComponent)
        start(job)
        let flag = job.cancelFlag
        Task.detached(priority: .userInitiated) { [self] in
            do {
                let written = try ArchiveCompressor.compress(urls, to: output, format: format, progress: { progress in
                    Task { @MainActor in
                        job.fraction = progress.fraction
                        job.detail = progress.currentItem
                    }
                }, isCancelled: { flag.isCancelled })
                await MainActor.run {
                    job.state = .done("Created \(written.lastPathComponent)")
                    self.finished(job, revealing: [written])
                }
            } catch {
                await MainActor.run {
                    job.state = flag.isCancelled ? .cancelled : .failed(Self.describe(error))
                    self.finished(job, revealing: [])
                }
            }
        }
    }

    // MARK: Jobs

    private func run(extract archive: URL, to destination: URL, options: ArchiveExtractionOptions) {
        let job = ArchiveJob(kind: .extract, name: archive.lastPathComponent)
        start(job)
        let flag = job.cancelFlag
        let trash = trashAfterExtracting
        Task.detached(priority: .userInitiated) { [self] in
            let extractor = ArchiveExtractor(url: archive)
            do {
                let result = try extractor.extract(to: destination, options: options, progress: { progress in
                    Task { @MainActor in
                        job.fraction = progress.fraction
                        job.detail = progress.currentItem
                    }
                }, isCancelled: { flag.isCancelled })
                if trash {
                    for volume in ArchiveVolumes.volumes(for: archive) {
                        try? FileManager.default.trashItem(at: volume, resultingItemURL: nil)
                    }
                }
                await MainActor.run {
                    let count = result.entryCount
                    job.fraction = 1
                    job.state = .done("\(count) item\(count == 1 ? "" : "s") extracted")
                    self.finished(job, revealing: result.containingFolder.map { [$0] } ?? result.items)
                }
            } catch ArchiveError.passwordRequired {
                await MainActor.run { self.askPassword(for: archive, job: job, destination: destination, options: options, wrong: false) }
            } catch ArchiveError.wrongPassword {
                await MainActor.run { self.askPassword(for: archive, job: job, destination: destination, options: options, wrong: true) }
            } catch {
                await MainActor.run {
                    job.state = flag.isCancelled ? .cancelled : .failed(Self.describe(error))
                    self.finished(job, revealing: [])
                }
            }
        }
    }

    private func start(_ job: ArchiveJob) {
        jobs.append(job)
        // The panel appears only if the job is still going after 400 ms.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, job.state == .running else { return }
                if self.progress == nil { self.progress = ArchiveProgressController(module: self) }
                self.progress?.show()
            }
        }
    }

    private func finished(_ job: ArchiveJob, revealing urls: [URL]) {
        switch job.state {
        case .done(let message):
            if progress == nil {
                Toast.shared.show(job.kind == .extract ? "Extracted" : "Compressed", detail: message) {
                    NSWorkspace.shared.activateFileViewerSelecting(urls)
                }
            }
            if revealAfterExtracting, job.kind == .extract, !urls.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            }
        case .failed(let message):
            if progress == nil {
                Toast.shared.show("Couldn't open \(job.name)", detail: message, duration: 4)
            }
        default:
            break
        }
        // Finished jobs linger in the panel for a moment, then leave.
        DispatchQueue.main.asyncAfter(deadline: .now() + (job.state == .cancelled ? 0.5 : 2.5)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.jobs.removeAll { $0.id == job.id }
                if self.jobs.isEmpty {
                    self.progress?.close()
                    self.progress = nil
                }
            }
        }
    }

    private func askPassword(for archive: URL, job: ArchiveJob, destination: URL, options: ArchiveExtractionOptions, wrong: Bool) {
        job.state = .cancelled  // this attempt is over; a new job starts if a password is given
        jobs.removeAll { $0.id == job.id }
        if jobs.isEmpty { progress?.close(); progress = nil }
        PasswordPrompt.ask(archiveName: archive.lastPathComponent, wrong: wrong) { [weak self] password in
            guard let self, let password else { return }
            var options = options
            options.password = password
            self.run(extract: archive, to: destination, options: options)
        }
    }

    nonisolated static func describe(_ error: Error) -> String {
        guard let error = error as? ArchiveError else { return error.localizedDescription }
        switch error {
        case .notAnArchive: return "This doesn't look like an archive Tutto can open."
        case .cannotOpen(let detail): return "It couldn't be opened (\(detail))."
        case .passwordRequired: return "It needs a password."
        case .wrongPassword: return "The password didn't work."
        case .unsupportedEncryption(let format): return "Encrypted \(format) archives can't be opened with the libarchive built into macOS."
        case .corrupt(let detail): return "It looks damaged or incomplete (\(detail))."
        case .cancelled: return "Cancelled."
        case .writeFailed(let detail): return "Writing the files failed (\(detail))."
        case .unsupportedFormat(let format): return "\(format) isn't supported."
        }
    }

    private enum Keys {
        static let registeredBuild = "archives.finderRegisteredBuild"
        static let destination = "archives.destination"
        static let fixedFolder = "archives.fixedFolder"
        static let folderRule = "archives.folderRule"
        static let trash = "archives.trashAfter"
        static let reveal = "archives.revealAfter"
        static let encoding = "archives.encoding"
        static let openAction = "archives.openAction"
    }
}

/// `tutto://archive?action=…&path=…` from the Finder extension, and files opened with Tutto.
@MainActor
enum ArchiveRequests {
    static func handle(_ url: URL, model: AppModel) {
        guard url.host == "archive", let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let items = components.queryItems ?? []
        let action = items.first { $0.name == "action" }?.value ?? ""
        let paths = items.filter { $0.name == "path" }.compactMap(\.value).map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !paths.isEmpty else { return }
        guard let archives = model.archives else {
            Toast.shared.show("Archives is off", detail: "Turn it on in Tutto › General", duration: 3) {
                MainWindowController.shared.show(page: .archives)
            }
            return
        }
        switch action {
        case "extract-here": archives.extract(paths, mode: .here)
        case "extract-folder": archives.extract(paths, mode: .ownFolder)
        case "extract-choose": archives.extract(paths, mode: .choose)
        case "compress": archives.compress(paths)
        case "browse": paths.forEach { ArchiveBrowserWindows.shared.open($0) }
        default: break
        }
    }

    static func open(_ urls: [URL], model: AppModel) {
        let archives = urls.filter { ArchiveFormats.isLikelyArchive($0) }
        guard !archives.isEmpty else { return }
        guard let module = model.archives else {
            Toast.shared.show("Archives is off", detail: "Turn it on in Tutto › General", duration: 3)
            return
        }
        switch module.openAction {
        case .browse: archives.forEach { ArchiveBrowserWindows.shared.open($0) }
        case .extract: module.extract(archives, mode: .preferred)
        }
    }
}
