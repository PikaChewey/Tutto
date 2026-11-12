import XCTest
@testable import TuttoKit

final class BluetoothBatteriesTests: XCTestCase {
    func testLevelsParseFromNumbersAndText() {
        XCTAssertEqual(BluetoothBatteryRules.level(from: NSNumber(value: 64), zeroMeansUnknown: true), 64)
        XCTAssertEqual(BluetoothBatteryRules.level(from: "80%", zeroMeansUnknown: true), 80)
        XCTAssertEqual(BluetoothBatteryRules.level(from: " 55 % ", zeroMeansUnknown: true), 55)
        XCTAssertNil(BluetoothBatteryRules.level(from: nil, zeroMeansUnknown: true))
        XCTAssertNil(BluetoothBatteryRules.level(from: "full", zeroMeansUnknown: true))
        XCTAssertNil(BluetoothBatteryRules.level(from: NSNumber(value: 101), zeroMeansUnknown: false), "not a percentage")
        XCTAssertNil(BluetoothBatteryRules.level(from: NSNumber(value: -1), zeroMeansUnknown: false))
        XCTAssertNil(BluetoothBatteryRules.level(from: NSNumber(value: true), zeroMeansUnknown: false), "a Bool is not a level")
    }

    func testZeroIsUnknownOnlyWhereTheSourceSaysSo() {
        XCTAssertNil(BluetoothBatteryRules.level(from: NSNumber(value: 0), zeroMeansUnknown: true))
        XCTAssertEqual(BluetoothBatteryRules.level(from: NSNumber(value: 0), zeroMeansUnknown: false), 0)
        let dead = BluetoothBatteryRules.hidDevice(["Product": "Magic Mouse", "BatteryPercent": 0])
        XCTAssertEqual(dead?.levels.single, 0, "an empty mouse is a reading")
    }

    func testEarbudsReadLeftRightAndCase() throws {
        let device = try XCTUnwrap(BluetoothBatteryRules.audioDevice(
            name: "Bryan's AirPods Pro", address: "AA-BB-CC-DD-EE-FF", majorClass: 4, minorClass: 6,
            values: ["batteryPercentLeft": 80, "batteryPercentRight": 82, "batteryPercentCase": 50,
                     "batteryPercentSingle": 0]))
        XCTAssertEqual(device.levels, BluetoothBatteryLevels(left: 80, right: 82, caseLevel: 50))
        XCTAssertEqual(device.kind, .headphones)
        XCTAssertEqual(device.id, "aabbccddeeff")
        XCTAssertEqual(device.text, "L 80 % · R 82 % · Case 50 %")
    }

    func testAbsentValuesMeanNoDevice() {
        XCTAssertNil(BluetoothBatteryRules.audioDevice(name: "Speaker", address: nil, majorClass: 4, minorClass: 0, values: [:]))
        XCTAssertNil(BluetoothBatteryRules.audioDevice(name: "Speaker", address: nil, majorClass: 4, minorClass: 0,
                                                        values: ["batteryPercentSingle": 0]))
        XCTAssertNil(BluetoothBatteryRules.hidDevice(["Product": "Apple Internal Keyboard / Trackpad"]), "no BatteryPercent")
    }

    func testACombinedFigureIsUsedWhenNothingElseIs() {
        let levels = BluetoothBatteryRules.audioLevels(["batteryPercentCombined": 70])
        XCTAssertEqual(levels, BluetoothBatteryLevels(single: 70))
        let both = BluetoothBatteryRules.audioLevels(["batteryPercentCombined": 70, "batteryPercentLeft": 60])
        XCTAssertNil(both.single, "the parts win over the combined figure")
    }

