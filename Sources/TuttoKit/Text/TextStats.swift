//
//  TextStats.swift
//  TuttoKit — word counter
//
//  Counts a piece of text the way word processors report it, in one pass:
//  - Words: runs between whitespace that contain a letter or digit ("well-known", "don't",
//    "3.14" are one word each; a lone "—" is none). Text in scripts written without spaces
//    (Chinese, Japanese, Thai…) is split by the system's word breaker instead.
//  - Characters: what you see as one character (an emoji with a skin tone counts once).
//  - Sentences: the system's sentence breaker, counting only sentences with a letter or digit.
//  - Paragraphs: non-empty lines, as Word counts paragraph marks.
//

import Foundation

public struct TextStats: Equatable, Sendable {
    public var words = 0
    public var characters = 0
    public var charactersExcludingSpaces = 0
    public var sentences = 0
    public var paragraphs = 0

    public init(words: Int = 0, characters: Int = 0, charactersExcludingSpaces: Int = 0,
                sentences: Int = 0, paragraphs: Int = 0) {
        self.words = words
        self.characters = characters
        self.charactersExcludingSpaces = charactersExcludingSpaces
        self.sentences = sentences
        self.paragraphs = paragraphs
    }

    public static let empty = TextStats()

    /// Average adult silent reading speed for non-fiction (words per minute).
    public static let averageReadingSpeed = 238.0
    /// A comfortable presentation pace (words per minute).
    public static let speakingSpeed = 150.0

    public func readingTime(wordsPerMinute: Double = TextStats.averageReadingSpeed) -> TimeInterval {
        Double(words) / wordsPerMinute * 60
    }

    public func speakingTime(wordsPerMinute: Double = TextStats.speakingSpeed) -> TimeInterval {
        Double(words) / wordsPerMinute * 60
    }

    // MARK: Measuring

    public static func measure(_ text: String) -> TextStats {
        guard !text.isEmpty else { return .empty }
        var stats = TextStats()

        var tokenStart: String.Index?
        var tokenHasWordCharacter = false
        var tokenNeedsWordBreaker = false
        var lineHasContent = false

        func endToken(at end: String.Index) {
            defer {
                tokenStart = nil
                tokenHasWordCharacter = false
                tokenNeedsWordBreaker = false
            }
            guard let start = tokenStart, tokenHasWordCharacter else { return }
            if tokenNeedsWordBreaker {
                stats.words += wordBreakerCount(text[start..<end])
            } else {
                stats.words += 1
            }
        }

        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            stats.characters += 1
            if character.isWhitespace {
                endToken(at: index)
                if character.isNewline {
                    if lineHasContent { stats.paragraphs += 1 }
                    lineHasContent = false
                }
            } else {
                stats.charactersExcludingSpaces += 1
                lineHasContent = true
                if tokenStart == nil { tokenStart = index }
                if character.isLetter || character.isNumber { tokenHasWordCharacter = true }
                if !tokenNeedsWordBreaker, let scalar = character.unicodeScalars.first, isWrittenWithoutSpaces(scalar) {
                    tokenNeedsWordBreaker = true
                }
            }
            index = text.index(after: index)
        }
        endToken(at: text.endIndex)
        if lineHasContent { stats.paragraphs += 1 }

        let nsText = text as NSString
        nsText.enumerateSubstrings(in: NSRange(location: 0, length: nsText.length), options: .bySentences) { sentence, _, _, _ in
            if let sentence, sentence.contains(where: { $0.isLetter || $0.isNumber }) { stats.sentences += 1 }
        }
        return stats
    }

    /// Words in a run of text with no spaces in it, by the system's (ICU) word breaker.
    private static func wordBreakerCount(_ run: Substring) -> Int {
        var count = 0
        let string = String(run) as NSString
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .byWords) { word, _, _, _ in
            if let word, word.contains(where: { $0.isLetter || $0.isNumber }) { count += 1 }
        }
        return count
    }

    /// Scripts written without spaces between words.
    private static func isWrittenWithoutSpaces(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0E00...0x0EFF,   // Thai, Lao
             0x1000...0x109F,   // Myanmar
             0x1780...0x17FF,   // Khmer
             0x3040...0x30FF,   // Hiragana, Katakana
             0x3400...0x4DBF,   // CJK Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xF900...0xFAFF,   // CJK Compatibility Ideographs
             0x20000...0x2FA1F: // CJK Extensions B…
            return true
        default:
            return false
        }
    }

    // MARK: Formatting

    /// "45 s", "3 min", "1 h 12 min".
    public static func format(duration seconds: TimeInterval) -> String {
        let total = max(0, seconds)
        if total < 60 { return "\(Int(total.rounded(.up))) s" }
        let minutes = Int((total / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }
}
