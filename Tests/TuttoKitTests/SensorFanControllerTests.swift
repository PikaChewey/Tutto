import XCTest
@testable import TuttoKit

/// An in-memory SMC. Writes only land when the key exists, the size matches and the
/// fake is "privileged"; every attempt is recorded.
final class FakeSMC: SMCAccess {
    var values: [String: SMCRawValue]
    private(set) var writes: [(key: String, bytes: [UInt8])] = []
    var privileged = true
    /// M3/M4 firmware: mode = 1 is refused until Ftst = 1.
    var requiresUnlock = false
    /// Optional per-key failure injection.
    var failingKeys: Set<String> = []

    init(_ values: [String: SMCRawValue]) { self.values = values }

    func read(_ key: String) -> SMCRawValue? { values[key] }

    func write(_ key: String, _ bytes: [UInt8]) -> Int32 {
        writes.append((key, bytes))
        guard privileged else { return FanStatus.notPrivileged }
        guard var value = values[key] else { return FanStatus.notFound }
        guard value.bytes.count == bytes.count else { return FanStatus.badArgument }
        if failingKeys.contains(key) { return FanStatus.error }
        let isModeKey = key.hasSuffix("md") || key.hasSuffix("Md")
        if requiresUnlock, isModeKey, bytes.first == 1, values["Ftst"]?.bytes.first != 1 { return FanStatus.error }
        value.bytes = bytes
        values[key] = value
        return FanStatus.success
    }

    var writtenKeys: [String] { writes.map(\.key) }
    func clearLog() { writes.removeAll() }

    static func flt(_ value: Float) -> SMCRawValue {
        SMCRawValue(type: "flt ", bytes: withUnsafeBytes(of: value.bitPattern.littleEndian) { Array($0) })
    }
    static func ui8(_ value: UInt8) -> SMCRawValue { SMCRawValue(type: "ui8 ", bytes: [value]) }
    static func fpe2(_ value: Double) -> SMCRawValue {
        let raw = UInt16(value * 4)
        return SMCRawValue(type: "fpe2", bytes: [UInt8(raw >> 8), UInt8(raw & 0xff)])
    }

    /// The MacBook Pro 14" M5 as probed: one fan, lowercase mode key, no Ftst, fan stopped.
    static func m5() -> FakeSMC {
        FakeSMC(["FNum": ui8(1), "F0Ac": flt(0), "F0Mn": flt(2317), "F0Mx": flt(6550), "F0Tg": flt(0), "F0md": ui8(0)])
    }

    /// An M3/M4-style Mac: Ftst gate in front of the mode key.
    static func m4() -> FakeSMC {
        let smc = FakeSMC(["FNum": ui8(1), "F0Ac": flt(1200), "F0Mn": flt(1200), "F0Mx": flt(5800), "F0Tg": flt(1200),
                           "F0md": ui8(0), "Ftst": ui8(0)])
        smc.requiresUnlock = true
        return smc
    }

    /// A T2 Intel Mac: uppercase mode key and fpe2 speeds.
    static func intel() -> FakeSMC {
        FakeSMC(["FNum": ui8(2), "F0Ac": fpe2(1800), "F0Mn": fpe2(1200), "F0Mx": fpe2(5600), "F0Tg": fpe2(1800),
                 "F0Md": ui8(0), "F1Ac": fpe2(1800), "F1Mn": fpe2(1200), "F1Mx": fpe2(5600), "F1Tg": fpe2(1800),
                 "F1Md": ui8(0)])
    }
}

final class SensorFanControllerTests: XCTestCase {
    private func noPause(_: TimeInterval) {}

    func testM5ManualWritesModeThenTarget() {
        let smc = FakeSMC.m5()
        let controller = FanController(smc: smc, pause: noPause)
        let result = controller.setFan(0, mode: 1, rpm: 3000)
        XCTAssertEqual(result, .ok)
        XCTAssertEqual(smc.writtenKeys, ["F0md", "F0Tg"])
        XCTAssertEqual(smc.values["F0md"], FakeSMC.ui8(1))
        XCTAssertEqual(smc.values["F0Tg"]?.doubleValue, 3000)
        XCTAssertEqual(controller.manualFans, [0])
        XCTAssertFalse(controller.allAutomatic)
    }

    func testTargetIsClampedToSMCRange() {
        let cases: [(Double, Double)] = [(10_000, 6550), (100, 2317), (-.infinity, 2317), (.infinity, 6550), (4000.5, 4000.5)]
        for (requested, expected) in cases {
            let smc = FakeSMC.m5()
            let result = FanController(smc: smc, pause: noPause).setFan(0, mode: 1, rpm: requested)
            XCTAssertEqual(result.status, FanStatus.success, "\(requested)")
            XCTAssertEqual(smc.values["F0Tg"]?.doubleValue, expected, "\(requested)")
        }
    }

    func testRejectsBadArgumentsWithoutWriting() {
        let smc = FakeSMC.m5()
        let controller = FanController(smc: smc, pause: noPause)
        XCTAssertEqual(controller.setFan(0, mode: 1, rpm: .nan).status, FanStatus.badArgument)
        XCTAssertEqual(controller.setFan(1, mode: 1, rpm: 3000).status, FanStatus.badArgument)
        XCTAssertEqual(controller.setFan(-1, mode: 0, rpm: 0).status, FanStatus.badArgument)
        XCTAssertEqual(controller.setFan(0, mode: 2, rpm: 3000).status, FanStatus.badArgument)
        XCTAssertTrue(smc.writes.isEmpty)
    }