    func testKinds() {
        XCTAssertEqual(BluetoothBatteryRules.kind(name: "Magic Keyboard with Touch ID", majorClass: nil, minorClass: nil), .keyboard)
        XCTAssertEqual(BluetoothBatteryRules.kind(name: "Magic Mouse", majorClass: nil, minorClass: nil), .mouse)
        XCTAssertEqual(BluetoothBatteryRules.kind(name: "Magic Trackpad", majorClass: 5, minorClass: 0x20), .trackpad, "the name wins")
        XCTAssertEqual(BluetoothBatteryRules.kind(name: "AirPods Max", majorClass: nil, minorClass: nil), .headphones)
        XCTAssertEqual(BluetoothBatteryRules.kind(name: "Bryan's iPhone", majorClass: 4, minorClass: 1), .headphones, "audio class")
        XCTAssertEqual(BluetoothBatteryRules.kind(name: "K380", majorClass: 5, minorClass: 0x10), .keyboard)
        XCTAssertEqual(BluetoothBatteryRules.kind(name: "MX", majorClass: 5, minorClass: 0x20), .mouse)
        XCTAssertEqual(BluetoothBatteryRules.kind(name: "Pad", majorClass: 5, minorClass: 0x25), .trackpad)
        XCTAssertEqual(BluetoothBatteryRules.kind(name: "Controller", majorClass: 5, minorClass: 0x08), .other)
        XCTAssertEqual(BluetoothBatteryRules.kind(name: "Thing", majorClass: nil, minorClass: nil), .other)
    }

    func testEveryKindHasASymbol() {
        let symbols = BluetoothDeviceKind.allCases.map(\.symbol)
        XCTAssertEqual(Set(symbols).count, symbols.count, "each kind looks different")
        XCTAssertEqual(BluetoothDeviceKind.headphones.symbol, "headphones")
        XCTAssertEqual(BluetoothDeviceKind.keyboard.symbol, "keyboard")
        XCTAssertEqual(BluetoothDeviceKind.mouse.symbol, "computermouse")
    }

    func testFormatting() {
        XCTAssertEqual(BluetoothBatteryRules.text(BluetoothBatteryLevels(single: 64)), "64 %")
        XCTAssertEqual(BluetoothBatteryRules.text(BluetoothBatteryLevels(left: 80, right: 82)), "L 80 % · R 82 %")
        XCTAssertEqual(BluetoothBatteryRules.text(BluetoothBatteryLevels(left: 80, caseLevel: 5)), "L 80 % · Case 5 %")
        XCTAssertEqual(BluetoothBatteryRules.text(BluetoothBatteryLevels(single: 64, caseLevel: 50)), "64 % · Case 50 %")
        XCTAssertEqual(BluetoothBatteryRules.text(BluetoothBatteryLevels()), "")
        XCTAssertEqual(BluetoothBatteryRules.spoken(BluetoothBatteryLevels(left: 80, right: 82, caseLevel: 50)),
                       "left 80 percent, right 82 percent, case 50 percent")
        XCTAssertEqual(BluetoothBatteryRules.spoken(BluetoothBatteryLevels(single: 64)), "64 percent")
    }

    func testLowIsTwentyOrUnder() {
        XCTAssertTrue(BluetoothBatteryRules.isLow(20))
        XCTAssertTrue(BluetoothBatteryRules.isLow(0))
        XCTAssertFalse(BluetoothBatteryRules.isLow(21))
        let parts = BluetoothBatteryRules.parts(BluetoothBatteryLevels(left: 18, right: 82, caseLevel: 20))
        XCTAssertEqual(parts.map(\.isLow), [true, false, true], "each level on its own")
        let device = BluetoothBatteryDevice(id: "x", name: "Buds", kind: .headphones, levels: BluetoothBatteryLevels(left: 18, right: 82))
        XCTAssertTrue(device.isLow)
        XCTAssertEqual(BluetoothBatteryLevels(left: 18, right: 82).lowest, 18)
    }

