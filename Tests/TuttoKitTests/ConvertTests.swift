import Foundation
import XCTest
@testable import TuttoKit

final class ConvertRulesTests: XCTestCase {
    func testKindsFromExtensions() {
        XCTAssertEqual(FileKind.of(extension: "HEIC"), .image)
        XCTAssertEqual(FileKind.of(extension: "dng"), .image)
        XCTAssertEqual(FileKind.of(extension: "webp"), .image)
        XCTAssertEqual(FileKind.of(extension: "mov"), .video)
        XCTAssertEqual(FileKind.of(extension: "mp3"), .audio)
        XCTAssertEqual(FileKind.of(extension: "pdf"), .pdf)
        XCTAssertEqual(FileKind.of(extension: "docx"), .document)
        XCTAssertEqual(FileKind.of(extension: "md"), .document)
        XCTAssertEqual(FileKind.of(extension: "vtt"), .subtitles)
        XCTAssertEqual(FileKind.of(extension: "zip"), .other)
    }

    func testTargetsForASelection() {
        XCTAssertEqual(ConvertPlanner.targets(for: [.image]).prefix(4), [.jpeg, .png, .heic, .pdf])
        // Images and PDFs share PNG and JPEG (PDF pages become pictures too).
        XCTAssertEqual(Set(ConvertPlanner.targets(for: [.image, .pdf])), [.png, .jpeg])
        XCTAssertEqual(ConvertPlanner.targets(for: [.image, .audio]), [])
        XCTAssertEqual(ConvertPlanner.targets(for: [.other]), [])
        XCTAssertTrue(ConvertPlanner.canCompress(.pdf))
        XCTAssertFalse(ConvertPlanner.canCompress(.document))
        XCTAssertTrue(ConvertPlanner.combines([.image, .image, .pdf], into: .pdf))
        XCTAssertFalse(ConvertPlanner.combines([.image], into: .pdf))
        XCTAssertFalse(ConvertPlanner.combines([.image, .video], into: .pdf))
    }

    func testNoFormatIsOfferedThatMacOSCannotWrite() {
        let offered = Set(FileKind.allCases.flatMap(ConvertPlanner.targets(for:)))
        XCTAssertFalse(offered.map(\.fileExtension).contains("mp3"))
        XCTAssertFalse(offered.map(\.fileExtension).contains("webp"))
        XCTAssertEqual(OutputFormat.mp4HEVC.fileExtension, "mp4")
        XCTAssertEqual(OutputFormat.jpeg.fileExtension, "jpg")
    }

    func testNamesBesideTheOriginalNeverOverwrite() {
        let source = URL(fileURLWithPath: "/tmp/x/photo.heic")
        var taken: Set<String> = ["/tmp/x/photo.jpg"]
        let exists: (URL) -> Bool = { taken.contains($0.path) }
        XCTAssertEqual(OutputNames.converted(source, ext: "jpg", exists: exists).lastPathComponent, "photo 2.jpg")
        XCTAssertEqual(OutputNames.converted(source, ext: "png", exists: exists).lastPathComponent, "photo.png")
        let jpeg = URL(fileURLWithPath: "/tmp/x/photo.jpeg")
        XCTAssertEqual(OutputNames.converted(jpeg, ext: "jpg", exists: exists).lastPathComponent, "photo (converted).jpg")
        XCTAssertEqual(OutputNames.compressed(jpeg, exists: exists).lastPathComponent, "photo (compressed).jpeg")
        taken.insert("/tmp/x/photo (compressed).jpeg")
        XCTAssertEqual(OutputNames.compressed(jpeg, exists: exists).lastPathComponent, "photo (compressed) 2.jpeg")
        let many = (1...5).map { URL(fileURLWithPath: "/tmp/x/beach \($0).png") }
        XCTAssertEqual(OutputNames.combined(many, ext: "pdf", exists: exists)?.lastPathComponent, "beach 1 and 4 more.pdf")
        let pdf = URL(fileURLWithPath: "/tmp/x/report.pdf")
        XCTAssertEqual(OutputNames.page(pdf, page: 3, of: 9, ext: "png", exists: exists).lastPathComponent, "report 3.png")
        XCTAssertEqual(OutputNames.page(pdf, page: 1, of: 1, ext: "png", exists: exists).lastPathComponent, "report.png")
    }

    func testVideoBitrateAndFitting() {
        let balanced = CompressionSettings.videoBitrate(width: 1920, height: 1080, fps: 30, quality: .balanced, codec: .h264)
        XCTAssertEqual(balanced, Int(1920.0 * 1080 * 30 * 0.08))
        let hevc = CompressionSettings.videoBitrate(width: 1920, height: 1080, fps: 30, quality: .balanced, codec: .hevc)
        XCTAssertEqual(Double(hevc), Double(balanced) * 0.6, accuracy: 2)
        XCTAssertGreaterThanOrEqual(CompressionSettings.videoBitrate(width: 16, height: 16, fps: 1, quality: .small, codec: .hevc), 250_000)
        let fitted = CompressionSettings.fitted(width: 3840, height: 2160, maxHeight: 1080)
        XCTAssertEqual(fitted.width, 1920)
        XCTAssertEqual(fitted.height, 1080)
        let portrait = CompressionSettings.fitted(width: 1081, height: 1921, maxHeight: nil)
        XCTAssertEqual(portrait.width, 1080)
        XCTAssertEqual(portrait.height, 1920)
    }

