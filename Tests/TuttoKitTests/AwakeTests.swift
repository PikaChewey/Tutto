import XCTest
@testable import TuttoKit

final class AwakeDurationTests: XCTestCase {
    func testTypedTimes() {
        let cases: [(String, TimeInterval?)] = [
            ("90", 90 * 60),
            ("45", 45 * 60),
            ("2h", 2 * 3600),
            ("2h30", 2.5 * 3600),
            ("2h 30", 2.5 * 3600),
            ("2h30m", 2.5 * 3600),
            ("2H30M", 2.5 * 3600),
            ("1.5h", 1.5 * 3600),
            ("1d", 86_400),
            ("1d 6h", 30 * 3600),
            ("1d6", 30 * 3600),
            ("45m", 45 * 60),
            ("45 min", 45 * 60),
            ("2 hours", 2 * 3600),
            ("1 hour 15 minutes", 75 * 60),
            ("1w", 7 * 86_400),
            ("2:30", 2.5 * 3600),
            ("0:45", 45 * 60),
            ("  3h  ", 3 * 3600),
            ("", nil),
            ("0", nil),
            ("abc", nil),
            ("2x", nil),
            ("30m2h", nil),      // smallest unit first
            ("2h2h", nil),       // a unit twice
            ("2:5", nil),        // minutes need two digits
            ("2:75", nil),
            ("1m30", nil),       // nothing below minutes
            ("-5", nil),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(AwakeDuration.seconds(from: text), expected, "\"\(text)\"")
        }
    }

    func testRoundsToTheMinute() {
        XCTAssertEqual(AwakeDuration.seconds(from: "0.01h"), 60)
        XCTAssertNil(AwakeDuration.seconds(from: "0.001h"))
    }

    func testLabels() {
        XCTAssertEqual(AwakeDuration.label(3600), "1h")
        XCTAssertEqual(AwakeDuration.label(9000), "2h 30m")
        XCTAssertEqual(AwakeDuration.label(30 * 3600), "1d 6h")
        XCTAssertEqual(AwakeDuration.label(45 * 60), "45m")
        XCTAssertEqual(AwakeDuration.menuBar(2 * 3600 + 13 * 60 + 1), "2h 14m")  // rounded up
        XCTAssertEqual(AwakeDuration.menuBar(59), "1m")
        XCTAssertEqual(AwakeDuration.menuBar(0), "0m")
    }

    func testCountdown() {
        XCTAssertEqual(AwakeDuration.countdown(2 * 3600 + 14 * 60 + 7).main, "2:14")
        XCTAssertEqual(AwakeDuration.countdown(2 * 3600 + 14 * 60 + 7).seconds, ":07")
        XCTAssertEqual(AwakeDuration.countdown(4 * 60 + 7).main, "4")
        XCTAssertEqual(AwakeDuration.countdown(86_400 + 3600 + 60).main, "1d 1:01")
        XCTAssertEqual(AwakeDuration.countdown(-5).main, "0")
    }
}

final class AwakeRulesTests: XCTestCase {
    private func at(_ charge: Int?, battery: Bool = true, heat: Heat = .nominal, closed: Bool = false, display: Bool = false) -> AwakeConditions {
        AwakeConditions(onBattery: battery, charge: charge, heat: heat, lidClosed: closed, externalDisplay: display)
    }

    func testEndFloor() {
        let policy = AwakePolicy()
        XCTAssertNil(AwakeRules.endReason(policy, at(10)))
        XCTAssertEqual(AwakeRules.endReason(policy, at(9)), "The battery fell to 9%")
        XCTAssertNil(AwakeRules.endReason(policy, at(5, battery: false)), "charging")
        XCTAssertNil(AwakeRules.endReason(policy, at(nil)), "unreadable never counts as low")
        var off = policy
        off.endBelow = 0
        XCTAssertNil(AwakeRules.endReason(off, at(2)))
    }

    func testHeat() {
        var policy = AwakePolicy()
        XCTAssertEqual(AwakeRules.endReason(policy, at(80, heat: .critical)), "The Mac got critically hot")
        XCTAssertEqual(AwakeRules.lowPowerReason(policy, at(80, heat: .serious)), "running hot")
        XCTAssertNil(AwakeRules.lowPowerReason(policy, at(80, heat: .fair)))
        policy.heatRules = false
        XCTAssertNil(AwakeRules.endReason(policy, at(80, heat: .critical)))
    }

