//
//  PluginContent.swift
//  Tutto
//
//  What a plugin's card shows, read from what its command prints. Tutto draws the card itself,
//  in the current theme, so a plugin's card always looks like the rest of the panel.
//
//  Plain text: the first line is the value, the second a detail, further lines a list (wide cards).
//  JSON, for more:
//    {"value": "3", "unit": "open", "title": "PRs", "detail": "2 need review",
//     "symbol": "arrow.triangle.pull", "level": "notice", "progress": 0.4,
//     "series": [3, 4, 2, 5], "url": "https://…",
//     "items": [{"title": "Fix login", "detail": "api", "url": "https://…"}]}
//  "level" is normal, notice or alert; "progress" is 0…1 (or a percent); "series" draws a line.
//

import Foundation

public struct PluginWidgetContent: Equatable, Sendable {
    public enum Level: String, Sendable {
        case normal, notice, alert

        init(text: String) {
            switch text.lowercased() {
            case "notice", "warn", "warning", "attention": self = .notice
            case "alert", "error", "bad", "critical", "danger", "fail", "failed": self = .alert
            default: self = .normal
            }
        }
    }

    public struct Item: Equatable, Sendable {
        public var title: String
        public var detail: String?
        public var url: String?
        public var symbol: String?

        public init(title: String, detail: String? = nil, url: String? = nil, symbol: String? = nil) {
            self.title = title
            self.detail = detail
            self.url = url
            self.symbol = symbol
        }
    }

    /// Replaces the plugin's name as the card's caption.
    public var title: String?
    public var value: String
    public var unit: String?
    public var detail: String?
    public var symbol: String?
    public var level: Level = .normal
    public var progress: Double?
    public var series: [Double] = []
    public var items: [Item] = []
    /// Opened when the card is clicked.
    public var url: String?

    public init(value: String, unit: String? = nil, title: String? = nil, detail: String? = nil, symbol: String? = nil,
                level: Level = .normal, progress: Double? = nil, series: [Double] = [], items: [Item] = [], url: String? = nil) {
        self.value = value
        self.unit = unit
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.level = level
        self.progress = progress
        self.series = series
        self.items = items
        self.url = url
    }

    public static let maxItems = 8
    public static let maxSeries = 120

    /// The series as a line draws it: the last `points` values, scaled from their own lowest to
    /// highest (a flat series sits in the middle).
    public func normalizedSeries(points: Int = 60) -> [Double] {
        let values = Array(series.suffix(points))
        guard let low = values.min(), let high = values.max() else { return [] }
        guard high > low else { return values.map { _ in 0.5 } }
        return values.map { ($0 - low) / (high - low) }
    }

    /// What the card shows for this output.
    public static func parse(_ output: String) -> PluginWidgetContent {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("{"), let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return fromJSON(object)
        }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = lines.first else { return PluginWidgetContent(value: "—") }
        var content = PluginWidgetContent(value: clip(first, 48))
        if lines.count > 1 { content.detail = clip(lines[1], 160) }
        content.items = lines.dropFirst(2).prefix(maxItems).map { Item(title: clip($0, 120)) }
        return content
    }

    private static func fromJSON(_ object: [String: Any]) -> PluginWidgetContent {
        func string(_ key: String, _ limit: Int) -> String? {
            switch object[key] {
            case let text as String: text.isEmpty ? nil : clip(text, limit)
            case let number as NSNumber: number.stringValue
            default: nil
            }
        }
        var content = PluginWidgetContent(value: string("value", 48) ?? "—")
        content.title = string("title", 40)
        content.unit = string("unit", 16)
        content.detail = string("detail", 160)
        content.symbol = string("symbol", 64)
        content.level = Level(text: string("level", 16) ?? string("status", 16) ?? "")
        content.url = string("url", 2048) ?? string("href", 2048)
        if let number = (object["progress"] as? NSNumber)?.doubleValue, number.isFinite {
            content.progress = min(max(number > 1 ? number / 100 : number, 0), 1)
        }
        let series = (object["series"] as? [Any]) ?? (object["values"] as? [Any]) ?? []
        content.series = series.compactMap { ($0 as? NSNumber)?.doubleValue }.filter(\.isFinite).suffix(maxSeries).map { $0 }
        content.items = ((object["items"] as? [Any]) ?? []).prefix(maxItems).compactMap { entry in
            if let title = entry as? String { return Item(title: clip(title, 120)) }
            guard let item = entry as? [String: Any], let title = item["title"] as? String else { return nil }
            return Item(title: clip(title, 120), detail: (item["detail"] as? String).map { clip($0, 120) },
                        url: (item["url"] as? String) ?? (item["href"] as? String), symbol: item["symbol"] as? String)
        }
        return content
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }
}
