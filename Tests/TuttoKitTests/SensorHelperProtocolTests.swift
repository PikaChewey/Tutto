import Security
import XCTest
@testable import TuttoKit

/// Records calls and answers like the helper would.
private final class FakeHelper: NSObject, TuttoFanHelperProtocol, NSXPCListenerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
    private func record(_ call: String) { lock.lock(); _calls.append(call); lock.unlock() }

    func version(reply: @escaping (String) -> Void) {
        record("version")
        reply(TuttoFanHelper.version)
    }

    func setFan(_ index: Int, mode: Int, rpm: Double, reply: @escaping (Int32, String?) -> Void) {
        record("setFan \(index) \(mode) \(rpm)")
        if index == 0 {
            reply(FanStatus.success, nil)
        } else {
            reply(FanStatus.badArgument, "No fan \(index)")
        }
    }

    func resetAllFans(reply: @escaping (Int32) -> Void) {
        record("resetAllFans")
        reply(FanStatus.notPrivileged)
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = TuttoFanHelper.makeInterface()
        connection.exportedObject = self
        connection.resume()
        return true
    }
}

final class SensorHelperProtocolTests: XCTestCase {
    func testConstants() {
        XCTAssertEqual(TuttoFanHelper.machServiceName, "ca.bryanyao.Tutto.helper")
        XCTAssertEqual(TuttoFanHelper.plistName, "ca.bryanyao.Tutto.helper.plist")
        XCTAssertEqual(TuttoFanHelper.clientRequirement,
                       #"anchor apple generic and identifier "ca.bryanyao.Tutto" and certificate leaf[subject.OU] = "8WA5T6YMPK""#)
        XCTAssertEqual(NSStringFromProtocol(TuttoFanHelperProtocol.self), "TuttoFanHelperProtocol",
                       "the helper declares the same @objc name")
    }

    func testStatusCodesMatchIOReturn() {
        XCTAssertEqual(UInt32(bitPattern: FanStatus.notPrivileged), 0xe000_02c1)
        XCTAssertEqual(UInt32(bitPattern: FanStatus.badArgument), 0xe000_02c2)
        XCTAssertEqual(UInt32(bitPattern: FanStatus.unsupported), 0xe000_02c7)
        XCTAssertEqual(UInt32(bitPattern: FanStatus.notFound), 0xe000_02f0)
        XCTAssertEqual(UInt32(bitPattern: FanStatus.error), 0xe000_02bc)
        XCTAssertTrue(FanStatus.describe(FanStatus.notPrivileged).contains("root"))
    }

    /// A malformed requirement would throw an Objective-C exception inside the helper.
    func testRequirementsCompile() {
        for text in [TuttoFanHelper.clientRequirement, TuttoFanHelper.helperRequirement] {
            var requirement: SecRequirement?
            XCTAssertEqual(SecRequirementCreateWithString(text as CFString, [], &requirement), errSecSuccess, text)
            XCTAssertNotNil(requirement)
        }
    }

    func testProtocolRoundTripsOverXPC() throws {
        let helper = FakeHelper()
        let listener = NSXPCListener.anonymous()
        listener.delegate = helper
        listener.resume()
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = TuttoFanHelper.makeInterface()
        connection.resume()
        defer { connection.invalidate() }
        let proxy = try XCTUnwrap(connection.remoteObjectProxyWithErrorHandler { error in
            XCTFail("XPC error: \(error)")
        } as? TuttoFanHelperProtocol)

        let version = expectation(description: "version")
        proxy.version { value in
            XCTAssertEqual(value, TuttoFanHelper.version)
            version.fulfill()
        }
        let ok = expectation(description: "setFan ok")
        proxy.setFan(0, mode: 1, rpm: 3000.5) { status, message in
            XCTAssertEqual(status, FanStatus.success)
            XCTAssertNil(message)
            ok.fulfill()
        }
        let bad = expectation(description: "setFan bad")
        proxy.setFan(3, mode: 0, rpm: 0) { status, message in
            XCTAssertEqual(status, FanStatus.badArgument)
            XCTAssertEqual(message, "No fan 3")
            bad.fulfill()
        }
        let reset = expectation(description: "reset")
        proxy.resetAllFans { status in
            XCTAssertEqual(status, FanStatus.notPrivileged)
            reset.fulfill()
        }
        wait(for: [version, ok, bad, reset], timeout: 5)
        XCTAssertTrue(helper.calls.contains("setFan 0 1 3000.5"))
    }

    /// The helper's listener requirement turns away any client that is not Tutto.app, such as this test runner.
    func testClientRequirementRejectsOtherProcesses() throws {
        let helper = FakeHelper()
        let listener = NSXPCListener.anonymous()
        listener.setConnectionCodeSigningRequirement(TuttoFanHelper.clientRequirement)
        listener.delegate = helper
        listener.resume()
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = TuttoFanHelper.makeInterface()
        connection.resume()
        defer { connection.invalidate() }

        let rejected = expectation(description: "rejected")
        let proxy = try XCTUnwrap(connection.remoteObjectProxyWithErrorHandler { _ in rejected.fulfill() } as? TuttoFanHelperProtocol)
        proxy.resetAllFans { _ in XCTFail("an unsigned client must not reach the helper") }
        wait(for: [rejected], timeout: 5)
        XCTAssertTrue(helper.calls.isEmpty)
    }

    /// Without root the SMC refuses writes. Writes back the value already there, so nothing changes either way.
    func testNonRootSMCWriteIsNotPrivileged() throws {
        guard geteuid() != 0 else { throw XCTSkip("running as root; never write the SMC from tests") }
        guard let key = Fans.modeKey(for: 0), let current = SMCDevice.shared.read(key) else { throw XCTSkip("no fan mode key") }
        XCTAssertEqual(SMCDevice.shared.write(key, current.bytes), FanStatus.notPrivileged)
        XCTAssertEqual(SMCDevice.shared.read(key), current)
    }

    func testInvalidKeysAreRejectedBeforeTheSMC() {
        XCTAssertNil(SMCDevice.shared.read("F0"))
        XCTAssertNil(SMCDevice.shared.read("Fä0d"))
        XCTAssertEqual(SMCDevice.shared.write("TOOLONG", [0]), FanStatus.badArgument)
        XCTAssertEqual(SMCDevice.shared.write("F0md", []), FanStatus.badArgument)
    }
}