    func testLowPower() {
        let policy = AwakePolicy()
        XCTAssertEqual(AwakeRules.lowPowerReason(policy, at(80, closed: true)), "lid closed")
        XCTAssertEqual(AwakeRules.lowPowerReason(policy, at(80, battery: false, closed: true)), "lid closed")
        XCTAssertNil(AwakeRules.lowPowerReason(policy, at(80, closed: true, display: true)), "desk set-up")
        XCTAssertEqual(AwakeRules.lowPowerReason(policy, at(39)), "battery below 40%")
        XCTAssertNil(AwakeRules.lowPowerReason(policy, at(40)))
        XCTAssertNil(AwakeRules.lowPowerReason(policy, at(20, battery: false)))
    }

    func testFloorsStayInOrder() {
        var policy = AwakePolicy()
        policy.endBelow = 45
        policy.lowPowerBelow = 30
        policy.normalize()
        XCTAssertLessThan(policy.endBelow, policy.lowPowerBelow)
        policy.endBelow = 0
        policy.lowPowerBelow = 0
        policy.normalize()
        XCTAssertEqual(policy.lowPowerBelow, 0)
    }

    func testPausing() {
        let chat = AwakeApp(bundleID: "com.example.chat", name: "Chat", category: "public.app-category.social-networking")
        let game = AwakeApp(bundleID: "com.example.game", name: "Game", category: "public.app-category.action-games")
        let editor = AwakeApp(bundleID: "com.example.editor", name: "Editor", category: "public.app-category.developer-tools")
        let video = AwakeApp(bundleID: "com.example.cut", name: "Cut", category: "public.app-category.video")
        let none = AwakeApp(bundleID: "com.example.none", name: "None", category: nil)
        let apple = AwakeApp(bundleID: "com.apple.MobileSMS", name: "Messages", category: "public.app-category.social-networking")
        let tutto = AwakeApp(bundleID: "ca.bryanyao.Tutto", name: "Tutto", category: "public.app-category.games")
        XCTAssertTrue(AwakePausing.pauses(chat, choices: [:]))
        XCTAssertTrue(AwakePausing.pauses(game, choices: [:]))
        XCTAssertFalse(AwakePausing.pauses(editor, choices: [:]))
        XCTAssertFalse(AwakePausing.pauses(video, choices: [:]), "an export may be running")
        XCTAssertFalse(AwakePausing.pauses(none, choices: [:]))
        XCTAssertTrue(AwakePausing.pauses(none, choices: ["com.example.none": true]))
        XCTAssertFalse(AwakePausing.pauses(chat, choices: ["com.example.chat": false]))
        XCTAssertFalse(AwakePausing.pauses(apple, choices: ["com.apple.MobileSMS": true]))
        XCTAssertFalse(AwakePausing.pauses(tutto, choices: [:]))
    }

    func testProcessFamily() {
        // 10 started 11 and 12; 11 started 13. 20 is someone else.
        let parents: [Int32: Int32] = [10: 1, 11: 10, 12: 10, 13: 11, 20: 1]
        let family = ProcessTree.family(of: 10, parents: parents)
        XCTAssertEqual(Set(family), [10, 11, 12, 13])
        XCTAssertEqual(family.last, 10, "children before the parent")
        XCTAssertLessThan(family.firstIndex(of: 13)!, family.firstIndex(of: 11)!)
        XCTAssertEqual(ProcessTree.family(of: 99, parents: parents), [99])
    }

    func testOwnProcessIdentity() {
        let me = SystemProcesses.identity(of: getpid())
        XCTAssertEqual(me?.uid, getuid())
        XCTAssertGreaterThan(me?.startTime ?? 0, 1_700_000_000)
        XCTAssertFalse(ProcessTree.parents().isEmpty)
    }
}

