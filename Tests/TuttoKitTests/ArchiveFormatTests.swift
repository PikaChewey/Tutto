//
//  ArchiveFormatTests.swift
//  TuttoKitTests
//
//  The empirical format matrix for the system libarchive (3.7.4 on macOS 26): every format is
//  created at test time (bsdtar, zip, Foundation, or hand-crafted bytes) and extracted.
//

import Foundation
import XCTest
@testable import TuttoKit

final class ArchiveFormatTests: XCTestCase {

    func testLibarchiveVersion() {
        // Documented baseline; the matrix in ArchiveTypes.swift was verified against it.
        XCTAssertTrue(ArchiveSystemInfo.libarchiveVersion.hasPrefix("libarchive 3."), ArchiveSystemInfo.libarchiveVersion)
    }

    // MARK: bsdtar-created formats

    func testFormatsWrittenByBsdtar() throws {
        let tmp = TempDir()
        let staging = makeStaging(tmp)
        let cases: [(String, [String])] = [
            ("p.zip", ["--format", "zip"]),
            ("p.7z", ["--format", "7zip"]),
            ("p-copy.7z", ["--format", "7zip", "--options", "7zip:compression=copy"]),
            ("p-deflate.7z", ["--format", "7zip", "--options", "7zip:compression=deflate"]),
            ("p-bzip2.7z", ["--format", "7zip", "--options", "7zip:compression=bzip2"]),
            ("p-lzma2.7z", ["--format", "7zip", "--options", "7zip:compression=lzma2"]),
            ("p-ppmd.7z", ["--format", "7zip", "--options", "7zip:compression=ppmd"]),
            ("p-store.zip", ["--format", "zip", "--options", "zip:compression=store"]),
            ("p.tar", ["--format", "pax"]),
            ("p-ustar.tar", ["--format", "ustar"]),
            ("p-gnu.tar", ["--format", "gnutar"]),
            ("p.tar.gz", ["-z"]),
            ("p.tgz", ["-z"]),
            ("p.tar.bz2", ["-j"]),
            ("p.tar.xz", ["-J"]),
            ("p.tar.lzma", ["--lzma"]),
            ("p.tar.lz", ["--lzip"]),
            ("p.tar.Z", ["-Z"]),
            ("p.cpio", ["--format", "cpio"]),
            ("p-newc.cpio", ["--format", "newc"]),
            ("p.cpgz", ["--format", "cpio", "-z"]),
            ("p.iso", ["--format", "iso9660"]),
            ("p.xar", ["--format", "xar"]),
            ("p.uu.tar", ["--uuencode"]),
        ]
        for (name, flags) in cases {
            let archive = tmp.url.appendingPathComponent(name)
            try Tool.bsdtar(flags + ["-cf", archive.path, "-C", staging.path, "Project"])
            let dest = tmp.sub("dest-\(name)")
            let result = try extract(archive, to: dest)
            XCTAssertEqual(treeContents(dest), projectTree, name)
            XCTAssertEqual(result.items.map(\.lastPathComponent), ["Project"], name)
            XCTAssertNil(result.detectedEncoding, name)
            let listed = try ArchiveExtractor(url: archive).listEntries()
            XCTAssertTrue(listed.contains { $0.path == "Project/日本語.txt" && !$0.isDirectory && $0.size == 8 }, "\(name): \(listed)")
        }
    }

    func testArAndWarcHoldFilesOnly() throws {
        let tmp = TempDir()
        let staging = makeStaging(tmp)
        for (name, format) in [("n.a", "arbsd"), ("n-gnu.ar", "argnu"), ("n.warc", "warc")] {
            let archive = tmp.url.appendingPathComponent(name)
            try Tool.bsdtar(["--format", format, "-cf", archive.path, "-C", staging.path, "notes.txt"])
            let dest = tmp.sub("dest-\(name)")
            _ = try extract(archive, to: dest)
            XCTAssertEqual(treeContents(dest), ["notes.txt": "notes\n"], name)
        }
    }

    // MARK: Single-file compressors (raw format)

