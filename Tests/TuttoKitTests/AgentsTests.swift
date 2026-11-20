import XCTest
@testable import TuttoKit

/// The Agents card: sessions read from what Claude Code and Codex write down, their limits, and
/// what their processes cost.
final class AgentsTests: XCTestCase {
    private let home = "/Users/me"

    // MARK: Sessions

    private func record(_ status: String, waiting: String? = nil, name: String? = "Fix login", entry: String = "claude-desktop",
                        updated: Double = 1_794_904_733_067) -> ClaudeSessionRecord {
        var json: [String: Any] = ["pid": 63773, "sessionId": "8db0", "cwd": "/Users/me/Projects/site", "startedAt": 1_794_904_241_741,
                                   "kind": "interactive", "entrypoint": entry, "status": status, "statusUpdatedAt": updated,
                                   "hostSessionId": "local_3183c7e5-57ca"]
        if let waiting { json["waitingFor"] = waiting }
        if let name { json["name"] = name }
        return ClaudeSessionRecord.decode(try! JSONSerialization.data(withJSONObject: json))!
    }

    func testClaudeRecordsBecomeSessions() {
        let waiting = record("waiting", waiting: "input needed").session(home: home)
        XCTAssertEqual(waiting.activity, .needsYou("input needed"))
        XCTAssertEqual(waiting.name, "Fix login")
        XCTAssertEqual(waiting.pid, 63773)
        XCTAssertEqual(waiting.host, .claudeApp)
        XCTAssertEqual(waiting.since, Date(timeIntervalSince1970: 1_794_904_733.067))
        XCTAssertEqual(waiting.openURL?.absoluteString, "claude://code/continue?session=local_3183c7e5-57ca")
        XCTAssertEqual(record("busy").session(home: home).activity, .working)
        XCTAssertEqual(record("idle").session(home: home).activity, .yourTurn)
        XCTAssertEqual(record("something-new").session(home: home).activity, .yourTurn)
        // A terminal session has no app link; an unnamed one is named after its folder.
        let terminal = record("busy", name: nil, entry: "cli").session(home: home)
        XCTAssertEqual(terminal.host, .other)
        XCTAssertNil(terminal.openURL)
        XCTAssertEqual(terminal.name, "site")
        XCTAssertNil(ClaudeSessionRecord.decode(Data("{\"pid\":1}".utf8)), "a record without its session isn't one")
    }

    func testFoldersReadAsPeopleSayThem() {
        XCTAssertEqual(AgentSession.displayFolder("/Users/me/Projects/site", home: home), "~/Projects/site")
        XCTAssertEqual(AgentSession.displayFolder("/Users/me", home: home), "~")
        XCTAssertEqual(AgentSession.displayFolder("/Users/me/Library/Application Support/Claude/scratch-workspaces/a/b", home: home), "Scratch")
        XCTAssertEqual(AgentSession.displayFolder("/opt/work", home: home), "/opt/work")
    }

    func testWhatNeedsYouComesFirst() {
        let t = Date(timeIntervalSince1970: 1_000)
        func s(_ id: String, _ activity: AgentActivity, _ since: Double) -> AgentSession {
            AgentSession(tool: .claude, sessionID: id, name: id, folder: "/", activity: activity, since: t.addingTimeInterval(since), host: .other)
        }
        let ordered = AgentSession.ordered([s("done", .yourTurn, 50), s("old-work", .working, 10), s("ask", .needsYou(nil), 0),
                                            s("new-work", .working, 40)])
        XCTAssertEqual(ordered.map(\.sessionID), ["ask", "new-work", "old-work", "done"])
    }

