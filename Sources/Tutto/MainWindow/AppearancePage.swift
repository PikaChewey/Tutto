//
//  AppearancePage.swift
//  Tutto
//
//  Themes (Bryan, 2026-11-10: "your own colours and look"): pick one of Tutto's or one of yours,
//  or adjust the one in use: accent, greys, contrast, background, cards, corners, density,
//  numbers, light or dark. The whole app follows at once, with the panel beside you as a preview.
//  A theme is a JSON file in the Themes folder: save yours, share it, drop someone else's in.
//

import AppKit
import SwiftUI
import TuttoKit

struct AppearancePage: View {
    @Bindable var model: AppModel
    @State private var naming = false
    @State private var name = ""
    @State private var saveProblem: String?
    @State private var custom = Color.blue

    private var theme: ThemeStore { .shared }
    private var spec: ThemeSpec { theme.spec }

    /// Accents to pick from; any other colour comes from the colour picker.
    private static let accents: [(name: String, hex: String)] = [
        ("Blue", "#3E7BFA"), ("Indigo", "#6366F1"), ("Purple", "#8E6CF0"), ("Pink", "#E05A9C"), ("Red", "#E5484D"),
        ("Orange", "#E8833A"), ("Amber", "#C98A0C"), ("Green", "#2F8F5B"), ("Teal", "#1E9AA6"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: "Appearance",
                       subtitle: "Pick a theme or make your own: the accent, the greys, how cards and corners look and how roomy it all is. Tutto changes at once; your themes are files you can share.")
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 26) {
                    controls.frame(minWidth: 330, idealWidth: 360, maxWidth: .infinity)
                    preview
                }
                VStack(alignment: .leading, spacing: 22) {
                    controls
                    preview
                }
            }
        }
        .onAppear { theme.loadFiles() }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Caption("Preview")
            PanelPreview(model: model)
        }
        .frame(width: PanelPreview.width)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 22) {
            gallery
            adjust
            files
        }
    }

    // MARK: Themes

    private var gallery: some View {
        let mine = theme.files
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Caption("Themes")
                Spacer()
                Text(theme.matching?.name ?? "Your changes, not saved")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ink3)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 112, maximum: 160), spacing: 10)], alignment: .leading, spacing: 10) {
                ForEach(ThemeSpec.builtIn, id: \.name) { spec in
                    ThemeSwatch(spec: spec, selected: spec.looksLike(self.spec)) { apply(spec) }
                }
                ForEach(mine, id: \.url) { file in
                    ThemeSwatch(spec: file.spec, selected: file.spec.looksLike(spec), yours: true) { apply(file.spec) }
                        .contextMenu {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                            Button("Move to Trash") { theme.deleteFile(file.url) }
                        }
                }
            }
        }
    }

    private func apply(_ spec: ThemeSpec) {
        withAnimation(Motion.snappy) { theme.apply(spec) }
    }

    // MARK: Adjusting

    private var adjust: some View {
        VStack(alignment: .leading, spacing: 8) {
            InkGroup("Adjust") {
                accentRow
                Hairline().opacity(0.6)
                choice("Greys", \.neutrals, [(.neutral, "Neutral"), (.warm, "Warm"), (.cool, "Cool")])
                Hairline().opacity(0.6)
                choice("Contrast", \.contrast, [(.standard, "Standard"), (.high, "High")])
                Hairline().opacity(0.6)
                choice("Panel background", \.background, [(.glass, "Glass"), (.tinted, "Tinted"), (.solid, "Solid")])
                Hairline().opacity(0.6)
                choice("Cards", \.cards, [(.filled, "Filled"), (.outlined, "Outlined")])
                Hairline().opacity(0.6)
                choice("Corners", \.corners, [(.small, "Small"), (.medium, "Medium"), (.large, "Large")])
                Hairline().opacity(0.6)
                choice("Spacing", \.density, [(.compact, "Compact"), (.standard, "Standard"), (.roomy, "Roomy")])
                Hairline().opacity(0.6)
                choice("Numbers", \.numbers, [(.standard, "Standard"), (.rounded, "Rounded"), (.mono, "Mono")])
                Hairline().opacity(0.6)
                choice("Light or dark", \.appearance, [(.system, "Match Mac"), (.light, "Light"), (.dark, "Dark")])
            }
            contrastNotes
        }
    }

    private var accentRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Accent").font(.system(size: 12.5))
                Spacer()
                Text(accentName).font(.system(size: 11)).foregroundStyle(Color.ink3)
            }
            HStack(spacing: 7) {
                AccentDot(fill: AnyShapeStyle(AngularGradient(colors: [.red, .orange, .yellow, .green, .blue, .purple, .red], center: .center)),
                          selected: spec.accent == .system, help: "Your Mac's accent") { set { $0.accent = .system } }
                AccentDot(fill: AnyShapeStyle(Color.ink), selected: spec.accent == .mono, help: "No colour: marks in the ink") {
                    set { $0.accent = .mono }
                }
                ForEach(Self.accents, id: \.hex) { accent in
                    let rgba = RGBA(hex: accent.hex)!
                    AccentDot(fill: AnyShapeStyle(rgba.color), selected: spec.accent == .color(rgba), help: accent.name) {
                        set { $0.accent = .color(rgba) }
                    }
                }
                ColorPicker("Any colour", selection: Binding(get: { customColor }, set: { color in
                    set { $0.accent = .color(RGBA(color).withAlpha(1).quantized) }
                }), supportsOpacity: false)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 30)
                .help("Any colour")
            }
        }
        .padding(.vertical, Metrics.rowPadding)
    }

    private var customColor: Color {
        if case .color(let rgba) = spec.accent { return rgba.color }
        return .blue
    }

    private var accentName: String {
        switch spec.accent {
        case .system: "Your Mac's"
        case .mono: "None"
        case .color(let rgba): Self.accents.first { RGBA(hex: $0.hex) == rgba }?.name ?? rgba.hex
        }
    }

    private func choice<Value: Hashable>(_ title: String, _ key: WritableKeyPath<ThemeSpec, Value>,
                                         _ options: [(Value, String)]) -> some View {
        LabeledRow(title) {
            InkSegmented(selection: Binding(get: { spec[keyPath: key] }, set: { value in set { $0[keyPath: key] = value } }),
                         options: options)
        }
    }

    private func set(_ change: (inout ThemeSpec) -> Void) {
        withAnimation(Motion.snappy) { theme.update(change) }
    }

    /// What's hard to read in this theme, with a fix for the accent.
    @ViewBuilder
    private var contrastNotes: some View {
        let problems = spec.contrastProblems(systemAccent: RGBA(Color.accentColor))
        if !problems.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Color.alert)
                Text(problems.joined(separator: " "))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if problems.contains(where: { $0.contains("accent") }), case .color(let rgba) = spec.accent {
                    Button("Fix") { fixAccent(rgba) }
                        .buttonStyle(OutlineButtonStyle(compact: true))
                        .help("Darken or lighten the accent until it stands out")
                }
            }
            .padding(.horizontal, 2)
        }
    }

    /// The accent moved just far enough to stand out on cards in every mode the theme shows in.
    private func fixAccent(_ rgba: RGBA) {
        var fixed = rgba
        for dark in [false, true] where spec.appearance == .system || (spec.appearance == .dark) == dark {
            let palette = spec.palette(dark: dark)
            let ink = palette.ink ?? (dark ? RGBA.white : RGBA.black)
            let card = (palette.card ?? ink.withAlpha(palette.cardFill)).over(palette.background)
            fixed = fixed.adjusted(toContrast: 3.1, against: card)
        }
        set { $0.accent = .color(fixed.withAlpha(1).quantized) }
    }

    // MARK: Files

    private var files: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if naming {
                    TextField("Theme name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                        .onSubmit(save)
                    Button("Save", action: save)
                        .primaryButton()
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    QuietButton(title: "Cancel") {
                        naming = false
                        saveProblem = nil
                    }
                } else {
                    Button("Save as Theme…") {
                        name = freeName(theme.matching.map { "My \($0.name)" } ?? "My Theme")
                        naming = true
                    }
                    .buttonStyle(OutlineButtonStyle(compact: true))
                    Button("Show Themes Folder") {
                        try? FileManager.default.createDirectory(at: theme.folder.directory, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([theme.folder.directory])
                    }
                    .buttonStyle(OutlineButtonStyle(compact: true))
                }
                Spacer()
            }
            if let saveProblem {
                Text(saveProblem).font(.system(size: 11.5)).foregroundStyle(Color.alert)
            }
            ForEach(theme.problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ink2)
            }
            Text("A theme is a JSON file: the choices above, and colours set outright for light or dark if you like (\"colors\": {\"dark\": {\"background\": \"#0B0E14\"}}, for ink, background, card, line, accent and alert). Drop one in the folder and it shows up here.")
                .font(.system(size: 11))
                .foregroundStyle(Color.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    /// The name, or the name with a number, so it doesn't take another theme's.
    private func freeName(_ base: String) -> String {
        let taken = Set((ThemeSpec.builtIn + theme.files.map(\.spec)).map { $0.name.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        return (2...99).map { "\(base) \($0)" }.first { !taken.contains($0.lowercased()) } ?? base
    }

    private func save() {
        if let problem = theme.saveFile(named: name) {
            saveProblem = problem
        } else {
            saveProblem = nil
            naming = false
        }
    }
}

/// A theme as a small picture of the panel: its background, two cards and a wide one, its ink and
/// its accent, at its corners and spacing.
private struct ThemeSwatch: View {
    var spec: ThemeSpec
    var selected: Bool
    var yours = false
    var action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        let dark = spec.appearance == .dark || (spec.appearance == .system && scheme == .dark)
        let palette = spec.palette(dark: dark)
        let ink = palette.ink ?? (dark ? RGBA.white : RGBA.black)
        let accent = palette.monoAccent ? ink : (palette.accent ?? RGBA(Color.accentColor))
        let glass = dark ? RGBA(0.17, 0.17, 0.18) : RGBA(0.91, 0.91, 0.92)
        let ground = palette.solidBackground ? palette.background : glass.mixed(with: accent, palette.tint * 1.6)
        let card = (palette.card ?? ink.withAlpha(palette.cardFill)).over(ground)
        let corner = 7 * spec.cornerScale
        let gap = 4 * spec.densityScale
        let line = palette.lineColor ?? ink.withAlpha(palette.line)

        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                VStack(spacing: gap) {
                    HStack(spacing: gap) {
                        miniCard(card: card, ink: ink, accent: accent, line: line, corner: corner, outlined: palette.cardStroke, graph: true)
                        miniCard(card: card, ink: ink, accent: accent, line: line, corner: corner, outlined: palette.cardStroke, graph: false)
                    }
                    miniCard(card: card, ink: ink, accent: accent, line: line, corner: corner, outlined: palette.cardStroke, graph: true)
                }
                .padding(6 * spec.densityScale)
                .frame(height: 70)
                .background(RoundedRectangle(cornerRadius: corner + 3, style: .continuous).fill(ground.color))
                .overlay(RoundedRectangle(cornerRadius: corner + 3, style: .continuous).strokeBorder(Color.hairline))
                HStack(spacing: 4) {
                    Text(spec.name)
                        .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                    if yours {
                        Text("yours").font(.system(size: 9.5)).foregroundStyle(Color.ink3)
                    }
                    Spacer(minLength: 2)
                    if selected {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.themeAccent)
                    }
                }
            }
            .padding(7)
            .background(RoundedRectangle(cornerRadius: Radius.of(10), style: .continuous)
                .fill(selected ? Color.themeAccent.opacity(0.10) : (hovering ? Color.wash : .clear)))
            .overlay(RoundedRectangle(cornerRadius: Radius.of(10), style: .continuous)
                .strokeBorder(selected ? Color.themeAccent : Color.hairline, lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(spec.name) theme")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func miniCard(card: RGBA, ink: RGBA, accent: RGBA, line: RGBA, corner: Double, outlined: Bool, graph: Bool) -> some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(card.color)
            .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(outlined ? line.color : .clear))
            .overlay(alignment: .leading) {
                VStack(alignment: .leading, spacing: 3) {
                    Capsule().fill(ink.withAlpha(0.35).color).frame(width: 14, height: 2.5)
                    HStack(alignment: .bottom, spacing: 4) {
                        Capsule().fill(ink.color).frame(width: 12, height: 5)
                        if graph {
                            Capsule().fill(accent.color).frame(height: 2.5)
                        }
                    }
                }
                .padding(.horizontal, 5)
            }
    }
}

/// An accent to pick: a dot, ringed when it's the one in use.
private struct AccentDot: View {
    var fill: AnyShapeStyle
    var selected: Bool
    var help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(fill)
                .frame(width: 16, height: 16)
                .overlay(Circle().strokeBorder(Color.ink.opacity(0.15)))
                .padding(2.5)
                .overlay(Circle().strokeBorder(selected ? Color.ink : .clear, lineWidth: 1.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
