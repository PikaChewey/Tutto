//
//  Components.swift
//  Tutto
//
//  The handful of pieces every surface is built from. Monochrome ink, hairlines,
//  monospaced numbers, and motion only when something actually changes.
//

import AppKit
import SwiftUI
import TuttoKit

// MARK: - Meters

/// A thin hairline track with an ink fill. `value` is 0…1.
struct Meter: View {
    var value: Double
    var height: CGFloat = 3
    /// Turns the fill to the alert color (only for real threshold events).
    var alert = false
    /// The fill when there's no alert (the menu bar panel uses the accent, like a native progress bar).
    var fill: Color = .ink
    var track: Color = .wash

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule()
                    .fill(alert ? Color.alert : fill)
                    .frame(width: max(height, geo.size.width * min(max(value, 0), 1)))
                    .opacity(value <= 0.001 ? 0 : 1)
            }
        }
        .frame(height: height)
        // Live values update without animation: on a glass panel every animated frame is
        // re-rendered on the CPU, and a 1 Hz value would keep it animating constantly.
        .accessibilityHidden(true)
    }
}

/// A one-pixel line of recent values with a faint wash underneath. Values are 0…1.
struct Sparkline: View {
    var values: [Double]
    var capacity = 60
    /// The line; its area is filled with a faint wash of the same colour.
    var color: Color = .primary
    /// A short history spans the whole width (the panel's tiles), instead of growing from the right.
    var stretch = false

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let step = size.width / CGFloat(max((stretch ? min(values.count, capacity) : capacity) - 1, 1))
            let start = size.width - step * CGFloat(values.count - 1)
            var line = Path()
            for (index, value) in values.enumerated() {
                let point = CGPoint(x: start + step * CGFloat(index),
                                    y: size.height - CGFloat(min(max(value, 0), 1)) * (size.height - 1) - 0.5)
                if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
            }
            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: start, y: size.height))
            fill.closeSubpath()
            context.fill(fill, with: .color(color == .primary ? .primary.opacity(0.06) : color.opacity(0.14)))
            context.stroke(line, with: .color(color == .primary ? .primary.opacity(0.85) : color), lineWidth: color == .primary ? 1 : 1.25)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Keycaps

/// A shortcut drawn as small engraved keycaps: ⌃ ⇧ V.
struct KeyCaps: View {
    var shortcut: KeyShortcut?
    var compact = false

    var body: some View {
        if let shortcut {
            HStack(spacing: 2) {
                ForEach(Array(shortcut.symbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.system(size: compact ? 9.5 : 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.ink2)
                        .frame(minWidth: compact ? 13 : 15, minHeight: compact ? 15 : 17)
                        .padding(.horizontal, symbol.count > 1 ? 3 : 0)
                        .background(RoundedRectangle(cornerRadius: Radius.of(3.5), style: .continuous).fill(Color.wash))
                        .overlay(RoundedRectangle(cornerRadius: Radius.of(3.5), style: .continuous).strokeBorder(Color.hairline))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(shortcut.spokenDescription)
        } else {
            Text("—")
                .font(.system(size: 11))
                .foregroundStyle(Color.ink4)
                .accessibilityLabel("No shortcut")
        }
    }
}

// MARK: - Layout pieces

/// A hairline rule.
struct Hairline: View {
    var vertical = false
    var body: some View {
        Rectangle()
            .fill(Color.hairline)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

/// Caption on the left, anything on the right. The standard settings row.
struct LabeledRow<Content: View>: View {
    var title: String
    var detail: String?
    @ViewBuilder var content: Content

    init(_ title: String, detail: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.ink)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .lineSpacing(2)
                        .foregroundStyle(Color.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            content
        }
        .padding(.vertical, Metrics.rowPadding)
        .frame(minHeight: 30)
        .accessibilityElement(children: .contain)
    }
}

/// Shared spacing for rows inside an `InkGroup`, so every list in the app breathes the same.
enum Metrics {
    /// Above and below each row's text, inside its separators (scaled by the theme's density).
    @MainActor static var rowPadding: CGFloat { (10 * ThemeStore.shared.tokens.densityScale).rounded() }
    /// Between a row's title and its one-line description.
    static let titleToDetail: CGFloat = 3
}

/// A key/value pair in a readout: small caption over a monospaced value.
struct Readout: View {
    var caption: String
    var value: String
    var unit: String?
    var large = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Caption(caption)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: large ? 22 : 15, weight: large ? .semibold : .medium).monospacedDigit())
                    .foregroundStyle(Color.ink)
                if let unit {
                    Text(unit)
                        .font(.system(size: large ? 12 : 11, weight: .medium))
                        .foregroundStyle(Color.ink3)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption)
        .accessibilityValue("\(value) \(unit ?? "")")
    }
}

/// A group of rows on a faint surface with hairline separators — the only "card" Tutto uses.
struct InkGroup<Content: View>: View {
    var title: String?
    var trailing: AnyView?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if title != nil || trailing != nil {
                HStack {
                    if let title { Caption(title) }
                    Spacer()
                    trailing
                }
                .padding(.horizontal, 2)
            }
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: Radius.of(10), style: .continuous).fill(Color.wash.opacity(0.7)))
            .overlay(RoundedRectangle(cornerRadius: Radius.of(10), style: .continuous).strokeBorder(Color.hairline))
        }
    }
}

