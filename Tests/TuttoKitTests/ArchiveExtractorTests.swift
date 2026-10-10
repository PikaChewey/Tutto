//
//  ArchiveExtractorTests.swift
//  TuttoKitTests
//
//  Folder rules, unique naming, safety (traversal, symlinks, hard links), passwords,
//  cancellation, progress, metadata. Fixtures are generated per test in a temp directory.
//

import Darwin
import Foundation
import XCTest
@testable import TuttoKit

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    private(set) var fractions: [Double] = []
    private(set) var times: [TimeInterval] = []

    @discardableResult
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }

    func record(_ p: ArchiveProgress) {
        lock.lock(); defer { lock.unlock() }
        fractions.append(p.fraction)
        times.append(ProcessInfo.processInfo.systemUptime)
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

func extract(_ archive: URL, to destination: URL, _ options: ArchiveExtractionOptions = ArchiveExtractionOptions()) throws -> ArchiveExtractionResult {
    try ArchiveExtractor(url: archive).extract(to: destination, options: options, progress: { _ in }, isCancelled: { false })
}

func XCTAssertThrowsArchiveError(_ expected: ArchiveError, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> Void) {
    do {
        try body()
        XCTFail("Expected \(expected), nothing thrown", file: file, line: line)
    } catch let error as ArchiveError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Expected \(expected), got \(error)", file: file, line: line)
    }
}

func assertNoTempFolders(_ dir: URL, file: StaticString = #filePath, line: UInt = #line) {
    let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix(".Tutto-") }
    XCTAssertEqual(leftovers, [], "temporary folders left behind", file: file, line: line)
}

/// staging/Project/{readme.txt, src/main.swift, 日本語.txt} and staging/notes.txt
func makeStaging(_ tmp: TempDir) -> URL {
    let staging = tmp.sub("staging")
    tmp.write("staging/Project/readme.txt", text: "readme\n")
    tmp.write("staging/Project/src/main.swift", text: "print(1)\n")
    tmp.write("staging/Project/日本語.txt", text: "nihongo\n")
    tmp.write("staging/notes.txt", text: "notes\n")
    return staging
}

let projectTree: [String: String] = [
    "Project/readme.txt": "readme\n",
    "Project/src/main.swift": "print(1)\n",
    "Project/日本語.txt": "nihongo\n",
]

final class ArchiveExtractorTests: XCTestCase {

    // MARK: Folder rules

    func testSmartRuleSingleTopLevelFolderIsNotWrapped() throws {
        let tmp = TempDir()
        let staging = makeStaging(tmp)
        let zip = tmp.url.appendingPathComponent("Single.zip")
        try Tool.bsdtar(["--format", "zip", "-cf", zip.path, "-C", staging.path, "Project"])
        let dest = tmp.sub("dest")

        let result = try extract(zip, to: dest)
        XCTAssertEqual(listing(dest), ["Project"])
        XCTAssertNil(result.containingFolder)
        XCTAssertEqual(result.items.map(\.lastPathComponent), ["Project"])
        XCTAssertEqual(treeContents(dest), projectTree)
        XCTAssertEqual(result.entryCount, 5)   // Project/, src/, 3 files
        XCTAssertEqual(result.bytesWritten, Int64("readme\nprint(1)\nnihongo\n".utf8.count))
        assertNoTempFolders(dest)
    }

    func testSmartRuleSingleTopLevelFileIsNotWrapped() throws {
        let tmp = TempDir()
        let staging = makeStaging(tmp)
        let zip = tmp.url.appendingPathComponent("OneFile.zip")
        try Tool.bsdtar(["--format", "zip", "-cf", zip.path, "-C", staging.path, "notes.txt"])
        let dest = tmp.sub("dest")
        let result = try extract(zip, to: dest)
        XCTAssertEqual(listing(dest), ["notes.txt"])
        XCTAssertEqual(result.items, [dest.appendingPathComponent("notes.txt")])
    }

