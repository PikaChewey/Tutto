//
//  ArchiveFilenameEncodingTests.swift
//  TuttoKitTests
//

import Foundation
import XCTest
@testable import TuttoKit

final class ArchiveFilenameEncodingTests: XCTestCase {

    private func raw(_ names: [String], _ encoding: String.Encoding) -> [Data] {
        names.map { Data(bytes($0, encoding)) }
    }

    func testUTF8AndASCIINeedNoEncoding() {
        XCTAssertNil(FilenameEncoding.detect([]))
        XCTAssertNil(FilenameEncoding.detect([Data("plain.txt".utf8), Data("dir/file".utf8)]))
        XCTAssertNil(FilenameEncoding.detect([Data("日本語.txt".utf8), Data("Привет.txt".utf8)]))
    }

    func testDetectsEachCandidate() {
        let cases: [(String, String.Encoding, [String])] = [
            ("Shift-JIS", .shiftJIS, ["日本語.txt", "フォルダ/ファイル.txt", "新しいフォルダ/写真/旅行の記録.jpg"]),
            ("GB18030", FilenameEncoding.gb18030, ["中文文件.txt", "新建文件夹/说明.txt"]),
            ("Big5", FilenameEncoding.big5, ["繁體中文.txt", "新增資料夾/說明.txt"]),
            ("Korean", FilenameEncoding.korean, ["한국어.txt", "새 폴더/설명.txt"]),
            ("CP1251", .windowsCP1251, ["Привет.txt", "Документы/отчёт.txt"]),
            ("CP866", FilenameEncoding.cp866, ["Привет.txt", "Документы/", "Документы/отчёт.txt"]),
            ("CP437", FilenameEncoding.cp437, ["Café.txt", "Ñandú.txt"]),
            ("Mac Roman", .macOSRoman, ["Café.txt", "Résumé.doc"]),
        ]
        for (label, encoding, names) in cases {
            let samples = raw(names, encoding)
            let detected = FilenameEncoding.detect(samples)
            XCTAssertEqual(detected, encoding, "\(label): got \(detected.map(FilenameEncoding.displayName) ?? "nil")")
            XCTAssertEqual(samples.map { FilenameEncoding.decode($0, using: detected) }, names, label)
        }
        // CP1252 and ISO Latin-1 decode these bytes identically; either is right.
        let western = raw(["Naïve résumé.txt", "Über/Straße.txt"], .windowsCP1252)
        let detected = FilenameEncoding.detect(western)
        XCTAssertTrue([String.Encoding.windowsCP1252, .isoLatin1].contains(detected))
        XCTAssertEqual(western.map { FilenameEncoding.decode($0, using: detected) }, ["Naïve résumé.txt", "Über/Straße.txt"])
    }

    func testSingleShortNames() {
        XCTAssertEqual(FilenameEncoding.detect(raw(["Привет.txt"], .windowsCP1251)), .windowsCP1251)
        XCTAssertEqual(FilenameEncoding.detect(raw(["日本語.txt"], .shiftJIS)), .shiftJIS)
        XCTAssertEqual(FilenameEncoding.detect(raw(["说明.txt"], FilenameEncoding.gb18030)), FilenameEncoding.gb18030)
        XCTAssertEqual(FilenameEncoding.detect(raw(["ﾃｽﾄ.txt"], .shiftJIS)), .shiftJIS, "half-width katakana")
    }

    func testMixedArchiveKeepsUTF8Names() {
        let names = [Data("ascii.txt".utf8), Data("日本語-utf8.txt".utf8), Data(bytes("日本語.txt", .shiftJIS))]
        let detected = FilenameEncoding.detect(names)
        XCTAssertEqual(detected, .shiftJIS)
        XCTAssertEqual(names.map { FilenameEncoding.decode($0, using: detected) }, ["ascii.txt", "日本語-utf8.txt", "日本語.txt"])
    }

    func testBackslashTrailByteRepair() {
        // libarchive turns 0x5C into "/" in non-Unicode names: 表 (95 5C) arrives as 95 2F.
        var mangled = bytes("表.txt", .shiftJIS)
        XCTAssertEqual(Array(mangled.prefix(2)), [0x95, 0x5C])
        mangled[1] = 0x2F
        XCTAssertEqual(FilenameEncoding.decode(Data(mangled), using: .shiftJIS), "表.txt")
        // A real separator after a complete character stays a separator.
        var dir = bytes("ソフト\\a.txt", .shiftJIS)
        dir = dir.map { $0 == 0x5C ? 0x2F : $0 }
        XCTAssertEqual(FilenameEncoding.decode(Data(dir), using: .shiftJIS), "ソフト/a.txt")
        XCTAssertEqual(FilenameEncoding.detect([Data(mangled), Data(dir)]), .shiftJIS)
    }

    func testUndecodableBytesBecomeUnderscores() {
        XCTAssertEqual(FilenameEncoding.decode(Data([0x61, 0xFF, 0x62]), using: nil), "a_b")
        // Valid UTF-8 is never re-interpreted, even with an explicit legacy encoding.
        XCTAssertEqual(FilenameEncoding.decode(Data("Café".utf8), using: .shiftJIS), "Café")
    }
}
