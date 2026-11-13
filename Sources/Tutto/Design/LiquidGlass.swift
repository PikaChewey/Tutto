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

import AppKit
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

/// How the Liquid Glass panel is built (Bryan 2026-11-13: "i dont think it looks glassy enough";
/// shown three, picked floating; then, of the Notification Center frost behind the floating cards:
/// "doesnt look the best, take more from the outer frame from the original option B"). The glass
/// stage renders the others with `glass-look:<name>`.
enum GlassLook: String {
    /// One sheet, cards as platters on it (the first version).
    case sheet
    /// Every card its own piece of glass floating over the desktop on a colourless frosted frame,
    /// the header and the footer glass capsules (shipped 2026-11-13, replaced the same day).
    case floating
    /// What ships (option B): one sheet of Apple's most see-through glass, lightly dimmed so the
    /// text reads over any wallpaper, a rim of light around it; the cards on it barely-there
    /// platters with their own rims. The desktop's colour comes through, not a grey frost.
    case clear

    nonisolated(unsafe) static var current: GlassLook = .clear
}

extension View {
    /// Glass of the prototype look in `shape` (regular, or clear with `clear`).
    @ViewBuilder
    func prototypeGlass<S: Shape>(_ shape: S, clear: Bool = false) -> some View {
        if #available(macOS 26, *), ThemeStore.shared.tokens.liquid {
            glassEffect(clear ? Glass.clear : Glass.regular, in: shape)
        } else {
            self
        }
    }
}

/// A thin line of light around a piece of glass: bright on the top-left edge, faint below.
struct GlassRim<S: InsettableShape>: View {
    var shape: S
    var strength: Double = 1
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        shape.strokeBorder(
            LinearGradient(stops: [.init(color: .white.opacity((dark ? 0.55 : 0.95) * strength), location: 0),
                                   .init(color: .white.opacity((dark ? 0.08 : 0.3) * strength), location: 0.45),
                                   .init(color: .white.opacity((dark ? 0.22 : 0.6) * strength), location: 1)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            lineWidth: 1)
        .allowsHitTesting(false)
    }
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

/// Behind the floating glass cards: one frosted frame that blurs whatever is behind the panel
/// without colouring it, as Notification Center does (Bryan 2026-11-13: the cards alone looked
/// "bare naked" with everything around and between them perfectly seen). The cards stay glass.
struct FrostedFrame: NSViewRepresentable {
    var radius: CGFloat = 26
    /// The blur's material (the most neutral one; `frost:<name>` tries others on the glass stage).
    nonisolated(unsafe) static var material: NSVisualEffectView.Material = .fullScreenUI
    /// What it blurs: the screen behind the window; the glass stage's wallpaper is inside its window.
    nonisolated(unsafe) static var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = Self.material
        view.blendingMode = Self.blending
        view.state = .active
        view.maskImage = Self.mask(radius: radius)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}

    /// A stretchable rounded-rectangle mask, so the blur has the frame's corners.
    private static func mask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