    func testSmartRuleMultipleTopLevelItemsAreWrapped() throws {
        let tmp = TempDir()
        let staging = makeStaging(tmp)
        let zip = tmp.url.appendingPathComponent("Bundle.zip")
        try Tool.bsdtar(["--format", "zip", "-cf", zip.path, "-C", staging.path, "Project", "notes.txt"])
        let dest = tmp.sub("dest")

        let result = try extract(zip, to: dest)
        XCTAssertEqual(listing(dest), ["Bundle"])
        XCTAssertEqual(result.containingFolder?.lastPathComponent, "Bundle")
        XCTAssertEqual(listing(dest.appendingPathComponent("Bundle")), ["notes.txt", "Project"].sorted())
        var expected = projectTree.reduce(into: [String: String]()) { $0["Bundle/" + $1.key] = $1.value }
        expected["Bundle/notes.txt"] = "notes\n"
        XCTAssertEqual(treeContents(dest), expected)
        assertNoTempFolders(dest)
    }

    func testAlwaysRuleWrapsSingleItem() throws {
        let tmp = TempDir()
        let staging = makeStaging(tmp)
        let zip = tmp.url.appendingPathComponent("Single.zip")
        try Tool.bsdtar(["--format", "zip", "-cf", zip.path, "-C", staging.path, "Project"])
        let dest = tmp.sub("dest")
        let result = try extract(zip, to: dest, ArchiveExtractionOptions(folderRule: .always))
        XCTAssertEqual(listing(dest), ["Single"])
        XCTAssertEqual(result.containingFolder, dest.appendingPathComponent("Single", isDirectory: true))
        XCTAssertEqual(listing(dest.appendingPathComponent("Single")), ["Project"])
    }

    func testNeverRulePutsItemsDirectlyInDestination() throws {
        let tmp = TempDir()
        let staging = makeStaging(tmp)
        let zip = tmp.url.appendingPathComponent("Bundle.zip")
        try Tool.bsdtar(["--format", "zip", "-cf", zip.path, "-C", staging.path, "Project", "notes.txt"])
        let dest = tmp.sub("dest")
        let result = try extract(zip, to: dest, ArchiveExtractionOptions(folderRule: .never))
        XCTAssertEqual(listing(dest), ["notes.txt", "Project"].sorted())
        XCTAssertNil(result.containingFolder)
        XCTAssertEqual(Set(result.items.map(\.lastPathComponent)), ["notes.txt", "Project"])
        assertNoTempFolders(dest)
    }

    // MARK: Unique names

