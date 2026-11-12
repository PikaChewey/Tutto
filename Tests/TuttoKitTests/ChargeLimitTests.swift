import IOKit.ps
import XCTest
@testable import TuttoKit

/// An SMC with the charging keys of a chosen firmware. Records writes; can refuse them.
private final class FakeChargeSMC: SMCAccess {
    var values: [String: SMCRawValue]
    var writes: [(String, [UInt8])] = []
    var refuse: Int32?
    /// Takes the write but keeps the old value (an SMC that ignores it).
    var ignoreWrites = false

    init(_ values: [String: SMCRawValue]) { self.values = values }

    static func newer(inhibited: Bool = false) -> FakeChargeSMC {
        FakeChargeSMC(["CHTE": SMCRawValue(type: "ui32", bytes: [inhibited ? 1 : 0, 0, 0, 0])])
    }

    static func older() -> FakeChargeSMC {
        FakeChargeSMC(["CH0B": SMCRawValue(type: "hex_", bytes: [0]), "CH0C": SMCRawValue(type: "hex_", bytes: [0])])
    }

    func read(_ key: String) -> SMCRawValue? { values[key] }

    func write(_ key: String, _ bytes: [UInt8]) -> Int32 {
        writes.append((key, bytes))
        if let refuse { return refuse }
        guard var value = values[key] else { return FanStatus.notFound }
        if !ignoreWrites {
            value.bytes = bytes
            values[key] = value
        }
        return FanStatus.success
    }
}

private final class FakeClock {
    var now: TimeInterval = 1_000
}

final class ChargeLimitRulesTests: XCTestCase {
    private func decide(_ percent: Int, plugged: Bool = true, limit: Int = 80, topUp: Bool = false, inhibiting: Bool = false)
        -> ChargeLimitRules.Decision {
        ChargeLimitRules.decide(.init(percent: percent, pluggedIn: plugged, limit: limit, topUp: topUp, inhibiting: inhibiting))
    }

    func testStopsAtTheLimit() {
        XCTAssertFalse(decide(60).inhibit)
        XCTAssertFalse(decide(79).inhibit)
        XCTAssertTrue(decide(80).inhibit)
        XCTAssertTrue(decide(95).inhibit, "above the limit it holds rather than charging on")
    }

    func testHysteresisKeepsWhatItWasDoing() {
        // Charging up through the band: keeps charging until the limit.
        for percent in 75...79 { XCTAssertFalse(decide(percent, inhibiting: false).inhibit, "\(percent)") }
        // Held, drifting down through the band: keeps holding.
        for percent in 75...79 { XCTAssertTrue(decide(percent, inhibiting: true).inhibit, "\(percent)") }
        // Below limit − 5 it charges again.
        XCTAssertFalse(decide(74, inhibiting: true).inhibit)
    }

    func testUnpluggedHoldsNothingAndEndsTopUp() {
        let decision = decide(90, plugged: false, topUp: true, inhibiting: true)
        XCTAssertFalse(decision.inhibit)
        XCTAssertFalse(decision.topUp)
    }

    func testTopUpChargesToFullThenClears() {
        let charging = decide(85, topUp: true, inhibiting: true)
        XCTAssertFalse(charging.inhibit)
        XCTAssertTrue(charging.topUp)
        let full = decide(100, topUp: true)
        XCTAssertFalse(full.topUp, "clears itself at 100 %")
        XCTAssertTrue(full.inhibit, "and the limit holds again")
    }

    func testLimitOf100NeverHolds() {
        XCTAssertFalse(decide(100, limit: 100).inhibit)
        XCTAssertFalse(decide(100, limit: 100, inhibiting: true).inhibit)
    }

    func testLevelsSnapToStepsOf5() {
        XCTAssertEqual(ChargeLimitRules.levels.first, 50)
        XCTAssertEqual(ChargeLimitRules.levels.last, 100)
        XCTAssertEqual(ChargeLimitRules.levels.count, 11)
        XCTAssertEqual(ChargeLimitRules.normalize(82), 80)
        XCTAssertEqual(ChargeLimitRules.normalize(83), 85)
        XCTAssertEqual(ChargeLimitRules.normalize(10), 50)
        XCTAssertEqual(ChargeLimitRules.normalize(140), 100)
        // An odd level from settings is treated as its snapped value.
        XCTAssertTrue(decide(80, limit: 79).inhibit)
    }

