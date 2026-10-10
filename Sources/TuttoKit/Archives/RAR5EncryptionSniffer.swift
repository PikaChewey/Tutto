//
//  RAR5EncryptionSniffer.swift
//  TuttoKit — archives
//
//  libarchive 3.7.4 neither decrypts RAR5 nor marks encrypted RAR5 entries (verified: an entry
//  carrying a file-encryption extra record reports archive_entry_is_encrypted == 0 and
//  archive_read_has_encrypted_entries == -2, and its ciphertext would be written out as if it
//  were the file). This walks the RAR5 block headers (https://www.rarlab.com/technote.htm)
//  without touching file data to find:
//    • an archive encryption header (type 4: names and headers are encrypted), and
//    • file headers whose extra area holds a file encryption record (record type 0x01).
//

import Foundation

enum RAR5EncryptionSniffer {
    struct Report: Equatable {
        var headersEncrypted = false
        /// Names (UTF-8, as stored) of file entries with an encryption record.
        var encryptedFiles: [String] = []
        var isEncrypted: Bool { headersEncrypted || !encryptedFiles.isEmpty }
    }

    static let signature: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]

    /// Returns nil when the file isn't a RAR5 archive (or can't be read).
    static func inspect(_ url: URL, maxBlocks: Int = 200_000) -> Report? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 8), [UInt8](head) == signature else { return nil }

        var report = Report()
        var offset: UInt64 = 8
        for _ in 0..<maxBlocks {
            // CRC32 (4) + header size vint (≤ 3 bytes in practice; headers are capped at 2 MB).
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let prefix = try? handle.read(upToCount: 4 + 10), prefix.count > 4 else { break }
            var cursor = ByteCursor(bytes: [UInt8](prefix), position: 4)
            guard let headerSize = cursor.vint(), headerSize > 0, headerSize <= 2 * 1024 * 1024 else { break }
            let headerStart = offset + 4 + UInt64(cursor.position - 4)
            guard (try? handle.seek(toOffset: headerStart)) != nil,
                  let headerData = try? handle.read(upToCount: Int(headerSize)), headerData.count == Int(headerSize) else { break }

            var h = ByteCursor(bytes: [UInt8](headerData), position: 0)
            guard let type = h.vint(), let flags = h.vint() else { break }
            var extraSize: UInt64 = 0
            var dataSize: UInt64 = 0
            if flags & 0x0001 != 0 { guard let v = h.vint() else { break }; extraSize = v }
            if flags & 0x0002 != 0 { guard let v = h.vint() else { break }; dataSize = v }

            switch type {
            case 4:
                report.headersEncrypted = true
                return report
            case 2:
                // File header: file flags, unpacked size, attributes, [mtime], [data CRC],
                // compression info, host OS, name length, name, extra area.
                guard let fileFlags = h.vint(), h.vint() != nil, h.vint() != nil else { break }
                if fileFlags & 0x0002 != 0 { h.skip(4) }
                if fileFlags & 0x0004 != 0 { h.skip(4) }
                guard h.vint() != nil, h.vint() != nil, let nameLength = h.vint(),
                      let nameBytes = h.take(Int(nameLength)) else { break }
                if extraSize > 0, let extra = h.take(Int(extraSize)), extraHasEncryptionRecord(extra) {
                    report.encryptedFiles.append(String(decoding: nameBytes, as: UTF8.self))
                }
            case 5:
                return report   // end of archive
            default:
                break
            }
            offset = headerStart + headerSize + dataSize
        }
        return report
    }

    private static func extraHasEncryptionRecord(_ extra: [UInt8]) -> Bool {
        var c = ByteCursor(bytes: extra, position: 0)
        while c.position < extra.count {
            guard let size = c.vint(), size > 0 else { return false }
            let recordStart = c.position
            guard let type = c.vint() else { return false }
            if type == 0x01 { return true }
            c.position = recordStart + Int(size)
        }
        return false
    }
}

/// Little-endian reader for RAR5 variable-length integers.
struct ByteCursor {
    var bytes: [UInt8]
    var position: Int

    mutating func vint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while position < bytes.count, shift < 64 {
            let b = bytes[position]
            position += 1
            result |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }

    mutating func skip(_ n: Int) { position += n }

    mutating func take(_ n: Int) -> [UInt8]? {
        guard n >= 0, position + n <= bytes.count else { return nil }
        defer { position += n }
        return Array(bytes[position..<position + n])
    }
}
