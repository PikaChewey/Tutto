//
//  SelfTest.swift
//  TuttoHelper
//
//  `TuttoHelper --self-test`, run as a normal user from Terminal:
//  - prints what the helper sees on this Mac;
//  - checks that the helper's XPC setup rejects a client that is not Tutto.app;
//  - checks that SMC writes fail cleanly without root.
//  It never changes fan state. The XPC checks use an SMC whose writes are blocked, and
//  the privilege probe writes back the value a key already holds. It skips the probe as root.
//

import Foundation
import Security

enum SelfTest {
    static func run() -> Int32 {
        var failures = 0
        func check(_ ok: Bool, _ description: String) {
            print("\(ok ? "PASS" : "FAIL")  \(description)")
            if !ok { failures += 1 }
        }

        print("TuttoHelper \(TuttoFanHelper.version) self-test (uid \(getuid()), euid \(geteuid()))")
        let smc = SMCDevice.shared
        let reader = WriteBlockingSMC(smc)
        let controller = FanController(smc: reader)
        let count = controller.fanCount
        print("fans: \(count); \(FanSMC.unlockKey): \(smc.read(FanSMC.unlockKey) == nil ? "absent" : "present")")
        for fan in 0..<count {
            let modeKey = controller.modeKey(for: fan)
            let mode = modeKey.flatMap { smc.read($0)?.bytes.first }.map(String.init) ?? "?"
            func value(_ key: String) -> String { smc.readDouble(key).map { String(format: "%.0f", $0) } ?? "–" }
            print("fan \(fan): mode key \(modeKey ?? "none") = \(mode), actual \(value(FanSMC.actualKey(fan))), "
                + "min \(value(FanSMC.minimumKey(fan))), max \(value(FanSMC.maximumKey(fan))), target \(value(FanSMC.targetKey(fan)))")
        }

        // 1. Code-signing requirement, through the same attach/accept code the daemon uses.
        check(roundTrip(requirement: nil) == .accepted, "XPC control: no requirement -> this process is accepted")
        if let own = ownCDHashRequirement() {
            check(roundTrip(requirement: own) == .accepted, "XPC control: requirement for this binary's cdhash -> accepted")
        }
        // Normally this binary is not signed as the app, so it must be turned away. Signed as
        // ca.bryanyao.Tutto by the team (e.g. a test copy), it must get through instead.
        let isApp = satisfies(TuttoFanHelper.clientRequirement)
        let outcome = roundTrip(requirement: TuttoFanHelper.clientRequirement)
        check(outcome == (isApp ? .accepted : .rejected),
              isApp ? "XPC: this process is signed as Tutto.app (team \(TuttoFanHelper.teamIdentifier)) and is accepted"
                    : "XPC: Tutto's client requirement rejects this process (not ca.bryanyao.Tutto from team \(TuttoFanHelper.teamIdentifier))")

        // 2. Resetting an all-automatic Mac issues no writes.
        if controller.allAutomatic {
            let status = controller.resetAll()
            check(status == FanStatus.success && reader.attemptedWrites.isEmpty,
                  "resetAll on all-automatic fans issues no writes (\(reader.attemptedWrites.count) attempted)")
        } else {
            print("SKIP  resetAll check: a fan is in manual mode right now")
        }

        // 3. Without root, the real SMC refuses writes. Write back the current bytes so nothing can change.
        if geteuid() == 0 {
            print("SKIP  privilege probe: running as root, and the self-test never writes as root")
        } else if count > 0 {
            for key in [controller.modeKey(for: 0), FanSMC.targetKey(0)].compactMap({ $0 }) {
                guard let current = smc.read(key) else { continue }
                let status = smc.write(key, current.bytes)
                check(status == FanStatus.notPrivileged,
                      "non-root write of \(key) (unchanged value) -> \(FanStatus.describe(status))")
            }
        } else {
            print("SKIP  privilege probe: no fans")
        }

        print(failures == 0 ? "OK" : "\(failures) check(s) failed")
        return failures == 0 ? 0 : 1
    }

    // MARK: XPC round trip

    enum Outcome: Equatable { case accepted, rejected, timedOut }

    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var outcome = Outcome.timedOut
        func set(_ value: Outcome) {
            lock.lock()
            if outcome == .timedOut { outcome = value }
            lock.unlock()
        }
    }

    /// Connects this process to an anonymous listener configured exactly like the daemon's.
    static func roundTrip(requirement: String?) -> Outcome {
        let service = HelperService(smc: WriteBlockingSMC(SMCDevice.shared), requirement: requirement, exitsWhenIdle: false, awakeJournal: nil)
        let listener = NSXPCListener.anonymous()
        service.attach(to: listener)
        listener.resume()
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = TuttoFanHelper.makeInterface()
        connection.resume()
        defer { connection.invalidate() }

        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
            box.set(.rejected)
            done.signal()
        } as? TuttoFanHelperProtocol
        proxy?.version { _ in
            box.set(.accepted)
            done.signal()
        }
        _ = done.wait(timeout: .now() + 5)
        withExtendedLifetime(service) {}
        box.lock.lock()
        defer { box.lock.unlock() }
        return box.outcome
    }

    /// Whether this running process meets a code-signing requirement.
    static func satisfies(_ requirementText: String) -> Bool {
        var code: SecCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement
        else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    /// `cdhash H"…"` for this executable, or nil if it is unsigned.
    static func ownCDHashRequirement() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              let hash = dictionary[kSecCodeInfoUnique as String] as? Data
        else { return nil }
        return "cdhash H\"\(hash.map { String(format: "%02x", $0) }.joined())\""
    }
}

/// Passes reads through to the real SMC and records, but never performs, writes.
final class WriteBlockingSMC: SMCAccess {
    private let base: SMCAccess
    private(set) var attemptedWrites: [String] = []

    init(_ base: SMCAccess) { self.base = base }

    func read(_ key: String) -> SMCRawValue? { base.read(key) }

    func write(_ key: String, _ bytes: [UInt8]) -> Int32 {
        attemptedWrites.append(key)
        return FanStatus.notPermitted
    }
}
