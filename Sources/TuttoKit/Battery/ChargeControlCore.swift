//
//  ChargeControlCore.swift
//  Tutto
//
//  Charge limit's root half: the SMC keys that stop a MacBook taking charge while it keeps
//  running on the adapter, and `ChargeInhibitor`, which TuttoHelper uses to hold charging off
//  under a lease. The app has to renew the lease (every `ChargeLease.renewInterval`); if it
//  stops, the helper allows charging by itself, so a hung or crashed Tutto can never leave a
//  Mac that won't charge. A journal file marks an inhibit until it's undone, so a helper that
//  was killed allows charging at its next start.
//
//  Keys, by firmware (read on the Mac, never assumed):
//  - `CHTE` (ui32, 4 bytes): newer Apple silicon firmware (macOS 26). 1 = don't charge, 0 = charge.
//    The bytes go little-endian: 01 00 00 00 stops charging.
//  - `CH0B` and `CH0C` (1 byte each): older Apple silicon firmware. 0x02 = don't charge, 0x00 = charge.
//  The adapter stays on either way: the Mac runs from the wall and the battery just sits.
//
//  This file is compiled into BOTH TuttoKit and TuttoHelper (symlink in
//  Sources/TuttoHelper/Shared/). Keep it Foundation-only.
//

import Foundation

// MARK: - Keys

public enum ChargeSMC {
    /// How this Mac's SMC stops charging.
    public enum Method: String, Equatable, Sendable {
        /// `CHTE`, a 4-byte flag (newer firmware).
        case flag32
        /// `CH0B` (and `CH0C` where it exists), one byte each (older firmware).
        case legacy
    }

    public static let flagKey = "CHTE"
    public static let legacyKeys = ["CH0B", "CH0C"]

    /// The method this Mac supports, probed with `keyExists`. `CHTE` wins where both exist.
    public static func method(keyExists: (String) -> Bool) -> Method? {
        if keyExists(flagKey) { return .flag32 }
        if keyExists(legacyKeys[0]) { return .legacy }
        return nil
    }

    /// The keys a method writes, of those that exist.
    public static func keys(for method: Method, keyExists: (String) -> Bool) -> [String] {
        switch method {
        case .flag32: return [flagKey]
        case .legacy: return legacyKeys.filter(keyExists)
        }
    }

    /// The bytes to write for "don't charge" (`inhibit`) or "charge", sized to the key.
    public static func bytes(inhibit: Bool, method: Method, size: Int) -> [UInt8]? {
        switch method {
        case .flag32:
            guard size == 4 else { return nil }
            return [inhibit ? 1 : 0, 0, 0, 0]
        case .legacy:
            guard size >= 1 else { return nil }
            return [inhibit ? 0x02 : 0x00] + [UInt8](repeating: 0, count: size - 1)
        }
    }

    /// Whether a key's value says "don't charge" (any non-zero byte).
    public static func isInhibited(_ value: SMCRawValue) -> Bool {
        value.bytes.contains { $0 != 0 }
    }
}

// MARK: - Lease

public enum ChargeLease {
    /// The app renews a hold this often while it keeps charging off.
    public static let renewInterval: TimeInterval = 60
    /// The lease the app asks for: one missed renewal is tolerated, two are not.
    public static let duration: TimeInterval = 90
    /// The helper clamps any lease into this range.
    public static let shortest: TimeInterval = 5
    public static let longest: TimeInterval = 300

    public static func clamp(_ seconds: TimeInterval) -> TimeInterval {
        guard seconds.isFinite else { return shortest }
        return Swift.min(Swift.max(seconds, shortest), longest)
    }

    /// Seconds on a clock that stops while the Mac sleeps (mach absolute time), so a lease
    /// doesn't run out during sleep and the app gets its full time to renew after waking.
    public static func monotonicNow() -> TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}

// MARK: - The helper's side

/// Holds charging off under a lease, and puts it back. Runs as root inside TuttoHelper, on one
/// serial queue; tests drive it with a fake SMC and clock.
final class ChargeInhibitor {
    struct Result: Equatable {
        var status: Int32
        var message: String?
        static let ok = Result(status: FanStatus.success, message: nil)
        var succeeded: Bool { status == FanStatus.success }
    }

    private let smc: SMCAccess
    private let journalURL: URL?
    private let clock: () -> TimeInterval
    private let pause: (TimeInterval) -> Void

    /// True while this helper holds charging off.
    private(set) var isInhibiting = false
    /// When the hold ends unless renewed, on `clock`.
    private(set) var leaseEnd: TimeInterval?

