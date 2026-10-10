//
//  Theme.swift
//  Tutto (design system)
//
//  Monochrome. One ink (black in light mode, white in dark mode) at a few
//  opacities, hairlines instead of shadows, SF Pro with monospaced numbers.
//

import AppKit
import SwiftUI

// MARK: - Ink

extension Color {
    /// Text and marks. Black in light mode, white in dark mode.
    /// Opacities are tuned so secondary (ink2) and tertiary (ink3) text pass WCAG AA (4.5:1)
    /// even on the light menu material (about #ECECEC), not just on white.
    static let ink = Color.primary
    static let ink2 = Color.primary.opacity(0.84)
    static let ink3 = Color.primary.opacity(0.74)
    static let ink4 = Color.primary.opacity(0.30)
    static let hairline = Color.primary.opacity(0.12)
    static let wash = Color.primary.opacity(0.06)

    /// Ink that ignores the menu bar material's vibrancy, for solid fills (vibrant `.primary`
    /// renders large filled shapes as a dim gray on the glass panel).
    static let solidInk = Color(nsColor: NSColor(name: "solidInk") { appearance in
        appearance.isDark ? NSColor(white: 0.96, alpha: 1) : NSColor(white: 0.08, alpha: 1)
    })

    /// The opposite of ink, for marks drawn on top of solid ink.
    static let paper = Color(nsColor: NSColor(name: "paper") { appearance in
        appearance.isDark ? .black : .white
    })

    /// Opaque window background (welcome window). Off-black and off-white, never pure.
    static let canvas = Color(nsColor: NSColor(name: "canvas") { appearance in
        appearance.isDark ? NSColor(white: 0.04, alpha: 1) : NSColor(white: 0.98, alpha: 1)
    })

    /// The trackpad surface: a shade off the panel so it reads as an object.
    static let surface = Color(nsColor: NSColor(name: "surface") { appearance in
        appearance.isDark ? NSColor(white: 0.085, alpha: 1) : NSColor(white: 1, alpha: 1)
    })
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

// MARK: - Type

extension Font {
    static func mono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// Small uppercase monospaced label, like an engraving on an instrument.
struct Caption: View {
    var text: String
    var uppercase = true

    init(_ text: String, uppercase: Bool = true) {
        self.text = text
        self.uppercase = uppercase
    }

    var body: some View {
        Text(uppercase ? text.uppercased() : text)
            .font(.mono(10, weight: .medium))
            .tracking(uppercase ? 0.8 : 0)
            .foregroundStyle(Color.ink3)
    }
}

// MARK: - Motion

/// Motion tokens. Nothing exceeds 0.45 s; exits run about 0.7× their entrance.
/// Surfaces opened from the keyboard (palettes, capture overlay) appear with no animation at all.
enum Motion {
    /// Toggles, segmented pills, tool indicators.
    static let micro = Animation.spring(duration: 0.20, bounce: 0)
    /// Things appearing or changing state (toasts, panel content, handles settling).
    static let snappy = Animation.spring(duration: 0.28, bounce: 0.05)
    /// Larger moves: page changes, onboarding steps, sections expanding.
    static let smooth = Animation.spring(duration: 0.40, bounce: 0)
    /// Button press feedback.
    static let press = Animation.easeOut(duration: 0.12)

    /// The animation to use, or a short fade when Reduce Motion is on.
    static func adaptive(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : animation
    }
}

// MARK: - Controls

/// A small monochrome switch. Filled ink when on, hairline when off.
struct InkSwitch: View {
    @Binding var isOn: Bool
    var label: String
    /// Shown dimmed when it's on but not actually working (e.g. waiting for permission).
    var active = true

