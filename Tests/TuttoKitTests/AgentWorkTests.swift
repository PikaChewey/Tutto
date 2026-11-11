import XCTest
@testable import TuttoKit

final class AgentWorkTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testStartsThenExtendsItsOwnSession() {
        var gate = AgentGate(grace: 600)
        XCTAssertEqual(gate.activity(at: t0, session: false, ours: false), .start)
        XCTAssertEqual(gate.end(after: t0), t0.addingTimeInterval(600))
        XCTAssertEqual(gate.activity(at: t0.addingTimeInterval(120), session: true, ours: true), .extend)
        XCTAssertEqual(gate.end(after: t0.addingTimeInterval(130)), t0.addingTimeInterval(720), "the grace counts from the last sign of work")
    }

    func testLeavesASessionStartedByHandAlone() {
        var gate = AgentGate(grace: 600)
        XCTAssertEqual(gate.activity(at: t0, session: true, ours: false), .nothing)
    }

    func testEndedByHandStaysOffUntilQuiet() {
        var gate = AgentGate(grace: 600)
        _ = gate.activity(at: t0, session: false, ours: false)
        gate.endedByHand()
        XCTAssertEqual(gate.activity(at: t0.addingTimeInterval(30), session: false, ours: false), .nothing)
        XCTAssertEqual(gate.activity(at: t0.addingTimeInterval(400), session: false, ours: false), .nothing, "still working: stays off")
        // Quiet for the whole grace, then work again: on again.
        XCTAssertEqual(gate.activity(at: t0.addingTimeInterval(400 + 601), session: false, ours: false), .start)
        XCTAssertFalse(gate.heldOff)
    }

    func testToolsBusyCountsOnlyWhatAgentsStarted() {
        // 100 = agent (claude), 101 = a build it started, 102 = the build's compiler,
        // 200 = an unrelated app, 103 = an idle helper under the agent.
        let parents: [Int32: Int32] = [100: 50, 101: 100, 102: 101, 103: 100, 200: 1, 50: 1]
        let names: [Int32: String] = [100: "claude", 101: "zsh", 102: "swift-frontend", 103: "node", 200: "Safari", 50: "login"]
        let elapsed: UInt64 = 60_000
        // The agent itself busy, an unrelated app busy: not tools.
        XCTAssertFalse(AgentWork.toolsBusy(cpu: [100: 30_000, 200: 60_000], parents: parents, names: names, elapsed: elapsed))
        // An idle helper under the agent: under the 5 % line.
        XCTAssertFalse(AgentWork.toolsBusy(cpu: [103: 600], parents: parents, names: names, elapsed: elapsed))
        // The compiler two levels down using most of a core: busy.
        XCTAssertTrue(AgentWork.toolsBusy(cpu: [102: 50_000], parents: parents, names: names, elapsed: elapsed))
        XCTAssertFalse(AgentWork.toolsBusy(cpu: [102: 50_000], parents: parents, names: names, elapsed: 0))
    }

    func testOldStayAwakeSettingsGetTheNewOptions() throws {
        let old = #"{"lowPowerBelow":30,"endBelow":5}"#.data(using: .utf8)!
        let policy = try JSONDecoder().decode(AwakePolicy.self, from: old)
        XCTAssertEqual(policy.lowPowerBelow, 30)
        XCTAssertTrue(policy.whileAgentsWork)
        XCTAssertEqual(policy.agentQuietMinutes, 10)
        XCTAssertTrue(policy.muteWhenClosed)
    }

    func testToolsAreEverythingUnderAnAgentButAgents() {
        // 100 claude → 101 zsh → 102 swift-frontend; 100 → 103 node; 100 → 104 claude (a subagent) → 105 git;
        // 200 Safari (not under an agent).
        let parents: [Int32: Int32] = [100: 50, 101: 100, 102: 101, 103: 100, 104: 100, 105: 104, 200: 1, 50: 1]
        let names: [Int32: String] = [100: "claude", 101: "zsh", 102: "swift-frontend", 103: "node", 104: "claude", 105: "git", 200: "Safari", 50: "login"]
        XCTAssertEqual(AgentWork.tools(parents: parents, names: names), [101, 102, 103, 105])
        XCTAssertEqual(AgentWork.tools(parents: [1: 0, 2: 1], names: [1: "launchd", 2: "zsh"]), [])
    }

    func testProcessSnapshotReadsNamesAndParents() {
        let snapshot = ProcessTree.snapshot()
        let me = snapshot[getpid()]
        XCTAssertNotNil(me)
        XCTAssertEqual(me?.parent, getppid())
        XCTAssertFalse(me?.name.isEmpty ?? true)
        XCTAssertGreaterThan(snapshot.count, 5)
    }

    func testPowerSourceReadIsConsistent() {
        let power = PowerSourceNow.read()
        if let charge = power.charge { XCTAssertTrue((0...100).contains(charge)) }
        if power.onBattery { XCTAssertNotNil(power.charge, "on battery means there's a battery to read") }
    }
}
