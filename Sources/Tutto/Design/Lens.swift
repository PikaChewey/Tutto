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

/// A card under the pointer, lit the way Liquid Glass is (WWDC25 "Meet Liquid Glass": highlights
/// "respond to geometry and motion", and the material "illuminates from within" where you touch,
/// the glow spreading from under the finger; "Design hover interactions for visionOS": a highlight,
/// not a scale, on views people use often; RealityKit's spotlight hover "tracks the hover location").
/// Bryan, 2026-11-21: the lift "doesn't feel like apple", it shouldn't enlarge, and the light sat in
/// the same place every time. So: nothing grows; a soft light sits under the pointer and follows it
/// on a critically damped spring (it trails a touch, never wobbles, and keeps its speed when you
/// change direction); the rim catches that light on the edge nearest the pointer; a press brightens
/// the light and spreads it across the card, then it settles. It fades in quickly and out slowly,
/// left where the pointer last was. Reduce Motion: the light stays still, from above.
struct CardLift: ViewModifier {
    var on: Bool
    var radius: CGFloat
    @State private var point: CGPoint?
    @State private var pressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    /// The light trailing the pointer: quick, no overshoot.
    private static let follow = Animation.spring(response: 0.22, dampingFraction: 1)

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.of(radius), style: .continuous)
        let dark = scheme == .dark
        // Under the content, over the card's surface (apply it before `.background(CardSurface…)`):
        // the light never washes over the text.
        content
            .background {
                GeometryReader { geo in
                    let size = geo.size
                    let at = reduceMotion || point == nil ? CGPoint(x: size.width / 2, y: point == nil ? 0 : size.height * 0.2) : point!
                    let reach = max(size.width, size.height) * (pressed ? 2.2 : 1.5)
                    ZStack {
                        // The light itself: feathered, faint, brighter while pressed.
                        Circle()
                            .fill(RadialGradient(colors: [Color.white.opacity((dark ? 0.12 : 0.55) * (pressed ? 1.6 : 1)), Color.white.opacity(0)],
                                                 center: .center, startRadius: 0, endRadius: reach / 2))
                            .frame(width: reach, height: reach)
                            .position(at)
                        // The rim, lit only where the light reaches it.
                        shape.strokeBorder(Color.white.opacity(dark ? 0.5 : 0.95), lineWidth: 1)
                            .mask {
                                Circle()
                                    .fill(RadialGradient(colors: [.white, .white.opacity(0.08)], center: .center, startRadius: 0, endRadius: reach * 0.42))
                                    .frame(width: reach, height: reach)
                                    .position(at)
                            }
                    }
                    .clipShape(shape)
                    .blendMode(dark ? .plusLighter : .normal)
                }
                .opacity(on ? 1 : 0)
                .allowsHitTesting(false)
            }
            .onContinuousHover(coordinateSpace: .local) { phase in
                guard case .active(let location) = phase else { return }
                if point == nil || reduceMotion { point = location } else { withAnimation(Self.follow) { point = location } }
            }
            .simultaneousGesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !pressed { withAnimation(.easeOut(duration: 0.12)) { pressed = true } } }
                .onEnded { _ in withAnimation(.easeOut(duration: 0.45)) { pressed = false } })
            .animation(on ? .easeOut(duration: 0.15) : .easeOut(duration: 0.4), value: on)
    }
}
