//
//  ArchiveBrowsingTests.swift
//  TuttoKitTests
//
//  Looking inside archives (the tree), taking out only some entries, and adding and removing
//  files in place.
//

import Foundation
import XCTest
@testable import TuttoKit

final class ArchiveBrowsingTests: XCTestCase {

    func testTreeMakesUpFoldersAndTotalsThem() {
        let tree = ArchiveTree(entries: [
            ArchiveEntryInfo(path: "a/b/c.txt", isDirectory: false, size: 3, isEncrypted: false),
            ArchiveEntryInfo(path: "a/d.txt", isDirectory: false, size: 4, isEncrypted: false),
            ArchiveEntryInfo(path: "e.txt", isDirectory: false, size: 5, isEncrypted: false),
            ArchiveEntryInfo(path: "a/", isDirectory: true, size: 0, isEncrypted: false),
        ])
        XCTAssertEqual(tree.children(of: "").map(\.path), ["a", "e.txt"], "folders first")
        XCTAssertEqual(tree.node("a")?.size, 7)
        XCTAssertEqual(tree.node("a")?.fileCount, 2)
        XCTAssertEqual(tree.root.size, 12)
        XCTAssertEqual(tree.children(of: "a/").map(\.name), ["b", "d.txt"])
        XCTAssertEqual(tree.node("a/b/c.txt")?.parent, "a/b/")
        XCTAssertEqual(ArchiveTree.trail(to: "a/b"), ["a", "a/b"])
        XCTAssertEqual(tree.search("D.TXT").map(\.path), ["a/d.txt"])
        XCTAssertTrue(ArchiveNames.isArchive("inner.tar.gz"))
        XCTAssertFalse(ArchiveNames.isArchive("notes.txt"))
    }

    private func makeAlbum(_ tmp: TempDir) -> URL {
        tmp.write("src/Album/photo.txt", text: "photo\n")
        tmp.write("src/Album/sub/deep.txt", text: "deep\n")
        tmp.write("src/Album/sub/deeper/x.txt", text: "x\n")
        return tmp.url.appendingPathComponent("src/Album")
    }

    func testExtractsOnlyTheChosenEntriesFromTheFolderInView() throws {
        let tmp = TempDir()
        let album = makeAlbum(tmp)
        for format in ArchiveCompressionFormat.allCases {
            let archive = try ArchiveCompressor.compress([album], to: tmp.url.appendingPathComponent("A.\(format.fileExtension)"), format: format)
            let dest = tmp.sub("pick-\(format.rawValue)")
            var options = ArchiveExtractionOptions(folderRule: .never)
            options.selection = ArchiveSelection(paths: ["Album/sub"], base: "Album/")
            _ = try ArchiveExtractor(url: archive).extract(to: dest, options: options)
            XCTAssertEqual(treeContents(dest), ["sub/deep.txt": "deep\n", "sub/deeper/x.txt": "x\n"], "\(format)")

            let single = tmp.sub("single-\(format.rawValue)")
            options.selection = ArchiveSelection(paths: ["Album/sub/deeper/x.txt"], base: "Album/sub/deeper/")
            _ = try ArchiveExtractor(url: archive).extract(to: single, options: options)
            XCTAssertEqual(treeContents(single), ["x.txt": "x\n"], "\(format)")
        }
    }

    func testListingCarriesModificationDates() throws {
        let tmp = TempDir()
        let album = makeAlbum(tmp)
        let archive = try ArchiveCompressor.compress([album], to: tmp.url.appendingPathComponent("A.zip"), format: .zip)
        let entries = try ArchiveExtractor(url: archive).listEntries()
        let photo = try XCTUnwrap(entries.first { $0.path == "Album/photo.txt" })
        XCTAssertNotNil(photo.modified)
        XCTAssertLessThan(abs(photo.modified!.timeIntervalSinceNow), 600)
    }

    func testRemovesAndAddsInEveryWritableFormat() throws {
        let tmp = TempDir()
        let album = makeAlbum(tmp)
        let extra = tmp.write("more/new.txt", text: "new\n")
        let replacement = tmp.write("more/photo.txt", text: "photo 2\n")
        for format in ArchiveCompressionFormat.allCases {
            let archive = try ArchiveCompressor.compress([album], to: tmp.url.appendingPathComponent("E.\(format.fileExtension)"), format: format)
            XCTAssertNil(ArchiveEditor.readOnlyReason(archive), "\(format)")
            try ArchiveEditor.update(archive, removing: ["Album/sub/deeper"],
                                     adding: [ArchiveAddition(source: extra, folder: "Album/sub"),
                                              ArchiveAddition(source: replacement, folder: "Album/")],
                                     trashingOld: false)
            let dest = tmp.sub("edited-\(format.rawValue)")
            _ = try ArchiveExtractor(url: archive).extract(to: dest, options: ArchiveExtractionOptions(folderRule: .never))
            XCTAssertEqual(treeContents(dest), [
                "Album/photo.txt": "photo 2\n", "Album/sub/deep.txt": "deep\n", "Album/sub/new.txt": "new\n",
            ], "\(format)")
            // Still the same kind of archive, readable by the system's bsdtar.
            XCTAssertEqual(ArchiveEditor.kind(of: archive), ArchiveEditor.kind(of: archive))
            let check = try Tool.run("/usr/bin/bsdtar", ["-tf", archive.path])
            XCTAssertEqual(check.status, 0, check.output)
            XCTAssertEqual(listing(tmp.url).filter { $0.hasPrefix(".Tutto") }, [], "no leftovers")
        }
    }

    func testRemovingEverythingLeavesAnEmptyButValidArchive() throws {
        let tmp = TempDir()
        let album = makeAlbum(tmp)
        let archive = try ArchiveCompressor.compress([album], to: tmp.url.appendingPathComponent("Empty.zip"), format: .zip)
        try ArchiveEditor.update(archive, removing: ["Album"], trashingOld: false)
        XCTAssertEqual(try ArchiveExtractor(url: archive).listEntries().count, 0)
    }
}