    func testMergeJoinsTheSameDeviceFromBothSources() {
        let audio = BluetoothBatteryDevice(id: "aabbccddeeff", name: "Magic Keyboard", kind: .other, levels: BluetoothBatteryLevels())
        let hid = BluetoothBatteryRules.hidDevice(["Product": "Magic Keyboard", "BatteryPercent": 71, "DeviceAddress": "aa-bb-cc-dd-ee-ff"])!
        let merged = BluetoothBatteryRules.merge([[audio], [hid]])
        XCTAssertEqual(merged.count, 1, "no level in the first, so it isn't listed on its own; the second is")
        XCTAssertEqual(merged[0].levels.single, 71)
        XCTAssertEqual(merged[0].kind, .keyboard)

        let first = BluetoothBatteryDevice(id: "aabbccddeeff", name: "Buds", kind: .other, levels: BluetoothBatteryLevels(left: 40))
        let second = BluetoothBatteryDevice(id: "aabbccddeeff", name: "Buds", kind: .headphones, levels: BluetoothBatteryLevels(left: 99, right: 41))
        let both = BluetoothBatteryRules.merge([[first], [second]])
        XCTAssertEqual(both.count, 1)
        XCTAssertEqual(both[0].levels, BluetoothBatteryLevels(left: 40, right: 41), "the first source wins where both report")
        XCTAssertEqual(both[0].kind, .headphones)
    }

    func testMergeSortsAndDropsEmptyOnes() {
        func device(_ name: String, _ kind: BluetoothDeviceKind, _ level: Int?) -> BluetoothBatteryDevice {
            BluetoothBatteryDevice(id: name.lowercased(), name: name, kind: kind, levels: BluetoothBatteryLevels(single: level))
        }
        let merged = BluetoothBatteryRules.merge([
            [device("Magic Mouse", .mouse, 90), device("Zed Keyboard", .keyboard, 40), device("Ghost", .other, nil)],
            [device("AirPods", .headphones, 60), device("Alpha Keyboard", .keyboard, 10)],
        ])
        XCTAssertEqual(merged.map(\.name), ["AirPods", "Alpha Keyboard", "Zed Keyboard", "Magic Mouse"])
        XCTAssertTrue(BluetoothBatteryRules.merge([]).isEmpty)
        XCTAssertTrue(BluetoothBatteryRules.merge([[device("Ghost", .other, nil)]]).isEmpty, "nothing to show, no card")
    }

    func testIdentityPrefersTheAddress() {
        XCTAssertEqual(BluetoothBatteryRules.identity(address: "AA:BB:CC:DD:EE:FF", name: "x"), "aabbccddeeff")
        XCTAssertEqual(BluetoothBatteryRules.identity(address: "aa-bb-cc-dd-ee-ff", name: "x"), "aabbccddeeff")
        XCTAssertEqual(BluetoothBatteryRules.identity(address: "nonsense", name: "Magic Mouse"), "magic mouse")
        XCTAssertEqual(BluetoothBatteryRules.identity(address: nil, name: "Magic Mouse"), "magic mouse")
    }

    func testShortNamesDropTheOwner() {
        XCTAssertEqual(BluetoothBatteryRules.shortName("Bryan's AirPods Pro"), "AirPods Pro")
        XCTAssertEqual(BluetoothBatteryRules.shortName("Bryan\u{2019}s Magic Mouse"), "Magic Mouse")
        XCTAssertEqual(BluetoothBatteryRules.shortName("Magic Keyboard"), "Magic Keyboard")
        XCTAssertEqual(BluetoothBatteryRules.shortName("Bryan's "), "Bryan's ", "nothing left to show")
        XCTAssertEqual(BluetoothBatteryRules.shortName("The kitchen's speaker"), "The kitchen's speaker", "not a first name")
    }

    func testANamelessDeviceStillHasALabel() {
        let device = BluetoothBatteryRules.hidDevice(["BatteryPercent": 50])
        XCTAssertEqual(device?.name, "Bluetooth device")
    }

    func testReadingTheRegistryIsHarmless() {
        // Whatever this machine has connected, it returns a list (possibly empty) without throwing.
        for device in HIDBatteryReader.read() {
            XCTAssertFalse(device.levels.isEmpty)
            XCTAssertFalse(device.name.isEmpty)
        }
    }
}
