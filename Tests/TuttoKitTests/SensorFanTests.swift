import XCTest
@testable import TuttoKit

final class SensorFanTests: XCTestCase {
    // MARK: Real hardware (read-only)

    func testReadsFansOnThisMac() {
        let fans = Fans.read()
        XCTAssertGreaterThanOrEqual(fans.count, 0)
        XCTAssertEqual(fans.count, Fans.count)
        for fan in fans {
            XCTAssertGreaterThan(fan.minRPM, 0)
            XCTAssertLessThan(fan.minRPM, fan.maxRPM)
            XCTAssertGreaterThanOrEqual(fan.currentRPM, 0)
            XCTAssertLessThan(fan.currentRPM, fan.maxRPM * 1.5)
            XCTAssertNotNil(Fans.modeKey(for: fan.index), "Apple silicon and T2 Macs have a per-fan mode key")
        }
        // On the M5 MacBook Pro this prints: [fan 0: 0 rpm, 2317–6550, target 0, auto]
        print("fans:", fans.map { "fan \($0.index): \(Int($0.currentRPM)) rpm, \(Int($0.minRPM))–\(Int($0.maxRPM)), "
            + "target \($0.targetRPM.map { String(Int($0)) } ?? "–"), \($0.mode.rawValue)" })
    }

    // MARK: Fans.read with a fake SMC

    func testReadsM5LayoutFromFake() {
        let fans = Fans.read(using: FakeSMC.m5())
        XCTAssertEqual(fans, [FanReading(index: 0, currentRPM: 0, minRPM: 2317, maxRPM: 6550, targetRPM: 0, mode: .auto)])
        XCTAssertTrue(fans[0].isStopped)
        XCTAssertEqual(fans[0].fractionOfRange, 0)
    }

    func testReadsManualModeAndIntelForcedBits() {
        let m5 = FakeSMC.m5()
        m5.values["F0md"] = FakeSMC.ui8(1)
        XCTAssertEqual(Fans.read(using: m5).first?.mode, .manual)

        let intel = FakeSMC.intel()
        intel.values["F1Md"] = nil
        intel.values["F0Md"] = nil
        intel.values["FS! "] = SMCRawValue(type: "ui16", bytes: [0x00, 0x02])  // fan 1 forced
        XCTAssertEqual(Fans.read(using: intel).map(\.mode), [.auto, .manual])
        XCTAssertEqual(Fans.read(using: intel).first?.minRPM, 1200)
    }

    func testFanlessMacReadsNothing() {
        XCTAssertTrue(Fans.read(using: FakeSMC(["FNum": FakeSMC.ui8(0)])).isEmpty)
        XCTAssertTrue(Fans.read(using: FakeSMC([:])).isEmpty)
    }

    func testFanModeMapping() {
        XCTAssertEqual(FanMode(smcMode: 0), .auto)
        XCTAssertEqual(FanMode(smcMode: 1), .manual)
        XCTAssertEqual(FanMode(smcMode: 3), .auto)
        XCTAssertEqual(FanMode(smcMode: 7), .unknown)
        XCTAssertEqual(FanMode(smcMode: nil), .unknown)
    }

    // MARK: Mode key detection

    func testModeKeyDetection() {
        func key(_ fan: Int, _ existing: Set<String>) -> String? { FanSMC.modeKey(for: fan, keyExists: existing.contains) }
        XCTAssertEqual(key(0, ["F0md"]), "F0md")
        XCTAssertEqual(key(0, ["F0Md"]), "F0Md")
        XCTAssertEqual(key(0, ["F0md", "F0Md"]), "F0md", "lowercase wins when both exist")
        XCTAssertNil(key(0, []))
        XCTAssertNil(key(0, ["F1md"]))
        XCTAssertEqual(key(1, ["F0md", "F1Md"]), "F1Md")
        XCTAssertNil(key(10, ["F10md"]), "fan keys have one digit")
        XCTAssertNil(key(-1, ["F-1md"]))
    }

    func testModeKeyOnThisMac() throws {
        guard Fans.count > 0 else { throw XCTSkip("no fans") }
        let key = try XCTUnwrap(Fans.modeKey(for: 0))
        XCTAssertTrue(["F0md", "F0Md"].contains(key))
    }

    // MARK: Encoding

    func testFloatEncodingIsLittleEndianAndRoundTrips() throws {
        XCTAssertEqual(FanSMC.encode(rpm: 2317, type: "flt ", size: 4), [0x00, 0xd0, 0x10, 0x45])  // 0x4510d000
        for rpm in [0, 1, 2317, 3000.5, 6550, 12345.25] {
            let bytes = try XCTUnwrap(FanSMC.encode(rpm: rpm, type: "flt ", size: 4))
            let raw = SMCRawValue(type: "flt ", bytes: bytes)
            XCTAssertEqual(raw.doubleValue, rpm, "Swift decoder")
            XCTAssertEqual(SMCDevice.decodeWithCBridge(raw), rpm, "C decoder (TSMCValueAsDouble)")
        }
    }