    func testSingleFileCompressorsNameTheOutputAfterTheArchive() throws {
        let tmp = TempDir()
        let staging = makeStaging(tmp)
        let payload = "notes\n"
        tmp.write("report.txt.gz", try GzipBuilder.gzip(Data(payload.utf8), originalName: "something-else.txt"))
        tmp.write("nameless.gz", try GzipBuilder.gzip(Data(payload.utf8)))
        for (name, flag) in [("report.txt.bz2", "-j"), ("report.txt.xz", "-J"), ("report.txt.lzma", "--lzma"),
                             ("report.txt.lz", "--lzip"), ("report.txt.Z", "-Z")] {
            try Tool.bsdtar(["--format", "raw", flag, "-cf", tmp.url.appendingPathComponent(name).path, "-C", staging.path, "notes.txt"])
        }
        let expectations = [
            "report.txt.gz": "report.txt", "nameless.gz": "nameless", "report.txt.bz2": "report.txt",
            "report.txt.xz": "report.txt", "report.txt.lzma": "report.txt", "report.txt.lz": "report.txt",
            "report.txt.Z": "report.txt",
        ]
        for (archiveName, outputName) in expectations {
            let archive = tmp.url.appendingPathComponent(archiveName)
            let dest = tmp.sub("dest-\(archiveName)")
            let result = try extract(archive, to: dest)
            XCTAssertEqual(treeContents(dest), [outputName: payload], archiveName)
            XCTAssertEqual(result.items.map(\.lastPathComponent), [outputName])
            XCTAssertEqual(try ArchiveExtractor(url: archive).listEntries().map(\.path), [outputName])
        }
        // "always" still wraps the single file in a folder named after the archive.
        let dest = tmp.sub("dest-always")
        let wrapped = try extract(tmp.url.appendingPathComponent("report.txt.gz"), to: dest, ArchiveExtractionOptions(folderRule: .always))
        XCTAssertEqual(wrapped.containingFolder?.lastPathComponent, "report.txt")
        XCTAssertEqual(treeContents(dest), ["report.txt/report.txt": payload])
    }

