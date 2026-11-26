//
//  AgentsModule.swift
//  Tutto
//
//  The coding agents on this Mac (Bryan, 2026-11-17): which Claude Code and Codex sessions are
//  working, which need you (one click opens that exact session), what each costs the Mac, what
//  they left running, and how close each is to its usage limit.
//
//  Nothing here polls while you're not looking: macOS reports writes to the agents' own files
//  (an FSEvents stream), each session's process reports its exit (kqueue), and process readings
//  run only while the card or page is on screen, plus one look a minute for runaway process trees
//  while an agent works. Claude's transcripts are read once and then only what's added
//  (ClaudeUsageStore).
//

import AppKit
import ApplicationServices
import os
import TuttoKit

@MainActor
@Observable
final class AgentsModule: ModuleController {
    /// Every session worth showing, what needs you first.
    private(set) var sessions: [AgentSession] = []
    /// Claude's limits: Claude's own numbers when it answered lately, else the estimate.
    private(set) var claudeLimits: AgentLimits?
    /// Whether Claude's own numbers are showing, and if not, why.
    private(set) var claudePlanStatus: ClaudePlanUsageReader.Status = .unknown
    @ObservationIgnored private var claudeEstimate: AgentLimits?
    @ObservationIgnored private var claudePlan: ClaudePlanUsage?
    @ObservationIgnored private var claudePlanSamples: [ClaudePlanUsage] = []
    @ObservationIgnored private let planReader = ClaudePlanUsageReader()
    @ObservationIgnored private var planTimer: DispatchSourceTimer?
    /// Renew Claude Code's sign-in when it has run out, so Claude's own numbers keep coming.
    var renewsClaudeSignIn: Bool {
        didSet {
            UserDefaults.standard.set(renewsClaudeSignIn, forKey: "agents.renewClaudeSignIn")
            planReader.renews = renewsClaudeSignIn
            if renewsClaudeSignIn { planReader.read(force: true) }
        }
    }
    private(set) var codexLimits: AgentLimits?
    /// What each agent costs, by its process (Claude sessions), while it's on screen.
    private(set) var loads: [Int32: AgentLoad] = [:]
    /// The Codex app and its agents, as one.
    private(set) var codexLoad: AgentLoad?
    private(set) var leftRunning: [LeftRunning] = []
    /// Sessions whose process tree has grown past the runaway count.
    private(set) var runaway: Set<String> = []
    /// Processes asked to quit, until they do.
    private(set) var stopping: Set<Int32> = []
    /// A clock for "12 min" while something shows it.
    private(set) var now = Date()
    /// Chats with something you haven't read, as Claude's and Codex's apps count them, newest first
    /// (read while the card or page is on screen).
    private(set) var unread: [UnreadChat] = []

    // Settings
    var alertNeedsYou: Bool { didSet { defaults.set(alertNeedsYou, forKey: Keys.alertNeedsYou) } }
    var alertFinished: Bool { didSet { defaults.set(alertFinished, forKey: Keys.alertFinished) } }
    var menuBarSignal: Bool { didSet { defaults.set(menuBarSignal, forKey: Keys.menuBarSignal) } }
    var menuBarLimits: Bool { didSet { defaults.set(menuBarLimits, forKey: Keys.menuBarLimits) } }
    var warnRunaway: Bool { didSet { defaults.set(warnRunaway, forKey: Keys.warnRunaway) } }