    func testTypedSizes() {
        XCTAssertEqual(ByteSizeText.bytes("500 KB"), 500_000)
        XCTAssertEqual(ByteSizeText.bytes("1.5mb"), 1_500_000)
        XCTAssertEqual(ByteSizeText.bytes("2,5 MB"), 2_500_000)
        XCTAssertEqual(ByteSizeText.bytes("800k"), 800_000)
        XCTAssertEqual(ByteSizeText.bytes("750000"), 750_000)
        XCTAssertNil(ByteSizeText.bytes("big"))
        XCTAssertNil(ByteSizeText.bytes("5 parsecs"))
        XCTAssertNil(ByteSizeText.bytes(""))
    }

    func testQualitySearchFindsTheBestFit() {
        // A made-up encoder: size grows with quality.
        var tries = 0
        let size: (Double) -> Int = { quality in tries += 1; return Int(100_000 + quality * 900_000) }
        let best = QualitySearch.best(target: 500_000, size: size)
        XCTAssertNotNil(best)
        XCTAssertLessThanOrEqual(size(best!), 500_000)
        XCTAssertGreaterThan(best!, 0.38)   // within one step of the true answer (0.444)
        XCTAssertLessThanOrEqual(tries, 8)
        XCTAssertNil(QualitySearch.best(target: 50_000, size: size))
        XCTAssertEqual(QualitySearch.best(target: 5_000_000, size: size), 0.95)
    }
}

final class TextFormatsTests: XCTestCase {
    private let srt = """
    1
    00:00:01,000 --> 00:00:04,250
    Hello there.

    2
    00:01:02,005 --> 00:01:05,000
    Two lines,
    in one cue.

    """

    func testSRTToVTTAndBack() {
        let cues = Subtitles.parse(srt)
        XCTAssertEqual(cues, [SubtitleCue(start: 1000, end: 4250, text: "Hello there."),
                              SubtitleCue(start: 62_005, end: 65_000, text: "Two lines,\nin one cue.")])
        let vtt = Subtitles.vtt(cues)
        XCTAssertTrue(vtt.hasPrefix("WEBVTT\n\n00:00:01.000 --> 00:00:04.250\nHello there."))
        XCTAssertEqual(Subtitles.parse(vtt), cues)
        XCTAssertEqual(Subtitles.parse(Subtitles.srt(cues)), cues)
    }

    func testVTTWithShortTimesSettingsAndTags() {
        let vtt = """
        WEBVTT

        intro
        01:02.500 --> 01:04.000 align:start position:10%
        <v Alice>Hi <b>you</b></v>
        """
        let cues = Subtitles.parse(vtt)
        XCTAssertEqual(cues, [SubtitleCue(start: 62_500, end: 64_000, text: "<v Alice>Hi <b>you</b></v>")])
        XCTAssertEqual(Subtitles.plainText(cues), "Hi you\n")
        XCTAssertTrue(Subtitles.srt(cues).contains("00:01:02,500 --> 00:01:04,000"))
    }

    func testMarkdownToHTML() {
        let html = MarkdownHTML.html("""
        # Title

        Some **bold**, *italic* and `code <b>` with a [link](https://example.com).

        - one
        - two

        1. first
        2. second

        > quoted

        ```
        let x = 1 < 2
        ```
        ---
        """, title: "Doc")
        XCTAssertTrue(html.contains("<h1>Title</h1>"))
        XCTAssertTrue(html.contains("<p>Some <strong>bold</strong>, <em>italic</em> and <code>code &lt;b&gt;</code> with a <a href=\"https://example.com\">link</a>.</p>"))
        XCTAssertTrue(html.contains("<ul><li>one</li><li>two</li></ul>"))
        XCTAssertTrue(html.contains("<ol><li>first</li><li>second</li></ol>"))
        XCTAssertTrue(html.contains("<blockquote><p>quoted</p></blockquote>"))
        XCTAssertTrue(html.contains("<pre><code>let x = 1 &lt; 2</code></pre>"))
        XCTAssertTrue(html.contains("<hr>"))
        XCTAssertTrue(html.contains("<title>Doc</title>"))
    }

    func testMarkdownLeavesSnakeCaseAndStarsAlone() {
        let html = MarkdownHTML.html("snake_case_name and 2 * 3 * 4")
        XCTAssertTrue(html.contains("<p>snake_case_name and 2 * 3 * 4</p>"))
    }
}
