import XCTest
@testable import TuttoKit

final class SensorTemperatureTests: XCTestCase {
    override class func tearDown() {
        TemperatureSensors.release()
        super.tearDown()
    }

    // MARK: Real hardware (read-only)

    func testReadsPlausibleTemperaturesOnThisMac() throws {
        let readings = TemperatureSensors.read()
        guard !readings.isEmpty else { throw XCTSkip("no temperature sensors visible on this Mac") }
        XCTAssertEqual(Set(readings.map(\.id)).count, readings.count, "ids are unique")
        for reading in readings {
            XCTAssertTrue(TemperatureSensors.plausibleRange.contains(reading.celsius), "\(reading.name) \(reading.celsius)")
            XCTAssertFalse(reading.label.isEmpty)
            XCTAssertGreaterThanOrEqual(reading.sampleCount, 1)
        }
        let summary = readings.summary
        XCTAssertNotNil(summary.headline)
        // Second read reuses the IOHID client and yields the same sensors.
        XCTAssertEqual(Set(TemperatureSensors.read().map(\.id)), Set(readings.map(\.id)))
        print("sensors (\(readings.count)):", readings.map { "\($0.label)=\(String(format: "%.1f", $0.celsius))" }.joined(separator: ", "))
        print("summary:", summary)
        print(TemperatureSensors.mappingDescription)
    }

    func testJunkSensorIsFilteredOnThisMac() throws {
        let raw = TemperatureSensors.rawHIDReadings()
        guard !raw.isEmpty else { throw XCTSkip("no IOHID temperature sensors") }
        let readings = TemperatureSensors.readHID()
        XCTAssertTrue(readings.allSatisfy { TemperatureSensors.isPlausible($0.celsius) })
        // The M5 has a "PMU tdev1" stuck near −9201 °C. A name with only junk values must not surface.
        for (name, entries) in Dictionary(grouping: raw, by: \.name)
        where entries.allSatisfy({ !TemperatureSensors.isPlausible($0.celsius) }) {
            XCTAssertFalse(readings.contains { $0.name == name }, name)
        }
    }

    func testCPUAndGPUFromSMCOnM5() throws {
        guard let chip = TemperatureSensors.currentChip, chip.generation == 5 else { throw XCTSkip("not an M5") }
        let smc = TemperatureSensors.readSMC()
        XCTAssertFalse(smc.filter { $0.group == .cpu }.isEmpty, "documented M5 Tp keys")
        XCTAssertFalse(smc.filter { $0.group == .gpu }.isEmpty, "documented M5 Tg keys")
        XCTAssertTrue(smc.allSatisfy { $0.source == .smc && $0.id.hasPrefix("smc:") })
        XCTAssertTrue(smc.contains { $0.label == "CPU 1" })
        XCTAssertTrue(smc.contains { $0.label == "GPU 1" })
    }

    // MARK: Filtering and deduplication

    func testJunkReadingsAreDropped() {
        let readings = TemperatureSensors.makeHIDReadings([
            ("PMU tdev1", -9201.14), ("PMU tdie1", 57.4), ("PMU tdie2", .nan), ("PMU tdie3", .infinity),
            ("PMU tdie4", 130.5), ("PMU tdie5", -20.5), ("PMU tdie6", 130), ("PMU tdie7", -20), ("", 40),
        ])
        XCTAssertEqual(readings.map(\.name), ["PMU tdie1", "PMU tdie6", "PMU tdie7"])
    }

    func testIdenticalNamesAreAveraged() throws {
        let readings = TemperatureSensors.makeHIDReadings([
            ("gas gauge battery", 29.0), ("gas gauge battery", 30.0), ("gas gauge battery", -9201),
            ("gas gauge battery", 31.0), ("NAND CH0 temp", 36),
        ])
        XCTAssertEqual(readings.count, 2)
        let battery = try XCTUnwrap(readings.first { $0.group == .battery })
        XCTAssertEqual(battery.celsius, 30, accuracy: 1e-9)
        XCTAssertEqual(battery.sampleCount, 3)
        XCTAssertEqual(battery.label, "Battery")
        XCTAssertEqual(battery.id, "hid:gas gauge battery")
    }

    // MARK: Labels and groups

    func testLabelsAndGroups() {
        let expectations: [(String, String, TemperatureGroup)] = [
            ("PMU tdie1", "SoC die 1", .soc),
            ("PMU tdie14", "SoC die 14", .soc),
            ("PMU2 tdie3", "PMU2 die 3", .other),
            ("PMU tdev2", "PMU sensor 2", .other),
            ("PMU2 tdev5", "PMU2 sensor 5", .other),
            ("PMU tcal", "PMU calibration", .other),
            ("PMU2 tcal", "PMU2 calibration", .other),
            ("NAND CH0 temp", "SSD (NAND channel 0)", .storage),
            ("gas gauge battery", "Battery", .battery),
            ("pACC MTR Temp Sensor2", "CPU performance cluster 2", .cpu),
            ("eACC MTR Temp Sensor0", "CPU efficiency cluster 0", .cpu),
            ("GPU MTR Temp Sensor1", "GPU 1", .gpu),
            ("SOC MTR Temp Sensor0", "SoC 0", .soc),
            ("Mystery sensor", "Mystery sensor", .other),
            ("PMU tdieX", "PMU tdieX", .other),
        ]
        for (name, label, group) in expectations {
            let result = TemperatureSensors.classifyHID(name)
            XCTAssertEqual(result.label, label, name)
            XCTAssertEqual(result.group, group, name)
        }
    }

