//
//  ArchiveFixtureBuildersTests.swift
//  TuttoKitTests
//
//  Test-time fixture builders. Nothing binary is committed: archives are created in a temp
//  directory either with the system /usr/bin/bsdtar, /usr/bin/zip, /usr/bin/ditto, or byte by
//  byte here (zip with legacy-encoded names, RAR5 and RAR4 "store" archives, a 7z with an AES
//  coder, CAB, LHA, ustar, gzip). The small test class at the bottom checks the builders.
//

import Foundation
import XCTest

// MARK: - Byte helpers

enum CRC32 {
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    static func checksum<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

extension Data {
    mutating func le16(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func le32(_ v: UInt32) { for i in 0..<4 { append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
    mutating func le64(_ v: UInt64) { for i in 0..<8 { append(UInt8((v >> (8 * UInt64(i))) & 0xFF)) } }
    /// RAR5 variable-length integer: 7 bits per byte, low bits first, 0x80 = more follows.
    mutating func vint(_ value: UInt64) {
        var v = value
        repeat {
            var b = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { b |= 0x80 }
            append(b)
        } while v != 0
    }
    /// 7-Zip "NUMBER" encoding (only the 1–3 byte forms are needed here).
    mutating func sevenZipNumber(_ v: UInt64) {
        if v < 0x80 { append(UInt8(v)) }
        else if v < 0x4000 { append(UInt8(0x80 | (v >> 8))); append(UInt8(v & 0xFF)) }
        else { precondition(v < 0x20_0000); append(UInt8(0xC0 | (v >> 16))); append(UInt8(v & 0xFF)); append(UInt8((v >> 8) & 0xFF)) }
    }
}

func bytes(_ s: String, _ encoding: String.Encoding) -> [UInt8] {
    guard let d = s.data(using: encoding) else { fatalError("\(s) not representable in \(encoding)") }
    return [UInt8](d)
}

func dosDateTime(year: Int = 2024, month: Int = 5, day: Int = 6, hour: Int = 7, minute: Int = 8, second: Int = 10) -> (date: UInt16, time: UInt16) {
    (UInt16(((year - 1980) << 9) | (month << 5) | day), UInt16((hour << 11) | (minute << 5) | (second / 2)))
}

// MARK: - Zip (stored entries, raw name bytes)

struct ZipBuilder {
    struct Entry {
        var name: [UInt8]
        var data: Data
        var flags: UInt16
        var isDirectory: Bool
        var extra: Data
    }

    var entries: [Entry] = []

    mutating func file(_ name: [UInt8], _ data: Data, utf8Flag: Bool = false, extra: Data = Data()) {
        entries.append(Entry(name: name, data: data, flags: utf8Flag ? 0x0800 : 0, isDirectory: false, extra: extra))
    }

    mutating func file(_ name: String, _ text: String, encoding: String.Encoding = .utf8, utf8Flag: Bool = false) {
        file(bytes(name, encoding), Data(text.utf8), utf8Flag: utf8Flag)
    }

    mutating func directory(_ name: [UInt8]) {
        entries.append(Entry(name: name, data: Data(), flags: 0, isDirectory: true, extra: Data()))
    }

    func build() -> Data {
        var out = Data()
        var central = Data()
        let (date, time) = dosDateTime()
        for e in entries {
            let crc = CRC32.checksum(e.data)
            let offset = UInt32(out.count)
            out.le32(0x0403_4B50); out.le16(20); out.le16(e.flags); out.le16(0)   // stored
            out.le16(time); out.le16(date); out.le32(crc)
            out.le32(UInt32(e.data.count)); out.le32(UInt32(e.data.count))
            out.le16(UInt16(e.name.count)); out.le16(UInt16(e.extra.count))
            out.append(contentsOf: e.name); out.append(e.extra); out.append(e.data)

            let mode: UInt32 = e.isDirectory ? 0o40755 : 0o100644
            central.le32(0x0201_4B50); central.le16((3 << 8) | 20); central.le16(20); central.le16(e.flags); central.le16(0)
            central.le16(time); central.le16(date); central.le32(crc)
            central.le32(UInt32(e.data.count)); central.le32(UInt32(e.data.count))
            central.le16(UInt16(e.name.count)); central.le16(UInt16(e.extra.count)); central.le16(0)
            central.le16(0); central.le16(0); central.le32((mode << 16) | (e.isDirectory ? 0x10 : 0)); central.le32(offset)
            central.append(contentsOf: e.name); central.append(e.extra)
        }
        let cdOffset = UInt32(out.count)
        out.append(central)
        out.le32(0x0605_4B50); out.le16(0); out.le16(0)
        out.le16(UInt16(entries.count)); out.le16(UInt16(entries.count))
        out.le32(UInt32(central.count)); out.le32(cdOffset); out.le16(0)
        return out
    }
}

// MARK: - RAR5 (store method), https://www.rarlab.com/technote.htm

enum RAR5Builder {
    static let signature = Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00])

    /// General block: CRC32(header size … extra area) + header size + fields, then data area.
    static func block(type: UInt64, flags: UInt64, body: Data, extra: Data = Data(), data: Data? = nil) -> Data {
        var fields = Data()
        fields.vint(type)
        var f = flags
        if !extra.isEmpty { f |= 0x0001 }
        if data != nil { f |= 0x0002 }
        fields.vint(f)
        if !extra.isEmpty { fields.vint(UInt64(extra.count)) }
        if let data { fields.vint(UInt64(data.count)) }
        fields.append(body)
        fields.append(extra)
        var header = Data()
        header.vint(UInt64(fields.count))
        header.append(fields)
        var out = Data()
        out.le32(CRC32.checksum(header))
        out.append(header)
        if let data { out.append(data) }
        return out
    }

    static func mainHeader(volume: Bool = false, volumeNumber: UInt64? = nil) -> Data {
        var body = Data()
        var archiveFlags: UInt64 = volume ? 0x0001 : 0
        if volumeNumber != nil { archiveFlags |= 0x0002 }
        body.vint(archiveFlags)
        if let volumeNumber { body.vint(volumeNumber) }
        return block(type: 1, flags: 0, body: body)
    }

    static func endHeader(moreVolumes: Bool = false) -> Data {
        var body = Data()
        body.vint(moreVolumes ? 0x0001 : 0)
        return block(type: 5, flags: 0, body: body)
    }

    /// File header with Unix host OS, mtime and (for files) the data CRC32.
    static func fileHeader(name: String, data: Data, isDirectory: Bool = false, blockFlags: UInt64 = 0,
                           storedData: Data? = nil, unpackedSize: Int? = nil, crc: UInt32? = nil,
                           encrypted: Bool = false) -> Data {
        var body = Data()
        let fileFlags: UInt64 = 0x0002 | (isDirectory ? 0x0001 : 0x0004)
        body.vint(fileFlags)
        body.vint(UInt64(unpackedSize ?? data.count))
        body.vint(isDirectory ? 0o40755 : 0o100644)
        body.le32(1_700_000_000)
        if !isDirectory { body.le32(crc ?? CRC32.checksum(data)) }
        body.vint(0)   // compression info: version 0, method 0 = store
        body.vint(1)   // host OS: Unix
        let nameBytes = Data(name.utf8)
        body.vint(UInt64(nameBytes.count))
        body.append(nameBytes)
        var extra = Data()
        if encrypted {
            // File encryption record: type 1, version 0 (AES-256), flags 0, KDF count, salt, IV.
            var record = Data()
            record.vint(0x01); record.vint(0); record.vint(0); record.append(15)
            record.append(Data(repeating: 0x53, count: 16)); record.append(Data(repeating: 0x49, count: 16))
            extra.vint(UInt64(record.count))
            extra.append(record)
        }
        // libarchive insists on a data area even for directories.
        return block(type: 2, flags: blockFlags, body: body, extra: extra, data: storedData ?? (isDirectory ? Data() : data))
    }

    static func archive(_ files: [(String, Data?)], encrypted: Bool = false) -> Data {
        var out = signature
        out.append(mainHeader())
        for (name, data) in files {
            if let data {
                out.append(fileHeader(name: name, data: data, encrypted: encrypted))
            } else {
                out.append(fileHeader(name: name, data: Data(), isDirectory: true))
            }
        }
        out.append(endHeader())
        return out
    }

    /// Two volumes holding one stored file split at `split`.
    static func twoVolumes(name: String, data: Data, split: Int) -> (Data, Data) {
        let first = data.prefix(split), second = data.suffix(from: split)
        var v1 = signature
        v1.append(mainHeader(volume: true))
        v1.append(fileHeader(name: name, data: data, blockFlags: 0x0010, storedData: Data(first), crc: CRC32.checksum(first)))
        v1.append(endHeader(moreVolumes: true))
        var v2 = signature
        v2.append(mainHeader(volume: true, volumeNumber: 1))
        v2.append(fileHeader(name: name, data: data, blockFlags: 0x0008, storedData: Data(second), crc: CRC32.checksum(data)))
        v2.append(endHeader())
        return (v1, v2)
    }

    /// Archive whose headers are encrypted (archive encryption header right after the signature).
    static func headerEncrypted() -> Data {
        var body = Data()
        body.vint(0); body.vint(0); body.append(15); body.append(Data(repeating: 0x53, count: 16))
        var out = signature
        out.append(block(type: 4, flags: 0, body: body))
        out.append(Data(repeating: 0, count: 64))
        return out
    }
}

// MARK: - RAR 1.5–4.x (store method)

enum RAR4Builder {
    static let signature = Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00])

