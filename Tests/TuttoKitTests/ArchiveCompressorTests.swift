//
//  ArchiveCompressorTests.swift
//  TuttoKitTests
//

import Foundation
import XCTest
@testable import TuttoKit

final class ArchiveCompressorTests: XCTestCase {

    /// src/Album/{photo.txt, sub/deep.txt, Café 日本.txt, link -> photo.txt, .DS_Store}, src/loose.txt
    private func makeSource(_ tmp: TempDir) throws -> (album: URL, loose: URL) {
        tmp.write("src/Album/photo.txt", text: "photo\n")
        tmp.write("src/Album/sub/deep.txt", text: "deep\n")
        tmp.write("src/Album/Café 日本.txt", text: "unicode\n")
        tmp.write("src/Album/.DS_Store", text: "junk")
        tmp.write("src/Album/sub/.DS_Store", text: "junk")
        try FileManager.default.createSymbolicLink(atPath: tmp.url.appendingPathComponent("src/Album/link").path, withDestinationPath: "photo.txt")
        let loose = tmp.write("src/loose.txt", text: "loose\n")
        return (tmp.url.appendingPathComponent("src/Album"), loose)
    }

    func testRoundTripEveryFormat() throws {
        let tmp = TempDir()
        let (album, loose) = try makeSource(tmp)
        for format in ArchiveCompressionFormat.allCases {
            let output = tmp.url.appendingPathComponent("out/Bundle.\(format.fileExtension)")
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            let counter = Counter()
            let written = try ArchiveCompressor.compress([album, loose], to: output, format: format,
                                                         progress: { counter.record($0) }, isCancelled: { false })
            XCTAssertEqual(written, output, "\(format)")
            XCTAssertEqual(counter.fractions.last, 1)

            // Readable by the system bsdtar too.
            let listingOutput = try Tool.run("/usr/bin/bsdtar", ["-tf", written.path], environment: ["LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"])
            XCTAssertEqual(listingOutput.status, 0, listingOutput.output)
            XCTAssertFalse(listingOutput.output.contains(".DS_Store"), "\(format)")

            let dest = tmp.sub("dest-\(format.rawValue)")
            let result = try extract(written, to: dest, ArchiveExtractionOptions(folderRule: .never))
            XCTAssertNil(result.detectedEncoding, "\(format)")
            XCTAssertEqual(treeContents(dest), [
                "Album/photo.txt": "photo\n", "Album/sub/deep.txt": "deep\n", "Album/Café 日本.txt": "unicode\n",
                "loose.txt": "loose\n",
            ], "\(format)")
            let link = dest.appendingPathComponent("Album/link").path
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link), "photo.txt", "\(format) keeps symlinks")
            XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent("Album/.DS_Store").path))
            XCTAssertEqual(listing(output.deletingLastPathComponent()).filter { $0.hasPrefix(".Tutto") }, [])
        }
    }

    func testZipNamesCarryTheUTF8Flag() throws {
        let tmp = TempDir()
        let file = tmp.write("src/Café 日本.txt", text: "x")
        let zip = try ArchiveCompressor.compress([file], to: tmp.url.appendingPathComponent("u.zip"), format: .zip)
        let data = [UInt8](try Data(contentsOf: zip))
        // Walk the central directory: signature 50 4B 01 02, flags at +8, name length at +28, name at +46.
        var found = false
        var i = 0
        while i + 46 <= data.count {
            if data[i] == 0x50, data[i + 1] == 0x4B, data[i + 2] == 0x01, data[i + 3] == 0x02 {
                let flags = UInt16(data[i + 8]) | UInt16(data[i + 9]) << 8
                let nameLength = Int(UInt16(data[i + 28]) | UInt16(data[i + 29]) << 8)
                let name = String(decoding: data[(i + 46)..<(i + 46 + nameLength)], as: UTF8.self)
                XCTAssertEqual(name.precomposedStringWithCanonicalMapping, "Café 日本.txt")
                XCTAssertNotEqual(flags & 0x0800, 0, "UTF-8 flag set")
                found = true
            }
            i += 1
        }
        XCTAssertTrue(found)
        let unzip = try Tool.run("/usr/bin/unzip", ["-t", zip.path])
        XCTAssertEqual(unzip.status, 0, unzip.output)
    }

    func testOutputNameIsMadeUnique() throws {
        let tmp = TempDir()
        let file = tmp.write("src/a.txt", text: "a")
        let output = tmp.url.appendingPathComponent("Archive.zip")
        tmp.write("Archive.zip", text: "existing")
        let first = try ArchiveCompressor.compress([file], to: output, format: .zip)
        let second = try ArchiveCompressor.compress([file], to: output, format: .zip)
        XCTAssertEqual(first.lastPathComponent, "Archive 2.zip")
        XCTAssertEqual(second.lastPathComponent, "Archive 3.zip")
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "existing")
        let tgz = try ArchiveCompressor.compress([file], to: tmp.url.appendingPathComponent("Archive.tar.gz"), format: .tarGzip)
        XCTAssertEqual(tgz.lastPathComponent, "Archive.tar.gz")
        let tgz2 = try ArchiveCompressor.compress([file], to: tmp.url.appendingPathComponent("Archive.tar.gz"), format: .tarGzip)
        XCTAssertEqual(tgz2.lastPathComponent, "Archive 2.tar.gz")
    }

    func testDefaultOutputURL() {
        let a = URL(fileURLWithPath: "/Users/x/Desktop/Report")
        let b = URL(fileURLWithPath: "/Users/x/Desktop/notes.txt")
        XCTAssertEqual(ArchiveCompressor.defaultOutputURL(for: [a], format: .zip).path, "/Users/x/Desktop/Report.zip")
        XCTAssertEqual(ArchiveCompressor.defaultOutputURL(for: [a, b], format: .sevenZip).path, "/Users/x/Desktop/Archive.7z")
        XCTAssertEqual(ArchiveCompressor.defaultOutputURL(for: [b], format: .tarXz).path, "/Users/x/Desktop/notes.txt.tar.xz")
    }

    func testCancellationLeavesNothing() throws {
        let tmp = TempDir()
        let big = tmp.write("src/big.bin", Data(count: 8 << 20))
        let outDir = tmp.sub("out")
        for format in ArchiveCompressionFormat.allCases {
            let counter = Counter()
            XCTAssertThrowsArchiveError(.cancelled) {
                _ = try ArchiveCompressor.compress([big], to: outDir.appendingPathComponent("big.\(format.fileExtension)"), format: format,
                                                   progress: { _ in }, isCancelled: { counter.increment() > 3 })
            }
            XCTAssertEqual(listing(outDir), [], "\(format)")
            XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: outDir.path)) ?? [], [], "\(format) temp removed")
        }
    }

    func testMissingInput() {
        let tmp = TempDir()
        XCTAssertThrowsError(try ArchiveCompressor.compress([tmp.url.appendingPathComponent("nope")], to: tmp.url.appendingPathComponent("x.zip"), format: .zip)) { error in
            guard case ArchiveError.cannotOpen = error else { return XCTFail("got \(error)") }
        }
    }
}
