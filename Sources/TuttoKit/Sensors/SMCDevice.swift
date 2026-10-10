//
//  SMCDevice.swift
//  Tutto
//
//  The real SMC, through the AppleSMC user client in CBridges. Reads work for any user.
//  Writes return kIOReturnNotPrivileged unless the process is root.
//
//  This file is compiled into BOTH TuttoKit and TuttoHelper (symlink in
//  Sources/TuttoHelper/Shared/).
//

import CBridges
import Foundation

final class SMCDevice: SMCAccess {
    static let shared = SMCDevice()

    /// CBridges keeps one global user-client connection; serialize every call on it.
    private let lock = NSLock()

    /// Four printable ASCII characters, or nil.
    static func isValidKey(_ key: String) -> Bool {
        let scalars = key.unicodeScalars
        return scalars.count == 4 && scalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7f }
    }

    func read(_ key: String) -> SMCRawValue? {
        guard Self.isValidKey(key) else { return nil }
        var value = TSMCValue()
        lock.lock()
        let found = key.withCString { TSMCRead($0, &value) }
        lock.unlock()
        guard found else { return nil }
        let size = Int(min(value.dataSize, 32))
        let bytes = withUnsafeBytes(of: &value.bytes) { Array($0.prefix(size)) }
        return SMCRawValue(type: Self.fourCharacterString(value.dataType), bytes: bytes)
    }

    func write(_ key: String, _ bytes: [UInt8]) -> Int32 {
        guard Self.isValidKey(key), !bytes.isEmpty, bytes.count <= 32 else { return FanStatus.badArgument }
        lock.lock()
        defer { lock.unlock() }
        return key.withCString { name in
            bytes.withUnsafeBufferPointer { TSMCWrite(name, $0.baseAddress, UInt32($0.count)) }
        }
    }

    /// Reads a key as a number. Nil when it is missing or not numeric.
    func readDouble(_ key: String) -> Double? { read(key)?.doubleValue }

    /// The C decoder in CBridges (`TSMCValueAsDouble`), for cross-checking `FanSMC.decode`.
    static func decodeWithCBridge(_ raw: SMCRawValue) -> Double? {
        guard raw.type.utf8.count == 4, raw.bytes.count <= 32 else { return nil }
        var value = TSMCValue()
        value.dataType = raw.type.utf8.reduce(0) { $0 << 8 | UInt32($1) }
        value.dataSize = UInt32(raw.bytes.count)
        withUnsafeMutableBytes(of: &value.bytes) { buffer in
            for (index, byte) in raw.bytes.enumerated() { buffer[index] = byte }
        }
        var out = 0.0
        return TSMCValueAsDouble(&value, &out) ? out : nil
    }

    static func fourCharacterString(_ code: UInt32) -> String {
        let bytes = [UInt8(code >> 24 & 0xff), UInt8(code >> 16 & 0xff), UInt8(code >> 8 & 0xff), UInt8(code & 0xff)]
        return String(decoding: bytes, as: UTF8.self)
    }
}