    /// HEAD_CRC is the low 16 bits of CRC32 over HEAD_TYPE … end of header.
    static func header(type: UInt8, flags: UInt16, rest: Data) -> Data {
        var h = Data()
        h.append(type); h.le16(flags); h.le16(UInt16(7 + rest.count)); h.append(rest)
        var out = Data()
        out.le16(UInt16(CRC32.checksum(h) & 0xFFFF))
        out.append(h)
        return out
    }

    static func mainHeader(flags: UInt16 = 0) -> Data {
        var rest = Data(); rest.le16(0); rest.le32(0)
        return header(type: 0x73, flags: flags, rest: rest)
    }

    static func fileHeader(name: [UInt8], data: Data, isDirectory: Bool = false, encrypted: Bool = false) -> Data {
        var flags: UInt16 = 0x8000
        if isDirectory { flags |= 0x00E0 }
        if encrypted { flags |= 0x0004 | 0x0400 }
        let (date, time) = dosDateTime()
        var rest = Data()
        rest.le32(UInt32(data.count)); rest.le32(UInt32(data.count))
        rest.append(3)                                  // host OS: Unix
        rest.le32(CRC32.checksum(data))
        rest.le32((UInt32(date) << 16) | UInt32(time))
        rest.append(20)                                 // version needed: 2.0
        rest.append(0x30)                               // method: store
        rest.le16(UInt16(name.count))
        rest.le32(isDirectory ? 0o40755 : 0o100644)
        rest.append(contentsOf: name)
        if encrypted { rest.append(Data("SALTSALT".utf8)) }
        return header(type: 0x74, flags: flags, rest: rest) + data
    }