    func testFpe2EncodingRoundTrips() throws {
        XCTAssertEqual(FanSMC.encode(rpm: 3000, type: "fpe2", size: 2), [0x2e, 0xe0])
        for rpm in [0, 1200, 3000.25, 5600.75] {
            let bytes = try XCTUnwrap(FanSMC.encode(rpm: rpm, type: "fpe2", size: 2))
            let raw = SMCRawValue(type: "fpe2", bytes: bytes)
            XCTAssertEqual(raw.doubleValue, rpm)
            XCTAssertEqual(SMCDevice.decodeWithCBridge(raw), rpm)
        }
    }

    func testEncodingRejectsBadInput() {
        XCTAssertNil(FanSMC.encode(rpm: .nan, type: "flt ", size: 4))
        XCTAssertNil(FanSMC.encode(rpm: .infinity, type: "flt ", size: 4))
        XCTAssertNil(FanSMC.encode(rpm: -1, type: "flt ", size: 4))
        XCTAssertNil(FanSMC.encode(rpm: 3000, type: "flt ", size: 2))
        XCTAssertNil(FanSMC.encode(rpm: 3000, type: "ui16", size: 2))
        XCTAssertNil(FanSMC.encode(rpm: 20000, type: "fpe2", size: 2))
    }

    func testSwiftDecoderMatchesCDecoder() {
        let samples: [SMCRawValue] = [
            SMCRawValue(type: "ui8 ", bytes: [7]),
            SMCRawValue(type: "ui16", bytes: [0x96, 0x00]),
            SMCRawValue(type: "ui32", bytes: [0, 0, 0x0a, 0xda]),
            SMCRawValue(type: "sp78", bytes: [0x2e, 0x80]),
            SMCRawValue(type: "sp78", bytes: [0xff, 0x00]),
            SMCRawValue(type: "si8 ", bytes: [0xfe]),
            SMCRawValue(type: "si16", bytes: [0xff, 0xfe]),
            SMCRawValue(type: "fpe2", bytes: [0x24, 0x34]),
            FakeSMC.flt(57.4),
        ]
        for sample in samples {
            XCTAssertEqual(sample.doubleValue, SMCDevice.decodeWithCBridge(sample), sample.type)
        }
        XCTAssertNil(SMCRawValue(type: "hex_", bytes: [1]).doubleValue)
        XCTAssertNil(FakeSMC.flt(.nan).doubleValue)
    }

    // MARK: FanCommand

    func testClampingHelper() {
        XCTAssertEqual(FanSMC.clamp(9000, minimum: 2317, maximum: 6550), 6550)
        XCTAssertEqual(FanSMC.clamp(0, minimum: 2317, maximum: 6550), 2317)
        XCTAssertEqual(FanSMC.clamp(3000, minimum: 2317, maximum: 6550), 3000)
        XCTAssertNil(FanSMC.clamp(.nan, minimum: 2317, maximum: 6550))
        XCTAssertNil(FanSMC.clamp(3000, minimum: 6550, maximum: 2317))
    }

    func testFanCommandClamping() {
        let fan = FanReading(index: 0, currentRPM: 0, minRPM: 2317, maxRPM: 6550, targetRPM: 0, mode: .auto)
        XCTAssertEqual(FanCommand.rpm(9000).clamped(for: fan), .rpm(6550))
        XCTAssertEqual(FanCommand.rpm(1000).clamped(for: fan), .rpm(2317))
        XCTAssertEqual(FanCommand.rpm(4200).clamped(for: fan), .rpm(4200))
        XCTAssertEqual(FanCommand.rpm(.nan).clamped(for: fan), .auto, "invalid speeds fall back to automatic")
        XCTAssertEqual(FanCommand.rpm(3000).clamped(minRPM: 0, maxRPM: 0), .auto, "no usable range")
        XCTAssertEqual(FanCommand.auto.clamped(for: fan), .auto)
        XCTAssertEqual(FanCommand.maximum.clamped(for: fan), .maximum)
    }

    func testFanCommandHelperArguments() {
        let fan = FanReading(index: 0, currentRPM: 0, minRPM: 2317, maxRPM: 6550, targetRPM: 0, mode: .auto)
        XCTAssertTrue(FanCommand.auto.helperArguments(for: fan) == (0, 0))
        XCTAssertTrue(FanCommand.maximum.helperArguments(for: fan) == (1, 6550))
        XCTAssertTrue(FanCommand.rpm(100).helperArguments(for: fan) == (1, 2317))
        XCTAssertTrue(FanCommand.rpm(5000).helperArguments(for: fan) == (1, 5000))
    }

    func testFanCommandCodableRoundTrip() throws {
        for command in [FanCommand.auto, .rpm(3456.5), .maximum] {
            let data = try JSONEncoder().encode(command)
            XCTAssertEqual(try JSONDecoder().decode(FanCommand.self, from: data), command)
        }
    }
}
