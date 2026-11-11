//
//  TextFormats.swift
//  Tutto
//
//  Conversions that are only text: subtitles between SRT and WebVTT (and to plain text), and
//  Markdown to HTML (which macOS then turns into Word, RTF, ODT or PDF like any other HTML).
//

import Foundation

// MARK: - Subtitles

public struct SubtitleCue: Equatable, Sendable {
    /// Milliseconds from the start.
    public var start: Int
    public var end: Int
    public var text: String

    public init(start: Int, end: Int, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

public enum Subtitles {
    /// Cues from SRT or WebVTT (either works: the timing lines tell them apart).
    public static func parse(_ text: String) -> [SubtitleCue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [SubtitleCue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timing = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let sides = lines[timing].components(separatedBy: "-->")
            guard sides.count == 2, let start = milliseconds(sides[0]),
                  let end = milliseconds(sides[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? "") else { continue }
            let body = lines[(timing + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            cues.append(SubtitleCue(start: start, end: end, text: body))
        }
        return cues
    }

    /// "00:01:02,345", "01:02.345", "00:01:02.345" → milliseconds.
    static func milliseconds(_ text: String) -> Int? {
        let clean = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = clean.split(separator: ":").map(String.init)
        guard (2...3).contains(parts.count) else { return nil }
        let secondsPart = parts.last!.split(separator: ".").map(String.init)
        guard let seconds = Int(secondsPart[0]) else { return nil }
        let fraction = secondsPart.count > 1 ? Int(secondsPart[1].padding(toLength: 3, withPad: "0", startingAt: 0).prefix(3)) ?? 0 : 0
        guard let minutes = Int(parts[parts.count - 2]) else { return nil }
        let hours = parts.count == 3 ? Int(parts[0]) ?? 0 : 0
        return ((hours * 60 + minutes) * 60 + seconds) * 1000 + fraction
    }

    static func timestamp(_ ms: Int, separator: Character) -> String {
        let ms = max(ms, 0)
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, String(separator), ms % 1000)
    }

    public static func srt(_ cues: [SubtitleCue]) -> String {
        cues.enumerated().map { index, cue in
            "\(index + 1)\n\(timestamp(cue.start, separator: ",")) --> \(timestamp(cue.end, separator: ","))\n\(cue.text)"
        }.joined(separator: "\n\n") + "\n"
    }

    public static func vtt(_ cues: [SubtitleCue]) -> String {
        "WEBVTT\n\n" + cues.map { cue in
            "\(timestamp(cue.start, separator: ".")) --> \(timestamp(cue.end, separator: "."))\n\(cue.text)"
        }.joined(separator: "\n\n") + "\n"
    }

    /// The words alone, one cue per line, with WebVTT's voice and style tags taken out.
    public static func plainText(_ cues: [SubtitleCue]) -> String {
        cues.map { cue in
            cue.text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\n", with: " ")
        }.joined(separator: "\n") + "\n"
    }
}

// MARK: - Markdown

/// The everyday parts of Markdown (headings, paragraphs, bold, italic, code, lists, quotes,
/// links, rules) as HTML. Anything it doesn't know stays as plain text, escaped.
public enum MarkdownHTML {
    public static func html(_ markdown: String, title: String = "") -> String {
        var body: [String] = []
        var paragraph: [String] = []
        var list: (ordered: Bool, items: [String])?
        var quote: [String] = []
        var code: [String]?

        func flushParagraph() {
            if !paragraph.isEmpty { body.append("<p>\(inline(paragraph.joined(separator: " ")))</p>") }
            paragraph.removeAll()
        }
        func flushList() {
            if let current = list {
                let tag = current.ordered ? "ol" : "ul"
                body.append("<\(tag)>" + current.items.map { "<li>\(inline($0))</li>" }.joined() + "</\(tag)>")
            }
            list = nil
        }
        func flushQuote() {
            if !quote.isEmpty { body.append("<blockquote><p>\(inline(quote.joined(separator: " ")))</p></blockquote>") }
            quote.removeAll()
        }
        func flushAll() { flushParagraph(); flushList(); flushQuote() }

        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if var lines = code {
                if line.hasPrefix("```") {
                    body.append("<pre><code>\(escape(lines.joined(separator: "\n")))</code></pre>")
                    code = nil
                } else {
                    lines.append(raw)
                    code = lines
                }
                continue
            }
            if line.hasPrefix("```") { flushAll(); code = []; continue }
            if line.isEmpty { flushAll(); continue }
            if let level = headingLevel(line) {
                flushAll()
                let text = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
                body.append("<h\(level)>\(inline(text))</h\(level)>")
                continue
            }
            if line == "---" || line == "***" || line == "___" { flushAll(); body.append("<hr>"); continue }
            if line.hasPrefix(">") {
                flushParagraph(); flushList()
                quote.append(line.dropFirst().trimmingCharacters(in: .whitespaces))
                continue
            }
            if let item = listItem(line) {
                flushParagraph(); flushQuote()
                if list == nil || list!.ordered != item.ordered { flushList(); list = (item.ordered, []) }
                list!.items.append(item.text)
                continue
            }
            flushList(); flushQuote()
            paragraph.append(line)
        }
        if let lines = code { body.append("<pre><code>\(escape(lines.joined(separator: "\n")))</code></pre>") }
        flushAll()
        return "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"><title>\(escape(title))</title></head><body>\n"
            + body.joined(separator: "\n") + "\n</body></html>\n"
    }

    static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    static func listItem(_ line: String) -> (ordered: Bool, text: String)? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) { return (false, String(line.dropFirst(2))) }
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") {
            return (true, String(line.dropFirst(digits.count + 2)))
        }
        return nil
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Code first (nothing inside it is Markdown), then links, bold, italic.
    static func inline(_ text: String) -> String {
        var output = ""
        var rest = Substring(text)
        while let tick = rest.firstIndex(of: "`") {
            output += emphasis(String(rest[..<tick]))
            let after = rest.index(after: tick)
            if let close = rest[after...].firstIndex(of: "`") {
                output += "<code>\(escape(String(rest[after..<close])))</code>"
                rest = rest[rest.index(after: close)...]
            } else {
                output += escape("`")
                rest = rest[after...]
            }
        }
        return output + emphasis(String(rest))
    }

    static func emphasis(_ text: String) -> String {
        var html = escape(text)
        html = html.replacingOccurrences(of: #"\[([^\]]+)\]\(([^)\s]+)\)"#, with: "<a href=\"$2\">$1</a>", options: .regularExpression)
        html = html.replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "<strong>$1</strong>", options: .regularExpression)
        html = html.replacingOccurrences(of: #"__(.+?)__"#, with: "<strong>$1</strong>", options: .regularExpression)
        html = html.replacingOccurrences(of: #"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])"#, with: "<em>$1</em>", options: .regularExpression)
        html = html.replacingOccurrences(of: #"(?<![\w_])_(?!\s)(.+?)(?<!\s)_(?![\w_])"#, with: "<em>$1</em>", options: .regularExpression)
        return html
    }
}
