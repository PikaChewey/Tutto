//
//  Lens.swift
//  Tutto
//
//  The tools bar's hover, for every control on the panel (Bryan, 2026-11-13: "I really like the
//  hover over and smooth glass feel ... of the small mini bar icons ... but the rest of it doesn't
//  have the same hover over effects"). Under the pointer a raised piece of glass, the lens, comes up
//  behind a control on the tools bar's spring, and what's on it swells a little, as if magnified; a
//  press pushes it in. Not on app icons: an app icon is its own tile, so the Sound strip's icons
//  show what a click does instead (SoundAppButton). Cards that open a page lift: the rim brightens,
//  a sheen comes over them, they grow 2 %.
//  Classic look: the same motion on a faint ink wash. Nothing animates until the pointer moves.
//

import SwiftUI

/// Snapshots: controls drawn as if under the pointer (`hover:CPU,2h,Custom`), by their title.
enum LensStage {
    nonisolated(unsafe) static var forced: Set<String> = []
    static func on(_ key: String?) -> Bool { key.map { forced.contains($0) } ?? false }
}

extension Motion {
    /// The tools bar's lens: quick, with a little bounce.
    static let lens = Animation.spring(duration: 0.3, bounce: 0.18)
    /// What swells under the lens: text, and icons (more, as the tools bar's do).
    static let textSwell: CGFloat = 1.05
    static let iconSwell: CGFloat = 1.12

    static func lens(reduceMotion: Bool) -> Animation { reduceMotion ? .easeOut(duration: 0.1) : lens }
}

/// The lens: a raised piece of glass (an ink wash in the Classic look).
struct LensPlatter<S: InsettableShape>: View {
    var shape: S
    var raise: Double = 1.5

    var body: some View {
        if ThemeStore.liquid {
            LiquidFill(shape: shape, raise: raise)
        } else {
            shape.fill(Color.ink.opacity(0.08))
        }
    }
}

// MARK: - The hover

/// The lens behind a control while the pointer is on it. `x` and `y` reach past the content, so the
/// content stays on the grid.
struct LensHover<S: InsettableShape>: ViewModifier {
    var shape: S
    var x: CGFloat
    var y: CGFloat
    var swell: CGFloat
    var hovering: ((Bool) -> Void)?
    var stageKey: String?

    @State private var local = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var on: Bool { local || LensStage.on(stageKey) }

    func body(content: Content) -> some View {
        content
            .scaleEffect(on && !reduceMotion ? swell : 1)
            .padding(.horizontal, x)
            .padding(.vertical, y)
            .background {
                if on {
                    LensPlatter(shape: shape)
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                }
            }
            .padding(.horizontal, -x)
            .padding(.vertical, -y)
            .animation(Motion.lens(reduceMotion: reduceMotion), value: on)
            .onHover { inside in
                local = inside
                hovering?(inside)
            }
    }
}

/// The lens drawn from a hover state the view keeps itself.
struct LensBackground<S: InsettableShape>: ViewModifier {
    var on: Bool
    var shape: S
    var x: CGFloat
    var y: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, x)
            .padding(.vertical, y)
            .background {
                if on {
                    LensPlatter(shape: shape)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .padding(.horizontal, -x)
            .padding(.vertical, -y)
            .animation(Motion.lens(reduceMotion: reduceMotion), value: on)
    }
}

extension View {
    /// The tools bar's hover: a lens behind, the content swelling a little.
    func lensHover(cornerRadius: CGFloat = 9, x: CGFloat = 6, y: CGFloat = 3, swell: CGFloat = Motion.textSwell,
                   stageKey: String? = nil, hovering: ((Bool) -> Void)? = nil) -> some View {
        modifier(LensHover(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), x: x, y: y,
                           swell: swell, hovering: hovering, stageKey: stageKey))
    }
}

/// A card that opens something lifts under the pointer: brighter rim, a sheen, 2 % larger.
struct CardLift: ViewModifier {
    var on: Bool
    var radius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.of(radius), style: .continuous)
        content
            .overlay {
                if on {
                    shape
                        .fill(LinearGradient(colors: [Color.white.opacity(scheme == .dark ? 0.1 : 0.28), Color.white.opacity(0)],
                                             startPoint: .top, endPoint: .bottom))
                        .overlay(GlassRim(shape: shape, strength: 0.9))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .scaleEffect(on && !reduceMotion ? 1.02 : 1)
            .animation(Motion.lens(reduceMotion: reduceMotion), value: on)
    }
}