final class HotspotFailoverTests: XCTestCase {
    func testJoinsAfterFiveSecondsAndBacksOff() {
        var machine = HotspotFailover()
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(machine.networkLost(at: t0), [.retry(after: 5)])
        XCTAssertEqual(machine.networkLost(at: t0.addingTimeInterval(1)), [], "one outage at a time")
        XCTAssertEqual(machine.timerFired(at: t0.addingTimeInterval(4)), [], "not yet")
        XCTAssertEqual(machine.timerFired(at: t0.addingTimeInterval(5)), [.join, .retry(after: 5)])
        XCTAssertEqual(machine.timerFired(at: t0.addingTimeInterval(10)), [.join, .retry(after: 10)])
        XCTAssertEqual(machine.timerFired(at: t0.addingTimeInterval(20)), [.join, .retry(after: 20)])
        XCTAssertEqual(machine.timerFired(at: t0.addingTimeInterval(40)), [.join, .retry(after: 30)])
        XCTAssertEqual(machine.timerFired(at: t0.addingTimeInterval(70)), [.join, .retry(after: 30)])
        XCTAssertEqual(machine.networkBack(at: t0.addingTimeInterval(75)), [.recovered(after: 75)])
        XCTAssertFalse(machine.inOutage)
        XCTAssertEqual(machine.timerFired(at: t0.addingTimeInterval(200)), [])
    }
}

// MARK: - The helper's controller, with a fake pmset

private final class FakePMSet: PowerCommands {
    var sleepDisabled = false
    var lowPowerBattery = 0
    var lowPowerAC = 0
    var refuse: Set<String> = []
    var log: [[String]] = []

    func pmset(_ arguments: [String]) -> (status: Int32, output: String) {
        log.append(arguments)
        if refuse.contains(arguments.joined(separator: " ")) { return (1, "refused") }
        switch arguments {
        case ["-g"]:
            return (0, "System-wide power settings:\n SleepDisabled\t\t\(sleepDisabled ? 1 : 0)\nCurrently in use:\n lowpowermode         \(lowPowerBattery)\n")
        case ["-g", "custom"]:
            return (0, "Battery Power:\n lowpowermode         \(lowPowerBattery)\n sleep                1\nAC Power:\n lowpowermode         \(lowPowerAC)\n sleep                1\n")
        case ["-a", "disablesleep", "1"]: sleepDisabled = true
        case ["-a", "disablesleep", "0"]: sleepDisabled = false
        case let a where a.count == 3 && a[0] == "-b" && a[1] == "lowpowermode": lowPowerBattery = Int(a[2]) ?? -1
        default: return (1, "unexpected")
        }
        return (0, "")
    }
}

private final class FakeProcesses: ProcessSignals {
    var alive: [Int32: (startTime: Double, uid: UInt32)] = [:]
    var signals: [(Int32, Int32)] = []

    func identity(of pid: Int32) -> (startTime: Double, uid: UInt32)? { alive[pid] }
    func send(_ signal: Int32, to pid: Int32) -> Bool {
        signals.append((signal, pid))
        return true
    }
}

final class AwakeControllerTests: XCTestCase {
    private var directory: URL!
    private var journal: URL { directory.appendingPathComponent("awake.json") }
    private var clock = Date(timeIntervalSince1970: 2_000_000_000)

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("awake-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func controller(_ pmset: FakePMSet, _ processes: FakeProcesses = FakeProcesses()) -> AwakeController {
        AwakeController(commands: pmset, processes: processes, journalURL: journal, now: { [unowned self] in self.clock })
    }

    func testBeginEndRestoresSleep() {
        let pmset = FakePMSet()
        let awake = controller(pmset)
        XCTAssertTrue(awake.begin(until: clock.addingTimeInterval(3600)).succeeded)
        XCTAssertTrue(pmset.sleepDisabled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path), "journaled before the change")
        XCTAssertTrue(awake.end().succeeded)
        XCTAssertFalse(pmset.sleepDisabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
        XCTAssertFalse(awake.isActive)
    }

    func testLeavesSomeoneElsesSleepSettingAlone() {
        let pmset = FakePMSet()
        pmset.sleepDisabled = true
        let awake = controller(pmset)
        XCTAssertTrue(awake.begin(until: clock.addingTimeInterval(600)).succeeded)
        XCTAssertTrue(awake.end().succeeded)
        XCTAssertTrue(pmset.sleepDisabled, "it was on before; it stays on")
        XCTAssertFalse(pmset.log.contains(["-a", "disablesleep", "0"]))
    }

    func testRefusedStartLeavesNothingBehind() {
        let pmset = FakePMSet()
        pmset.refuse = ["-a disablesleep 1"]
        let awake = controller(pmset)
        XCTAssertFalse(awake.begin(until: clock.addingTimeInterval(600)).succeeded)
        XCTAssertFalse(awake.isActive)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    }