    var body: some View {
        Button {
            withAnimation(Motion.micro) { isOn.toggle() }
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Color.ink : Color.wash)
                    .overlay(Capsule().strokeBorder(isOn ? Color.clear : Color.ink4, lineWidth: 1))
                Circle()
                    .fill(isOn ? Color.paper : Color.ink3)
                    .padding(isOn ? 2.5 : 3.5)
            }
            .frame(width: 30, height: 17)
            .opacity(active ? 1 : 0.45)
            .padding(4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? (active ? "On" : "On, waiting") : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

/// Text-only segmented choice: the selected option sits on a solid ink pill.
struct InkSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    var options: [(value: Value, title: String)]
    var help: (Value) -> String = { _ in "" }
    /// Spoken names, when the visible titles are abbreviations.
    var spoken: (Value) -> String? = { _ in nil }
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button {
                    withAnimation(Motion.micro) { selection = option.value }
                } label: {
                    Text(option.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(selected ? Color.paper : Color.ink2)
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .background {
                            if selected {
                                Capsule().fill(Color.ink).matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(help(option.value))
                .accessibilityLabel(spoken(option.value) ?? option.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.wash))
        .overlay(Capsule().strokeBorder(Color.hairline, lineWidth: 1))
    }
}

/// − value + in a capsule. Click the number to type one; hold − or + to keep going.
struct InkStepper: View {
    var label: String
    var value: Int
    var range: ClosedRange<Int>
    var onChange: (Int) -> Void

    @State private var text = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: 0) {
            step("minus", by: -1)
            TextField(label, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Color.ink)
                .multilineTextAlignment(.center)
                .frame(width: 26)
                .focused($editing)
                .onSubmit(commit)
                .onChange(of: editing) { _, focused in if !focused { commit() } }
                .accessibilityLabel(label)
            step("plus", by: 1)
        }
        .frame(height: 24)
        .background(Capsule().fill(Color.wash))
        .overlay(Capsule().strokeBorder(editing ? Color.ink4 : Color.hairline, lineWidth: 1))
        .onAppear { text = "\(value)" }
        .onChange(of: value) { _, newValue in if !editing { text = "\(newValue)" } }
        .accessibilityElement(children: .combine)
        .accessibilityValue("\(value) millimetres")
        .accessibilityAdjustableAction { direction in
            set(value + (direction == .increment ? 1 : -1))
        }
    }

    private func step(_ symbol: String, by delta: Int) -> some View {
        Button {
            set(value + delta)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle((delta < 0 ? value > range.lowerBound : value < range.upperBound) ? Color.ink2 : Color.ink4)
                .frame(width: 20, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
        .accessibilityHidden(true)
    }

    private func set(_ newValue: Int) {
        let clamped = min(max(newValue, range.lowerBound), range.upperBound)
        text = "\(clamped)"
        if clamped != value { onChange(clamped) }
    }

    private func commit() {
        let digits = text.filter(\.isNumber)
        set(Int(digits) ?? value)
    }
}

/// Toggle written as a word with a tick box, e.g. "☑ Click".
struct InkCheck: View {
    var title: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(Motion.micro) { isOn.toggle() }
        } label: {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .fill(isOn ? Color.ink : Color.clear)
                    .overlay(RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .strokeBorder(isOn ? Color.clear : Color.ink4, lineWidth: 1))
                    .overlay {
                        Image(systemName: "checkmark")
                            .font(.system(size: 7.5, weight: .heavy))
                            .foregroundStyle(Color.paper)
                            .opacity(isOn ? 1 : 0)
                    }
                    .frame(width: 13, height: 13)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isOn ? Color.ink : Color.ink2)
            }
            .frame(minHeight: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

/// Primary action: solid ink capsule, paper text. `compact` for inline rows.
struct InkButtonStyle: ButtonStyle {
    var compact = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11.5 : 13, weight: .semibold))
            .foregroundStyle(Color.paper)
            .padding(.vertical, compact ? 4 : 10)
            .padding(.horizontal, compact ? 10 : 18)
            .background(Capsule().fill(Color.ink))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

extension View {
    func primaryButton() -> some View { buttonStyle(InkButtonStyle()) }
}

/// Quiet text button for footers.
struct QuietButton: View {
    var title: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(hovering ? Color.ink : Color.ink2)
                .padding(.horizontal, 6)
                .frame(minHeight: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Marks

/// The Trackpad Corner mark: a trackpad outline with its corner filled in.
struct CornerMark: View {
    var lit = true
    var size: CGFloat = 16

    var body: some View {
        let width = size
        let height = size * 0.66
        let radius = height * 0.24
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack(alignment: .bottomTrailing) {
            shape.strokeBorder(Color.ink, lineWidth: max(1.1, size / 13))
            Rectangle()
                .fill(lit ? Color.ink : Color.ink4)
                .frame(width: width * 0.46, height: height * 0.36)
        }
        .clipShape(shape)
        .frame(width: width, height: height)
        .accessibilityHidden(true)
    }
}

/// Template images for the menu bar (tinted by macOS for light and dark menu bars).
enum MenuBarGlyph {
    /// Tutto's mark: a rounded tile split into four, its bottom-right quarter filled —
    /// four tools in one, and the corner that Trackpad Corner made a right-click.
    static func image() -> NSImage {
        let size = NSSize(width: 18, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            let tile = NSRect(x: 1.5, y: 1, width: 15, height: 14)
            let outline = NSBezierPath(roundedRect: tile.insetBy(dx: 0.7, dy: 0.7), xRadius: 3.6, yRadius: 3.6)
            outline.lineWidth = 1.4
            NSColor.black.setStroke()
            outline.stroke()
            NSGraphicsContext.saveGraphicsState()
            outline.addClip()
            // Hairline cross dividing the tile into quarters.
            let cross = NSBezierPath()
            cross.move(to: NSPoint(x: tile.midX, y: tile.minY))
            cross.line(to: NSPoint(x: tile.midX, y: tile.maxY))
            cross.move(to: NSPoint(x: tile.minX, y: tile.midY))
            cross.line(to: NSPoint(x: tile.maxX, y: tile.midY))
            cross.lineWidth = 1
            NSColor.black.withAlphaComponent(0.55).setStroke()
            cross.stroke()
            NSColor.black.setFill()
            NSRect(x: tile.midX, y: tile.minY, width: tile.width / 2, height: tile.height / 2).fill()
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Tutto"
        return image
    }
}