    static func archive(_ files: [(String, Data?)], encrypted: Bool = false) -> Data {
        var out = signature
        out.append(mainHeader())
        for (name, data) in files {
            if let data {
                out.append(fileHeader(name: Array(name.utf8), data: data, encrypted: encrypted))
            } else {
                out.append(fileHeader(name: Array(name.utf8), data: Data(), isDirectory: true))
            }
        }
        out.append(header(type: 0x7B, flags: 0x4000, rest: Data()))
        return out
    }

    static func headerEncrypted() -> Data {
        var out = signature
        out.append(mainHeader(flags: 0x0080))
        out.append(Data("SALTSALT".utf8))
        out.append(Data(repeating: 0, count: 64))
        return out
    }
}

// MARK: - 7z with one folder and one coder (copy or AES-256 + SHA-256)

enum SevenZipBuilder {
    static let copyCoder: [UInt8] = [0x00]
    static let aesCoder: [UInt8] = [0x06, 0xF1, 0x07, 0x01]

    private static func streamsInfo(packPos: UInt64, packSize: Int, unpackSize: Int, coder: [UInt8], properties: [UInt8]) -> Data {
        var d = Data()
        d.append(0x06); d.sevenZipNumber(packPos); d.sevenZipNumber(1)                      // PackInfo
        d.append(0x09); d.sevenZipNumber(UInt64(packSize)); d.append(0x00)
        d.append(0x07); d.append(0x0B); d.sevenZipNumber(1); d.append(0x00)                 // UnPackInfo, 1 folder
        d.sevenZipNumber(1)                                                                  // 1 coder
        d.append(UInt8(coder.count) | (properties.isEmpty ? 0 : 0x20)); d.append(contentsOf: coder)
        if !properties.isEmpty { d.sevenZipNumber(UInt64(properties.count)); d.append(contentsOf: properties) }
        d.append(0x0C); d.sevenZipNumber(UInt64(unpackSize)); d.append(0x00)                // CodersUnPackSize, end
        return d
    }