    private enum Keys {
        static let alertNeedsYou = "agents.alertNeedsYou"
        static let alertFinished = "agents.alertFinished"
        static let menuBarSignal = "agents.menuBarSignal"
        static let menuBarLimits = "agents.menuBarLimits"
        static let warnRunaway = "agents.warnRunaway"
        static let readMarks = "agents.readMarks"
    }

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let log = Logger(subsystem: "ca.bryanyao.Tutto", category: "agents")
    @ObservationIgnored private let usage = ClaudeUsageStore()
    @ObservationIgnored private var stream: FSEventStreamRef?
    @ObservationIgnored private var claude: [AgentSession] = []
    /// When each Claude session's transcript was last written, by session id.
    @ObservationIgnored private var lastWrite: [String: Date] = [:]
    @ObservationIgnored private var codexFiles: [String: (offset: Int, state: CodexThreadState)] = [:]
    @ObservationIgnored private var codexNames: [String: String] = [:]
    @ObservationIgnored private var exits: [Int32: DispatchSourceProcess] = [:]
    @ObservationIgnored private var watchers = 0
    @ObservationIgnored private var sampler: DispatchSourceTimer?
    @ObservationIgnored private var minute: DispatchSourceTimer?
    @ObservationIgnored private var lastTable: [Int32: ProcessEntry]?
    @ObservationIgnored private var lastSample: UInt64 = 0
    @ObservationIgnored private var samples = 0
    @ObservationIgnored private var running = false
    @ObservationIgnored private var listed = false
    @ObservationIgnored private var queuedAlerts: [(kind: AlertKind, session: AgentSession)] = []
    @ObservationIgnored private var alertWork: DispatchWorkItem?
    @ObservationIgnored private var warnedRunaway: [String: Date] = [:]
    @ObservationIgnored private let unreadQueue = DispatchQueue(label: "ca.bryanyao.Tutto.agent-unread", qos: .utility)
    @ObservationIgnored private let tableCache = LevelDBReader.Cache()
    @ObservationIgnored private var allUnread: [UnreadChat] = []
    /// Chats opened from here, hidden until their app says they're read (or a couple of minutes pass).
    @ObservationIgnored private var opened: [String: Date] = [:]
    /// Chats marked read in Tutto, with their `state` then: a new reply, or "Mark as Unread" in the
    /// chat's app, changes it and brings the chat back. (Marks saved before that are numbers: the
    /// time of the turn that was unread.)
    @ObservationIgnored private var readMarks: [String: Any] = UserDefaults.standard.dictionary(forKey: Keys.readMarks) ?? [:]
    @ObservationIgnored private var unreadWork: DispatchWorkItem?
    @ObservationIgnored private var unreadStale = true
    @ObservationIgnored private let sampleQueue = DispatchQueue(label: "ca.bryanyao.Tutto.agent-processes", qos: .utility)

    private enum AlertKind { case needsYou, finished }

    static let claudeAppID = "com.anthropic.claudefordesktop"
    static let codexAppID = "com.openai.codex"

    init() {
        let d = UserDefaults.standard
        func flag(_ key: String) -> Bool { d.object(forKey: key) as? Bool ?? true }
        alertNeedsYou = flag(Keys.alertNeedsYou)
        alertFinished = flag(Keys.alertFinished)
        menuBarSignal = flag(Keys.menuBarSignal)
        // Off unless switched on: the menu bar shows just Tutto's icon (Bryan, 2026-11-21).
        menuBarLimits = d.object(forKey: Keys.menuBarLimits) as? Bool ?? false
        warnRunaway = flag(Keys.warnRunaway)
        renewsClaudeSignIn = d.bool(forKey: "agents.renewClaudeSignIn")
    }

    /// Claude Code or Codex has been used on this Mac (the card shows only then), checked when it starts.
    private(set) var installed = AgentsModule.agentsFound()