    func testExistingItemsAreNeverOverwritten() throws {
        let tmp = TempDir()
        let staging = makeStaging(tmp)
        let single = tmp.url.appendingPathComponent("Single.zip")
        let bundle = tmp.url.appendingPathComponent("Bundle.zip")
        try Tool.bsdtar(["--format", "zip", "-cf", single.path, "-C", staging.path, "Project"])
        try Tool.bsdtar(["--format", "zip", "-cf", bundle.path, "-C", staging.path, "Project", "notes.txt"])
        let dest = tmp.sub("dest")
        tmp.write("dest/Project/keep.txt", text: "mine")
        tmp.write("dest/Bundle/keep.txt", text: "mine too")
        tmp.write("dest/notes.txt", text: "my notes")

        let first = try extract(single, to: dest)
        XCTAssertEqual(first.items.map(\.lastPathComponent), ["Project 2"])
        let second = try extract(single, to: dest)
        XCTAssertEqual(second.items.map(\.lastPathComponent), ["Project 3"])
        let wrapped = try extract(bundle, to: dest)
        XCTAssertEqual(wrapped.containingFolder?.lastPathComponent, "Bundle 2")
        let never = try extract(bundle, to: dest, ArchiveExtractionOptions(folderRule: .never))
        XCTAssertEqual(Set(never.items.map(\.lastPathComponent)), ["notes 2.txt", "Project 4"])

        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("Project/keep.txt"), encoding: .utf8), "mine")
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("Bundle/keep.txt"), encoding: .utf8), "mine too")
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("notes.txt"), encoding: .utf8), "my notes")
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("notes 2.txt"), encoding: .utf8), "notes\n")
        XCTAssertEqual(listing(dest.appendingPathComponent("Project")), ["keep.txt"])
        assertNoTempFolders(dest)
    }

    // MARK: Safety

    func testPathTraversalEntriesStayInsideDestination() throws {
        let tmp = TempDir()
        var zip = ZipBuilder()
        zip.file("../evil.txt", "evil")
        zip.file("/abs.txt", "abs")
        zip.file("ok/../../evil2.txt", "evil2")
        zip.file("./good.txt", "good")
        zip.file("a/./b/../c.txt", "c")
        let archive = tmp.write("trav.zip", zip.build())
        let outer = tmp.sub("outer")
        let dest = tmp.sub("outer/dest")

        let result = try extract(archive, to: dest)
        XCTAssertEqual(result.containingFolder?.lastPathComponent, "trav")
        XCTAssertEqual(treeContents(dest), [
            "trav/evil.txt": "evil", "trav/abs.txt": "abs", "trav/ok/evil2.txt": "evil2",
            "trav/good.txt": "good", "trav/a/b/c.txt": "c",
        ])
        XCTAssertEqual(listing(outer), ["dest"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.url.appendingPathComponent("evil.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.url.appendingPathComponent("evil2.txt").path))
        assertNoTempFolders(dest)
    }

    func testTarTraversalAndEmptyNames() throws {
        let tmp = TempDir()
        var tar = TarBuilder()
        tar.directory("./")
        tar.file("../../up.txt", "up")
        tar.file("//double//slash.txt", "ds")
        tar.file("..", "dots")
        let archive = tmp.write("t.tar", tar.build())
        let dest = tmp.sub("dest")
        let result = try extract(archive, to: dest, ArchiveExtractionOptions(folderRule: .always))
        XCTAssertEqual(treeContents(dest), ["t/up.txt": "up", "t/double/slash.txt": "ds"])
        XCTAssertEqual(result.skippedEntries, [".."])
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.url.appendingPathComponent("up.txt").path))
    }

    func testSymlinkPointingOutsideIsNotFollowed() throws {
        let tmp = TempDir()
        let outside = tmp.sub("outside")
        var tar = TarBuilder()
        tar.symlink("link", to: outside.path)
        tar.file("link/pwned.txt", "pwned")
        tar.symlink("rel", to: "../../outside")
        tar.file("rel/pwned2.txt", "pwned")
        tar.file("safe.txt", "safe")
        let archive = tmp.write("evil.tar", tar.build())
        let dest = tmp.sub("dest")

        let result = try extract(archive, to: dest)
        XCTAssertEqual(listing(outside), [], "nothing may be written through the symlink")
        XCTAssertEqual(Set(result.skippedEntries), ["link/pwned.txt", "rel/pwned2.txt"])
        let folder = try XCTUnwrap(result.containingFolder)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: folder.appendingPathComponent("link").path), outside.path)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("safe.txt"), encoding: .utf8), "safe")
        assertNoTempFolders(dest)
    }

    func testHardLinksMustStayInside() throws {
        let tmp = TempDir()
        let victim = tmp.write("victim.txt", text: "secret")
        var tar = TarBuilder()
        tar.file("a.txt", "A")
        tar.hardlink("b.txt", to: "a.txt")
        tar.hardlink("c.txt", to: "../../victim.txt")
        tar.hardlink("d.txt", to: victim.path)
        tar.symlink("s", to: victim.path)
        tar.hardlink("e.txt", to: "s")
        let archive = tmp.write("links.tar", tar.build())
        let dest = tmp.sub("dest")

        let result = try extract(archive, to: dest)
        let folder = try XCTUnwrap(result.containingFolder)
        XCTAssertEqual(Set(result.skippedEntries), ["c.txt", "d.txt", "e.txt"])
        let a = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("a.txt").path)
        let b = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("b.txt").path)
        XCTAssertEqual(a[.systemFileNumber] as? Int, b[.systemFileNumber] as? Int, "b.txt is a hard link to a.txt")
        let victimInfo = try FileManager.default.attributesOfItem(atPath: victim.path)
        XCTAssertEqual(victimInfo[.referenceCount] as? Int, 1, "no new links to a file outside")
        XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "secret")
    }

    func testReadOnlyFoldersAreMadeOwnerWritable() throws {
        let tmp = TempDir()
        var tar = TarBuilder()
        tar.directory("Locked/", mode: 0o555)
        tar.directory("Locked/Inner/", mode: 0o500)
        tar.file(Array("Locked/Inner/file.txt".utf8), Data("ro".utf8), mode: 0o444)
        tar.file(Array("Locked/run.sh".utf8), Data("#!/bin/sh".utf8), mode: 0o755)
        let archive = tmp.write("ro.tar", tar.build())
        let dest = tmp.sub("dest")
        _ = try extract(archive, to: dest)
        func mode(_ p: String) throws -> Int {
            (try FileManager.default.attributesOfItem(atPath: dest.appendingPathComponent(p).path)[.posixPermissions] as? Int) ?? -1
        }
        XCTAssertEqual(try mode("Locked"), 0o755)
        XCTAssertEqual(try mode("Locked/Inner"), 0o700)
        XCTAssertEqual(try mode("Locked/Inner/file.txt"), 0o644)
        XCTAssertEqual(try mode("Locked/run.sh"), 0o755, "permissions are otherwise preserved")
        assertNoTempFolders(dest)
    }

    // MARK: Passwords

    func testZipCryptoPasswords() throws {
        let tmp = TempDir()
        let staging = makeStaging(tmp)
        let archive = tmp.url.appendingPathComponent("Secret.zip")
        let r = try Tool.run("/usr/bin/zip", ["-q", "-r", "-P", "hunter2", archive.path, "Project"], in: staging)
        XCTAssertEqual(r.status, 0, r.output)
        let dest = tmp.sub("dest")

        let entries = try ArchiveExtractor(url: archive).listEntries()
        XCTAssertTrue(entries.filter { !$0.isDirectory }.allSatisfy(\.isEncrypted))
        XCTAssertEqual(Set(entries.map(\.path)), ["Project", "Project/readme.txt", "Project/src", "Project/src/main.swift", "Project/日本語.txt"])

        XCTAssertThrowsArchiveError(.passwordRequired) { _ = try extract(archive, to: dest) }
        XCTAssertThrowsArchiveError(.wrongPassword) { _ = try extract(archive, to: dest, ArchiveExtractionOptions(password: "nope")) }
        XCTAssertEqual(listing(dest), [])
        assertNoTempFolders(dest)

        _ = try extract(archive, to: dest, ArchiveExtractionOptions(password: "hunter2"))
        XCTAssertEqual(treeContents(dest), projectTree)
    }

    func testZipAESPasswords() throws {
        let tmp = TempDir()
        let staging = makeStaging(tmp)
        for method in ["aes128", "aes256"] {
            let archive = tmp.url.appendingPathComponent("\(method).zip")
            try Tool.bsdtar(["--format", "zip", "--options", "zip:encryption=\(method)", "--passphrase", "s3cret",
                             "-cf", archive.path, "-C", staging.path, "Project"])
            let dest = tmp.sub("dest-\(method)")
            XCTAssertThrowsArchiveError(.passwordRequired) { _ = try extract(archive, to: dest) }
            XCTAssertThrowsArchiveError(.wrongPassword) { _ = try extract(archive, to: dest, ArchiveExtractionOptions(password: "S3cret")) }
            assertNoTempFolders(dest)
            _ = try extract(archive, to: dest, ArchiveExtractionOptions(password: "s3cret"))
            XCTAssertEqual(treeContents(dest), projectTree, method)
        }
    }

    // MARK: Cancellation & progress

    func testCancellationCleansUp() throws {
        let tmp = TempDir()
        let staging = tmp.sub("big")
        var random = Data(count: 6 << 20)
        random.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        try random.write(to: staging.appendingPathComponent("random.bin"))
        try random.write(to: staging.appendingPathComponent("random2.bin"))
        for (name, flag) in [("big.tar.gz", "-czf"), ("big.zip", "-cf")] {
            let archive = tmp.url.appendingPathComponent(name)
            var args = [flag, archive.path, "-C", staging.path, "."]
            if name.hasSuffix(".zip") { args.insert(contentsOf: ["--format", "zip"], at: 0) }
            try Tool.bsdtar(args)
            let dest = tmp.sub("dest-\(name)")
            let counter = Counter()
            XCTAssertThrowsArchiveError(.cancelled) {
                _ = try ArchiveExtractor(url: archive).extract(
                    to: dest, options: ArchiveExtractionOptions(), progress: { _ in },
                    isCancelled: { counter.increment() > 8 })
            }
            XCTAssertGreaterThan(counter.count, 8)
            XCTAssertEqual(listing(dest), [], name)
            assertNoTempFolders(dest)
        }
    }

    func testProgressIsMonotonicThrottledAndCompletes() throws {
        let tmp = TempDir()
        let staging = tmp.sub("big")
        var random = Data(count: 4 << 20)
        random.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        try random.write(to: staging.appendingPathComponent("random.bin"))
        let archive = tmp.url.appendingPathComponent("big.tar.gz")
        try Tool.bsdtar(["-czf", archive.path, "-C", staging.path, "random.bin"])
        let dest = tmp.sub("dest")
        let counter = Counter()
        let start = ProcessInfo.processInfo.systemUptime
        _ = try ArchiveExtractor(url: archive).extract(to: dest, options: ArchiveExtractionOptions(),
                                                       progress: { counter.record($0) }, isCancelled: { false })
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let fractions = counter.fractions
        XCTAssertEqual(fractions.last, 1)
        XCTAssertEqual(fractions, fractions.sorted(), "fraction never goes backwards")
        XCTAssertLessThanOrEqual(Double(fractions.count), 3 + elapsed * 20, "≤ 20 callbacks per second")
    }

    // MARK: Metadata

    func testMacOSXFolderBecomesMetadata() throws {
        let tmp = TempDir()
        let folder = tmp.sub("src/Folder")
        let tagged = tmp.write("src/Folder/tagged.txt", text: "hello")
        tmp.write("src/Folder/plain.txt", text: "plain")
        let value = "some value"
        XCTAssertEqual(setxattr(tagged.path, "com.example.tutto", value, value.utf8.count, 0, 0), 0)
        let archive = tmp.url.appendingPathComponent("ditto.zip")
        let r = try Tool.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", folder.path, archive.path])
        XCTAssertEqual(r.status, 0, r.output)
        XCTAssertTrue(try Tool.run("/usr/bin/unzip", ["-l", archive.path]).output.contains("__MACOSX"), "fixture has AppleDouble members")

        let dest = tmp.sub("dest")
        _ = try extract(archive, to: dest)
        XCTAssertEqual(listing(dest), ["Folder"], "no __MACOSX junk")
        XCTAssertEqual(listing(dest.appendingPathComponent("Folder")), ["plain.txt", "tagged.txt"])
        var buffer = [UInt8](repeating: 0, count: 64)
        let n = getxattr(dest.appendingPathComponent("Folder/tagged.txt").path, "com.example.tutto", &buffer, buffer.count, 0, 0)
        XCTAssertEqual(n, value.utf8.count, "extended attribute restored from the AppleDouble member")
        XCTAssertEqual(String(decoding: buffer.prefix(max(0, n)), as: UTF8.self), value)
    }

    func testTarAppleDoubleMembersBecomeMetadata() throws {
        let tmp = TempDir()
        let source = tmp.write("src/tagged.txt", text: "hello")
        let value = "from tar"
        XCTAssertEqual(setxattr(source.path, "com.example.tutto", value, value.utf8.count, 0, 0), 0)
        let appleDouble = tmp.url.appendingPathComponent("src/._tagged.txt")
        XCTAssertEqual(copyfile(source.path, appleDouble.path, nil, copyfile_flags_t(COPYFILE_PACK | COPYFILE_XATTR)), 0)
        var tar = TarBuilder()
        tar.directory("Folder/")
        tar.file(Array("Folder/._tagged.txt".utf8), try Data(contentsOf: appleDouble))   // AppleDouble precedes its file
        tar.file("Folder/tagged.txt", "hello")
        let archive = tmp.write("ad.tar", tar.build())
        let dest = tmp.sub("dest")
        _ = try extract(archive, to: dest)
        XCTAssertEqual(listing(dest.appendingPathComponent("Folder")), ["tagged.txt"], "no ._ debris")
        var buffer = [UInt8](repeating: 0, count: 64)
        let n = getxattr(dest.appendingPathComponent("Folder/tagged.txt").path, "com.example.tutto", &buffer, buffer.count, 0, 0)
        XCTAssertEqual(String(decoding: buffer.prefix(max(0, n)), as: UTF8.self), value)
    }

    func testOverlongPathsAreSkipped() throws {
        let tmp = TempDir()
        var tar = TarBuilder()
        let deep = Array(repeating: "deeply-nested-folder", count: 60).joined(separator: "/") + "/file.txt"
        tar.file(Array(deep.utf8), Data("deep".utf8))
        tar.file("ok.txt", "ok")
        let archive = tmp.write("deep.tar", tar.build())
        let dest = tmp.sub("dest")
        let result = try extract(archive, to: dest)
        XCTAssertEqual(result.skippedEntries, [deep])
        XCTAssertEqual(treeContents(dest), ["ok.txt": "ok"])
        assertNoTempFolders(dest)
    }

    func testModificationDates() throws {
        let tmp = TempDir()
        var tar = TarBuilder()
        tar.file("old.txt", "old")
        let archive = tmp.write("dated.tar", tar.build())
        let keep = tmp.sub("keep")
        _ = try extract(archive, to: keep)
        let kept = try FileManager.default.attributesOfItem(atPath: keep.appendingPathComponent("old.txt").path)[.modificationDate] as? Date
        XCTAssertEqual(kept?.timeIntervalSince1970, 1_700_000_000)

        let fresh = tmp.sub("fresh")
        _ = try extract(archive, to: fresh, ArchiveExtractionOptions(keepModificationDates: false))
        let now = try FileManager.default.attributesOfItem(atPath: fresh.appendingPathComponent("old.txt").path)[.modificationDate] as? Date
        XCTAssertLessThan(abs(now?.timeIntervalSinceNow ?? 1e9), 120)
    }

    func testQuarantineIsPropagated() throws {
        let tmp = TempDir()
        let staging = makeStaging(tmp)
        let archive = tmp.url.appendingPathComponent("Downloaded.zip")
        try Tool.bsdtar(["--format", "zip", "-cf", archive.path, "-C", staging.path, "Project"])
        let value = "0081;6720a000;Safari;"
        XCTAssertEqual(setxattr(archive.path, "com.apple.quarantine", value, value.utf8.count, 0, 0), 0)
        let dest = tmp.sub("dest")
        _ = try extract(archive, to: dest)
        for path in ["Project", "Project/readme.txt", "Project/src/main.swift"] {
            let n = getxattr(dest.appendingPathComponent(path).path, "com.apple.quarantine", nil, 0, 0, 0)
            XCTAssertGreaterThan(n, 0, "\(path) is quarantined")
        }
    }

    // MARK: Errors

    func testNotAnArchiveAndMissingFiles() throws {
        let tmp = TempDir()
        let dest = tmp.sub("dest")
        var random = Data(count: 4096)
        random.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        let junk = tmp.write("junk.zip", random)
        XCTAssertThrowsArchiveError(.notAnArchive) { _ = try extract(junk, to: dest) }
        XCTAssertThrowsArchiveError(.notAnArchive) { _ = try ArchiveExtractor(url: junk).listEntries() }
        let text = tmp.write("plain.txt", text: "just text, not compressed\n")
        XCTAssertThrowsArchiveError(.notAnArchive) { _ = try extract(text, to: dest) }
        let empty = tmp.write("empty.zip", Data())
        XCTAssertThrowsArchiveError(.notAnArchive) { _ = try extract(empty, to: dest) }
        do {
            _ = try extract(tmp.url.appendingPathComponent("missing.zip"), to: dest)
            XCTFail("expected cannotOpen")
        } catch ArchiveError.cannotOpen {
        }
        XCTAssertEqual(listing(dest), [])
        assertNoTempFolders(dest)
    }

    func testTruncatedArchiveFailsCleanly() throws {
        let tmp = TempDir()
        let staging = tmp.sub("big")
        var random = Data(count: 1 << 20)
        random.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        try random.write(to: staging.appendingPathComponent("random.bin"))
        let archive = tmp.url.appendingPathComponent("cut.tar.gz")
        try Tool.bsdtar(["-czf", archive.path, "-C", staging.path, "random.bin"])
        let full = try Data(contentsOf: archive)
        try full.prefix(full.count / 2).write(to: archive)
        let dest = tmp.sub("dest")
        XCTAssertThrowsError(try extract(archive, to: dest)) { error in
            guard case ArchiveError.corrupt = error else { return XCTFail("expected corrupt, got \(error)") }
        }
        XCTAssertEqual(listing(dest), [])
        assertNoTempFolders(dest)
    }

    func testChecksumMismatchIsReportedAsCorrupt() throws {
        let tmp = TempDir()
        var zip = ZipBuilder()
        zip.file("good.txt", "good data")
        zip.file("bad.txt", "original data")
        var data = zip.build()
        let range = try XCTUnwrap(data.range(of: Data("original data".utf8)))
        data[range.lowerBound] = UInt8(ascii: "O")       // flip one stored byte; CRC no longer matches
        let archive = tmp.write("crc.zip", data)
        let dest = tmp.sub("dest")
        XCTAssertThrowsError(try extract(archive, to: dest)) { error in
            guard case ArchiveError.corrupt(let message) = error else { return XCTFail("expected corrupt, got \(error)") }
            XCTAssertTrue(message.lowercased().contains("crc"), message)
        }
        XCTAssertEqual(listing(dest), [])
        assertNoTempFolders(dest)
        // (libarchive 3.7.4 does not verify the CRC of *stored* RAR5 entries at all, so there is
        // no RAR counterpart to this test; compressed RAR5 entries are verified by libarchive.)
    }

    func testZstdIsReportedAsUnsupported() throws {
        let tmp = TempDir()
        let archive = tmp.write("data.tar.zst", Data([0x28, 0xB5, 0x2F, 0xFD, 0x04, 0x58, 0x45, 0x00, 0x00, 0x10]))
        let dest = tmp.sub("dest")
        XCTAssertThrowsError(try extract(archive, to: dest)) { error in
            guard case ArchiveError.unsupportedFormat(let what) = error else { return XCTFail("got \(error)") }
            XCTAssertTrue(what.contains("Zstandard"), what)
        }
    }

    func testDestinationMustExist() {
        let tmp = TempDir()
        var zip = ZipBuilder()
        zip.file("a.txt", "A")
        let archive = tmp.write("a.zip", zip.build())
        XCTAssertThrowsError(try extract(archive, to: tmp.url.appendingPathComponent("nope"))) { error in
            guard case ArchiveError.writeFailed = error else { return XCTFail("got \(error)") }
        }
    }

    // MARK: Threads

    func testConcurrentExtractionsOnBackgroundThreads() throws {
        let tmp = TempDir()
        let staging = makeStaging(tmp)
        let archive = tmp.url.appendingPathComponent("Shared.tar.xz")
        try Tool.bsdtar(["-cJf", archive.path, "-C", staging.path, "Project", "notes.txt"])
        let dests = (0..<6).map { tmp.sub("dest\($0)") }
        let failures = Counter()
        DispatchQueue.concurrentPerform(iterations: dests.count) { i in
            do {
                let result = try ArchiveExtractor(url: archive).extract(to: dests[i], options: ArchiveExtractionOptions(),
                                                                        progress: { _ in }, isCancelled: { false })
                if result.containingFolder?.lastPathComponent != "Shared" { failures.increment() }
            } catch {
                failures.increment()
            }
        }
        XCTAssertEqual(failures.count, 0)
        for dest in dests { XCTAssertEqual(treeContents(dest).count, 4) }
    }
}
