//
//  FilenameEncoding.swift
//  TuttoKit — archives (ARC-2: fix garbled file names)
//
//  Zips made on Windows (and RAR4/LHA/CAB without Unicode flags) store names in the creator's
//  legacy code page. libarchive returns those names as raw bytes, so TuttoKit picks one
//  encoding for the whole archive:
//
//   1. Names that are valid UTF-8 (incl. ASCII) need nothing → detect returns nil.
//   2. Every candidate that strictly decodes all non-UTF-8 names is scored for plausibility
//      (letters of one script per word, no control/box-drawing/rare symbols, no "cafÉ"-style
//      case flips).
//   3. Foundation's NSString.stringEncoding(for:…) is asked too (candidates only, no lossy
//      conversion). Measured on this Mac it reliably separates Shift-JIS, GB18030, Big5 and
//      Korean (where per-character scoring ties), so a double-byte guess is taken as is. Its
//      single-byte guesses are weaker (CP866 → "CP1251", CP437/Mac Roman → no answer,
//      half-width kana → "CP1251"), so those are re-ranked against the other single-byte
//      candidates by score, and a double-byte reading only wins when clearly more plausible.
//   4. Without a Foundation answer the best score wins (ties → candidate order).
//
//  Candidates (in tie-break order): Shift-JIS (Apple's = CP932 incl. NEC extensions),
//  GB18030, Big5, Korean (CP949/UHC, a superset of EUC-KR), CP1251, CP866, CP437, CP1252,
//  ISO Latin-1, Mac Roman.
//
//  libarchive rewrites byte 0x5C ("\") to "/" in non-Unicode zip/LHA/CAB names. In Shift-JIS,
//  Big5 and GBK 0x5C is also a valid second byte (表 = 95 5C, ソ = 83 5C), so before decoding
//  with a double-byte encoding a "/" that follows a lead byte is turned back into 0x5C.
//

import Foundation

public enum FilenameEncoding {
    /// Korean: Windows code page 949 (Unified Hangul Code), a superset of EUC-KR.
    public static let korean = cf(.dosKorean)
    public static let gb18030 = cf(.GB_18030_2000)
    public static let big5 = cf(.big5)
    public static let cp866 = cf(.dosRussian)
    public static let cp437 = cf(.dosLatinUS)

    /// Candidate legacy encodings, in tie-break order.
    public static let candidates: [String.Encoding] = [
        .shiftJIS, gb18030, big5, korean,
        .windowsCP1251, cp866, cp437, .windowsCP1252, .isoLatin1, .macOSRoman,
    ]

    /// Detects one legacy encoding for an archive's raw names. Returns nil when every name is
    /// already valid UTF-8 (or ASCII), i.e. when no conversion is needed.
    public static func detect(_ rawNames: [Data]) -> String.Encoding? {
        let samples = rawNames.filter { !$0.isEmpty && !isValidUTF8($0) }
        guard !samples.isEmpty else { return nil }

        var scores: [(encoding: String.Encoding, score: Int)] = []
        for encoding in candidates {
            var total = 0
            var decodedAll = true
            for sample in samples {
                guard let text = strictDecode(sample, encoding) else { decodedAll = false; break }
                total += plausibility(of: text)
            }
            if decodedAll { scores.append((encoding, total)) }
        }
        func best(_ list: [(encoding: String.Encoding, score: Int)]) -> (encoding: String.Encoding, score: Int)? {
            var winner = list.first
            for candidate in list.dropFirst() where candidate.score > winner!.score { winner = candidate }
            return winner
        }
        guard let overall = best(scores) else { return .isoLatin1 }

        if let guess = foundationGuess(samples), let guessScore = scores.first(where: { $0.encoding == guess })?.score {
            if multiByte.contains(guess) {
                // Foundation's statistics separate the CJK encodings far better than per-character
                // scoring; trust it unless the result contains control/private-use garbage.
                if guessScore >= 0 { return guess }
            } else {
                // Single-byte guess: re-rank the single-byte candidates (CP866 vs CP1251, CP437 …);
                // a double-byte reading must be clearly better to win (half-width kana names).
                let singleByte = best(scores.filter { !multiByte.contains($0.encoding) }) ?? overall
                let margin = max(2, abs(singleByte.score) / 5)
                let chosen = guessScore >= singleByte.score - margin ? (guess, guessScore) : (singleByte.encoding, singleByte.score)
                if let mb = best(scores.filter { multiByte.contains($0.encoding) }),
                   Double(mb.score) > Double(chosen.1) * 1.5, mb.score > chosen.1 + 2 {
                    return mb.encoding
                }
                return chosen.0
            }
        }
        return overall.encoding
    }

    private static let multiByte: [String.Encoding] = [.shiftJIS, gb18030, big5, korean]

    /// Decodes a raw name. Valid UTF-8 is always returned as UTF-8; otherwise `encoding` is
    /// applied (with the 0x5C repair for double-byte encodings). Bytes that still can't be
    /// decoded become "_".
    public static func decode(_ raw: Data, using encoding: String.Encoding?) -> String {
        if let utf8 = String(data: raw, encoding: .utf8) { return utf8 }
        if let encoding, let text = strictDecode(raw, encoding) { return text }
        return String(decoding: raw, as: UTF8.self).replacingOccurrences(of: "\u{FFFD}", with: "_")
    }