    /// `packed` is stored as is; with the AES coder libarchive only needs to see the coder ID.
    static func archive(name: String, packed: Data, unpackSize: Int, coder: [UInt8], properties: [UInt8] = [],
                        encryptHeader: Bool = false) -> Data {
        var header = Data([0x01, 0x04])                                                     // Header, MainStreamsInfo
        header.append(streamsInfo(packPos: 0, packSize: packed.count, unpackSize: unpackSize, coder: coder, properties: properties))
        header.append(contentsOf: [0x08, 0x00])                                             // SubStreamsInfo, end
        header.append(0x00)                                                                 // end MainStreamsInfo
        header.append(0x05); header.sevenZipNumber(1)                                       // FilesInfo, 1 file
        var nameData = name.data(using: .utf16LittleEndian)!
        nameData.append(contentsOf: [0, 0])
        header.append(0x11); header.sevenZipNumber(UInt64(nameData.count + 1)); header.append(0x00); header.append(nameData)
        header.append(0x00); header.append(0x00)                                            // end FilesInfo, end Header

        var payload = packed
        if encryptHeader {
            let encoded = header
            payload.append(encoded)
            header = Data([0x17])                                                           // EncodedHeader
            header.append(streamsInfo(packPos: UInt64(packed.count), packSize: encoded.count, unpackSize: encoded.count,
                                      coder: aesCoder, properties: properties))
            header.append(0x00)
        }
        var start = Data()
        start.le64(UInt64(payload.count)); start.le64(UInt64(header.count)); start.le32(CRC32.checksum(header))
        var out = Data([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0x00, 0x04])
        out.le32(CRC32.checksum(start))
        out.append(start)
        out.append(payload)
        out.append(header)
        return out
    }

    static let aesProperties: [UInt8] = [0x53, 0x07] + [UInt8](repeating: 1, count: 16)
}

// MARK: - CAB (uncompressed folder)

enum CABBuilder {
    static func archive(_ files: [(String, Data)]) -> Data {
        let allData = files.reduce(Data()) { $0 + $1.1 }
        var cffiles = Data()
        var offset: UInt32 = 0
        let (date, time) = dosDateTime()
        for (name, data) in files {
            cffiles.le32(UInt32(data.count)); cffiles.le32(offset); cffiles.le16(0)
            cffiles.le16(date); cffiles.le16(time); cffiles.le16(0x20)
            cffiles.append(contentsOf: Array(name.utf8)); cffiles.append(0)
            offset += UInt32(data.count)
        }
        let coffFiles: UInt32 = 36 + 8
        let coffData = coffFiles + UInt32(cffiles.count)
        var cfdata = Data()
        cfdata.le32(0); cfdata.le16(UInt16(allData.count)); cfdata.le16(UInt16(allData.count)); cfdata.append(allData)
        var out = Data("MSCF".utf8)
        out.le32(0); out.le32(coffData + UInt32(cfdata.count)); out.le32(0); out.le32(coffFiles); out.le32(0)
        out.append(3); out.append(1); out.le16(1); out.le16(UInt16(files.count)); out.le16(0); out.le16(0); out.le16(0)
        out.le32(coffData); out.le16(1); out.le16(0)                                         // CFFOLDER, no compression
        out.append(cffiles)
        out.append(cfdata)
        return out
    }
}

// MARK: - LHA level-0 headers, -lh0- (stored)

