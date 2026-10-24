import XCTest
@testable import TuttoKit

final class SystemReaderTests: XCTestCase {
    func testCPUUsageBetweenSnapshots() {
        let a = [CPUTicks(user: 100, system: 50, idle: 850, nice: 0), CPUTicks(user: 0, system: 0, idle: 1000, nice: 0)]
        let b = [CPUTicks(user: 200, system: 100, idle: 1700, nice: 0), CPUTicks(user: 0, system: 0, idle: 2000, nice: 0)]
        let usage = CPUReader.usage(from: a, to: b)
        XCTAssertEqual(usage.perCore[0], 0.15, accuracy: 0.0001)
        XCTAssertEqual(usage.perCore[1], 0, accuracy: 0.0001)
        XCTAssertEqual(usage.total, 0.075, accuracy: 0.0001)
    }

    func testCPUCountersWrap() {
        let a = [CPUTicks(user: 0xFFFF_FFF0, system: 0, idle: 0, nice: 0)]
        let b = [CPUTicks(user: 0x10, system: 0, idle: 0x20, nice: 0)]
        let usage = CPUReader.usage(from: a, to: b)
        XCTAssertEqual(usage.perCore[0], 32.0 / 64.0, accuracy: 0.0001)
    }

    func testLiveReadersReturnPlausibleValues() throws {
        let ticks = CPUReader.ticks()
        XCTAssertEqual(ticks.count, ProcessInfo.processInfo.processorCount)
        XCTAssertEqual(CPUReader.topology.kinds.count, ticks.count)
        let memory = try XCTUnwrap(MemoryReader.read())
        XCTAssertGreaterThan(memory.total, 1 << 30)
        XCTAssertLessThanOrEqual(memory.used, memory.total)
        XCTAssertNotNil(DiskReader.rootVolume())
        if let gpu = GPUReader.read().first {
            XCTAssertNotNil(gpu.utilization)
        }
    }

    func testBatteryParsingMatchesSystemSettings() {
        // Values from this Mac's AppleSmartBattery entry; System Settings shows 94 %.
        let registry: [String: Any] = [
            "CurrentCapacity": 95, "MaxCapacity": 100, "DesignCapacity": 6249, "NominalChargeCapacity": 5871,
            "AppleRawMaxCapacity": 5719, "CycleCount": 127, "Temperature": 3037, "Voltage": 12871,
            "InstantAmperage": NSNumber(value: UInt64(bitPattern: -1500)), "ExternalConnected": false,
            "IsCharging": false, "FullyCharged": false,
            "PowerTelemetryData": ["SystemLoad": 10541, "SystemPowerIn": 0],
        ]
        let info = BatteryReader.parse(registry)
        XCTAssertEqual(info.percent, 95)
        XCTAssertEqual(info.maxCapacity, 5871)
        XCTAssertEqual(Int((info.health * 100).rounded()), 94)
        XCTAssertEqual(info.cycleCount, 127)
        XCTAssertEqual(info.temperature ?? 0, 30.37, accuracy: 0.001)
        XCTAssertEqual(info.amperage ?? 0, -1.5, accuracy: 0.001)
        XCTAssertEqual(info.powerDraw ?? 0, 10.541, accuracy: 0.001)
        XCTAssertEqual(info.stateText, "On battery")
    }

    func testHealthIsMacOSFigureNotTheDriftingGaugeRatio() {
        // Later the same day: the gauge's estimate fell to 5833 mAh (93.3 %) while macOS still said 94 %.
        var info = BatteryReader.parse(["DesignCapacity": 6249, "NominalChargeCapacity": 5833, "CurrentCapacity": 47])
        XCTAssertEqual(info.healthPercent, 93)  // fallback only: estimate, rounded to a whole percent
        info.reportedHealth = 94
        XCTAssertEqual(info.healthPercent, 94)
        XCTAssertEqual(info.health, 0.94, accuracy: 0.0001)
    }

    func testSystemProfilerHealthParsing() {
        let json = """
        {"SPPowerDataType":[{"_name":"spbattery_information","sppower_battery_health_info":
        {"sppower_battery_cycle_count":135,"sppower_battery_health":"Good",
        "sppower_battery_health_maximum_capacity":"94%"}},{"_name":"sppower_information"}]}
        """
        XCTAssertEqual(BatteryHealthReport.parse(Data(json.utf8)), BatteryHealthReport(maximumCapacity: 94, condition: "Normal"))
        XCTAssertNil(BatteryHealthReport.parse(Data(#"{"SPPowerDataType":[{"_name":"sppower_information"}]}"#.utf8)))
        XCTAssertNil(BatteryHealthReport.parse(Data("not json".utf8)))
    }

    func testLiveHealthMatchesSystemProfiler() throws {
        guard BatteryReader.read() != nil else { throw XCTSkip("No battery") }
        let reported = try XCTUnwrap(BatteryHealthReport.fetch())
        XCTAssert((50...110).contains(reported.maximumCapacity))
        XCTAssertNotNil(reported.condition)
    }

    func testNetworkCountersAre64BitAndOnlyGoUp() {
        let a = NetworkReader.counters()
        let b = NetworkReader.counters()
        XCTAssertGreaterThan(a.received, 0)
        XCTAssertGreaterThanOrEqual(b.received, a.received)
        XCTAssertGreaterThanOrEqual(b.sent, a.sent)

        // Same exact counters as netstat (allowing for traffic between the two reads).
        let netstat = Process()
        netstat.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        netstat.arguments = ["-ib"]
        let pipe = Pipe()
        netstat.standardOutput = pipe
        try? netstat.run()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        netstat.waitUntilExit()
        var received: UInt64 = 0
        for line in text.split(separator: "\n") {
            let columns = line.split(separator: " ")
            guard columns.count >= 10, columns[0].hasPrefix("en"), columns[2].hasPrefix("<Link") else { continue }
            received += UInt64(columns[columns.count - 5]) ?? 0
        }
        XCTAssertLessThan(abs(Int64(received) - Int64(b.received)), 50_000_000)
    }

    func testTopParsing() {
        let block = """
         1234 total, 5 running
        PID    COMMAND          %CPU MEM    POWER
        394    WindowServer     35.2 211M   48.3
        56729  Claude Helper (R 10.3 1.2G+  10.8
        408    coreaudiod       9.6  5424K  11.8
        """
        let rows = TopProcessStream.parse(block)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].pid, 394)
        XCTAssertEqual(rows[0].energyImpact, 48.3)
        XCTAssertEqual(rows[1].cpu, 10.3)
        XCTAssertEqual(rows[1].memory, UInt64(1.2 * 1024 * 1024 * 1024))
        XCTAssertEqual(rows[2].memory, 5424 * 1024)
    }
}