    func testAutomaticAfterManualClearsModeAndTarget() {
        let smc = FakeSMC.m5()
        let controller = FanController(smc: smc, pause: noPause)
        _ = controller.setFan(0, mode: 1, rpm: 5000)
        smc.clearLog()
        XCTAssertEqual(controller.setFan(0, mode: 0, rpm: 0), .ok)
        XCTAssertEqual(smc.writtenKeys, ["F0md", "F0Tg"])
        XCTAssertEqual(smc.values["F0md"], FakeSMC.ui8(0))
        XCTAssertEqual(smc.values["F0Tg"]?.doubleValue, 0)
        XCTAssertTrue(controller.allAutomatic)
    }

    func testAutomaticWhenAlreadyAutomaticWritesNothing() {
        let smc = FakeSMC.m5()
        let controller = FanController(smc: smc, pause: noPause)
        XCTAssertEqual(controller.setFan(0, mode: 0, rpm: 0), .ok)
        XCTAssertEqual(controller.resetAll(), FanStatus.success)
        XCTAssertTrue(smc.writes.isEmpty)
    }

    func testSystemModeThreeCountsAsAutomatic() {
        let smc = FakeSMC.m5()
        smc.values["F0md"] = FakeSMC.ui8(3)
        let controller = FanController(smc: smc, pause: noPause)
        XCTAssertTrue(controller.allAutomatic)
        XCTAssertEqual(controller.resetAll(), FanStatus.success)
        XCTAssertTrue(smc.writes.isEmpty)
    }

    func testResetAllRestoresFanLeftManualBySomeoneElse() {
        let smc = FakeSMC.m5()
        smc.values["F0md"] = FakeSMC.ui8(1)
        smc.values["F0Tg"] = FakeSMC.flt(6000)
        let controller = FanController(smc: smc, pause: noPause)
        XCTAssertFalse(controller.allAutomatic)
        XCTAssertEqual(controller.resetAll(), FanStatus.success)
        XCTAssertEqual(smc.values["F0md"], FakeSMC.ui8(0))
        XCTAssertEqual(smc.values["F0Tg"]?.doubleValue, 0)
        XCTAssertTrue(controller.allAutomatic)
    }

    func testFtstUnlockSequenceOnM4StyleFirmware() {
        let smc = FakeSMC.m4()
        var pauses: [TimeInterval] = []
        let controller = FanController(smc: smc, pause: { pauses.append($0) })
        XCTAssertEqual(controller.setFan(0, mode: 1, rpm: 4000), .ok)
        XCTAssertEqual(smc.writtenKeys, ["F0md", "Ftst", "F0md", "F0Tg"])
        XCTAssertEqual(pauses, [3])
        XCTAssertEqual(smc.values["Ftst"], FakeSMC.ui8(1))

        smc.clearLog()
        XCTAssertEqual(controller.resetAll(), FanStatus.success)
        XCTAssertEqual(smc.writtenKeys, ["F0md", "F0Tg", "Ftst"])
        XCTAssertEqual(smc.values["Ftst"], FakeSMC.ui8(0))
        XCTAssertEqual(smc.values["F0md"], FakeSMC.ui8(0))
    }

    func testFtstIsNeverWrittenWhenAbsent() {
        let smc = FakeSMC.m5()
        smc.failingKeys = ["F0md"]
        let result = FanController(smc: smc, pause: noPause).setFan(0, mode: 1, rpm: 3000)
        XCTAssertEqual(result.status, FanStatus.error)
        XCTAssertFalse(smc.writtenKeys.contains("Ftst"))
        XCTAssertFalse(smc.writtenKeys.contains("F0Tg"))
    }

    func testNonRootFailsFastWithNotPrivileged() {
        let smc = FakeSMC.m4()
        smc.privileged = false
        var pauses = 0
        let result = FanController(smc: smc, pause: { _ in pauses += 1 }).setFan(0, mode: 1, rpm: 3000)
        XCTAssertEqual(result.status, FanStatus.notPrivileged)
        XCTAssertNotNil(result.message)
        XCTAssertEqual(smc.writtenKeys, ["F0md"], "no Ftst unlock or retries once root is known to be missing")
        XCTAssertEqual(pauses, 0)
    }

    func testFailedTargetWriteRollsBackToAutomatic() {
        let smc = FakeSMC.m5()
        smc.failingKeys = ["F0Tg"]
        let controller = FanController(smc: smc, pause: noPause)
        let result = controller.setFan(0, mode: 1, rpm: 3000)
        XCTAssertEqual(result.status, FanStatus.error)
        XCTAssertEqual(smc.values["F0md"], FakeSMC.ui8(0))
        XCTAssertTrue(controller.manualFans.isEmpty)
    }

    func testIntelUsesUppercaseModeKeyAndFpe2Target() {
        let smc = FakeSMC.intel()
        let controller = FanController(smc: smc, pause: noPause)
        XCTAssertEqual(controller.setFan(1, mode: 1, rpm: 3000), .ok)
        XCTAssertEqual(smc.writtenKeys, ["F1Md", "F1Tg"])
        XCTAssertEqual(smc.values["F1Tg"]?.bytes, [0x2e, 0xe0])  // 3000 × 4 = 0x2ee0
        smc.clearLog()
        XCTAssertEqual(controller.resetAll(), FanStatus.success)
        XCTAssertEqual(smc.writtenKeys, ["F1Md"], "Intel targets are left to the SMC")
    }
}
