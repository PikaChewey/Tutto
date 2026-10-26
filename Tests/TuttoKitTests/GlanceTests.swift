import XCTest
@testable import TuttoKit

/// The panel's one line: a problem first, otherwise the battery's state, every word measured.
final class GlanceTests: XCTestCase {
    private func battery(_ percent: Int, charging: Bool = false, plugged: Bool = false, full: Bool = false,
                         left: Int? = nil, toFull: Int? = nil) -> BatteryInfo {
        var info = BatteryReader.parse(["DesignCapacity": 6249, "NominalChargeCapacity": 5871, "CurrentCapacity": percent,
                                        "IsCharging": charging, "ExternalConnected": plugged, "FullyCharged": full])
        info.minutesToEmpty = left
        info.minutesToFull = toFull
        return info
    }

    private func glance(_ battery: BatteryInfo?, cpu: Double = 0.2, pressure: MemoryPressure? = .normal, hottest: Double? = 45,
                        diskUsed: Double? = 0.6) -> Glance {
        Glance.make(battery: battery, cpu: cpu, memoryPressure: pressure, hottest: hottest, diskFree: 96_000_000_000, diskUsed: diskUsed)
    }

    func testACalmMacSaysItsBatteryState() {
        XCTAssertEqual(glance(battery(55, left: 249)), Glance("On battery", "4 h 9 min left"))
        XCTAssertEqual(glance(battery(55)), Glance("On battery"))
        XCTAssertEqual(glance(battery(80, charging: true, plugged: true, toFull: 45)), Glance("Charging", "Full in 45 min"))
        XCTAssertEqual(glance(battery(100, plugged: true, full: true)), Glance("Fully charged", "On power"))
        XCTAssertEqual(glance(battery(80, plugged: true)), Glance("On power", "Not charging"))
        XCTAssertEqual(glance(nil), Glance("All good"))
    }

    func testProblemsComeFirstInOrder() {
        XCTAssertEqual(glance(battery(8, left: 18), hottest: 99), Glance("Battery low", "18 min left", level: .alert))
        XCTAssertEqual(glance(battery(8, plugged: true), hottest: 99), Glance("Running hot", "99°", level: .alert))
        XCTAssertEqual(glance(battery(55), pressure: .critical), Glance("Memory is full", "Pressure critical", level: .alert))
        XCTAssertEqual(glance(battery(55), cpu: 0.95, diskUsed: 0.97).title, "Disk almost full")
        XCTAssertEqual(glance(battery(55, left: 120), pressure: .warning), Glance("On battery", "2 h 0 min left"))
        XCTAssertEqual(glance(battery(55), cpu: 0.91), Glance("Working hard", "CPU 91%", level: .notice))
    }

    func testNoEstimateMeansNoMadeUpTime() {
        XCTAssertEqual(glance(battery(8)), Glance("Battery low", "8%", level: .alert))
        XCTAssertNil(Glance.duration(0))
        XCTAssertNil(Glance.duration(60 * 72))
        XCTAssertEqual(Glance.duration(60), "1 h 0 min")
    }
}
