import XCTest
@testable import TuttoKit

final class TextStatsTests: XCTestCase {
    func testEmpty() {
        XCTAssertEqual(TextStats.measure(""), .empty)
        XCTAssertEqual(TextStats.measure("   \n\n  "), TextStats(characters: 7))
    }

    func testBasics() {
        let stats = TextStats.measure("Hello world")
        XCTAssertEqual(stats, TextStats(words: 2, characters: 11, charactersExcludingSpaces: 10, sentences: 1, paragraphs: 1))
    }

    func testWordRulesMatchWordProcessors() {
        // Hyphenated words, contractions and numbers are one word each; a dash on its own is none.
        XCTAssertEqual(TextStats.measure("well-known don't 3.14 — e-mail").words, 4)
        XCTAssertEqual(TextStats.measure("  leading and   trailing  ").words, 3)
        XCTAssertEqual(TextStats.measure("one\ttwo\nthree").words, 3)
    }

    func testSentences() {
        XCTAssertEqual(TextStats.measure("Hello. How are you? Fine!").sentences, 3)
        XCTAssertEqual(TextStats.measure("No final punctuation").sentences, 1)
        XCTAssertEqual(TextStats.measure("...").sentences, 0)
    }

    func testParagraphsAreNonEmptyLines() {
        let stats = TextStats.measure("First para.\n\nSecond para.\nThird line.\n\n\n")
        XCTAssertEqual(stats.paragraphs, 3)
        XCTAssertEqual(stats.sentences, 3)
        XCTAssertEqual(TextStats.measure("one\r\ntwo").paragraphs, 2)
    }

    func testCharactersAreWhatYouSee() {
        let stats = TextStats.measure("👍🏽 ok é")
        XCTAssertEqual(stats.characters, 6)
        XCTAssertEqual(stats.charactersExcludingSpaces, 4)
        XCTAssertEqual(stats.words, 2)  // the emoji isn't a word
    }

    func testScriptsWithoutSpacesUseTheWordBreaker() {
        let stats = TextStats.measure("我喜欢学习中文。")
        XCTAssertGreaterThanOrEqual(stats.words, 3)
        XCTAssertEqual(stats.characters, 8)
        XCTAssertEqual(stats.sentences, 1)
        XCTAssertEqual(TextStats.measure("Tokyo 東京に行きました").words, 1 + TextStats.measure("東京に行きました").words)
    }

    func testTimes() {
        let stats = TextStats(words: 238)
        XCTAssertEqual(stats.readingTime(), 60, accuracy: 0.001)
        XCTAssertEqual(TextStats(words: 150).speakingTime(), 60, accuracy: 0.001)
        XCTAssertEqual(TextStats.format(duration: 0), "0 s")
        XCTAssertEqual(TextStats.format(duration: 12.2), "13 s")
        XCTAssertEqual(TextStats.format(duration: 150), "3 min")
        XCTAssertEqual(TextStats.format(duration: 3600), "1 h")
        XCTAssertEqual(TextStats.format(duration: 4320), "1 h 12 min")
    }

    func testLargeTextIsFast() {
        let text = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 20_000)  // 180,000 words
        let start = Date()
        let stats = TextStats.measure(text)
        XCTAssertEqual(stats.words, 180_000)
        XCTAssertEqual(stats.sentences, 20_000)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)
    }
}
