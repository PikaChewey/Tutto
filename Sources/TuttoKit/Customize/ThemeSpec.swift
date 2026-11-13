//
//  ThemeSpec.swift
//  Tutto
//
//  Themes are data (Bryan, 2026-11-10: customizable "in the same sense that the GUI in like vs
//  code is customizeable"): a few named choices (accent, neutrals, contrast, background, cards,
//  corners, density, numbers, light or dark) and, for anyone who wants more, colour overrides per
//  token for light and dark, the way an editor theme overrides its colour tokens. A theme never
//  runs anything; Tutto draws itself from it. Built-in themes, plus your own as JSON files in
//  ~/Library/Application Support/Tutto/Themes (share one by sending the file).
//

import Foundation

// MARK: - Colour

/// A colour as four 0...1 components, written "#RRGGBB" or "#RRGGBBAA".
public struct RGBA: Equatable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
        self.alpha = min(max(alpha, 0), 1)
    }

    /// "#RGB", "#RRGGBB" or "#RRGGBBAA" (the "#" is optional).
    public init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count == 6 || text.count == 8, let value = UInt64(text, radix: 16) else { return nil }
        let full = text.count == 6 ? (value << 8) | 0xFF : value
        self.init(Double((full >> 24) & 0xFF) / 255, Double((full >> 16) & 0xFF) / 255,
                  Double((full >> 8) & 0xFF) / 255, Double(full & 0xFF) / 255)
    }

    public var hex: String {
        func byte(_ v: Double) -> String { String(format: "%02X", Int((v * 255).rounded())) }
        return "#" + byte(red) + byte(green) + byte(blue) + (alpha < 1 ? byte(alpha) : "")
    }

    public func withAlpha(_ alpha: Double) -> RGBA { RGBA(red, green, blue, alpha) }

    /// Rounded to what "#RRGGBBAA" holds, so a colour picked on screen equals itself once saved.
    public var quantized: RGBA {
        func q(_ v: Double) -> Double { (v * 255).rounded() / 255 }
        return RGBA(q(red), q(green), q(blue), q(alpha))
    }

    /// This colour laid over an opaque `background`.
    public func over(_ background: RGBA) -> RGBA {
        RGBA(red * alpha + background.red * (1 - alpha),
             green * alpha + background.green * (1 - alpha),
             blue * alpha + background.blue * (1 - alpha))
    }

    /// `amount` of the way to `other` (0 = self).
    public func mixed(with other: RGBA, _ amount: Double) -> RGBA {
        let t = min(max(amount, 0), 1)
        return RGBA(red + (other.red - red) * t, green + (other.green - green) * t,
                    blue + (other.blue - blue) * t, alpha + (other.alpha - alpha) * t)
    }

    /// Relative luminance (WCAG 2), of the opaque colour.
    public var luminance: Double {
        func channel(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// The WCAG contrast ratio between two opaque colours (1...21).
    public static func contrast(_ a: RGBA, _ b: RGBA) -> Double {
        let (l1, l2) = (a.luminance, b.luminance)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    /// The closest colour, toward black or white (whichever gets there), with at least `ratio`
    /// contrast against `background`; itself when it already has it.
    public func adjusted(toContrast ratio: Double, against background: RGBA) -> RGBA {
        let opaque = over(background)
        guard RGBA.contrast(opaque, background) < ratio else { return self }
        let target = background.luminance > 0.4 ? RGBA(0, 0, 0) : RGBA(1, 1, 1)
        var low = 0.0, high = 1.0
        for _ in 0..<20 {
            let mid = (low + high) / 2
            if RGBA.contrast(opaque.mixed(with: target, mid), background) >= ratio { high = mid } else { low = mid }
        }
        return opaque.mixed(with: target, high)
    }

    public static let black = RGBA(0, 0, 0)
    public static let white = RGBA(1, 1, 1)
}

// MARK: - Theme

public struct ThemeSpec: Codable, Equatable, Sendable {
    public enum Accent: Equatable, Hashable, Sendable {
        /// The accent colour chosen in macOS.
        case system
        /// No colour at all: marks in the ink.
        case mono
        case color(RGBA)

        init(text: String) {
            switch text.lowercased() {
            case "system", "": self = .system
            case "mono", "ink", "none": self = .mono
            default: self = RGBA(hex: text).map(Accent.color) ?? .system
            }
        }

        var text: String {
            switch self {
            case .system: "system"
            case .mono: "mono"
            case .color(let rgba): rgba.hex
            }
        }
    }

    public enum Neutrals: String, Codable, CaseIterable, Sendable { case neutral, warm, cool }
    public enum Contrast: String, Codable, CaseIterable, Sendable { case standard, high }
    /// `liquid`: Apple's Liquid Glass (macOS 26): the panel one sheet of glass, cards quiet platters
    /// on it, and what you point at lifting into glass. Before macOS 26 it looks like `glass`.
    public enum Background: String, Codable, CaseIterable, Sendable { case glass, tinted, solid, liquid }
    public enum Cards: String, Codable, CaseIterable, Sendable { case filled, outlined }
    public enum Corners: String, Codable, CaseIterable, Sendable { case small, medium, large }
    public enum Density: String, Codable, CaseIterable, Sendable { case compact, standard, roomy }
    public enum Numbers: String, Codable, CaseIterable, Sendable { case standard, rounded, mono }
    public enum Appearance: String, Codable, CaseIterable, Sendable { case system, light, dark }

    /// Colours a theme file can set outright, for light and dark ("colors": {"dark": {"background": "#0B0E14"}}).
    public enum Token: String, CaseIterable, Sendable {
        /// Text and marks.
        case ink
        /// The panel and windows when the background is solid.
        case background
        /// A card's fill.
        case card
        /// Hairlines and outlines.
        case line
        case accent
        /// Warnings (a full disk, a hot processor).
        case alert
    }

    public var name: String
    public var accent: Accent = .system
    public var neutrals: Neutrals = .neutral
    public var contrast: Contrast = .standard
    public var background: Background = .glass
    public var cards: Cards = .filled
    public var corners: Corners = .medium
    public var density: Density = .standard
    public var numbers: Numbers = .standard
    public var appearance: Appearance = .system
    /// "light"/"dark" → token → "#RRGGBB(AA)".
    public var colors: [String: [String: String]] = [:]

    public init(name: String, accent: Accent = .system, neutrals: Neutrals = .neutral, contrast: Contrast = .standard,
                background: Background = .glass, cards: Cards = .filled, corners: Corners = .medium,
                density: Density = .standard, numbers: Numbers = .standard, appearance: Appearance = .system,
                colors: [String: [String: String]] = [:]) {
        self.name = name
        self.accent = accent
        self.neutrals = neutrals
        self.contrast = contrast
        self.background = background
        self.cards = cards
        self.corners = corners
        self.density = density
        self.numbers = numbers
        self.appearance = appearance
        self.colors = colors
    }

    enum CodingKeys: String, CodingKey {
        case name, accent, neutrals, contrast, background, cards, corners, density, numbers, appearance, colors
    }

    /// Every field may be left out (or misspelt): it keeps its default, so a theme made for an
    /// older or newer Tutto still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: RawRepresentable & Decodable>(_ key: CodingKeys, _ fallback: T) -> T where T.RawValue == String {
            (try? c.decodeIfPresent(String.self, forKey: key)).flatMap { T(rawValue: $0.lowercased()) } ?? fallback
        }
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Untitled"
        accent = Accent(text: (try? c.decodeIfPresent(String.self, forKey: .accent)) ?? "system")
        neutrals = value(.neutrals, .neutral)
        contrast = value(.contrast, .standard)
        background = value(.background, .glass)
        cards = value(.cards, .filled)
        corners = value(.corners, .medium)
        density = value(.density, .standard)
        numbers = value(.numbers, .standard)
        appearance = value(.appearance, .system)
        colors = (try? c.decodeIfPresent([String: [String: String]].self, forKey: .colors)) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(accent.text, forKey: .accent)
        try c.encode(neutrals, forKey: .neutrals)
        try c.encode(contrast, forKey: .contrast)
        try c.encode(background, forKey: .background)
        try c.encode(cards, forKey: .cards)
        try c.encode(corners, forKey: .corners)
        try c.encode(density, forKey: .density)
        try c.encode(numbers, forKey: .numbers)
        try c.encode(appearance, forKey: .appearance)
        if !colors.isEmpty { try c.encode(colors, forKey: .colors) }
    }

    /// The same look, whatever it's called.
    public func looksLike(_ other: ThemeSpec) -> Bool {
        var a = self, b = other
        a.name = ""
        b.name = ""
        return a == b
    }

    /// A colour set outright for `token` in light or dark, if the theme sets one.
    public func override(_ token: Token, dark: Bool) -> RGBA? {
        (colors[dark ? "dark" : "light"]?[token.rawValue]).flatMap(RGBA.init(hex:))
    }

    public mutating func setOverride(_ token: Token, dark: Bool, to color: RGBA?) {
        let mode = dark ? "dark" : "light"
        var set = colors[mode] ?? [:]
        set[token.rawValue] = color?.hex
        colors[mode] = set.isEmpty ? nil : set
    }

    /// Corner radii are scaled by this.
    public var cornerScale: Double {
        switch corners {
        case .small: 0.5
        case .medium: 1
        case .large: 1.4
        }
    }

    /// Padding and gaps are scaled by this.
    public var densityScale: Double {
        switch density {
        case .compact: 0.78
        case .standard: 1
        case .roomy: 1.2
        }
    }

    // MARK: Palette

    /// The colours to draw with in light or dark. `systemAccent` is macOS's accent, for checks only.
    public func palette(dark: Bool) -> ThemePalette {
        var palette = ThemePalette()
        palette.ink = override(.ink, dark: dark) ?? Self.ink(neutrals, dark: dark)
        switch contrast {
        case .standard:
            (palette.secondary, palette.tertiary, palette.faint, palette.line, palette.wash) = (0.84, 0.74, 0.30, 0.12, 0.06)
        case .high:
            (palette.secondary, palette.tertiary, palette.faint, palette.line, palette.wash) = (0.93, 0.85, 0.46, 0.24, 0.09)
        }
        palette.cardFill = cards == .filled ? (contrast == .high ? 0.08 : 0.055) : 0
        palette.cardStroke = cards == .outlined
        palette.background = override(.background, dark: dark) ?? Self.canvas(neutrals, dark: dark)
        palette.solidBackground = background == .solid
        palette.tint = background == .tinted ? (dark ? 0.10 : 0.07) : 0
        switch accent {
        case .system: palette.accent = nil
        case .mono: palette.accent = palette.ink ?? (dark ? .white : .black)
        case .color(let rgba): palette.accent = rgba
        }
        if let accent = override(.accent, dark: dark) { palette.accent = accent }
        palette.monoAccent = accent == .mono && override(.accent, dark: dark) == nil
        palette.card = override(.card, dark: dark)
        palette.lineColor = override(.line, dark: dark)
        palette.alert = override(.alert, dark: dark)
        return palette
    }

    /// Text and marks for warm and cool neutrals (neutral uses the system's own label colour,
    /// which keeps the glass panel's vibrancy).
    static func ink(_ neutrals: Neutrals, dark: Bool) -> RGBA? {
        switch neutrals {
        case .neutral: nil
        case .warm: dark ? RGBA(hex: "#F4EEE6") : RGBA(hex: "#2B251E")
        case .cool: dark ? RGBA(hex: "#E7EEF6") : RGBA(hex: "#1C2633")
        }
    }

    /// The solid background, off-white and off-black, never pure.
    static func canvas(_ neutrals: Neutrals, dark: Bool) -> RGBA {
        switch neutrals {
        case .neutral: dark ? RGBA(0.04, 0.04, 0.04) : RGBA(0.98, 0.98, 0.98)
        case .warm: RGBA(hex: dark ? "#15120E" : "#F8F4EC")!
        case .cool: RGBA(hex: dark ? "#0D1117" : "#F3F6FA")!
        }
    }

    // MARK: Checks

    /// What's hard to read in this theme, in the modes it shows in (the accent needs 3:1 against
    /// the cards, small text 4.5:1). `systemAccent` stands in for macOS's accent.
    public func contrastProblems(systemAccent: RGBA = RGBA(hex: "#007AFF")!) -> [String] {
        var problems: [String] = []
        let modes: [Bool] = switch appearance {
        case .system: [false, true]
        case .light: [false]
        case .dark: [true]
        }
        for dark in modes {
            let palette = palette(dark: dark)
            let mode = dark ? "dark" : "light"
            let ground = palette.background
            let ink = (palette.ink ?? (dark ? RGBA.white : RGBA.black))
            let card = (palette.card ?? ink.withAlpha(palette.cardFill)).over(ground)
            if RGBA.contrast(ink.withAlpha(palette.tertiary).over(card), card) < 4.5 {
                problems.append("Small text is hard to read in \(mode) mode.")
            }
            let accent = (palette.accent ?? systemAccent).over(card)
            if !palette.monoAccent, RGBA.contrast(accent, card) < 3 {
                problems.append("The accent is hard to see in \(mode) mode.")
            }
        }
        return problems
    }

    // MARK: Built in

    /// Tutto's own look first.
    public static let tutto = ThemeSpec(name: "Tutto")

    /// Liquid Glass (macOS 26): the default look.
    public static let liquidGlass = ThemeSpec(name: "Liquid Glass", background: .liquid, corners: .large)

    public static let builtIn: [ThemeSpec] = [
        tutto,
        ThemeSpec(name: "Graphite", accent: .mono, contrast: .high, cards: .outlined, corners: .small,
                  density: .compact, numbers: .mono),
        ThemeSpec(name: "Paper", accent: .color(RGBA(hex: "#B5532C")!), neutrals: .warm, background: .solid,
                  corners: .large, density: .roomy, numbers: .rounded),
        ThemeSpec(name: "Slate", accent: .color(RGBA(hex: "#3E7BFA")!), neutrals: .cool, background: .tinted),
        ThemeSpec(name: "Midnight", accent: .color(RGBA(hex: "#8C9BFF")!), neutrals: .cool, background: .solid,
                  corners: .large, numbers: .rounded, appearance: .dark,
                  colors: ["dark": ["background": "#0A0D14", "card": "#FFFFFF10"]]),
        ThemeSpec(name: "Forest", accent: .color(RGBA(hex: "#2F8F5B")!), neutrals: .warm, background: .tinted,
                  numbers: .rounded),
    ]
}

