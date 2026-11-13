//
//  LiquidGlass.swift
//  Tutto
//
//  The Liquid Glass theme (macOS 26), drawn the way Apple's guidance and the reactions to it say
//  it reads best:
//  - One sheet of glass: the panel. Glass is for the layer you act on, and glass on glass muddies
//    both, so cards are platters on it (a translucent fill and a hairline of light along the top
//    edge), never glass of their own. Text always sits on a platter, never straight on clear glass
//    over a busy wallpaper (the most repeated complaint about Liquid Glass).
//  - Controls on the sheet are raised platters, not glass (glass inside glass draws as a dark blob
//    and hides its own label, measured on the preview stage): chips, the segmented thumb, and the
//    lens that glides along the tools bar, magnifying the icon under it. Only what floats above the
//    panel for a moment, the tool's name and keys, is glass of its own. At rest the panel is quiet.
//  - Shapes nest: a card's corners are the panel's less the gap between them (concentric), small
//    controls are capsules.
//  - Motion is springs, interruptible, a 0.97 press; nothing animates while the panel sits still,
//    and Reduce Motion, Reduce Transparency and Increase Contrast are the system's to apply.
//  Before macOS 26 none of this runs: the theme falls back to the plain glass look.
//

import SwiftUI

extension View {
    /// Liquid Glass in `shape` when the theme asks for it (macOS 26); otherwise the view as it is.
    /// `interactive` glass answers the pointer: it brightens where you press and flexes.
    @ViewBuilder
    func liquidGlass<S: Shape>(_ shape: S, interactive: Bool = false, tint: Color? = nil, enabled: Bool = true) -> some View {
        if #available(macOS 26, *), enabled, ThemeStore.shared.tokens.liquid {
            glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            self
        }
    }
}

extension ThemeStore {
    /// True when the Liquid Glass theme is on and the system draws it.
    @MainActor static var liquid: Bool { shared.tokens.liquid }
}

/// A card on the glass: a translucent platter that keeps text legible over any wallpaper, with a
/// hairline of light along its top edge. Under the pointer it lifts into glass.
struct LiquidPlatter: View {
    var radius: CGFloat
    var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let dark = scheme == .dark
        shape
            .fill(Color.white.opacity(dark ? (hovering ? 0.11 : 0.075) : (hovering ? 0.62 : 0.46)))
            .overlay(shape.strokeBorder(
                LinearGradient(colors: [Color.white.opacity(dark ? 0.22 : 0.85), Color.white.opacity(dark ? 0.03 : 0.25),
                                        Color.white.opacity(dark ? 0.07 : 0.4)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 0.8))
            .shadow(color: .black.opacity(dark ? 0 : (hovering ? 0.08 : 0.04)), radius: hovering ? 6 : 2, y: hovering ? 2 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.1), value: hovering)
    }
}

/// A control on the glass (a chip, a button, the segmented thumb, the tools bar's lens): a raised
/// translucent capsule with light along its top edge. Glass inside glass draws as a dark blob and
/// hides what's on it (measured on the preview stage), so controls on the panel are platters too.
struct LiquidFill<S: InsettableShape>: View {
    var shape: S
    /// 1 at rest; more for the selected thumb and the lens, which sit higher.
    var raise: Double = 1
    var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let fill = (dark ? 0.11 : 0.42) * raise + (hovering ? (dark ? 0.07 : 0.18) : 0)
        shape
            .fill(Color.white.opacity(min(fill, dark ? 0.34 : 0.96)))
            .overlay(shape.strokeBorder(
                LinearGradient(colors: [Color.white.opacity(dark ? 0.32 : 0.95), Color.white.opacity(dark ? 0.05 : 0.35)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 0.75))
            .shadow(color: .black.opacity((dark ? 0.22 : 0.07) * raise), radius: 1.5 * raise, y: 0.5 * raise)
            .animation(.spring(duration: 0.2, bounce: 0.1), value: hovering)
    }
}