    func testWords() {
        XCTAssertEqual(ChargeLimitRules.status(percent: 80, pluggedIn: true, charging: false, limit: 80, topUp: false, inhibiting: true),
                       "Holding at 80 %, running on the adapter")
        XCTAssertEqual(ChargeLimitRules.status(percent: 62, pluggedIn: true, charging: true, limit: 80, topUp: false, inhibiting: false),
                       "Charging to 80 %")
        XCTAssertEqual(ChargeLimitRules.status(percent: 62, pluggedIn: false, charging: false, limit: 80, topUp: false, inhibiting: false),
                       "On battery. Charging stops at 80 % when plugged in.")
        XCTAssertEqual(ChargeLimitRules.status(percent: 90, pluggedIn: true, charging: true, limit: 80, topUp: true, inhibiting: false),
                       "Charging to 100 % once, then back to 80 %")
        XCTAssertEqual(ChargeLimitRules.panelNote(percent: 80, pluggedIn: true, topUp: false, inhibiting: true), "Held at 80 %")
        XCTAssertEqual(ChargeLimitRules.panelNote(percent: 90, pluggedIn: true, topUp: true, inhibiting: false), "Charging to 100 % once")
        XCTAssertNil(ChargeLimitRules.panelNote(percent: 62, pluggedIn: true, topUp: false, inhibiting: false))
        XCTAssertNil(ChargeLimitRules.panelNote(percent: 80, pluggedIn: false, topUp: false, inhibiting: true))
    }

    func testReadingParsesTheInternalBattery() {
        let plugged: [String: Any] = [kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSCurrentCapacityKey: 80, kIOPSMaxCapacityKey: 100,
                                      kIOPSPowerSourceStateKey: kIOPSACPowerValue, kIOPSIsChargingKey: false]
        XCTAssertEqual(ChargeReading.parse(plugged), ChargeReading(percent: 80, pluggedIn: true, charging: false))
        let onBattery: [String: Any] = [kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSCurrentCapacityKey: 3_000, kIOPSMaxCapacityKey: 6_000,
                                        kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue]
        XCTAssertEqual(ChargeReading.parse(onBattery), ChargeReading(percent: 50, pluggedIn: false, charging: false))
        XCTAssertNil(ChargeReading.parse([kIOPSTypeKey: "UPS", kIOPSCurrentCapacityKey: 50, kIOPSMaxCapacityKey: 100]))
    }

    /// Read-only: whatever this Mac has, the probe doesn't write and agrees with the key list.
    func testThisMacIsReadNotWritten() {
        let method = ChargeControl.supportedMethod()
        if method == .flag32 { XCTAssertEqual(SMCDevice.shared.read("CHTE")?.bytes.count, 4) }
        if method == nil { XCTAssertFalse(ChargeControl.smcSaysInhibited()) }
    }
}

final class ChargeInhibitorTests: XCTestCase {
    private var journal: URL!

    override func setUp() {
        journal = FileManager.default.temporaryDirectory
            .appendingPathComponent("tutto-charge-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("charge.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: journal.deletingLastPathComponent())
    }

    private func make(_ smc: FakeChargeSMC, clock: FakeClock = FakeClock()) -> ChargeInhibitor {
        ChargeInhibitor(smc: smc, journalURL: journal, clock: { clock.now }, pause: { _ in })
    }

    func testKeyChoiceFollowsWhatExists() {
        XCTAssertEqual(ChargeSMC.method(keyExists: { $0 == "CHTE" }), .flag32)
        XCTAssertEqual(ChargeSMC.method(keyExists: { ["CHTE", "CH0B"].contains($0) }), .flag32, "CHTE wins")
        XCTAssertEqual(ChargeSMC.method(keyExists: { $0 == "CH0B" }), .legacy)
        XCTAssertNil(ChargeSMC.method(keyExists: { $0 == "CH0C" }), "CH0C alone isn't enough")
        XCTAssertNil(ChargeSMC.method(keyExists: { _ in false }))
        XCTAssertEqual(ChargeSMC.keys(for: .legacy, keyExists: { $0 == "CH0B" }), ["CH0B"])
    }

    func testValueFormats() {
        XCTAssertEqual(ChargeSMC.bytes(inhibit: true, method: .flag32, size: 4), [1, 0, 0, 0])
        XCTAssertEqual(ChargeSMC.bytes(inhibit: false, method: .flag32, size: 4), [0, 0, 0, 0])
        XCTAssertNil(ChargeSMC.bytes(inhibit: true, method: .flag32, size: 1))
        XCTAssertEqual(ChargeSMC.bytes(inhibit: true, method: .legacy, size: 1), [0x02])
        XCTAssertEqual(ChargeSMC.bytes(inhibit: false, method: .legacy, size: 1), [0x00])
        XCTAssertTrue(ChargeSMC.isInhibited(SMCRawValue(type: "ui32", bytes: [1, 0, 0, 0])))
        XCTAssertFalse(ChargeSMC.isInhibited(SMCRawValue(type: "ui32", bytes: [0, 0, 0, 0])))
    }

    func testInhibitWritesNewerKeyAndJournals() {
        let smc = FakeChargeSMC.newer()
        let inhibitor = make(smc)
        XCTAssertEqual(inhibitor.inhibit(lease: 90), .ok)
        XCTAssertTrue(inhibitor.isInhibiting)
        XCTAssertEqual(smc.values["CHTE"]?.bytes, [1, 0, 0, 0])
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
        XCTAssertEqual(inhibitor.allow(), .ok)
        XCTAssertEqual(smc.values["CHTE"]?.bytes, [0, 0, 0, 0])
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    }