/// Square icon button with a hover wash.
struct IconButton: View {
    var symbol: String
    var help: String
    var size: CGFloat = 26
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.48, weight: .medium))
                .foregroundStyle(hovering ? Color.ink : Color.ink2)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: Radius.of(6), style: .continuous).fill(hovering ? Color.wash : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Plain button that dips slightly while pressed.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // A card in the label brightens while pressed (CardLift reads it): the button's own press,
            // never a second gesture competing with its click.
            .environment(\.cardPressed, configuration.isPressed)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

/// Secondary action: hairline capsule.
struct OutlineButtonStyle: ButtonStyle {
    var compact = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11.5 : 12.5, weight: .medium))
            .foregroundStyle(Color.ink)
            .padding(.vertical, compact ? 4 : 7)
            .padding(.horizontal, compact ? 10 : 14)
            .background {
                if ThemeStore.liquid {
                    LiquidFill(shape: Capsule(), hovering: configuration.isPressed)
                } else {
                    Capsule().fill(configuration.isPressed ? Color.wash : Color.clear)
                }
            }
            .overlay(Capsule().strokeBorder(ThemeStore.liquid ? Color.clear : Color.ink4, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(Motion.press, value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

// MARK: - Status

/// ○ / ● status mark: hollow when something is missing, filled when it's working.
struct StatusDot: View {
    var on: Bool
    var body: some View {
        Circle()
            .strokeBorder(Color.ink, lineWidth: on ? 0 : 1.2)
            .background(Circle().fill(on ? Color.ink : .clear))
            .frame(width: 8, height: 8)
            .animation(Motion.micro, value: on)
            .accessibilityHidden(true)
    }
}

extension Color {
    /// The only non-ink color in Tutto's chrome, reserved for real problems
    /// (critical battery, heat, failures).
    @MainActor static var alert: Color { ThemeStore.shared.tokens.alert }
}

// MARK: - Entrance

/// The standard entrance: fades in from 96 % scale, 6 pt below, slightly blurred.
struct EntranceModifier: ViewModifier {
    var active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(active ? 0 : 1)
            .scaleEffect(active && !reduceMotion ? 0.96 : 1)
            .offset(y: active && !reduceMotion ? 6 : 0)
            .blur(radius: active && !reduceMotion ? 4 : 0)
    }
}

extension AnyTransition {
    static var entrance: AnyTransition {
        .modifier(active: EntranceModifier(active: true), identity: EntranceModifier(active: false))
    }
}

// MARK: - Formatting

enum Format {
    static func percent(_ fraction: Double, digits: Int = 0) -> String {
        String(format: "%.\(digits)f", min(max(fraction, 0), 9.99) * 100)
    }

    static func bytes(_ value: Int64, style: ByteCountFormatter.CountStyle = .memory) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: style)
    }

    static func bytes(_ value: UInt64, style: ByteCountFormatter.CountStyle = .memory) -> String {
        bytes(Int64(clamping: value), style: style)
    }

    /// "12.4 GB" split into ("12.4", "GB") for value + unit typography.
    static func bytesParts(_ value: Int64, style: ByteCountFormatter.CountStyle = .file) -> (String, String) {
        let text = ByteCountFormatter.string(fromByteCount: value, countStyle: style)
        let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
        return parts.count == 2 ? (parts[0], parts[1]) : (text, "")
    }

    /// Free space with at most three significant digits: "209 GB", "45.2 GB", "1.82 TB".
    static func diskParts(_ value: Int64) -> (String, String) {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var amount = Double(max(value, 0))
        var index = 0
        while amount >= 1000 && index < units.count - 1 {
            amount /= 1000
            index += 1
        }
        let text = amount >= 100 ? String(format: "%.0f", amount) : (amount >= 10 ? String(format: "%.1f", amount) : String(format: "%.2f", amount))
        return (text, units[index])
    }

    static func rate(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond else { return "—" }
        // ByteCountFormatter spells nothing as "Zero KB"; a rate reads better as a number.
        if bytesPerSecond < 1000 { return "\(Int(bytesPerSecond / 1000)) KB/s" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }

    /// "12.4 MB/s" split into ("12.4", "MB/s") for value + unit typography; "—" alone when unknown.
    static func rateParts(_ bytesPerSecond: Double?) -> (String, String) {
        let text = rate(bytesPerSecond)
        guard let space = text.firstIndex(of: " ") else { return (text, "") }
        return (String(text[..<space]), String(text[text.index(after: space)...]))
    }

    /// A rate as VoiceOver should say it: "12.4 MB per second", or "measuring" before the first reading.
    static func spokenRate(_ bytesPerSecond: Double?) -> String {
        bytesPerSecond == nil ? "measuring" : rate(bytesPerSecond).replacingOccurrences(of: "/s", with: " per second")
    }

    static func watts(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value >= 10 ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    static func number(_ value: Int) -> String { value.formatted() }

    static func minutes(_ value: Int?) -> String? {
        guard let value, value > 0, value < 60 * 48 else { return nil }
        return value >= 60 ? "\(value / 60) h \(value % 60) min" : "\(value) min"
    }

    static func temperature(_ celsius: Double?) -> String {
        guard let celsius else { return "—" }
        return String(format: "%.0f°", celsius)
    }
}

private struct CardPressedKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Inside a pressed `PressStyle` button.
    var cardPressed: Bool {
        get { self[CardPressedKey.self] }
        set { self[CardPressedKey.self] = newValue }
    }
}
