//
//  ClipboardModule.swift
//  Tutto
//
//  Clipboard history. macOS has no "clipboard changed" notification, so Tutto reads the
//  pasteboard's change counter (a local read, under a microsecond). The cost is the
//  timer itself, so it adapts: about once a second while you're using the Mac (with
//  generous timer leeway so macOS can fold it into wake-ups that happen anyway),
//  every few seconds when you're away, and not at all while the screen is locked.
//

import AppKit
import Carbon.HIToolbox
import Observation
import TuttoKit

@MainActor
@Observable
final class ClipboardModule: ModuleController {
    var isPaused: Bool {
        didSet {
            defaults.set(isPaused, forKey: Keys.paused)
            if !isPaused { lastChangeCount = NSPasteboard.general.changeCount }
        }
    }
    var maxItems: Int {
        didSet {
            defaults.set(maxItems, forKey: Keys.maxItems)
            store?.maxItems = maxItems
            refreshCount()
        }
    }
    /// Apps whose copies are never recorded (password managers and the like).
    var ignoredApps: [String] { didSet { defaults.set(ignoredApps, forKey: Keys.ignored) } }
    /// Off (default): pasting from history leaves your clipboard as it was.
    var keepPastedOnClipboard: Bool { didSet { defaults.set(keepPastedOnClipboard, forKey: Keys.keepPasted) } }

    private(set) var itemCount = 0
    private(set) var store: ClipboardStore?
    /// Bumps whenever the history changes, so open views refresh.
    private(set) var revision = 0

    private weak var model: AppModel?
    private let defaults = UserDefaults.standard
    private var timer: DispatchSourceTimer?
    private var interval: TimeInterval = 0
    private var ticks = 0
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var ownChangeCount: Int?
    private var screenLocked = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private let encoder = DispatchQueue(label: "ca.bryanyao.Tutto.clipboard-encode", qos: .utility)
    private var palette: ClipboardPaletteController?

    static let defaultIgnored = ["com.apple.keychainaccess", "com.apple.Passwords", "com.1password.1password",
                                 "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.lastpass.LastPass",
                                 "com.dashlane.dashlanephonefinal"]

    init(model: AppModel) {
        self.model = model
        defaults.register(defaults: [Keys.maxItems: 500])
        isPaused = defaults.bool(forKey: Keys.paused)
        maxItems = defaults.integer(forKey: Keys.maxItems)
        ignoredApps = defaults.stringArray(forKey: Keys.ignored) ?? Self.defaultIgnored
        keepPastedOnClipboard = defaults.bool(forKey: Keys.keepPasted)
    }

    // MARK: ModuleController

    func start() {
        if store == nil {
            store = ClipboardStore(directory: ClipboardStore.defaultDirectory, maxItems: maxItems)
            refreshCount()
        }
        lastChangeCount = NSPasteboard.general.changeCount
        observeScreenLock()
        reschedule(active: true)
    }

    func stop() {
        timer?.cancel()
        timer = nil
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        palette?.close()
        palette = nil
        store?.flush()
        store = nil
        itemCount = 0
    }

    // MARK: Polling

    private func reschedule(active: Bool) {
        let wanted: TimeInterval = screenLocked ? 0 : (active ? 1.0 : 4.0)
        guard wanted != interval || timer == nil || wanted == 0 else { return }
        timer?.cancel()
        timer = nil
        interval = wanted
        guard wanted > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // Large leeway lets macOS coalesce this with other work instead of waking up for it.
        timer.schedule(deadline: .now() + wanted, repeating: wanted, leeway: .milliseconds(Int(wanted * 500)))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        checkNow()
        ticks += 1
        // Every few ticks, see whether you're still at the Mac.
        if ticks % 5 == 0 {
            let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
            reschedule(active: idle < 60)
        }
    }