    func testInhibitWritesBothOlderKeys() {
        let smc = FakeChargeSMC.older()
        let inhibitor = make(smc)
        XCTAssertEqual(inhibitor.inhibit(lease: 90), .ok)
        XCTAssertEqual(smc.values["CH0B"]?.bytes, [0x02])
        XCTAssertEqual(smc.values["CH0C"]?.bytes, [0x02])
        inhibitor.allow()
        XCTAssertEqual(smc.values["CH0B"]?.bytes, [0])
        XCTAssertEqual(smc.values["CH0C"]?.bytes, [0])
    }

    func testRenewalDoesNotRewrite() {
        let smc = FakeChargeSMC.newer()
        let clock = FakeClock()
        let inhibitor = make(smc, clock: clock)
        _ = inhibitor.inhibit(lease: 90)
        clock.now += 60
        _ = inhibitor.inhibit(lease: 90)
        XCTAssertEqual(smc.writes.count, 1, "a renewal only moves the lease")
        XCTAssertEqual(inhibitor.leaseRemaining, 90, accuracy: 0.001)
    }

    func testLeaseRunsOutWithoutRenewal() {
        let smc = FakeChargeSMC.newer()
        let clock = FakeClock()
        let inhibitor = make(smc, clock: clock)
        _ = inhibitor.inhibit(lease: 90)
        clock.now += 89
        XCTAssertFalse(inhibitor.expireLeaseIfDue())
        XCTAssertTrue(inhibitor.isInhibiting)
        clock.now += 1
        XCTAssertTrue(inhibitor.expireLeaseIfDue(), "an app that stops renewing gets charging back")
        XCTAssertFalse(inhibitor.isInhibiting)
        XCTAssertEqual(smc.values["CHTE"]?.bytes, [0, 0, 0, 0])
        XCTAssertFalse(inhibitor.expireLeaseIfDue())
    }

    func testLeaseIsClamped() {
        let clock = FakeClock()
        let inhibitor = make(FakeChargeSMC.newer(), clock: clock)
        _ = inhibitor.inhibit(lease: 86_400)
        XCTAssertEqual(inhibitor.leaseRemaining, ChargeLease.longest, accuracy: 0.001)
        _ = inhibitor.inhibit(lease: .nan)
        XCTAssertEqual(inhibitor.leaseRemaining, ChargeLease.shortest, accuracy: 0.001)
        _ = inhibitor.inhibit(lease: -5)
        XCTAssertEqual(inhibitor.leaseRemaining, ChargeLease.shortest, accuracy: 0.001)
        XCTAssertGreaterThan(ChargeLease.duration, ChargeLease.renewInterval, "one late renewal is tolerated")
    }

    func testRefusedWriteLeavesChargingOn() {
        let smc = FakeChargeSMC.newer()
        smc.refuse = FanStatus.notPrivileged
        let inhibitor = make(smc)
        let result = inhibitor.inhibit(lease: 90)
        XCTAssertEqual(result.status, FanStatus.notPrivileged)
        XCTAssertFalse(inhibitor.isInhibiting)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    }

    func testIgnoredWriteIsAnError() {
        let smc = FakeChargeSMC.newer()
        smc.ignoreWrites = true
        let inhibitor = make(smc)
        XCTAssertEqual(inhibitor.inhibit(lease: 90).status, FanStatus.error)
        XCTAssertFalse(inhibitor.isInhibiting)
    }

    func testNoKeyIsUnsupported() {
        let smc = FakeChargeSMC([:])
        let inhibitor = make(smc)
        XCTAssertEqual(inhibitor.inhibit(lease: 90).status, FanStatus.unsupported)
        XCTAssertTrue(smc.writes.isEmpty)
        XCTAssertEqual(inhibitor.allow(), .ok)
    }

    func testAllowWritesNothingWhenItHoldsNothing() {
        let smc = FakeChargeSMC.newer(inhibited: true)  // something else stopped charging
        let inhibitor = make(smc)
        XCTAssertEqual(inhibitor.allow(), .ok)
        XCTAssertTrue(smc.writes.isEmpty, "only undoes its own hold")
        XCTAssertTrue(inhibitor.smcSaysInhibited)
    }

    func testJournalFromAKilledHelperAllowsChargingAtStart() throws {
        let smc = FakeChargeSMC.newer()
        _ = make(smc).inhibit(lease: 90)  // this helper "dies" holding it
        XCTAssertEqual(smc.values["CHTE"]?.bytes, [1, 0, 0, 0])
        let next = make(smc)
        XCTAssertTrue(next.recoverFromJournal())
        XCTAssertEqual(smc.values["CHTE"]?.bytes, [0, 0, 0, 0])
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
        XCTAssertFalse(make(smc).recoverFromJournal(), "nothing to do the second time")
    }
}