    /// Human-readable name ("Japanese (Windows, DOS)").
    public static func displayName(of encoding: String.Encoding) -> String {
        String.localizedName(of: encoding)
    }

    // MARK: - Internals

    static func cf(_ encoding: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue)))
    }

    static func isValidUTF8(_ data: Data) -> Bool {
        String(data: data, encoding: .utf8) != nil
    }

    static func strictDecode(_ raw: Data, _ encoding: String.Encoding) -> String? {
        let bytes = repairBackslashTrailBytes(raw, for: encoding)
        guard let text = String(data: bytes, encoding: encoding), !text.isEmpty else { return nil }
        return text
    }

    /// Undoes libarchive's "\" → "/" rewrite inside double-byte characters.
    static func repairBackslashTrailBytes(_ raw: Data, for encoding: String.Encoding) -> Data {
        let isLead: (UInt8) -> Bool
        let isSingleHigh: (UInt8) -> Bool
        switch encoding {
        case .shiftJIS, cf(.dosJapanese):
            isLead = { (0x81...0x9F).contains($0) || (0xE0...0xFC).contains($0) }
            isSingleHigh = { (0xA1...0xDF).contains($0) }
        case gb18030, cf(.GBK_95), big5, cf(.big5_HKSCS_1999):
            isLead = { (0x81...0xFE).contains($0) }
            isSingleHigh = { _ in false }
        default:
            return raw
        }
        guard raw.contains(0x2F) else { return raw }
        var bytes = [UInt8](raw)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b < 0x80 || isSingleHigh(b) { i += 1; continue }
            if isLead(b), i + 1 < bytes.count {
                if bytes[i + 1] == 0x2F { bytes[i + 1] = 0x5C }
                // GB18030 four-byte sequences: lead, 0x30–0x39, lead, 0x30–0x39.
                if encoding == gb18030, (0x30...0x39).contains(bytes[i + 1]) { i += 4; continue }
                i += 2
                continue
            }
            i += 1
        }
        return Data(bytes)
    }

    private static func foundationGuess(_ samples: [Data]) -> String.Encoding? {
        var joined = Data()
        for (index, sample) in samples.enumerated() {
            if index > 0 { joined.append(0x0A) }
            joined.append(sample)
        }
        var converted: NSString?
        var lossy: ObjCBool = false
        let raw = NSString.stringEncoding(
            for: joined,
            encodingOptions: [
                .suggestedEncodingsKey: candidates.map { NSNumber(value: $0.rawValue) },
                .useOnlySuggestedEncodingsKey: true,
                .allowLossyKey: false,
            ],
            convertedString: &converted,
            usedLossyConversion: &lossy)
        guard raw != 0, converted != nil, !lossy.boolValue else { return nil }
        return String.Encoding(rawValue: raw)
    }

    private enum Script { case latin, cyrillic, greek, other }

    /// Higher = more plausible as a human-written file name.
    static func plausibility(of text: String) -> Int {
        var score = 0
        var wordScripts = Set<Script>()
        var previousWasLowerLetter = false
        var previousWasNonASCIILetter = false

        func endWord() {
            if wordScripts.count > 1 { score -= 4 }
            wordScripts.removeAll(keepingCapacity: true)
        }

        for scalar in text.unicodeScalars {
            let v = scalar.value
            var script: Script? = nil
            var isUpper = false
            var isLower = false

            switch v {
            case 0x00..<0x20, 0x7F, 0x80..<0xA0, 0xFFFD, 0xE000...0xF8FF:
                score -= 50
            case 0x41...0x5A:
                script = .latin; isUpper = true
            case 0x61...0x7A:
                script = .latin; isLower = true
            case 0x20..<0x7F:
                break
            case 0x3040...0x30FF, 0x31F0...0x31FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xFF61...0xFF9F:
                score += 2; script = .other
            case 0x3000...0x303F, 0xFF01...0xFF5E:
                score += 1
            case 0x0410...0x042F, 0x0401:
                score += 2; script = .cyrillic; isUpper = true
            case 0x0430...0x044F, 0x0451:
                score += 2; script = .cyrillic; isLower = true
            case 0x0400...0x04FF:
                score -= 1; script = .cyrillic
                isUpper = scalar.properties.isUppercase; isLower = scalar.properties.isLowercase
            case 0x00C0...0x00FF where v != 0xD7 && v != 0xF7:
                score += 1; script = .latin
                isUpper = v <= 0xDE; isLower = v >= 0xDF
            case 0x0100...0x024F:
                script = .latin
                isUpper = scalar.properties.isUppercase; isLower = scalar.properties.isLowercase
            case 0x0370...0x03FF:
                score -= 1; script = .greek
                isUpper = scalar.properties.isUppercase; isLower = scalar.properties.isLowercase
            default:
                if scalar.properties.isAlphabetic { script = .other } else { score -= 3 }
            }

            if let script {
                let nonASCII = v >= 0x80
                if isUpper && previousWasLowerLetter && (nonASCII || previousWasNonASCIILetter) { score -= 2 }
                if script != .other { wordScripts.insert(script) }
                previousWasLowerLetter = isLower
                previousWasNonASCIILetter = nonASCII
            } else {
                endWord()
                previousWasLowerLetter = false
                previousWasNonASCIILetter = false
            }
        }
        endWord()
        return score
    }
}