enum LHABuilder {
    static func crc16(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0
        for b in data {
            crc ^= UInt16(b)
            for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1 }
        }
        return crc
    }

    static func archive(_ files: [([UInt8], Data)]) -> Data {
        var out = Data()
        let (date, time) = dosDateTime()
        for (name, data) in files {
            var body = Data("-lh0-".utf8)
            body.le32(UInt32(data.count)); body.le32(UInt32(data.count))
            body.le16(time); body.le16(date); body.append(0x20); body.append(0x00); body.append(UInt8(name.count))
            body.append(contentsOf: name)
            body.le16(crc16(data))
            out.append(UInt8(body.count)); out.append(UInt8(body.reduce(0) { ($0 + Int($1)) & 0xFF }))
            out.append(body); out.append(data)
        }
        out.append(0)
        return out
    }
}

// MARK: - ustar

struct TarBuilder {
    private(set) var data = Data()

    private mutating func header(name fullName: [UInt8], type: UInt8, size: Int = 0, mode: Int = 0o644, link fullLink: [UInt8] = []) {
        var name = fullName, link = fullLink
        if name.count > 100 || link.count > 100 {
            // pax extended header carrying the long path/linkpath.
            var records = Data()
            func record(_ key: String, _ value: [UInt8]) {
                let body = Array(" \(key)=".utf8) + value + [0x0A]
                var length = body.count + 1
                while String(length).count + body.count != length { length = String(length).count + body.count }
                records.append(contentsOf: Array(String(length).utf8) + body)
            }
            if name.count > 100 { record("path", name); name = Array(name.prefix(100)) }
            if link.count > 100 { record("linkpath", link); link = Array(link.prefix(100)) }
            header(name: Array("PaxHeader".utf8), type: UInt8(ascii: "x"), size: records.count)
            data.append(records)
            data.append(Data(repeating: 0, count: (512 - records.count % 512) % 512))
        }
        var h = [UInt8](repeating: 0, count: 512)
        func put(_ bytes: [UInt8], _ offset: Int) { for (i, b) in bytes.enumerated() { h[offset + i] = b } }
        func octal(_ v: Int, _ width: Int) -> [UInt8] {
            let s = String(v, radix: 8)
            return Array((String(repeating: "0", count: max(0, width - 1 - s.count)) + s).utf8) + [0]
        }
        put(name, 0)
        put(octal(mode, 8), 100); put(octal(501, 8), 108); put(octal(20, 8), 116)
        put(octal(size, 12), 124); put(octal(1_700_000_000, 12), 136)
        put(Array(repeating: 0x20, count: 8), 148)
        h[156] = type
        put(link, 157)
        put(Array("ustar".utf8) + [0], 257); put(Array("00".utf8), 263)
        let sum = h.reduce(0) { $0 + Int($1) }
        put(Array(String(format: "%06o", sum).utf8) + [0, 0x20], 148)
        data.append(contentsOf: h)
    }

    mutating func file(_ name: [UInt8], _ contents: Data, mode: Int = 0o644) {
        header(name: name, type: UInt8(ascii: "0"), size: contents.count, mode: mode)
        data.append(contents)
        let pad = (512 - contents.count % 512) % 512
        data.append(Data(repeating: 0, count: pad))
    }

    mutating func file(_ name: String, _ text: String) { file(Array(name.utf8), Data(text.utf8)) }

    mutating func directory(_ name: String, mode: Int = 0o755) { header(name: Array(name.utf8), type: UInt8(ascii: "5"), mode: mode) }

    mutating func symlink(_ name: String, to target: String) {
        header(name: Array(name.utf8), type: UInt8(ascii: "2"), mode: 0o755, link: Array(target.utf8))
    }

    mutating func hardlink(_ name: String, to target: String) {
        header(name: Array(name.utf8), type: UInt8(ascii: "1"), link: Array(target.utf8))
    }

    func build() -> Data { data + Data(repeating: 0, count: 1024) }
}

// MARK: - gzip via Foundation (NSData .zlib = raw DEFLATE)

enum GzipBuilder {
    static func gzip(_ payload: Data, originalName: String? = nil) throws -> Data {
        let deflated = try (payload as NSData).compressed(using: .zlib) as Data
        var out = Data([0x1F, 0x8B, 0x08, originalName == nil ? 0x00 : 0x08, 0, 0, 0, 0, 0x00, 0x03])
        if let originalName { out.append(contentsOf: Array(originalName.utf8)); out.append(0) }
        out.append(deflated)
        out.le32(CRC32.checksum(payload))
        out.le32(UInt32(truncatingIfNeeded: payload.count))
        return out
    }
}