/// The colours a theme resolves to in light or dark.
public struct ThemePalette: Equatable, Sendable {
    /// Text and marks; nil means the system's label colour.
    public var ink: RGBA?
    /// Ink's opacity for secondary, tertiary and faint text, hairlines and washes.
    public var secondary = 0.84
    public var tertiary = 0.74
    public var faint = 0.30
    public var line = 0.12
    public var wash = 0.06
    /// Ink's opacity on a card (0 for outlined cards).
    public var cardFill = 0.055
    public var cardStroke = false
    /// A card's colour set outright.
    public var card: RGBA?
    /// Hairlines' colour set outright.
    public var lineColor: RGBA?
    /// The solid background (windows, and the panel when it isn't glass).
    public var background = RGBA(0.98, 0.98, 0.98)
    public var solidBackground = false
    /// The accent's opacity over the glass (0: plain glass).
    public var tint = 0.0
    /// nil means macOS's accent.
    public var accent: RGBA?
    /// The accent is the ink (no colour).
    public var monoAccent = false
    /// nil means the system red.
    public var alert: RGBA?

    public init() {}
}

// MARK: - Files

/// Your themes as JSON files in a folder.
public struct ThemeFiles: Sendable {
    public let directory: URL
    /// Deleting moves to the Trash (tests delete outright).
    public let usesTrash: Bool