    private func observeScreenLock() {
        guard observers.isEmpty else { return }
        let distributed = DistributedNotificationCenter.default()
        observers.append((distributed, distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screenLocked = true
                self?.reschedule(active: false)
            }
        }))
        observers.append((distributed, distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screenLocked = false
                self?.reschedule(active: true)
            }
        }))
        let workspace = NSWorkspace.shared.notificationCenter
        for (name, locked) in [(NSWorkspace.willSleepNotification, true), (NSWorkspace.didWakeNotification, false)] {
            observers.append((workspace, workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.screenLocked = locked
                    self?.reschedule(active: !locked)
                }
            }))
        }
    }

    // MARK: Capture

    /// Reads the pasteboard if it changed since last time.
    func checkNow() {
        let pasteboard = NSPasteboard.general
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        if count == ownChangeCount { return }
        // A picture copied alone is made smaller first (Convert › Compress by itself); the history
        // records it when that's done.
        if let converter = model?.converter, converter.clipboardChanged() { return }
        guard !isPaused, store != nil else { return }
        capture(pasteboard)
    }

    /// Records what's on the clipboard now, even if it was seen already (after the converter made
    /// a copied picture smaller, or left it as it was).
    func recapture() {
        let pasteboard = NSPasteboard.general
        lastChangeCount = pasteboard.changeCount
        guard !isPaused, store != nil else { return }
        capture(pasteboard)
    }

    static let skipTypes: Set<String> = [
        "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType",
        "com.agilebits.onepassword", "de.petermaurer.TransientPasteboardType", "com.typeit4me.clipping",
        "Pasteboard generator type", "com.apple.is-remote-clipboard"
    ]

    private func capture(_ pasteboard: NSPasteboard) {
        let types = (pasteboard.types ?? []).map(\.rawValue)
        if types.contains(where: Self.skipTypes.contains) { return }
        let source = NSWorkspace.shared.frontmostApplication
        if let id = source?.bundleIdentifier, ignoredApps.contains(id) { return }
        let sourceID = source?.bundleIdentifier
        let sourceName = source?.localizedName

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            add(ClipPayload(kind: .file, text: urls.map(\.lastPathComponent).joined(separator: "\n"),
                            filePaths: urls.map(\.path), sourceBundleID: sourceID, sourceName: sourceName))
            return
        }
        let string = pasteboard.string(forType: .string)
        if let string, !string.isEmpty {
            let rich = pasteboard.data(forType: .rtf)
            let kind: ClipItem.Kind = ClipboardStore.isLink(string) ? .link : .text
            add(ClipPayload(kind: kind, text: string, richText: kind == .text ? rich : nil,
                            sourceBundleID: sourceID, sourceName: sourceName))
            return
        }
        let png = pasteboard.data(forType: .png)
        let tiff = png == nil ? pasteboard.data(forType: .tiff) : nil
        guard png != nil || tiff != nil else { return }
        // Converting a big TIFF to PNG takes a moment; never on the main thread.
        encoder.async { [weak self] in
            guard let rep = NSBitmapImageRep(data: png ?? tiff!) else { return }
            let data = png ?? rep.representation(using: .png, properties: [:])
            guard let data else { return }
            let payload = ClipPayload(kind: .image, image: data, imageWidth: rep.pixelsWide, imageHeight: rep.pixelsHigh,
                                      sourceBundleID: sourceID, sourceName: sourceName)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.add(payload) }
            }
        }
    }

    private func add(_ payload: ClipPayload) {
        guard let store else { return }
        store.add(payload)
        refreshCount()
    }

    private func refreshCount() {
        itemCount = store?.items.count ?? 0
        revision &+= 1
    }

    // MARK: Using items

    func showPalette() {
        checkNow()  // anything copied a moment ago is already in the list
        if palette == nil { palette = ClipboardPaletteController(module: self) }
        palette?.show(target: NSWorkspace.shared.frontmostApplication)
    }

    func paletteDidClose() {
        palette = nil  // release thumbnails and views
    }

    /// Puts an item back on the clipboard. Returns false if its files or image are gone.
    @discardableResult
    func copy(_ item: ClipItem, plainText: Bool = false) -> Bool {
        guard let store else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        var ok = true
        switch item.kind {
        case .text, .link:
            if !plainText, let url = store.richTextURL(for: item), let rich = try? Data(contentsOf: url) {
                pasteboard.declareTypes([.rtf, .string], owner: nil)
                pasteboard.setData(rich, forType: .rtf)
            }
            pasteboard.setString(item.text ?? "", forType: .string)
            if item.kind == .link, let url = URL(string: item.text ?? "") {
                pasteboard.setString(url.absoluteString, forType: .URL)
            }
        case .image:
            if let url = store.imageURL(for: item), let data = try? Data(contentsOf: url) {
                PasteboardImage.write(png: data, to: pasteboard)
            } else {
                ok = false
            }
        case .file:
            let urls = (item.filePaths ?? []).map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
            ok = !urls.isEmpty
            if ok { pasteboard.writeObjects(urls as [NSURL]) }
        }
        ownChangeCount = pasteboard.changeCount
        lastChangeCount = pasteboard.changeCount
        store.touch(item.id)
        refreshCount()
        return ok
    }

    /// Pastes the item into the app you were in. Unless "keep pasted items" is on, your clipboard
    /// goes back to what it held before once the app has taken the paste.
    func paste(_ item: ClipItem, into target: NSRunningApplication?, plainText: Bool = false) {
        guard AXIsProcessTrusted() else {
            // Can't press ⌘V for you, so leave it on the clipboard to paste by hand.
            if copy(item, plainText: plainText) {
                Toast.shared.show("Copied", detail: "Press ⌘V to paste · allow Accessibility to paste directly")
            } else {
                Toast.shared.show("Not available", detail: "The original file or image is gone")
            }
            return
        }
        let saved = keepPastedOnClipboard ? nil : PasteboardSnapshot(NSPasteboard.general)
        guard copy(item, plainText: plainText) else {
            saved?.restore(to: NSPasteboard.general)
            markOwnChange()
            Toast.shared.show("Not available", detail: "The original file or image is gone")
            return
        }
        let pasted = NSPasteboard.general.changeCount
        target?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            Self.postCommandV()
        }
        guard let saved else { return }
        // Apps read the clipboard when they handle ⌘V; give slow ones (Electron, remote sessions)
        // time before putting the old contents back. Skip it if you've copied something since.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            MainActor.assumeIsolated {
                guard NSPasteboard.general.changeCount == pasted else { return }
                saved.restore(to: NSPasteboard.general)
                self?.markOwnChange()
            }
        }
    }

    /// Pastes what's on the clipboard as plain text (no fonts, colors, links or pictures) into
    /// the app in front, then puts the clipboard back as it was, formatting and all.
    func pastePlainText() {
        let pasteboard = NSPasteboard.general
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
            Toast.shared.show("No text to paste", detail: "The clipboard holds no text")
            return
        }
        guard AXIsProcessTrusted() else {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            markOwnChange()
            Toast.shared.show("Copied as plain text", detail: "Press ⌘V to paste · allow Accessibility to paste directly")
            return
        }
        let saved = PasteboardSnapshot(pasteboard)
        let alreadyPlain = (pasteboard.types ?? []).allSatisfy { $0 == .string || $0.rawValue.hasPrefix("dyn.") || $0.rawValue == "public.utf8-plain-text" }
        if !alreadyPlain {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            markOwnChange()
        }
        let pasted = pasteboard.changeCount
        // The shortcut's own keys are still down: wait until they're let go (up to half a
        // second), or the app sees ⌥⇧⌘V instead of ⌘V.
        Self.whenModifiersReleased(within: 0.5) {
            Self.postCommandV()
            guard !alreadyPlain else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                MainActor.assumeIsolated {
                    guard NSPasteboard.general.changeCount == pasted else { return }
                    saved.restore(to: NSPasteboard.general)
                    self?.markOwnChange()
                }
            }
        }
    }

    private static func whenModifiersReleased(within limit: TimeInterval, started: Date = Date(), _ then: @escaping @MainActor () -> Void) {
        let held = CGEventSource.flagsState(.combinedSessionState).intersection([.maskCommand, .maskAlternate, .maskShift, .maskControl])
        if held.isEmpty || Date().timeIntervalSince(started) >= limit {
            then()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            MainActor.assumeIsolated { whenModifiersReleased(within: limit, started: started, then) }
        }
    }

    /// Our own pasteboard write: not a new copy to record.
    private func markOwnChange() {
        ownChangeCount = NSPasteboard.general.changeCount
        lastChangeCount = NSPasteboard.general.changeCount
    }

    func setPinned(_ item: ClipItem, _ pinned: Bool) {
        store?.setPinned(item.id, pinned)
        refreshCount()
    }

    func remove(_ item: ClipItem) {
        store?.remove(item.id)
        refreshCount()
    }

    func clearHistory(keepPinned: Bool = true) {
        if keepPinned { store?.clearUnpinned() } else { store?.clearAll() }
        refreshCount()
    }

    nonisolated static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }

    private enum Keys {
        static let paused = "clipboard.paused"
        static let maxItems = "clipboard.maxItems"
        static let ignored = "clipboard.ignoredApps"
        static let keepPasted = "clipboard.keepPasted"
    }
}

/// Everything on a pasteboard (every item, every type), to put back after a paste.
struct PasteboardSnapshot {
    private let items: [[(NSPasteboard.PasteboardType, Data)]]

    init(_ pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored = items.map { entries -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}
