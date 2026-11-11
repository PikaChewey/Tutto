//
//  ThemeStore.swift
//  Tutto
//
//  The theme in use, and the colours, radii, spacing and figures every view draws with. The
//  design tokens (Color.ink, Radius.of, PanelGrid, Font.figure) read the store, so a view that
//  uses one redraws when the theme changes: the whole app follows a new theme at once, no relaunch.
//

import AppKit
import Observation
import SwiftUI
import TuttoKit

/// The resolved look: built once per theme change, read by every token.
struct ThemeTokens {
    var ink: Color
    var ink2: Color
    var ink3: Color
    var ink4: Color
    var hairline: Color
    var wash: Color
    /// A card's fill, and while the pointer is over it.
    var card: Color
    var cardHover: Color
    /// Outlined cards' edge (clear for filled cards).
    var cardStroke: Color
    var accent: Color
    var alert: Color
    /// The opaque background (windows, and the panel when the theme's background is solid).
    var canvas: Color
    var paper: Color
    var solidInk: Color
    /// Laid over the panel's glass (clear when the theme's background is plain glass).
    var tint: Color
    var solidBackground: Bool
    var radiusScale: CGFloat
    var densityScale: CGFloat
    var numbers: Font.Design
}

@MainActor
@Observable
final class ThemeStore {
    static let shared = ThemeStore()

    /// The theme in use.
    private(set) var spec: ThemeSpec
    private(set) var tokens: ThemeTokens
    /// Your theme files, and lines for files that aren't themes.
    private(set) var files: [(spec: ThemeSpec, url: URL)] = []
    private(set) var problems: [String] = []

    let folder = ThemeFiles(directory: ThemeFiles.defaultDirectory)
    @ObservationIgnored private let defaults = UserDefaults.standard

    private init() {
        let saved = UserDefaults.standard.data(forKey: Keys.current).flatMap { try? JSONDecoder().decode(ThemeSpec.self, from: $0) }
        let spec = saved ?? .tutto
        self.spec = spec
        tokens = Self.tokens(for: spec)
    }

    /// At launch, once the app exists: its light or dark, and the theme files.
    func start() {
        Self.applyAppearance(spec.appearance)
        loadFiles()
    }

    /// Makes `spec` the theme in use (and remembers it, unless it's only for a render).
    func apply(_ spec: ThemeSpec, remember: Bool = true) {
        guard spec != self.spec else { return }
        let appearanceChanged = spec.appearance != self.spec.appearance
        self.spec = spec
        tokens = Self.tokens(for: spec)
        if remember, let data = try? JSONEncoder().encode(spec) { defaults.set(data, forKey: Keys.current) }
        if appearanceChanged { Self.applyAppearance(spec.appearance) }
    }

    func update(_ change: (inout ThemeSpec) -> Void) {
        var changed = spec
        change(&changed)
        apply(changed)
    }

    /// The built-in theme or theme file the current look matches, if any.
    var matching: ThemeSpec? {
        (ThemeSpec.builtIn + files.map(\.spec)).first { $0.looksLike(spec) }
    }

    /// Reads the themes folder again (a file added by hand shows up).
    func loadFiles() {
        let loaded = folder.load()
        files = loaded.themes
        problems = loaded.problems
    }