    func testDeadlineIsCappedAndMoves() {
        let awake = controller(FakePMSet())
        _ = awake.begin(until: clock.addingTimeInterval(30 * 86_400))
        XCTAssertEqual(awake.deadline, clock.addingTimeInterval(AwakeLimits.longest))
        _ = awake.begin(until: clock.addingTimeInterval(7200))
        XCTAssertEqual(awake.deadline, clock.addingTimeInterval(7200))
        XCTAssertFalse(awake.begin(until: clock.addingTimeInterval(-1)).succeeded)
        XCTAssertFalse(awake.isOverdue())
        clock = clock.addingTimeInterval(7200 + AwakeLimits.grace)
        XCTAssertTrue(awake.isOverdue())
    }

    func testLowPowerPutsBackWhatWasThere() {
        let pmset = FakePMSet()
        let awake = controller(pmset)
        _ = awake.begin(until: clock.addingTimeInterval(3600))
        XCTAssertTrue(awake.setLowPower(true).succeeded)
        XCTAssertEqual(pmset.lowPowerBattery, 1)
        XCTAssertTrue(awake.lowPowerClaimed)
        XCTAssertEqual(pmset.lowPowerAC, 0, "the charger's setting is never touched")
        XCTAssertTrue(awake.setLowPower(false).succeeded)
        XCTAssertEqual(pmset.lowPowerBattery, 0)

        pmset.lowPowerBattery = 1  // you keep it on yourself
        _ = awake.setLowPower(true)
        _ = awake.end()
        XCTAssertEqual(pmset.lowPowerBattery, 1)
        XCTAssertFalse(pmset.sleepDisabled)
    }

    func testLowPowerNeedsASession() {
        XCTAssertFalse(controller(FakePMSet()).setLowPower(true).succeeded)
    }

    func testFailedRestoreStaysJournaled() {
        let pmset = FakePMSet()
        let awake = controller(pmset)
        _ = awake.begin(until: clock.addingTimeInterval(3600))
        pmset.refuse = ["-a disablesleep 0"]
        XCTAssertFalse(awake.end().succeeded)
        XCTAssertTrue(awake.isActive)
        // A new helper (after a crash) finds it and finishes the job.
        pmset.refuse = []
        let next = controller(pmset)
        XCTAssertTrue(next.isActive)
        XCTAssertTrue(next.end().succeeded)
        XCTAssertFalse(pmset.sleepDisabled)
    }

    func testResumesOnlyTheProcessesItPaused() {
        let pmset = FakePMSet()
        let processes = FakeProcesses()
        processes.alive = [100: (10, 501), 101: (11, 501), 102: (12, 0)]
        let awake = controller(pmset, processes)
        _ = awake.begin(until: clock.addingTimeInterval(3600))
        let list = [PausedProcess(pid: 100, startTime: 10, uid: 501),
                    PausedProcess(pid: 101, startTime: 11, uid: 501),
                    PausedProcess(pid: 102, startTime: 12, uid: 501),   // root's: refused
                    PausedProcess(pid: 103, startTime: 13, uid: 501)]   // gone
        _ = awake.setPaused(list, ownedBy: 501)
        XCTAssertEqual(awake.journal?.paused.map(\.pid), [100, 101])
        processes.alive[101] = (99, 501)  // the pid went to another process meanwhile
        XCTAssertEqual(awake.resumePaused(), 1)
        XCTAssertEqual(processes.signals.map(\.1), [100])
        XCTAssertEqual(processes.signals.map(\.0), [SIGCONT])
        XCTAssertEqual(awake.journal?.paused, [])
    }

    func testParsesRealPMSetOutput() {
        let g = """
        System-wide power settings:
         SleepDisabled\t\t1
        Currently in use:
         standby              1
         lowpowermode         0
        """
        XCTAssertEqual(PMSetOutput.sleepDisabled(g), true)
        let custom = """
        Battery Power:
         Sleep On Power Button 1
         lowpowermode         1
         sleep                1
        AC Power:
         Sleep On Power Button 1
         lowpowermode         0
        """
        let modes = PMSetOutput.lowPowerModes(custom)
        XCTAssertEqual(modes.battery, 1)
        XCTAssertEqual(modes.ac, 0)
        XCTAssertNil(PMSetOutput.sleepDisabled("nothing here"))
    }
}