    public init(directory: URL, usesTrash: Bool = true) {
        self.directory = directory
        self.usesTrash = usesTrash
    }

    public static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Tutto/Themes", isDirectory: true)
    }

    /// Each theme with its file, by name, and a line per file that isn't a theme.
    public func load() -> (themes: [(spec: ThemeSpec, url: URL)], problems: [String]) {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var themes: [(ThemeSpec, URL)] = []
        var problems: [String] = []
        for url in urls.filter({ $0.pathExtension.lowercased() == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let data = try? Data(contentsOf: url),
                  (try? JSONSerialization.jsonObject(with: data)) is [String: Any],
                  var spec = try? JSONDecoder().decode(ThemeSpec.self, from: data) else {
                problems.append("\(url.lastPathComponent): not a theme (a JSON object is expected)")
                continue
            }
            if spec.name == "Untitled" { spec.name = url.deletingPathExtension().lastPathComponent }
            themes.append((spec, url))
        }
        return (themes.sorted { $0.0.name.localizedCaseInsensitiveCompare($1.0.name) == .orderedAscending }, problems)
    }

    /// The file a theme of this name is saved to.
    public func url(for name: String) -> URL {
        directory.appendingPathComponent(PluginStore.slug(name) + ".json")
    }

    /// Writes a theme to a file named after it (replacing the file only when asked).
    @discardableResult
    public func save(_ spec: ThemeSpec, replacing: Bool = false) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = url(for: spec.name)
        if !replacing, FileManager.default.fileExists(atPath: url.path) {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSLocalizedDescriptionKey: "You already have a theme called “\(spec.name)”: pick another name."])
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(spec).write(to: url, options: .atomic)
        return url
    }

    /// Moves a theme file to the Trash.
    public func delete(_ url: URL) throws {
        if usesTrash {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } else {
            try FileManager.default.removeItem(at: url)
        }
    }
}