    static func agentsFound() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [".claude/projects", ".codex/sessions"].contains { FileManager.default.fileExists(atPath: home.appendingPathComponent($0).path) }
    }

    var needsYou: [AgentSession] { sessions.filter { $0.activity.needsYou } }
    var limits: [AgentLimits] { [claudeLimits, codexLimits].compactMap { $0 } }

    /// What the menu bar says about limits: only one that's reached, nearly full, or running out soon.
    var menuBarLimit: (tool: AgentTool, estimate: LimitEstimate)? {
        guard menuBarLimits else { return nil }
        let urgent = limits.compactMap { limits -> (AgentTool, LimitEstimate)? in
            guard let headline = limits.headline, headline.matters(now: Date()) else { return nil }
            return (limits.tool, headline)
        }
        return urgent.max { $0.1.percent < $1.1.percent }
    }

    // MARK: Lifecycle

    func start() {
        guard !running else { return }
        running = true
        installed = Self.agentsFound()
        usage.onEstimate = { [weak self] estimate in
            self?.claudeEstimate = estimate
            self?.showClaudeLimits()
        }
        planReader.renews = renewsClaudeSignIn
        planReader.onResult = { [weak self] usage, status in self?.planRead(usage, status) }
        planReader.read(force: true)
        watch()
        reloadClaude(initial: true)
        loadCodex()
        usage.refresh()
        updateMinute()
    }

    func stop() {
        running = false
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        exits.values.forEach { $0.cancel() }
        exits.removeAll()
        sampler?.cancel()
        sampler = nil
        minute?.cancel()
        minute = nil
        alertWork?.cancel()
        usage.save()
    }

    // MARK: Watching the agents' files

    private func watch() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = ([".claude/sessions", ".claude/projects", ".codex/sessions", ".codex"]
            .map { home.appendingPathComponent($0).path } + [Self.claudeStorage.path])
            .filter { FileManager.default.fileExists(atPath: $0) }
        guard !paths.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, { _, info, count, paths, _, _ in
            guard let info else { return }
            let module = Unmanaged<AgentsModule>.fromOpaque(info).takeUnretainedValue()
            let list = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            MainActor.assumeIsolated { module.changed(Array(list.prefix(count))) }
        }, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func changed(_ paths: [String]) {
        var unreadChanged = false
        var sessionsChanged = false, codexChanged: [String] = [], transcripts: [String] = []
        for path in paths {
            if path.contains("/.claude/sessions/") { sessionsChanged = true }
            else if path.contains("/.claude/projects/") {
                transcripts.append(path)
                if path.hasSuffix(".jsonl") { lastWrite[((path as NSString).lastPathComponent as NSString).deletingPathExtension] = Date() }
            }
            else if path.contains("/.codex/sessions/"), path.hasSuffix(".jsonl") { codexChanged.append(path) }
            else if path.hasSuffix("/.codex/session_index.jsonl") { codexNames = Self.readCodexNames() ; codexChanged.append("") }
            if path.contains("/.codex/state_5.sqlite") || path.hasPrefix(Self.claudeStorage.path) { unreadChanged = true }
        }
        if unreadChanged { scheduleUnread() }
        if sessionsChanged { reloadClaude(initial: false) }
        if !codexChanged.isEmpty { readCodex(codexChanged.filter { !$0.isEmpty }) }
        if !transcripts.isEmpty { usage.changed(transcripts) }
    }

    // MARK: Claude sessions

    private func reloadClaude(initial: Bool) {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var found: [AgentSession] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), let record = ClaudeSessionRecord.decode(data) else { continue }
            // A record outlives a session that crashed: only one whose process is still Claude's counts.
            guard let entry = ProcessReader.entry(record.pid), entry.name.lowercased().contains("claude") else { continue }
            found.append(record.session())
            watchExit(record.pid)
        }
        claude = found
        if initial { seedLastWrites() }
        rebuild(initial: initial)
    }

    /// Each session's transcript's last write, from the disk, once (FSEvents keeps it after that).
    private func seedLastWrites() {
        let projects = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
        let folders = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        for session in claude where lastWrite[session.sessionID] == nil {
            for folder in folders {
                let file = folder.appendingPathComponent(session.sessionID + ".jsonl")
                if let date = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date {
                    lastWrite[session.sessionID] = date
                    break
                }
            }
        }
    }

    /// How long a working Claude session's transcript has been quiet: long enough, and it may be stuck.
    func quiet(_ session: AgentSession) -> TimeInterval? {
        guard session.tool == .claude, session.activity == .working, let last = lastWrite[session.sessionID] else { return nil }
        let quiet = now.timeIntervalSince(last)
        return quiet >= 15 * 60 ? quiet : nil
    }

    /// The session list again when an agent's process quits (its record may stay behind).
    private func watchExit(_ pid: Int32) {
        guard exits[pid] == nil else { return }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.exits[pid]?.cancel()
                self?.exits[pid] = nil
                self?.stopping.remove(pid)
                self?.reloadClaude(initial: false)
            }
        }
        source.resume()
        exits[pid] = source
    }

    // MARK: Codex threads

    private static var codexFolder: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions", isDirectory: true) }

    private static func readCodexNames() -> [String: String] {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/session_index.jsonl")
        return (try? String(contentsOf: url, encoding: .utf8)).map(CodexIndex.names) ?? [:]
    }

    /// The threads written to in the last six hours.
    private func loadCodex() {
        codexNames = Self.readCodexNames()
        let cutoff = Date().addingTimeInterval(-6 * 3600)
        var recent: [String] = []
        var newest: (path: String, date: Date)?
        if let walker = FileManager.default.enumerator(at: Self.codexFolder, includingPropertiesForKeys: [.contentModificationDateKey],
                                                       options: [.skipsHiddenFiles]) {
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { continue }
                if modified >= cutoff { recent.append(url.path) }
                if modified > (newest?.date ?? .distantPast) { newest = (url.path, modified) }
            }
        }
        // The newest thread too, however old: its last reading holds the week's limit.
        if let newest, !recent.contains(newest.path) { recent.append(newest.path) }
        readCodex(recent)
    }

    private func readCodex(_ paths: [String]) {
        for path in paths {
            var entry = codexFiles[path] ?? (offset: 0, state: CodexThreadState())
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) else { continue }
            if data.count < entry.offset { entry = (0, CodexThreadState()) }
            guard data.count > entry.offset else { continue }
            let consumed = data.withUnsafeBytes { raw in entry.state.scan(UnsafeRawBufferPointer(rebasing: raw[entry.offset...])) }
            entry.offset += consumed
            codexFiles[path] = entry
        }
        // The limits: the latest reading from any thread, and the 5-hour pace from all of them.
        let states = codexFiles.values.map(\.state)
        let latest = states.compactMap(\.limits).max { $0.at < $1.at }
        let samples = states.flatMap(\.samples).sorted { $0.at < $1.at }
        codexLimits = CodexLimits.limits(latest: latest, samples: samples, now: Date())
        rebuild(initial: false)
    }

    /// Codex threads worth a line: working, or finished in the last half hour.
    private var codexSessions: [AgentSession] {
        let now = Date()
        return codexFiles.values.compactMap { entry -> AgentSession? in
            let state = entry.state
            guard let session = state.session(name: state.threadID.flatMap { codexNames[$0] }, now: now) else { return nil }
            if session.activity == .working { return session }
            return now.timeIntervalSince(session.since) < 1800 ? session : nil
        }
    }

    // MARK: The list

    private func rebuild(initial: Bool) {
        let previous = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let next = AgentSession.ordered(claude + codexSessions)
        if listed && !initial {
            for session in next {
                guard let before = previous[session.id] else {
                    if session.activity.needsYou { queueAlert(.needsYou, session) }
                    continue
                }
                if session.activity.needsYou, !before.activity.needsYou { queueAlert(.needsYou, session) }
                if before.activity == .working, session.activity == .yourTurn,
                   session.since.timeIntervalSince(before.since) >= 60 { queueAlert(.finished, session) }
            }
        }
        listed = true
        if next != sessions { sessions = next }
        filterUnread()
        let gone = Set(previous.keys).subtracting(next.map(\.id))
        if !gone.isEmpty { runaway.subtract(gone) }
        updateMinute()
    }

    /// One look a minute while something works or a limit is shown: the "12 min"s move on,
    /// a Codex turn that stopped writing ends, a limit window that reset reads empty, and a
    /// runaway process tree is caught.
    private func updateMinute() {
        let needed = running && (sessions.contains { $0.activity == .working } || !limits.isEmpty)
        if needed, minute == nil {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(15))
            timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.minutely() } }
            timer.resume()
            minute = timer
        } else if !needed, let timer = minute {
            timer.cancel()
            minute = nil
        }
    }

    private func minutely() {
        now = Date()
        if codexFiles.values.contains(where: { $0.state.activity(now: now) == .working }) || !codexSessions.isEmpty {
            readCodex([])
        }
        usage.recompute()
        if watchers == 0, warnRunaway, sessions.contains(where: { $0.activity == .working }) { checkRunaway() }
    }

    // MARK: Alerts

    private func queueAlert(_ kind: AlertKind, _ session: AgentSession) {
        guard kind == .needsYou ? alertNeedsYou : alertFinished else { return }
        // You're looking at it already.
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier == hostApp(session)?.processIdentifier { return }
        queuedAlerts.append((kind, session))
        alertWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.showAlerts() } }
        alertWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    private func showAlerts() {
        let alerts = queuedAlerts
        queuedAlerts.removeAll()
        guard !alerts.isEmpty else { return }
        let asking = alerts.filter { $0.kind == .needsYou }
        let shown = asking.isEmpty ? alerts : asking
        let first = shown[0].session
        let title: String
        let detail: String
        if shown.count > 1 {
            title = asking.isEmpty ? "\(shown.count) agents finished" : "\(shown.count) agents need you"
            detail = shown.map(\.session.name).joined(separator: ", ")
        } else if asking.isEmpty {
            title = "\(first.tool.name) finished"
            detail = first.name
        } else {
            title = "\(first.tool.name) needs you"
            detail = Self.reason(first).map { "\(first.name) · \($0)" } ?? first.name
        }
        Toast.shared.show(title, detail: detail, image: hostIcon(first), duration: asking.isEmpty ? 3 : 6) { [weak self] in
            self?.show(first)
        }
    }

    /// "Input needed", in sentence case.
    static func reason(_ session: AgentSession) -> String? {
        guard case .needsYou(let reason?) = session.activity, !reason.isEmpty else { return nil }
        return reason.prefix(1).uppercased() + reason.dropFirst()
    }

    // MARK: Opening a session

    /// Brings the session forward: its app opens that exact session when it can (Claude's and
    /// Codex's links), else the app it runs in comes to the front with its window.
    func show(_ session: AgentSession) {
        if let url = session.openURL {
            NSWorkspace.shared.open(url)
            if let app = hostApp(session) { app.activate() }
            return
        }
        guard let pid = session.pid, let app = Self.appAbove(pid) else { return }
        app.activate()
        Self.raiseWindow(of: app, matching: [session.name, (session.folder as NSString).lastPathComponent])
    }

    func hostApp(_ session: AgentSession) -> NSRunningApplication? {
        switch session.host {
        case .claudeApp: NSRunningApplication.runningApplications(withBundleIdentifier: Self.claudeAppID).first
        case .codexApp: NSRunningApplication.runningApplications(withBundleIdentifier: Self.codexAppID).first
        case .other: session.pid.flatMap(Self.appAbove)
        }
    }

    func hostIcon(_ session: AgentSession) -> NSImage? {
        if let app = hostApp(session) { return app.icon }
        let id = session.tool == .claude ? Self.claudeAppID : Self.codexAppID
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    /// The app a process runs under (a terminal, an editor): the first regular app among its parents.
    static func appAbove(_ pid: Int32) -> NSRunningApplication? {
        var current: Int32? = pid
        var hops = 0
        while let p = current, p > 1, hops < 40 {
            if let app = NSRunningApplication(processIdentifier: p), app.activationPolicy == .regular { return app }
            current = ProcessReader.entry(p)?.parent
            hops += 1
        }
        return nil
    }

    /// Raises the app's window whose title mentions the session (terminals show the session's name
    /// or folder in theirs).
    static func raiseWindow(of app: NSRunningApplication, matching words: [String]) {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.5)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        let words = words.filter { $0.count > 2 }
        for window in windows {
            var title: AnyObject?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
            guard let text = title as? String, words.contains(where: { text.localizedCaseInsensitiveContains($0) }) else { continue }
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(element, kAXFocusedWindowAttribute as CFString, window)
            return
        }
    }

    // MARK: Stopping

    /// Asks a session's agent to quit (its conversation stays; it can be picked up again).
    func stop(_ session: AgentSession) {
        guard let pid = session.pid, ProcessReader.entry(pid)?.name.lowercased().contains("claude") == true else { return }
        stopping.insert(pid)
        kill(pid, SIGTERM)
        log.notice("agents: asked session \(session.sessionID, privacy: .public) (pid \(pid)) to quit")
    }

    /// Stops something left running: asked first, ended if it hasn't gone in 3 s.
    func stop(_ process: LeftRunning) {
        let pid = process.pid
        guard let entry = ProcessReader.entry(pid), entry.started == process.started, entry.uid == getuid() else { return }
        stopping.insert(pid)
        kill(pid, SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated {
                if let still = ProcessReader.entry(pid), still.started == process.started { kill(pid, SIGKILL) }
                self?.stopping.remove(pid)
                self?.leftRunning.removeAll { $0.pid == pid }
            }
        }
    }

    func stopAllLeftRunning() {
        leftRunning.forEach(stop)
    }

    // MARK: Unread chats

    nonisolated static var claudeStorage: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/Local Storage/leveldb", isDirectory: true)
    }

    nonisolated private static var claudeRecords: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)
    }

    /// How far back an unread chat still gets a row.
    nonisolated static let unreadWindow: TimeInterval = 7 * 86_400

    /// Reads the unread chats again soon (the apps write their storage in bursts); while nothing
    /// shows them, only notes that they changed.
    private func scheduleUnread(delay: TimeInterval = 1) {
        guard watchers > 0 else { unreadStale = true; return }
        unreadStale = false
        guard unreadWork == nil else { return }
        let names = codexNames
        let cache = tableCache
        let work = DispatchWorkItem { [weak self] in
            let chats = Self.readUnread(codexNames: names, cache: cache)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.unreadWork = nil
                    if let chats {
                        self.allUnread = chats
                        self.pruneReadMarks()
                    }
                    self.filterUnread()
                }
            }
        }
        unreadWork = work
        unreadQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    nonisolated private static func readUnread(codexNames: [String: String], cache: LevelDBReader.Cache) -> [UnreadChat]? {
        let cutoff = Date().addingTimeInterval(-unreadWindow)
        var chats: [UnreadChat] = []
        let entries = ClaudeUnread.entries(storage: claudeStorage, cache: cache)
        // Claude's storage unreadable this once (mid-compaction): keep the last list rather than
        // dropping every Claude chat and the marks that go with them.
        if entries == nil, FileManager.default.fileExists(atPath: claudeStorage.path) { return nil }
        if let entries, !entries.isEmpty {
            let paths = claudeRecordPaths(Set(entries.map(\.id)))
            for entry in entries {
                guard let path = paths[entry.id], let handle = FileHandle(forReadingAtPath: path) else { continue }
                let head = (try? handle.read(upToCount: 16_384)) ?? Data()
                try? handle.close()
                // One marked unread by hand shows however old its last turn is.
                if let chat = ClaudeUnread.chat(id: entry.id, head: head, marked: entry.marked), entry.marked || chat.at >= cutoff {
                    chats.append(chat)
                }
            }
        }
        let codexDB = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/state_5.sqlite").path
        if FileManager.default.fileExists(atPath: codexDB) {
            chats += (CodexUnread.chats(database: codexDB, names: codexNames) ?? []).filter { $0.at >= cutoff }
        }
        return UnreadChat.ordered(chats)
    }

    /// Where each session's record is: claude-code-sessions/<account>/<org>/<id>.json.
    nonisolated private static func claudeRecordPaths(_ wanted: Set<String>) -> [String: String] {
        let fm = FileManager.default
        var found: [String: String] = [:]
        for account in (try? fm.contentsOfDirectory(atPath: claudeRecords.path)) ?? [] {
            let accountPath = claudeRecords.appendingPathComponent(account).path
            for org in (try? fm.contentsOfDirectory(atPath: accountPath)) ?? [] {
                let folder = (accountPath as NSString).appendingPathComponent(org)
                for id in wanted where found[id] == nil {
                    let path = (folder as NSString).appendingPathComponent(id + ".json")
                    if fm.fileExists(atPath: path) { found[id] = path }
                }
            }
        }
        return found
    }

    /// The rows: not one already shown as working or waiting, nor one just opened from here.
    private func filterUnread() {
        let now = Date()
        opened = opened.filter { entry in now.timeIntervalSince(entry.value) < 120 && allUnread.contains { $0.id == entry.key } }
        let active = sessions.filter { $0.activity != .yourTurn }
        let next = allUnread.filter { chat in
            opened[chat.id] == nil && !active.contains { chat.matches($0) }
                && !markedRead(chat)
        }
        if next != unread { unread = next }
    }

    /// Marks chats read in Tutto: they leave the card and the page until a new turn lands in them.
    /// Their apps keep their own dots (Tutto only reads the apps' files, never writes them).
    func markRead(_ chats: [UnreadChat]) {
        guard !chats.isEmpty else { return }
        for chat in chats { readMarks[chat.id] = chat.state }
        defaults.set(readMarks, forKey: Keys.readMarks)
        filterUnread()
    }

    func markAllRead() { markRead(unread) }

    /// Marked read in Tutto and unchanged in its app since.
    private func markedRead(_ chat: UnreadChat) -> Bool {
        chat.isCovered(by: readMarks[chat.id])
    }

    /// Forgets marks for chats the apps no longer count as unread (they were read there).
    private func pruneReadMarks() {
        // Dropped once the app reads it, or once it changes there (a new reply, marked unread again).
        let kept = readMarks.filter { mark in allUnread.contains { $0.id == mark.key && markedRead($0) } }
        if kept.count != readMarks.count {
            readMarks = kept
            defaults.set(kept, forKey: Keys.readMarks)
        }
    }

    /// Opens the chat in its app, which marks it read.
    func open(_ chat: UnreadChat) {
        opened[chat.id] = Date()
        filterUnread()
        guard let url = chat.openURL else { return }
        NSWorkspace.shared.open(url)
        let id = chat.tool == .claude ? Self.claudeAppID : Self.codexAppID
        NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.activate()
    }

    /// A finished session that's also an unread chat (it gets the unread row instead).
    func isUnread(_ session: AgentSession) -> Bool {
        unread.contains { $0.matches(session) }
    }

    // MARK: Claude's own numbers

    /// While the card or page shows: asks now if the last answer is older than the interval, and
    /// again every interval.
    private func startPlanTimer() {
        guard running, planTimer == nil else { return }
        planReader.read()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + ClaudePlanUsageReader.interval, repeating: ClaudePlanUsageReader.interval, leeway: .seconds(20))
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.planReader.read() } }
        timer.resume()
        planTimer = timer
    }

    /// Asks Claude again now (the Agents page's Refresh).
    func refreshClaudePlan() { planReader.read(force: true) }

    private func planRead(_ usage: ClaudePlanUsage?, _ status: ClaudePlanUsageReader.Status) {
        claudePlanStatus = status
        if let usage {
            claudePlan = usage
            claudePlanSamples = (claudePlanSamples + [usage]).filter { usage.at.timeIntervalSince($0.at) < 3 * 3600 }
        }
        showClaudeLimits()
    }

    /// Claude's own reading while it's under half an hour old, else the estimate.
    private func showClaudeLimits() {
        let now = Date()
        if let plan = claudePlan, now.timeIntervalSince(plan.at) < 30 * 60 {
            claudeLimits = plan.limits(samples: claudePlanSamples, now: now)
        } else {
            claudeLimits = claudeEstimate
        }
    }

    // MARK: What it costs (on screen only)

    func begin() {
        #if DEBUG
        if previewing { return }
        #endif
        watchers += 1
        now = Date()
        if unreadStale { scheduleUnread(delay: 0) }
        startPlanTimer()
        guard sampler == nil else { return }
        sample()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(400))
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.sample() } }
        timer.resume()
        sampler = timer
    }

    func end() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        planTimer?.cancel()
        planTimer = nil
        sampler?.cancel()
        sampler = nil
        lastTable = nil
        lastSample = 0
    }

    private func sample() {
        now = Date()
        let claudeRoots = Dictionary(sessions.compactMap { s in s.pid.map { ($0, s.id) } }, uniquingKeysWith: { a, _ in a })
        let codexApp = NSRunningApplication.runningApplications(withBundleIdentifier: Self.codexAppID).first?.processIdentifier
        let previous = lastTable, before = lastSample
        let lookForLeftovers = samples % 5 == 0
        samples += 1
        sampleQueue.async { [weak self] in
            let table = ProcessReader.snapshot()
            let at = mach_absolute_time()
            let children = AgentLoads.children(table)
            let elapsed = before == 0 ? 0 : at &- before
            let nanos = AgentLoads.nanosPerMachUnit
            var loads: [Int32: AgentLoad] = [:]
            for pid in claudeRoots.keys {
                if let load = AgentLoads.load(root: pid, current: table, previous: previous, children: children, elapsed: elapsed, nanosPerUnit: nanos) {
                    loads[pid] = load
                }
            }
            // Codex: its app, and codex processes of its own (the CLI) outside the app.
            var codexRoots: [Int32] = codexApp.map { [$0] } ?? []
            let underApp = Set(codexApp.map { AgentLoads.tree($0, children: children) } ?? [])
            for entry in table.values where entry.name == "codex" && !underApp.contains(entry.pid) && table[entry.parent]?.name != "codex" {
                codexRoots.append(entry.pid)
            }
            let codexLoads = codexRoots.compactMap {
                AgentLoads.load(root: $0, current: table, previous: previous, children: children, elapsed: elapsed, nanosPerUnit: nanos)
            }
            let codex = codexLoads.isEmpty ? nil : AgentLoad(cpu: codexLoads.map(\.cpu).reduce(0, +), memory: codexLoads.map(\.memory).reduce(0, +),
                                                             watts: codexLoads.compactMap(\.watts).reduce(0, +), processes: codexLoads.map(\.processes).reduce(0, +),
                                                             busiest: codexLoads.compactMap(\.busiest).first)
            let leftovers = lookForLeftovers ? LeftRunningRules.find(in: table) : nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.sampler != nil || self.watchers > 0 else { return }
                    self.lastTable = table
                    self.lastSample = at
                    if self.loads != loads { self.loads = loads }
                    if self.codexLoad != codex { self.codexLoad = codex }
                    if let leftovers, leftovers.map(\.pid) != self.leftRunning.map(\.pid) || leftovers != self.leftRunning {
                        self.leftRunning = leftovers.filter { !self.stopping.contains($0.pid) }
                    }
                    self.noteRunaway(loads.compactMap { pid, load in load.isRunaway ? claudeRoots[pid] : nil })
                }
            }
        }
    }

    /// Off screen: one process-table read for trees past the runaway count.
    private func checkRunaway() {
        let roots = Dictionary(sessions.compactMap { s in s.pid.map { ($0, s.id) } }, uniquingKeysWith: { a, _ in a })
        guard !roots.isEmpty else { return }
        sampleQueue.async { [weak self] in
            let table = ProcessReader.snapshot()
            let children = AgentLoads.children(table)
            let found = roots.compactMap { pid, id in AgentLoads.tree(pid, children: children).count >= AgentLoad.runawayCount ? id : nil }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.noteRunaway(found) } }
        }
    }

    private func noteRunaway(_ ids: [String]) {
        let found = Set(ids)
        if found != runaway { runaway = found }
        guard warnRunaway else { return }
        for id in found where Date().timeIntervalSince(warnedRunaway[id] ?? .distantPast) > 3600 {
            warnedRunaway[id] = Date()
            guard let session = sessions.first(where: { $0.id == id }) else { continue }
            let count = session.pid.flatMap { loads[$0]?.processes }
            Toast.shared.show("\(session.tool.name) started \(count.map { "\($0)" } ?? "hundreds of") processes",
                              detail: "\(session.name): something may be looping", image: hostIcon(session), duration: 6) {
                MainWindowController.shared.show(page: .agents)
            }
        }
    }

    // MARK: Renders

    #if DEBUG
    @ObservationIgnored private var previewing = false

    /// Offscreen renders (`agents-demo`): sessions, limits and loads like a busy afternoon.
    func previewDemo() {
        let now = Date()
        previewing = true
        installed = true
        sessions = AgentSession.ordered([
            AgentSession(tool: .claude, sessionID: "a", name: "Add dark mode to settings", folder: NSHomeDirectory() + "/Projects/notes-app",
                         activity: .needsYou("input needed"), since: now.addingTimeInterval(-240), pid: 9001, host: .claudeApp),
            AgentSession(tool: .claude, sessionID: "b", name: "Speed up the image cache", folder: NSHomeDirectory() + "/Projects/gallery", activity: .working,
                         since: now.addingTimeInterval(-3900), pid: 9002, host: .claudeApp),
            AgentSession(tool: .codex, sessionID: "c", name: "Fix the flaky upload test", folder: NSHomeDirectory() + "/Projects/shop", activity: .working,
                         since: now.addingTimeInterval(-720), host: .codexApp),
            AgentSession(tool: .claude, sessionID: "d", name: "Write the API docs", folder: NSHomeDirectory() + "/Projects/api", activity: .yourTurn,
                         since: now.addingTimeInterval(-9600), pid: 9003, host: .claudeApp),
            AgentSession(tool: .claude, sessionID: "e", name: "Landing page", folder: NSHomeDirectory() + "/Projects/site", activity: .yourTurn,
                         since: now.addingTimeInterval(-600), pid: 9004, host: .other),
        ])
        loads = [9001: AgentLoad(cpu: 0.4, memory: 105_000_000, watts: 0.1, processes: 1, busiest: nil),
                 9002: AgentLoad(cpu: 142, memory: 1_240_000_000, watts: 6.2, processes: 14, busiest: "swift-build"),
                 9003: AgentLoad(cpu: 0, memory: 271_000_000, watts: nil, processes: 2, busiest: nil),
                 9004: AgentLoad(cpu: 0.1, memory: 86_000_000, watts: nil, processes: 1, busiest: nil)]
        codexLoad = AgentLoad(cpu: 38, memory: 640_000_000, watts: 1.8, processes: 9, busiest: nil)
        claudeLimits = AgentLimits(tool: .claude, fiveHour: LimitEstimate(window: .fiveHour, percent: 31, resetsAt: now.addingTimeInterval(9000), exact: true),
                                   week: LimitEstimate(window: .week, percent: 63, resetsAt: now.addingTimeInterval(190_000), exact: true))
        codexLimits = AgentLimits(tool: .codex, fiveHour: LimitEstimate(window: .fiveHour, percent: 78, resetsAt: now.addingTimeInterval(7200),
                                                                        limitAt: now.addingTimeInterval(2700), exact: true),
                                  week: LimitEstimate(window: .week, percent: 24, resetsAt: now.addingTimeInterval(300_000), exact: true))
        leftRunning = [LeftRunning(pid: 9100, name: "node", folder: NSHomeDirectory() + "/Projects/site", ports: [5173], memory: 312_000_000,
                                   started: now.addingTimeInterval(-26_000)),
                       LeftRunning(pid: 9101, name: "node", folder: NSHomeDirectory() + "/Projects/blog", ports: [3000], memory: 488_000_000,
                                   started: now.addingTimeInterval(-90_000))]
        unread = [UnreadChat(tool: .claude, chatID: "local_demo1", title: "Plan the next release", at: now.addingTimeInterval(-1500)),
                  UnreadChat(tool: .codex, chatID: "demo2", title: "Set up the release script", at: now.addingTimeInterval(-7400)),
                  UnreadChat(tool: .claude, chatID: "local_demo3", title: "Review the landing page copy", at: now.addingTimeInterval(-30_000)),
                  UnreadChat(tool: .claude, chatID: "local_demo4", title: "Daily notes", at: now.addingTimeInterval(-90_000))]
        self.now = now
    }
    #endif
}