// MARK: - Temp dirs and tools

final class TempDir {
    let url: URL

    init(_ label: String = "ArchiveTests") {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).resolvingSymlinksInPath()
        url = base.appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        // Archives may create read-only folders; make everything writable before removal.
        if let e = FileManager.default.enumerator(atPath: url.path) {
            for case let p as String in e { chmod(url.appendingPathComponent(p).path, 0o755) }
        }
        try? FileManager.default.removeItem(at: url)
    }

    func sub(_ name: String) -> URL {
        let u = url.appendingPathComponent(name, isDirectory: true)
        try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @discardableResult
    func write(_ name: String, _ data: Data) -> URL {
        let u = url.appendingPathComponent(name)
        try! FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! data.write(to: u)
        return u
    }

    @discardableResult
    func write(_ name: String, text: String) -> URL { write(name, Data(text.utf8)) }
}

enum Tool {
    /// Runs a system tool and returns its exit status and combined output.
    @discardableResult
    static func run(_ path: String, _ arguments: [String], in directory: URL? = nil,
                    environment: [String: String]? = nil) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        if let environment { process.environment = environment }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }

    static func bsdtar(_ arguments: [String], in directory: URL? = nil) throws {
        let r = try run("/usr/bin/bsdtar", arguments, in: directory, environment: ["LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "COPYFILE_DISABLE": "1"])
        if r.status != 0 { throw NSError(domain: "bsdtar", code: Int(r.status), userInfo: [NSLocalizedDescriptionKey: r.output]) }
    }
}

/// Reads every regular file under `root` into [relativePath: contents].
func treeContents(_ root: URL) -> [String: String] {
    var result: [String: String] = [:]
    guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return result }
    let base = root.resolvingSymlinksInPath().path
    for case let u as URL in e {
        let values = try? u.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
        var rel = u.resolvingSymlinksInPath().path
        if rel.hasPrefix(base + "/") { rel.removeFirst(base.count + 1) }
        result[rel.precomposedStringWithCanonicalMapping] = (try? String(contentsOf: u, encoding: .utf8)) ?? "<binary>"
    }
    return result
}

/// Visible names in a directory (ignores .DS_Store).
func listing(_ dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        .filter { $0 != ".DS_Store" }
        .map(\.precomposedStringWithCanonicalMapping)
        .sorted()
}

// MARK: - Builder self-checks

final class ArchiveFixtureBuildersTests: XCTestCase {
    func testCRC32KnownVector() {
        XCTAssertEqual(CRC32.checksum(Array("123456789".utf8)), 0xCBF4_3926)
    }

    func testVintEncoding() {
        var d = Data()
        d.vint(0); d.vint(127); d.vint(128); d.vint(300)
        XCTAssertEqual([UInt8](d), [0x00, 0x7F, 0x80, 0x01, 0xAC, 0x02])
    }

    func testGzipBuilderRoundTripsThroughGunzip() throws {
        let tmp = TempDir()
        let gz = tmp.write("hello.txt.gz", try GzipBuilder.gzip(Data("hello gzip\n".utf8), originalName: "hello.txt"))
        let r = try Tool.run("/usr/bin/gzip", ["-dc", gz.path])
        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(r.output, "hello gzip\n")
    }

    func testTarBuilderIsReadableByBsdtar() throws {
        let tmp = TempDir()
        var tar = TarBuilder()
        tar.directory("dir/")
        tar.file("dir/a.txt", "A")
        tar.symlink("dir/link", to: "a.txt")
        let url = tmp.write("t.tar", tar.build())
        let r = try Tool.run("/usr/bin/bsdtar", ["-tvf", url.path])
        XCTAssertEqual(r.status, 0, r.output)
        XCTAssertTrue(r.output.contains("dir/link -> a.txt"), r.output)
    }

    func testZipBuilderIsReadableByUnzip() throws {
        let tmp = TempDir()
        var zip = ZipBuilder()
        zip.file("a.txt", "A")
        let url = tmp.write("t.zip", zip.build())
        let r = try Tool.run("/usr/bin/unzip", ["-t", url.path])
        XCTAssertEqual(r.status, 0, r.output)
    }
}