    func testFinishedSessionsDropOutAfter36Hours() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func s(_ id: String, _ activity: AgentActivity, hoursAgo: Double) -> AgentSession {
            AgentSession(tool: .claude, sessionID: id, name: id, folder: "/", activity: activity,
                         since: now.addingTimeInterval(-hoursAgo * 3600), host: .other)
        }
        let shown = AgentSession.shown([s("fresh", .yourTurn, hoursAgo: 2), s("edge", .yourTurn, hoursAgo: 36),
                                        s("old", .yourTurn, hoursAgo: 37), s("long-run", .working, hoursAgo: 80),
                                        s("old-ask", .needsYou(nil), hoursAgo: 50)], now: now)
        XCTAssertEqual(shown.map(\.sessionID), ["fresh", "edge", "long-run", "old-ask"])
    }

    // MARK: Codex

    private let meta = #"{"timestamp":"2026-11-17T02:36:34.590Z","type":"session_meta","payload":{"id":"01a1e75c","cwd":"/Users/me/Waterloo","originator":"Codex Desktop","source":"vscode"}}"#
    private func event(_ type: String, _ time: String) -> String {
        #"{"timestamp":"\#(time)","type":"event_msg","payload":{"type":"\#(type)"}}"#
    }
    private func tokens(_ time: String, five: Double, week: Double) -> String {
        #"{"timestamp":"\#(time)","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":\#(five),"window_minutes":300,"resets_at":1794900426},"secondary":{"used_percent":\#(week),"window_minutes":10080,"resets_at":1795219963}}}}"#
    }

    func testCodexThreadsWorkThenFinish() {
        var state = CodexThreadState()
        for line in [meta, event("task_started", "2026-11-17T02:36:40Z"), tokens("2026-11-17T02:50:00.000Z", five: 40, week: 20)] {
            state.read(line: Substring(line))
        }
        let during = ISOTime.parse("2026-11-17T02:52:00Z")!
        XCTAssertEqual(state.activity(now: during), .working)
        XCTAssertEqual(state.since, ISOTime.parse("2026-11-17T02:36:40Z"))
        XCTAssertEqual(state.activity(now: during.addingTimeInterval(3600)), .yourTurn, "a turn nothing's written to for long has stopped")
        let session = state.session(name: "Solve A07", now: during, home: home)
        XCTAssertEqual(session?.name, "Solve A07")
        XCTAssertEqual(session?.host, .codexApp)
        XCTAssertEqual(session?.openURL?.absoluteString, "codex://threads/01a1e75c")
        XCTAssertEqual(state.limits?.fiveHour, 40)
        XCTAssertEqual(state.limits?.week, 20)
        XCTAssertEqual(state.limits?.fiveHourResets, Date(timeIntervalSince1970: 1_794_900_426))
        state.read(line: Substring(event("task_complete", "2026-11-17T03:05:00Z")))
        XCTAssertEqual(state.activity(now: during), .yourTurn)
        XCTAssertEqual(state.since, ISOTime.parse("2026-11-17T03:05:00Z"))
        state.read(line: "not json")
        XCTAssertEqual(state.limits?.fiveHour, 40, "a broken line changes nothing")
    }

    func testCodexLogsAreReadByTheirFirstBytes() {
        let big = #"{"timestamp":"2026-11-17T02:40:00Z","type":"response_item","payload":{"type":"message","content":"\#(String(repeating: "x", count: 5000)) \"type\":\"task_complete\""}}"#
        let text = [meta, event("task_started", "2026-11-17T02:36:40Z"), big, tokens("2026-11-17T02:50:00Z", five: 12, week: 3)]
            .joined(separator: "\n") + "\n" + event("task_complete", "2026-11-17T03:00:00Z")  // still being written
        var state = CodexThreadState()
        let used = Data(text.utf8).withUnsafeBytes { state.scan($0) }
        XCTAssertLessThan(used, text.utf8.count)
        XCTAssertEqual(state.threadID, "01a1e75c")
        XCTAssertNil(state.lastFinished, "a model's words about a task aren't the task, and the last line isn't finished")
        XCTAssertEqual(state.limits?.fiveHour, 12)
    }

    func testCodexNamesTheLastNameWins() {
        let text = """
        {"id":"a","thread_name":"First","updated_at":"2026-11-09T02:11:21Z"}
        {"id":"b","thread_name":"Other"}
        {"id":"a","thread_name":"Renamed"}
        """
        XCTAssertEqual(CodexIndex.names(text), ["a": "Renamed", "b": "Other"])
    }

    func testTimesParse() {
        XCTAssertEqual(ISOTime.parse("2026-11-17T03:05:43.838Z")!.timeIntervalSince1970, 1_794_884_743.838, accuracy: 0.001)
        XCTAssertEqual(ISOTime.parse("2026-11-17T03:05:43Z")!.timeIntervalSince1970, 1_794_884_743, accuracy: 0.001)
        XCTAssertEqual(ISOTime.parse("2026-10-21T23:59:59.925692+00:00")!.timeIntervalSince1970, 1_792_627_199.925692, accuracy: 0.001)
        XCTAssertEqual(ISOTime.parse("2026-10-21T19:59:59-04:00"), ISOTime.parse("2026-10-21T23:59:59Z"))
        XCTAssertNil(ISOTime.parse("yesterday"))
        XCTAssertNil(ISOTime.parse("2026-10-21T23:59:59Q"))
    }

    // MARK: Codex limits

    func testCodexLimitsAreExactAndPaced() {
        let resets = Date(timeIntervalSince1970: 10_000)
        func reading(_ at: Double, _ five: Double) -> CodexLimitReading {
            CodexLimitReading(at: Date(timeIntervalSince1970: at), fiveHour: five, fiveHourResets: resets, week: 30, weekResets: resets.addingTimeInterval(86_400))
        }
        // 10 points in 20 minutes: 50 → 100 takes another 100 minutes, before the reset.
        let samples = [reading(1_000, 40), reading(1_600, 45), reading(2_200, 50)]
        let limits = CodexLimits.limits(latest: samples.last, samples: samples, now: Date(timeIntervalSince1970: 2_200))!
        XCTAssertEqual(limits.fiveHour?.percent, 50)
        XCTAssertTrue(limits.fiveHour!.exact)
        XCTAssertEqual(limits.fiveHour!.limitAt!.timeIntervalSince1970, 2_200 + 6_000, accuracy: 1)
        XCTAssertEqual(limits.headline?.window, .fiveHour, "the window that runs out first")
        // After the reset it reads empty.
        let later = CodexLimits.limits(latest: samples.last, samples: samples, now: Date(timeIntervalSince1970: 10_001))!
        XCTAssertEqual(later.fiveHour?.percent, 0)
    }

    func testPaceNeedsARisingSpanBeforeTheReset() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertNil(LimitPace.limitAt(samples: [(now.addingTimeInterval(-60), 10), (now, 12)], current: 12, now: now, resetsAt: nil),
                     "a minute says too little")
        XCTAssertNil(LimitPace.limitAt(samples: [(now.addingTimeInterval(-1800), 12), (now, 12)], current: 12, now: now, resetsAt: nil))
        let at = LimitPace.limitAt(samples: [(now.addingTimeInterval(-1800), 40), (now, 70)], current: 70, now: now, resetsAt: nil)
        XCTAssertEqual(at!.timeIntervalSince(now), 1800, accuracy: 1)
        XCTAssertNil(LimitPace.limitAt(samples: [(now.addingTimeInterval(-1800), 40), (now, 70)], current: 70, now: now,
                                       resetsAt: now.addingTimeInterval(600)), "it resets before it runs out")
    }

    func testOnlyWhatMattersReachesTheMenuBar() {
        let now = Date()
        XCTAssertFalse(LimitEstimate(window: .week, percent: 60, resetsAt: nil, exact: true).matters(now: now))
        XCTAssertTrue(LimitEstimate(window: .week, percent: 90, resetsAt: nil, exact: true).matters(now: now))
        XCTAssertTrue(LimitEstimate(window: .fiveHour, percent: 100, resetsAt: nil, reached: true, exact: true).matters(now: now))
        XCTAssertTrue(LimitEstimate(window: .fiveHour, percent: 50, resetsAt: nil, limitAt: now.addingTimeInterval(1200), exact: false).matters(now: now))
    }

    // MARK: Claude logs

    private func reply(id: String, time: String, model: String = "claude-opus-5-5", input: Int = 0, output: Int = 0,
                       write: Int = 0, read: Int = 0, text: String = "hi") -> String {
        #"{"parentUuid":"x","type":"assistant","message":{"model":"\#(model)","id":"msg_\#(id)","type":"message","role":"assistant","content":[{"type":"text","text":"\#(text)"}],"usage":{"input_tokens":\#(input),"cache_creation_input_tokens":\#(write),"cache_read_input_tokens":\#(read),"cache_creation":{"ephemeral_5m_input_tokens":\#(write)},"output_tokens":\#(output)}},"requestId":"req_\#(id)","uuid":"u","timestamp":"\#(time)"}"#
    }

    func testRepliesAreCountedOnceAndWeightedByModel() {
        let lines = [
            reply(id: "A", time: "2026-11-17T10:00:00.000Z", input: 1_000_000),
            reply(id: "A", time: "2026-11-17T10:00:01.000Z", input: 1_000_000),  // the same reply's next block
            reply(id: "B", time: "2026-11-17T10:01:00.000Z", model: "claude-sonnet-5-5", output: 100_000),
            #"{"type":"user","message":{"content":"tool result"},"timestamp":"2026-11-17T10:02:00Z"}"#,
        ].joined(separator: "\n") + "\n" + reply(id: "C", time: "2026-11-17T10:03:00Z", output: 1)  // no newline yet
        var found = ClaudeLogScanner.Found()
        let used = ClaudeLogScanner.scan(Data(lines.utf8), into: &found)
        XCTAssertEqual(found.events.count, 3, "every complete reply line; the half-written last one waits")
        XCTAssertLessThan(used, lines.utf8.count)
        XCTAssertEqual(Set(found.events.map(\.key)).count, 2, "the same reply has the same key")
        XCTAssertEqual(found.events[0].cost, 4, accuracy: 0.0001, "a million Opus input tokens")
        XCTAssertEqual(found.events[2].cost, 1, accuracy: 0.0001, "100k Sonnet output tokens")
        XCTAssertEqual(ClaudePricing.cost(model: "claude-opus-5-5", input: 0, output: 0, cacheWrite: 1_000_000, cacheRead: 1_000_000), 5.2, accuracy: 0.0001)
    }

    func testALongReplyIsReadFromItsEnds() {
        // A reply with a big picture or file in it: its model and id at the start, its usage at the end.
        let long = reply(id: "L", time: "2026-11-17T11:00:00Z", output: 200_000, text: String(repeating: "a", count: 300_000))
        var found = ClaudeLogScanner.Found()
        ClaudeLogScanner.scan(Data((long + "\n").utf8), into: &found)
        XCTAssertEqual(found.events.count, 1)
        XCTAssertEqual(found.events.first?.cost ?? 0, 4, accuracy: 0.0001, "200k Opus output tokens")
        XCTAssertEqual(found.events.first?.time, ISOTime.parse("2026-11-17T11:00:00Z"))
    }

    func testLimitMessagesAreClaudesOwnNotQuotes() {
        let own = #"{"type":"assistant","message":{"model":"<synthetic>","id":"msg_x","content":[{"type":"text","text":"You've hit your session limit · resets 7:10am (America/Toronto)"}],"usage":{"input_tokens":0,"output_tokens":0}},"error":"rate_limit","isApiErrorMessage":true,"timestamp":"2026-10-15T06:57:00.000Z"}"#
        let weekly = #"{"type":"assistant","message":{"content":[{"type":"text","text":"You've hit your weekly limit · resets 7pm"}]},"error":"rate_limit","timestamp":"2026-11-11T18:33:00.000Z"}"#
        let quoted = #"{"type":"user","message":{"content":"it said \"error\":\"rate_limit\" and You've hit your session limit"},"timestamp":"2026-11-12T00:00:00Z"}"#
        var found = ClaudeLogScanner.Found()
        ClaudeLogScanner.scan(Data((own + "\n" + weekly + "\n" + quoted + "\n").utf8), into: &found)
        XCTAssertEqual(found.hits.map(\.kind), [.session, .weekly])
        XCTAssertEqual(found.hits.first?.time, ISOTime.parse("2026-10-15T06:57:00Z"))
    }

    // MARK: Claude estimate

    private func events(_ spans: [(start: Double, minutes: Int, perMinute: Double)]) -> [ClaudeUsageEvent] {
        var result: [ClaudeUsageEvent] = []
        for span in spans {
            for m in 0..<span.minutes {
                result.append(ClaudeUsageEvent(time: Date(timeIntervalSince1970: span.start + Double(m) * 60), cost: span.perMinute,
                                               key: UInt64(result.count)))
            }
        }
        return result.sorted { $0.time < $1.time }
    }

    func testFiveHourLimitIsLearnedFromAHitAndRaisedByLaterWindows() {
        let day: Double = 1_800_000_000
        // Day 1: $100 in an hour, then Claude says the limit is reached.
        // Day 2: a window spends $150 without a word: the limit is at least $150.
        // Now: $30 into a window that began 30 minutes ago, $1 a minute.
        let log = events([(day, 100, 1), (day + 86_400, 150, 1), (day + 2 * 86_400, 30, 1)])
        let hit = ClaudeLimitHit(time: Date(timeIntervalSince1970: day + 100 * 60), kind: .session)
        let now = Date(timeIntervalSince1970: day + 2 * 86_400 + 30 * 60)
        let limits = ClaudeLimitEstimator.estimate(events: log, hits: [hit], snapshot: nil, now: now)!
        let five = limits.fiveHour!
        XCTAssertFalse(five.exact)
        XCTAssertEqual(five.percent, 20, accuracy: 0.5, "$30 of $150")
        XCTAssertEqual(five.resetsAt, Date(timeIntervalSince1970: day + 2 * 86_400 + 5 * 3600))
        // $1 a minute: $120 to go is 2 hours, before the window resets.
        XCTAssertEqual(five.limitAt!.timeIntervalSince(now), 120 * 60, accuracy: 120)
        XCTAssertNil(limits.week, "no weekly reset known, no weekly estimate")
        XCTAssertTrue(limits.basis?.contains("5-hour limit you reached") ?? false)
    }

    func testAHitInTheCurrentWindowMeansReached() {
        let start: Double = 1_800_000_000
        let log = events([(start, 60, 2)])
        let hit = ClaudeLimitHit(time: Date(timeIntervalSince1970: start + 60 * 60), kind: .session)
        let limits = ClaudeLimitEstimator.estimate(events: log, hits: [hit], snapshot: nil, now: Date(timeIntervalSince1970: start + 70 * 60))!
        XCTAssertTrue(limits.fiveHour!.reached)
        XCTAssertEqual(limits.fiveHour!.percent, 100)
        XCTAssertEqual(limits.headline?.window, .fiveHour)
    }

    func testTheWeekIsAnchoredToClaudesResetAndCalibratedByUsage() {
        // /usage said 50 % of the week after $500, resetting at `anchor`; now it's two weeks on,
        // with $300 spent this week.
        let anchor = Date(timeIntervalSince1970: 1_800_000_000)
        let weekStart = anchor.timeIntervalSince1970 - 7 * 86_400
        var log = events([(weekStart + 3600, 500, 1)])
        let snapshot = ClaudeUsageSnapshot(fetched: Date(timeIntervalSince1970: weekStart + 3600 + 500 * 60), fiveHour: nil, fiveHourResets: nil,
                                           week: 50, weekResets: anchor)
        log += events([(anchor.timeIntervalSince1970 + 14 * 86_400 + 3600, 300, 1)])
        let now = Date(timeIntervalSince1970: anchor.timeIntervalSince1970 + 14 * 86_400 + 3600 + 300 * 60)
        let week = ClaudeLimitEstimator.estimate(events: log, hits: [], snapshot: snapshot, now: now)!.week!
        XCTAssertEqual(week.percent, 30, accuracy: 0.5, "$300 of a $1,000 week")
        XCTAssertEqual(week.resetsAt, anchor.addingTimeInterval(21 * 86_400))
    }

    func testTheSnapshotReadsFromClaudesSettings() {
        let json = #"{"numStartups":3,"cachedUsageUtilization":{"fetchedAtMs":1792422739944,"utilization":{"five_hour":{"utilization":3,"resets_at":"2026-10-19T16:29:59.925672+00:00"},"seven_day":{"utilization":79,"resets_at":"2026-10-21T23:59:59.925692+00:00"}}}}"#
        let snapshot = ClaudeUsageSnapshot.parse(Data(json.utf8))
        XCTAssertEqual(snapshot?.week, 79)
        XCTAssertEqual(snapshot?.fiveHour, 3)
        XCTAssertNotNil(snapshot?.weekResets)
        XCTAssertNil(ClaudeUsageSnapshot.parse(Data("{}".utf8)))
    }

    // MARK: Processes

    private func proc(_ pid: Int32, _ parent: Int32, _ name: String, cpu: UInt64 = 0, memory: UInt64 = 100, energy: UInt64 = 0,
                      started: Double = 0) -> ProcessEntry {
        ProcessEntry(pid: pid, parent: parent, uid: 501, name: name, cpuTime: cpu, memory: memory, energy: energy,
                     started: Date(timeIntervalSince1970: started))
    }

    func testAnAgentsLoadIncludesWhatItStarted() {
        let before: [Int32: ProcessEntry] = [10: proc(10, 1, "claude", cpu: 0), 11: proc(11, 10, "zsh"), 12: proc(12, 11, "swift-build", cpu: 0, energy: 0),
                      20: proc(20, 1, "Finder", cpu: 0)]
        let after: [Int32: ProcessEntry] = [10: proc(10, 1, "claude", cpu: 10, memory: 300), 11: proc(11, 10, "zsh"),
                     12: proc(12, 11, "swift-build", cpu: 300, memory: 600, energy: 2_000_000_000), 20: proc(20, 1, "Finder", cpu: 999)]
        let load = AgentLoads.load(root: 10, current: after, previous: before, children: AgentLoads.children(after),
                                   elapsed: 1_000, nanosPerUnit: 1_000_000)!  // 1 s
        XCTAssertEqual(load.processes, 3)
        XCTAssertEqual(load.memory, 1_000)
        XCTAssertEqual(load.cpu, 31, accuracy: 0.01)
        XCTAssertEqual(load.watts ?? 0, 2, accuracy: 0.01)
        XCTAssertEqual(load.busiest, "swift-build")
        XCTAssertFalse(load.isRunaway)
        XCTAssertNil(AgentLoads.load(root: 99, current: after, previous: before, children: [:], elapsed: 1, nanosPerUnit: 1))
        // A reused pid (a different process) isn't counted against the old one's time.
        var reused = after
        reused[12] = proc(12, 11, "node", cpu: 900, started: 50)
        XCTAssertEqual(AgentLoads.load(root: 10, current: reused, previous: before, children: AgentLoads.children(reused),
                                       elapsed: 1_000, nanosPerUnit: 1_000_000)!.cpu, 1, accuracy: 0.01)
    }

    func testRunawayTrees() {
        var table: [Int32: ProcessEntry] = [10: proc(10, 1, "claude")]
        for pid in Int32(100)..<Int32(100 + AgentLoad.runawayCount) { table[pid] = proc(pid, 10, "sh") }
        let load = AgentLoads.load(root: 10, current: table, previous: nil, children: AgentLoads.children(table), elapsed: 0, nanosPerUnit: 1)!
        XCTAssertTrue(load.isRunaway)
        XCTAssertEqual(load.cpu, 0, "no CPU without an interval")
    }

    func testWhatsLeftRunningIsADevProcessWithNoParentInAProject() {
        let now = Date(timeIntervalSince1970: 10_000)
        func entry(_ name: String, parent: Int32 = 1, uid: UInt32 = 501, age: Double = 600) -> ProcessEntry {
            ProcessEntry(pid: 7, parent: parent, uid: uid, name: name, cpuTime: 0, memory: 1, energy: 0, started: now.addingTimeInterval(-age))
        }
        XCTAssertTrue(LeftRunningRules.isCandidate(entry("node"), path: "/opt/homebrew/bin/node", uid: 501, now: now))
        XCTAssertTrue(LeftRunningRules.isCandidate(entry("python3.12"), path: nil, uid: 501, now: now))
        XCTAssertFalse(LeftRunningRules.isCandidate(entry("node", parent: 400), path: nil, uid: 501, now: now), "it has a parent")
        XCTAssertFalse(LeftRunningRules.isCandidate(entry("node", uid: 0), path: nil, uid: 501, now: now), "not yours")
        XCTAssertFalse(LeftRunningRules.isCandidate(entry("node", age: 10), path: nil, uid: 501, now: now), "just handed off")
        XCTAssertFalse(LeftRunningRules.isCandidate(entry("Finder"), path: nil, uid: 501, now: now))
        XCTAssertFalse(LeftRunningRules.isCandidate(entry("node"), path: "/Applications/ChatGPT.app/Contents/Resources/node", uid: 501, now: now),
                       "part of an app")
        XCTAssertTrue(LeftRunningRules.isInProject(folder: "/Users/me/Projects/site", home: home))
        XCTAssertFalse(LeftRunningRules.isInProject(folder: "/", home: home))
        XCTAssertFalse(LeftRunningRules.isInProject(folder: "/Users/me/Library/Caches", home: home))
    }
}