    /// Saves the current look as a theme file; returns why it couldn't be.
    @discardableResult
    func saveFile(named name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Give it a name." }
        guard !ThemeSpec.builtIn.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            return "A built-in theme has that name."
        }
        var spec = spec
        spec.name = trimmed
        do {
            try folder.save(spec)
        } catch {
            return error.localizedDescription
        }
        apply(spec)
        loadFiles()
        return nil
    }

    func deleteFile(_ url: URL) {
        try? folder.delete(url)
        loadFiles()
    }

    // MARK: Resolving

    private static func applyAppearance(_ appearance: ThemeSpec.Appearance) {
        switch appearance {
        case .system: NSApp?.appearance = nil
        case .light: NSApp?.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp?.appearance = NSAppearance(named: .darkAqua)
        }
    }

    static func tokens(for spec: ThemeSpec) -> ThemeTokens {
        let light = spec.palette(dark: false)
        let dark = spec.palette(dark: true)
        /// Ink at an opacity: the system's label colour (vibrant on glass) unless the theme tints it.
        func ink(_ opacity: @escaping @Sendable (ThemePalette) -> Double) -> Color {
            if light.ink == nil, dark.ink == nil, opacity(light) == opacity(dark) {
                return opacity(light) >= 1 ? .primary : .primary.opacity(opacity(light))
            }
            return dynamic { dark in
                let palette = dark ? darkPalette(spec) : lightPalette(spec)
                return (palette.ink ?? (dark ? .white : .black)).withAlpha(opacity(palette))
            }
        }
        func pick(_ color: @escaping @Sendable (ThemePalette) -> RGBA?, fallback: Color) -> Color {
            guard color(light) != nil || color(dark) != nil else { return fallback }
            return dynamic { dark in
                let palette = dark ? darkPalette(spec) : lightPalette(spec)
                return color(palette) ?? (dark ? RGBA.white : RGBA.black).withAlpha(palette.line)
            }
        }
        let accent: Color = (light.accent == nil && dark.accent == nil) ? .accentColor
            : dynamic { dark in (dark ? darkPalette(spec) : lightPalette(spec)).accent ?? RGBA(hex: "#007AFF")! }
        let card: Color = (light.card != nil || dark.card != nil)
            ? dynamic { dark in (dark ? darkPalette(spec) : lightPalette(spec)).card ?? RGBA.white.withAlpha(0) }
            : ink { $0.cardFill }
        let hairline = pick({ $0.lineColor }, fallback: ink { $0.line })
        let canvas = dynamic { dark in (dark ? darkPalette(spec) : lightPalette(spec)).background }
        let numbers: Font.Design = switch spec.numbers {
        case .standard: .default
        case .rounded: .rounded
        case .mono: .monospaced
        }
        return ThemeTokens(
            ink: ink { _ in 1 },
            ink2: ink { $0.secondary },
            ink3: ink { $0.tertiary },
            ink4: ink { $0.faint },
            hairline: hairline,
            wash: ink { $0.wash },
            card: card,
            cardHover: (light.card != nil || dark.card != nil) ? card.opacity(0.8) : ink { $0.cardFill + 0.03 },
            cardStroke: light.cardStroke ? hairline : .clear,
            accent: accent,
            alert: pick({ $0.alert }, fallback: Color(nsColor: .systemRed)),
            canvas: canvas,
            paper: (light.ink == nil && dark.ink == nil && !light.solidBackground)
                ? Color(nsColor: NSColor(name: "paper") { $0.isDark ? .black : .white }) : canvas,
            solidInk: light.ink == nil && dark.ink == nil
                ? Color(nsColor: NSColor(name: "solidInk") { $0.isDark ? NSColor(white: 0.96, alpha: 1) : NSColor(white: 0.08, alpha: 1) })
                : ink { _ in 1 },
            tint: light.tint > 0 ? accent.opacity(0.08) : .clear,
            solidBackground: light.solidBackground,
            radiusScale: CGFloat(spec.cornerScale),
            densityScale: CGFloat(spec.densityScale),
            numbers: numbers)
    }

    // The palettes are worked out again inside colour providers (they run at draw time, possibly
    // for a theme that's no longer current; each provider keeps the spec it was made for).
    nonisolated private static func lightPalette(_ spec: ThemeSpec) -> ThemePalette { spec.palette(dark: false) }
    nonisolated private static func darkPalette(_ spec: ThemeSpec) -> ThemePalette { spec.palette(dark: true) }

    /// A colour that resolves for light or dark when it's drawn.
    nonisolated static func dynamic(_ color: @escaping @Sendable (Bool) -> RGBA) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgba = color(appearance.isDark)
            return NSColor(srgbRed: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha)
        })
    }

    private enum Keys {
        static let current = "theme.current"
    }
}

extension RGBA {
    /// A swatch for the Appearance page.
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent), Double(ns.alphaComponent))
    }
}

// MARK: - Tokens

/// Corner radii, scaled by the theme ("Corners" on the Appearance page).
enum Radius {
    @MainActor static func of(_ base: CGFloat) -> CGFloat {
        (base * ThemeStore.shared.tokens.radiusScale).rounded(.toNearestOrAwayFromZero)
    }
}

extension Font {
    /// Figures (readings, the battery, counts) in the theme's number style, digits all one width.
    @MainActor static func figure(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: ThemeStore.shared.tokens.numbers).monospacedDigit()
    }
}

/// A card's surface: the theme's fill, and its outline when cards are outlined.
struct CardSurface: View {
    var radius: CGFloat
    var hovering = false

    var body: some View {
        let tokens = ThemeStore.shared.tokens
        RoundedRectangle(cornerRadius: Radius.of(radius), style: .continuous)
            .fill(hovering ? tokens.cardHover : tokens.card)
            .overlay(RoundedRectangle(cornerRadius: Radius.of(radius), style: .continuous).strokeBorder(tokens.cardStroke))
    }
}