    init(smc: SMCAccess, journalURL: URL?,
         clock: @escaping () -> TimeInterval = ChargeLease.monotonicNow,
         pause: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.smc = smc
        self.journalURL = journalURL
        self.clock = clock
        self.pause = pause
    }

    var method: ChargeSMC.Method? {
        ChargeSMC.method(keyExists: { smc.read($0) != nil })
    }

    /// Whether the SMC says charging is off right now (whoever turned it off).
    var smcSaysInhibited: Bool {
        guard let method else { return false }
        return ChargeSMC.keys(for: method, keyExists: { smc.read($0) != nil })
            .contains { smc.read($0).map(ChargeSMC.isInhibited) ?? false }
    }

    var leaseRemaining: TimeInterval {
        guard isInhibiting, let leaseEnd else { return 0 }
        return Swift.max(0, leaseEnd - clock())
    }

    /// Stops charging for `lease` seconds (clamped), or renews a hold already in place.
    func inhibit(lease: TimeInterval) -> Result {
        guard let method else {
            return Result(status: FanStatus.unsupported, message: "This Mac's SMC has no charging control key.")
        }
        if !isInhibiting {
            // Journal first: a helper killed right after the write still finds it at its next start.
            writeJournal()
            let written = write(inhibit: true, method: method)
            guard written.succeeded else {
                // Never leave a half-written state: put back whatever got through.
                _ = write(inhibit: false, method: method)
                removeJournal()
                return written
            }
            isInhibiting = true
        }
        leaseEnd = clock() + ChargeLease.clamp(lease)
        return .ok
    }

    /// Lets the Mac charge again. Writes only if this helper stopped it (or `force`, used at
    /// start-up when a journal says an earlier helper did).
    @discardableResult
    func allow(force: Bool = false) -> Result {
        guard isInhibiting || force else { return .ok }
        guard let method else {
            isInhibiting = false
            leaseEnd = nil
            removeJournal()
            return .ok
        }
        let result = write(inhibit: false, method: method)
        if result.succeeded {
            isInhibiting = false
            leaseEnd = nil
            removeJournal()
        }
        return result
    }

    /// Allows charging if the lease has run out. True when it did.
    func expireLeaseIfDue() -> Bool {
        guard isInhibiting, let leaseEnd, clock() >= leaseEnd else { return false }
        return allow().succeeded
    }

    /// At start-up: a journal left by a helper that was killed mid-hold. Allows charging and
    /// clears it. True when there was one.
    func recoverFromJournal() -> Bool {
        guard let journalURL, FileManager.default.fileExists(atPath: journalURL.path) else { return false }
        allow(force: true)
        return true
    }

    // MARK: Writes

    private func write(inhibit: Bool, method: ChargeSMC.Method) -> Result {
        let keys = ChargeSMC.keys(for: method, keyExists: { smc.read($0) != nil })
        guard !keys.isEmpty else {
            return Result(status: FanStatus.unsupported, message: "This Mac's SMC has no charging control key.")
        }
        for key in keys {
            guard let current = smc.read(key),
                  let bytes = ChargeSMC.bytes(inhibit: inhibit, method: method, size: current.bytes.count) else {
                return Result(status: FanStatus.unsupported, message: "\(key) has an unexpected size.")
            }
            if current.bytes == bytes { continue }
            var status = FanStatus.error
            for attempt in 0..<5 {
                status = smc.write(key, bytes)
                if status == FanStatus.success || status == FanStatus.notPrivileged { break }
                if attempt < 4 { pause(0.05) }
            }
            guard status == FanStatus.success else {
                return Result(status: status, message: "Couldn't \(inhibit ? "stop" : "restart") charging (\(key)): \(FanStatus.describe(status)).")
            }
            // Read it back: an SMC that took the write but kept its value hasn't done it.
            if let after = smc.read(key), ChargeSMC.isInhibited(after) != inhibit {
                return Result(status: FanStatus.error, message: "The SMC didn't keep \(key) at the new value.")
            }
        }
        return .ok
    }

    private func writeJournal() {
        guard let journalURL else { return }
        try? FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let note = #"{"chargingInhibited":true,"since":\#(Date().timeIntervalSince1970)}"#
        try? Data(note.utf8).write(to: journalURL, options: .atomic)
    }

    private func removeJournal() {
        guard let journalURL else { return }
        try? FileManager.default.removeItem(at: journalURL)
    }
}
