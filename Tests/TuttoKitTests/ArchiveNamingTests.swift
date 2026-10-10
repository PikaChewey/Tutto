//
//  ArchiveNamingTests.swift
//  TuttoKitTests
//

import Foundation
import XCTest
@testable import TuttoKit

final class ArchiveNamingTests: XCTestCase {

    func testBaseName() {
        let cases: [String: String] = [
            "Photos.zip": "Photos",
            "src.tar.gz": "src",
            "src.TAR.GZ": "src",
            "src.tgz": "src",
            "backup.tar.bz2": "backup",
            "backup.tbz2": "backup",
            "image.tar.xz": "image",
            "data.tar.zst": "data",
            "notes.txt.gz": "notes.txt",
            "Movie.part1.rar": "Movie",
            "Movie.part01.rar": "Movie",
            "Movie.PART001.RAR": "Movie",
            "Movie.rar": "Movie",
            "Old.r00": "Old",
            "Old.r17": "Old",
            "Span.z01": "Span",
            "Backup.7z.001": "Backup",
            "Backup.zip.002": "Backup",
            "Backup.tar.gz.001": "Backup",
            "video.001": "video",
            "v1.2.3.zip": "v1.2.3",
            "my.archive.rar": "my.archive",
            "README": "README",
            "disk.iso": "disk",
            "Installer.pkg": "Installer",
        ]
        for (name, expected) in cases {
            XCTAssertEqual(ArchiveNaming.baseName(of: URL(fileURLWithPath: "/tmp/\(name)")), expected, name)
        }
    }

    func testSingleFileOutputName() {
        XCTAssertEqual(ArchiveNaming.singleFileOutputName(for: URL(fileURLWithPath: "/x/notes.txt.gz")), "notes.txt")
        XCTAssertEqual(ArchiveNaming.singleFileOutputName(for: URL(fileURLWithPath: "/x/backup.tgz")), "backup.tar")
        XCTAssertEqual(ArchiveNaming.singleFileOutputName(for: URL(fileURLWithPath: "/x/data.bin.xz")), "data.bin")
        XCTAssertEqual(ArchiveNaming.singleFileOutputName(for: URL(fileURLWithPath: "/x/old.Z")), "old")
    }

    func testUniqueURL() throws {
        let tmp = TempDir()
        let file = tmp.url.appendingPathComponent("report.pdf")
        XCTAssertEqual(ArchiveNaming.uniqueURL(for: file), file)
        tmp.write("report.pdf", text: "1")
        XCTAssertEqual(ArchiveNaming.uniqueURL(for: file).lastPathComponent, "report 2.pdf")
        tmp.write("report 2.pdf", text: "2")
        XCTAssertEqual(ArchiveNaming.uniqueURL(for: file).lastPathComponent, "report 3.pdf")

        _ = tmp.sub("Folder")
        XCTAssertEqual(ArchiveNaming.uniqueURL(for: tmp.url.appendingPathComponent("Folder", isDirectory: true)).lastPathComponent, "Folder 2")
        _ = tmp.sub("v1.2")
        XCTAssertEqual(ArchiveNaming.uniqueURL(for: tmp.url.appendingPathComponent("v1.2", isDirectory: true)).lastPathComponent, "v1.2 2")

        tmp.write(".config", text: "c")
        XCTAssertEqual(ArchiveNaming.uniqueURL(for: tmp.url.appendingPathComponent(".config")).lastPathComponent, ".config 2")

        // A dangling symlink still occupies the name.
        try FileManager.default.createSymbolicLink(atPath: tmp.url.appendingPathComponent("dangling").path, withDestinationPath: "/nonexistent/x")
        XCTAssertEqual(ArchiveNaming.uniqueURL(for: tmp.url.appendingPathComponent("dangling")).lastPathComponent, "dangling 2")
    }

    func testIsLikelyArchive() {
        let yes = ["a.zip", "a.ZIP", "a.rar", "a.7z", "a.tar", "a.tar.gz", "a.tgz", "a.tbz2", "a.txz", "a.gz", "a.bz2", "a.xz",
                   "a.lzma", "a.Z", "a.iso", "a.cab", "a.lzh", "a.lha", "a.xar", "a.pkg", "a.cpio", "a.cpgz", "a.deb", "a.rpm",
                   "a.warc", "a.part2.rar", "a.r00", "a.r42", "a.z01", "a.z12", "a.7z.001", "a.zip.003", "a.001"]
        let no = ["a.txt", "a.jpg", "a.docx", "README", "report.2024", "a.zst2", "a.app", "a.dmg", "a.zz"]
        for name in yes { XCTAssertTrue(ArchiveFormats.isLikelyArchive(URL(fileURLWithPath: "/x/\(name)")), name) }
        for name in no { XCTAssertFalse(ArchiveFormats.isLikelyArchive(URL(fileURLWithPath: "/x/\(name)")), name) }
        XCTAssertTrue(ArchiveFormats.extractableExtensions.isSuperset(of: ["zip", "rar", "7z", "gz", "tgz", "iso", "xar", "lzh"]))
    }

    func testVolumeDetection() throws {
        let tmp = TempDir()
        func touch(_ names: [String]) -> [URL] { names.map { tmp.write($0, text: $0) } }

        let parts = touch(["Movie.part1.rar", "Movie.part2.rar", "Movie.part3.rar"])
        XCTAssertEqual(ArchiveVolumes.volumes(for: parts[1]), parts)
        XCTAssertEqual(ArchiveVolumes.firstVolume(for: parts[2]), parts[0])
        XCTAssertTrue(ArchiveVolumes.isSecondaryVolume(parts[1]))
        XCTAssertFalse(ArchiveVolumes.isSecondaryVolume(parts[0]))

        let padded = touch(["Show.part01.rar", "Show.part02.rar"])
        XCTAssertEqual(ArchiveVolumes.volumes(for: padded[0]), padded)

        let old = touch(["Old.rar", "Old.r00", "Old.r01"])
        XCTAssertEqual(ArchiveVolumes.volumes(for: old[0]), old)
        XCTAssertEqual(ArchiveVolumes.volumes(for: old[2]), old)
        XCTAssertEqual(ArchiveVolumes.firstVolume(for: old[1]), old[0])

        let span = touch(["Span.z01", "Span.z02", "Span.zip"])
        XCTAssertEqual(ArchiveVolumes.volumes(for: span[2]), span)
        XCTAssertEqual(ArchiveVolumes.volumes(for: span[1]), span)
        XCTAssertEqual(ArchiveVolumes.firstVolume(for: span[2]), span[0])

        let split = touch(["Backup.7z.001", "Backup.7z.002", "Backup.7z.003"])
        XCTAssertEqual(ArchiveVolumes.volumes(for: split[2]), split)
        XCTAssertEqual(ArchiveVolumes.firstVolume(for: split[1]), split[0])

        let single = touch(["Single.zip", "Lonely.rar"])
        XCTAssertEqual(ArchiveVolumes.volumes(for: single[0]), [single[0]])
        XCTAssertEqual(ArchiveVolumes.volumes(for: single[1]), [single[1]])
        XCTAssertFalse(ArchiveVolumes.isSecondaryVolume(single[0]))

        // Incomplete at the start: part1 missing → just the file itself.
        let orphan = touch(["Gap.part2.rar"])
        XCTAssertEqual(ArchiveVolumes.volumes(for: orphan[0]), orphan)
        // Spanned set without the final .zip is incomplete.
        let noTail = touch(["Tail.z01"])
        XCTAssertEqual(ArchiveVolumes.volumes(for: noTail[0]), noTail)
    }
}