    func testPMUDieSensorsAreNeverCalledCPUOrGPU() {
        for n in 1...14 {
            XCTAssertEqual(TemperatureSensors.classifyHID("PMU tdie\(n)").group, .soc)
            XCTAssertEqual(TemperatureSensors.classifyHID("PMU2 tdie\(n)").group, .other)
        }
    }

    func testNaturalSortWithinGroups() {
        let readings = TemperatureSensors.makeHIDReadings([
            ("PMU tdie10", 40), ("gas gauge battery", 30), ("PMU tdie2", 41), ("NAND CH0 temp", 35), ("PMU tdie1", 42),
        ])
        XCTAssertEqual(readings.map(\.label), ["SoC die 1", "SoC die 2", "SoC die 10", "Battery", "SSD (NAND channel 0)"])
    }

    // MARK: SMC map

    func testChipParsing() {
        XCTAssertEqual(TemperatureSensors.parseChip("Apple M5"), .init(generation: 5, variant: ""))
        XCTAssertEqual(TemperatureSensors.parseChip("Apple M4 Pro"), .init(generation: 4, variant: "Pro"))
        XCTAssertEqual(TemperatureSensors.parseChip("Apple M3 Ultra"), .init(generation: 3, variant: "Ultra"))
        XCTAssertEqual(TemperatureSensors.parseChip("Apple M12 Max"), .init(generation: 12, variant: "Max"))
        XCTAssertNil(TemperatureSensors.parseChip("Intel(R) Core(TM) i9-9980HK CPU @ 2.40GHz"))
    }

    func testM5MapNumbersOnlyPresentKeys() {
        let candidates = TemperatureSensors.smcCandidates(for: .init(generation: 5, variant: ""))
        XCTAssertEqual(candidates.filter { $0.group == .cpu }.count, 18)
        XCTAssertEqual(candidates.filter { $0.group == .gpu }.count, 8)
        // Keys present on the probed M5 (Tp08, Tp0K, Tp0U … absent).
        let present: Set<String> = ["Tp00", "Tp04", "Tp0C", "Tp0G", "Tp0O", "Tp0R", "Tp0X", "Tp0a", "Tp0p", "Tp0u", "Tp0y",
                                    "Tg0U", "Tg0X", "Tg0d", "Tg0g", "Tg0j", "Tg1Y", "Tg1c", "Tg1g", "Te04"]
        let keys = TemperatureSensors.presentKeys(candidates, keyExists: present.contains)
        XCTAssertEqual(keys.count, 19, "Te04 is not in the documented M5 map, so it is not labelled")
        XCTAssertEqual(keys.first, .init(key: "Tp00", group: .cpu, label: "CPU 1"))
        XCTAssertEqual(keys.first { $0.key == "Tp0y" }?.label, "CPU 11")
        XCTAssertEqual(keys.first { $0.key == "Tg1g" }?.label, "GPU 8")
    }

    func testOlderChipsUseStatsLabels() {
        let m4 = TemperatureSensors.smcCandidates(for: .init(generation: 4, variant: ""))
        XCTAssertTrue(m4.contains { $0.key == "Te05" && $0.label == "CPU efficiency core" })
        XCTAssertTrue(m4.contains { $0.key == "Tg0G" })
        XCTAssertFalse(m4.contains { $0.key == "Tg1U" })
        let m4Pro = TemperatureSensors.smcCandidates(for: .init(generation: 4, variant: "Pro"))
        XCTAssertTrue(m4Pro.contains { $0.key == "Tg1U" })
        XCTAssertTrue(TemperatureSensors.smcCandidates(for: .init(generation: 9, variant: "")).isEmpty)
    }

    // MARK: Summary

    func testSummary() {
        let readings = [
            TemperatureReading(name: "Tp00", label: "CPU 1", group: .cpu, celsius: 60, source: .smc),
            TemperatureReading(name: "Tp04", label: "CPU 2", group: .cpu, celsius: 70, source: .smc),
            TemperatureReading(name: "Tg0U", label: "GPU 1", group: .gpu, celsius: 50, source: .smc),
            TemperatureReading(name: "PMU tdie1", label: "SoC die 1", group: .soc, celsius: 45),
            TemperatureReading(name: "PMU tdie2", label: "SoC die 2", group: .soc, celsius: 55),
            TemperatureReading(name: "gas gauge battery", label: "Battery", group: .battery, celsius: 30, sampleCount: 3),
            TemperatureReading(name: "Other battery", label: "Battery", group: .battery, celsius: 34),
            TemperatureReading(name: "NAND CH0 temp", label: "SSD", group: .storage, celsius: 36),
        ]
        let summary = TemperatureSummary(readings)
        XCTAssertEqual(summary.cpuAverage, 65)
        XCTAssertEqual(summary.cpuHottest, 70)
        XCTAssertEqual(summary.gpuAverage, 50)
        XCTAssertEqual(summary.socAverage, 50)
        XCTAssertEqual(summary.socHottest, 55)
        XCTAssertEqual(summary.batteryAverage, 31)  // (30×3 + 34) / 4
        XCTAssertEqual(summary.ssd, 36)
        XCTAssertEqual(summary.headline, 70)
    }

    func testSummaryIsNilWithoutSensors() {
        let summary = TemperatureSummary([TemperatureReading(name: "PMU tdie1", label: "SoC die 1", group: .soc, celsius: 48)])
        XCTAssertNil(summary.cpuAverage)
        XCTAssertNil(summary.gpuHottest)
        XCTAssertNil(summary.batteryAverage)
        XCTAssertNil(summary.ssd)
        XCTAssertEqual(summary.headline, 48, "falls back to the hottest SoC die sensor")
        XCTAssertNil(TemperatureSummary([]).headline)
    }
}