    func testCompressedEmptyFile() throws {
        let tmp = TempDir()
        let archive = tmp.write("empty.txt.gz", try GzipBuilder.gzip(Data()))
        let dest = tmp.sub("dest")
        let result = try extract(archive, to: dest)
        XCTAssertEqual(result.items.map(\.lastPathComponent), ["empty.txt"])
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("empty.txt")), Data())
    }

    // MARK: RAR

    func testRAR5StoredArchive() throws {
        let tmp = TempDir()
        let archive = tmp.write("store5.rar", RAR5Builder.archive([
            ("folder", nil), ("folder/hello.txt", Data("Hello RAR5\n".utf8)), ("top.txt", Data("top\n".utf8)),
            ("日本語.txt", Data("utf8 names\n".utf8)),
        ]))
        let dest = tmp.sub("dest")
        let result = try extract(archive, to: dest)
        XCTAssertEqual(result.containingFolder?.lastPathComponent, "store5")
        XCTAssertEqual(treeContents(dest), [
            "store5/folder/hello.txt": "Hello RAR5\n", "store5/top.txt": "top\n", "store5/日本語.txt": "utf8 names\n",
        ])
        XCTAssertNil(result.detectedEncoding)
        let entries = try ArchiveExtractor(url: archive).listEntries()
        XCTAssertEqual(entries.map(\.path), ["folder", "folder/hello.txt", "top.txt", "日本語.txt"])
        XCTAssertEqual(entries.map(\.isDirectory), [true, false, false, false])
        XCTAssertFalse(entries.contains(where: \.isEncrypted))
    }

    func testRAR4StoredArchive() throws {
        let tmp = TempDir()
        let archive = tmp.write("store4.rar", RAR4Builder.archive([
            ("folder", nil), ("folder/hello.txt", Data("Hello RAR4\n".utf8)), ("top.txt", Data("top\n".utf8)),
        ]))
        let dest = tmp.sub("dest")
        let result = try extract(archive, to: dest)
        XCTAssertEqual(treeContents(dest), ["store4/folder/hello.txt": "Hello RAR4\n", "store4/top.txt": "top\n"])
        XCTAssertEqual(result.entryCount, 3)
    }

    func testRAR4LegacyEncodedNames() throws {
        let tmp = TempDir()
        var data = RAR4Builder.signature
        data.append(RAR4Builder.mainHeader())
        data.append(RAR4Builder.fileHeader(name: bytes("Документы", FilenameEncoding.cp866), data: Data(), isDirectory: true))
        data.append(RAR4Builder.fileHeader(name: bytes("Документы\\отчёт.txt", FilenameEncoding.cp866), data: Data("x".utf8)))
        data.append(RAR4Builder.header(type: 0x7B, flags: 0x4000, rest: Data()))
        let archive = tmp.write("dos.rar", data)
        let dest = tmp.sub("dest")
        let result = try extract(archive, to: dest)
        XCTAssertEqual(result.detectedEncoding, FilenameEncoding.cp866)
        XCTAssertEqual(treeContents(dest), ["Документы/отчёт.txt": "x"])
    }

    func testRAR5MultiVolumeFromAnyVolume() throws {
        let tmp = TempDir()
        let payload = Data((0..<500).map { UInt8(48 + $0 % 10) })
        let (v1, v2) = RAR5Builder.twoVolumes(name: "big.txt", data: payload, split: 123)
        let part1 = tmp.write("multi.part1.rar", v1)
        let part2 = tmp.write("multi.part2.rar", v2)
        XCTAssertEqual(ArchiveVolumes.volumes(for: part2), [part1, part2])
        let extractor = ArchiveExtractor(url: part2)
        XCTAssertEqual(extractor.volumes, [part1, part2])
        let dest = tmp.sub("dest")
        let result = try extractor.extract(to: dest, options: ArchiveExtractionOptions(), progress: { _ in }, isCancelled: { false })
        XCTAssertEqual(result.items.map(\.lastPathComponent), ["big.txt"])
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("big.txt")), payload)
    }

    func testEncryptedRARIsUnsupported() throws {
        let tmp = TempDir()
        let files: [(String, Data?)] = [("folder", nil), ("folder/secret.txt", Data("ciphertext\n".utf8))]
        let cases: [(String, Data)] = [
            ("enc5.rar", RAR5Builder.archive(files, encrypted: true)),
            ("hdr5.rar", RAR5Builder.headerEncrypted()),
            ("enc4.rar", RAR4Builder.archive(files, encrypted: true)),
            ("hdr4.rar", RAR4Builder.headerEncrypted()),
        ]
        for (name, data) in cases {
            let archive = tmp.write(name, data)
            let dest = tmp.sub("dest-\(name)")
            XCTAssertThrowsArchiveError(.unsupportedEncryption(format: "RAR")) { _ = try extract(archive, to: dest) }
            XCTAssertThrowsArchiveError(.unsupportedEncryption(format: "RAR")) {
                _ = try extract(archive, to: dest, ArchiveExtractionOptions(password: "anything"))
            }
            XCTAssertEqual(listing(dest), [], name)
            assertNoTempFolders(dest)
        }
        for name in ["enc5.rar", "enc4.rar"] {
            let entries = try ArchiveExtractor(url: tmp.url.appendingPathComponent(name)).listEntries()
            XCTAssertEqual(entries.first { $0.path == "folder/secret.txt" }?.isEncrypted, true, name)
        }
    }

    // MARK: 7z

    func testHandCrafted7zAndEncrypted7z() throws {
        let tmp = TempDir()
        let plain = tmp.write("plain.7z", SevenZipBuilder.archive(name: "plain.txt", packed: Data("plain text\n".utf8),
                                                                    unpackSize: 11, coder: SevenZipBuilder.copyCoder))
        let dest = tmp.sub("dest")
        _ = try extract(plain, to: dest)
        XCTAssertEqual(treeContents(dest), ["plain.txt": "plain text\n"])

        let aes = tmp.write("aes.7z", SevenZipBuilder.archive(name: "secret.txt", packed: Data(repeating: 0x11, count: 16), unpackSize: 11,
                                                                coder: SevenZipBuilder.aesCoder, properties: SevenZipBuilder.aesProperties))
        let aesHeader = tmp.write("aeshdr.7z", SevenZipBuilder.archive(name: "secret.txt", packed: Data(repeating: 0x11, count: 16), unpackSize: 11,
                                                                         coder: SevenZipBuilder.aesCoder, properties: SevenZipBuilder.aesProperties,
                                                                         encryptHeader: true))
        for archive in [aes, aesHeader] {
            let d = tmp.sub("dest-\(archive.lastPathComponent)")
            XCTAssertThrowsArchiveError(.unsupportedEncryption(format: "7-Zip")) { _ = try extract(archive, to: d) }
            XCTAssertThrowsArchiveError(.unsupportedEncryption(format: "7-Zip")) {
                _ = try extract(archive, to: d, ArchiveExtractionOptions(password: "pw"))
            }
            XCTAssertEqual(listing(d), [])
            assertNoTempFolders(d)
        }
        XCTAssertEqual(try ArchiveExtractor(url: aes).listEntries().first?.isEncrypted, true)
    }

    // MARK: CAB, LHA

    func testCABAndLHA() throws {
        let tmp = TempDir()
        let cab = tmp.write("stored.cab", CABBuilder.archive([("hello.txt", Data("hello cab\n".utf8)), ("dir\\inner.txt", Data("inner\n".utf8))]))
        let lzh = tmp.write("stored.lzh", LHABuilder.archive([(Array("hello.txt".utf8), Data("hello lha\n".utf8)),
                                                             (Array("dir\\inner.txt".utf8), Data("inner\n".utf8))]))
        let d1 = tmp.sub("cab"), d2 = tmp.sub("lzh")
        _ = try extract(cab, to: d1)
        _ = try extract(lzh, to: d2)
        XCTAssertEqual(treeContents(d1), ["stored/hello.txt": "hello cab\n", "stored/dir/inner.txt": "inner\n"])
        XCTAssertEqual(treeContents(d2), ["stored/hello.txt": "hello lha\n", "stored/dir/inner.txt": "inner\n"])
    }

    func testLHAWithShiftJISName() throws {
        let tmp = TempDir()
        let lzh = tmp.write("jp.lzh", LHABuilder.archive([(bytes("日本語.txt", .shiftJIS), Data("nihongo\n".utf8)),
                                                         (bytes("表計算.txt", .shiftJIS), Data("hyou\n".utf8))]))
        let dest = tmp.sub("dest")
        let result = try extract(lzh, to: dest)
        XCTAssertEqual(result.detectedEncoding, .shiftJIS)
        XCTAssertEqual(treeContents(dest), ["jp/日本語.txt": "nihongo\n", "jp/表計算.txt": "hyou\n"])
    }

    // MARK: Garbled zip names

    func testShiftJISZipNames() throws {
        let tmp = TempDir()
        var zip = ZipBuilder()
        zip.directory(bytes("フォルダ/", .shiftJIS))
        zip.file(bytes("フォルダ/ファイル.txt", .shiftJIS), Data("file\n".utf8))
        zip.file(bytes("日本語.txt", .shiftJIS), Data("nihongo\n".utf8))
        zip.file(bytes("表.txt", .shiftJIS), Data("0x5C trail byte\n".utf8))          // 95 5C
        zip.file(bytes("ソフト\\readme.txt", .shiftJIS), Data("backslash dir\n".utf8))   // 83 5C … 5C
        let archive = tmp.write("sjis.zip", zip.build())
        let dest = tmp.sub("dest")

        let result = try extract(archive, to: dest)
        XCTAssertEqual(result.detectedEncoding, .shiftJIS)
        XCTAssertEqual(treeContents(dest), [
            "sjis/フォルダ/ファイル.txt": "file\n", "sjis/日本語.txt": "nihongo\n",
            "sjis/表.txt": "0x5C trail byte\n", "sjis/ソフト/readme.txt": "backslash dir\n",
        ])
        let listed = try ArchiveExtractor(url: archive).listEntries().map(\.path)
        XCTAssertEqual(listed, ["フォルダ", "フォルダ/ファイル.txt", "日本語.txt", "表.txt", "ソフト/readme.txt"])
    }

    func testCyrillicZipNames() throws {
        let tmp = TempDir()
        for (label, encoding) in [("cp866", FilenameEncoding.cp866), ("cp1251", String.Encoding.windowsCP1251)] {
            var zip = ZipBuilder()
            zip.file(bytes("Привет.txt", encoding), Data("hi\n".utf8))
            zip.directory(bytes("Документы/", encoding))
            zip.file(bytes("Документы/отчёт за май.txt", encoding), Data("report\n".utf8))
            let archive = tmp.write("\(label).zip", zip.build())
            let dest = tmp.sub("dest-\(label)")
            let result = try extract(archive, to: dest)
            XCTAssertEqual(result.detectedEncoding, encoding, label)
            XCTAssertEqual(treeContents(dest), ["\(label)/Привет.txt": "hi\n", "\(label)/Документы/отчёт за май.txt": "report\n"], label)
        }
    }

    func testChineseKoreanAndWesternZipNames() throws {
        let tmp = TempDir()
        let cases: [(String, String.Encoding, [String])] = [
            ("gbk", FilenameEncoding.gb18030, ["中文文件.txt", "新建文件夹/说明文档.txt"]),
            ("big5", FilenameEncoding.big5, ["繁體中文.txt", "新增資料夾/說明.txt"]),
            ("korean", FilenameEncoding.korean, ["한국어 문서.txt", "새 폴더/설명서.txt"]),
            ("cp437", FilenameEncoding.cp437, ["Café.txt", "Ñandú/Año.txt"]),
            ("cp1252", .windowsCP1252, ["Naïve résumé.txt", "Über/Straße.txt"]),
        ]
        for (label, encoding, names) in cases {
            var zip = ZipBuilder()
            for name in names { zip.file(bytes(name, encoding), Data(name.utf8)) }
            let archive = tmp.write("\(label).zip", zip.build())
            let dest = tmp.sub("dest-\(label)")
            let result = try extract(archive, to: dest, ArchiveExtractionOptions(folderRule: .always))
            var expected: [String: String] = [:]
            for name in names { expected["\(label)/\(name)"] = name }
            XCTAssertEqual(treeContents(dest), expected, label)
            if encoding == .windowsCP1252 {
                XCTAssertTrue([String.Encoding.windowsCP1252, .isoLatin1].contains(result.detectedEncoding), label)
            } else {
                XCTAssertEqual(result.detectedEncoding, encoding, label)
            }
        }
    }

    func testUTF8ZipNamesNeedNoDetection() throws {
        let tmp = TempDir()
        var flagged = ZipBuilder()
        flagged.file("日本語.txt", "a", utf8Flag: true)
        var unflagged = ZipBuilder()
        unflagged.file("日本語.txt", "a")
        var unicodePath = ZipBuilder()
        // Info-ZIP Unicode Path extra field (0x7075) carrying the UTF-8 name for a Shift-JIS name.
        let sjis = bytes("日本語.txt", .shiftJIS)
        var field = Data([1]); field.le32(CRC32.checksum(sjis)); field.append(Data("日本語.txt".utf8))
        var extra = Data(); extra.le16(0x7075); extra.le16(UInt16(field.count)); extra.append(field)
        unicodePath.file(sjis, Data("a".utf8), extra: extra)
        for (name, builder) in [("flagged", flagged), ("unflagged", unflagged), ("upath", unicodePath)] {
            let archive = tmp.write("\(name).zip", builder.build())
            let dest = tmp.sub("dest-\(name)")
            let result = try extract(archive, to: dest)
            XCTAssertNil(result.detectedEncoding, name)
            XCTAssertEqual(listing(dest), ["日本語.txt"], name)
        }
    }

    func testEncodingOverride() throws {
        let tmp = TempDir()
        var zip = ZipBuilder()
        let raw = bytes("日本語.txt", .shiftJIS)
        zip.file(raw, Data("x".utf8))
        let archive = tmp.write("o.zip", zip.build())
        let dest = tmp.sub("dest")
        let result = try extract(archive, to: dest, ArchiveExtractionOptions(encodingOverride: .windowsCP1251))
        let expected = try XCTUnwrap(String(data: Data(raw), encoding: .windowsCP1251))
        XCTAssertEqual(result.detectedEncoding, .windowsCP1251)
        XCTAssertEqual(listing(dest), [expected])
        let listed = try ArchiveExtractor(url: archive).listEntries(options: ArchiveExtractionOptions(encodingOverride: .windowsCP1251))
        XCTAssertEqual(listed.map(\.path), [expected])
    }

    func testTarWithLegacyNamesDecodesPerEntry() throws {
        let tmp = TempDir()
        var tar = TarBuilder()
        tar.file(bytes("Привет.txt", .windowsCP1251), Data("a".utf8))
        tar.file(bytes("Отчёт за май.txt", .windowsCP1251), Data("b".utf8))
        let plain = tmp.write("legacy.tar", tar.build())
        let gz = tmp.write("legacy.tar.gz", try GzipBuilder.gzip(tar.build()))
        for archive in [plain, gz] {
            let dest = tmp.sub("dest-\(archive.lastPathComponent)")
            let result = try extract(archive, to: dest)
            XCTAssertEqual(result.detectedEncoding, .windowsCP1251)
            XCTAssertEqual(treeContents(dest), ["legacy/Привет.txt": "a", "legacy/Отчёт за май.txt": "b"])
        }
    }

    // MARK: Multi-volume byte splits and spanned zips

    func testSplitArchives() throws {
        let tmp = TempDir()
        let staging = tmp.sub("src")
        var random = Data(count: 300_000)
        random.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        try random.write(to: staging.appendingPathComponent("random.bin"))
        tmp.write("src/hello.txt", text: "hello split\n")

        for (format, ext) in [("7zip", "7z"), ("zip", "zip")] {
            let whole = tmp.url.appendingPathComponent("whole.\(ext)")
            try Tool.bsdtar(["--format", format, "-cf", whole.path, "-C", staging.path, "random.bin", "hello.txt"])
            let data = try Data(contentsOf: whole)
            var parts: [URL] = []
            var offset = 0, index = 1
            while offset < data.count {
                let chunk = data[offset..<min(offset + 100_000, data.count)]
                parts.append(tmp.write(String(format: "Split.\(ext).%03d", index), Data(chunk)))
                offset += 100_000; index += 1
            }
            XCTAssertEqual(ArchiveVolumes.volumes(for: parts[1]), parts)
            let dest = tmp.sub("dest-\(ext)")
            let result = try extract(parts[2], to: dest)
            XCTAssertEqual(result.containingFolder?.lastPathComponent, "Split")
            XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("Split/random.bin")), random)
        }

        // Info-ZIP spanned archive: Spanned.z01, Spanned.z02, Spanned.zip
        let r = try Tool.run("/usr/bin/zip", ["-q", "-s", "100k", tmp.url.appendingPathComponent("Spanned.zip").path, "random.bin", "hello.txt"], in: staging)
        XCTAssertEqual(r.status, 0, r.output)
        let spanned = tmp.url.appendingPathComponent("Spanned.zip")
        let set = ArchiveVolumes.volumes(for: spanned)
        XCTAssertEqual(set.map(\.lastPathComponent), ["Spanned.z01", "Spanned.z02", "Spanned.zip"])
        let dest = tmp.sub("dest-span")
        _ = try extract(spanned, to: dest)
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("Spanned/random.bin")), random)
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("Spanned/hello.txt"), encoding: .utf8), "hello split\n")
    }
}
