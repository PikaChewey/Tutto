//
//  ToastStudies.swift
//  Tutto
//
//  Debug-only: notification designs to choose from (Bryan, 2026-11-21: the all-caps toast "doesn't
//  fit the typography and UI/UX of tutto ... doesn't fit the aesthetic of the menu bar (liquid
//  glass)"). Today's toast next to four glass ones, each with the real messages: a screenshot
//  copied, an agent finished, an agent that needs you, text copied. Drawn on the glass stage
//  (`--snapshot DIR glass-stage toast-studies behind:<image>`); nothing here ships.
//

#if DEBUG
import AppKit
import SwiftUI

struct ToastSample: Identifiable {
    var id: String { title }
    var title: String
    var detail: String
    var image: NSImage?
    var symbol: String?
    var action: String?
    var urgent = false

    @MainActor static var all: [ToastSample] {
        let shot = NSImage(contentsOfFile: CommandLine.arguments.first { $0.hasPrefix("toast-shot:") }.map { String($0.dropFirst(11)) } ?? "")
        let claude = NSWorkspace.shared.icon(forFile: "/Applications/Claude.app")
        return [
            ToastSample(title: "Copied", detail: "1440 × 900", image: shot, action: "Edit"),
            ToastSample(title: "Claude finished", detail: "Fix the flaky upload test", image: claude, action: "Open"),
            ToastSample(title: "Claude needs you", detail: "Plus One sound effects · wants to run a command", image: claude, action: "Open", urgent: true),
            ToastSample(title: "Copied as plain text", detail: "Press ⌘V to paste", symbol: "doc.on.clipboard"),
        ]
    }
}

/// The picture or symbol on the left of a notification.
private struct ToastArt: View {
    var sample: ToastSample
    var size: CGFloat
    var radius: CGFloat

    var body: some View {
        if let image = sample.image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: sample.symbol == nil && sample.action == "Edit" ? .fill : .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else if let symbol = sample.symbol {
            Image(systemName: symbol)
                .font(.system(size: size * 0.5, weight: .medium))
                .foregroundStyle(Color.ink2)
                .frame(width: size, height: size)
        }
    }
}

/// A · Glass pill: one capsule of glass, the picture, the title in the panel's title weight, the detail.
struct ToastPill: View {
    var sample: ToastSample

    var body: some View {
        HStack(spacing: 10) {
            ToastArt(sample: sample, size: 28, radius: 7)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    if sample.urgent { Circle().fill(Color.themeAccent).frame(width: 6, height: 6) }
                    Text(sample.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.ink)
                }
                Text(sample.detail).font(.system(size: 11.5)).foregroundStyle(Color.ink2).lineLimit(1)
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, 18)
        .padding(.vertical, 8)
        .prototypeGlass(Capsule())
        .overlay(GlassRim(shape: Capsule(), strength: 0.7))
    }
}

/// B · Notification: a glass card like macOS's own banners, Tutto's name and "now" above the title,
/// the action on the right.
struct ToastBanner: View {
    var sample: ToastSample

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        HStack(alignment: .center, spacing: 11) {
            ToastArt(sample: sample, size: 36, radius: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(sample.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(sample.urgent ? Color.themeAccent : Color.ink)
                Text(sample.detail).font(.system(size: 12)).foregroundStyle(Color.ink2).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let action = sample.action {
                Text(action)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.ink)
                    .padding(.horizontal, 11).padding(.vertical, 5)
                    .background(Capsule().fill(Color.ink.opacity(0.08)))
            }
        }
        .padding(11)
        .frame(width: 320)
        .prototypeGlass(shape)
        .overlay(GlassRim(shape: shape, strength: 0.7))
    }
}

/// C · HUD: a square of glass in the middle of the screen, like macOS's volume and brightness.
struct ToastHUD: View {
    var sample: ToastSample

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        VStack(spacing: 7) {
            ToastArt(sample: sample, size: 52, radius: 11)
            VStack(spacing: 1) {
                Text(sample.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(sample.urgent ? Color.themeAccent : Color.ink)
                Text(sample.detail).font(.system(size: 11)).foregroundStyle(Color.ink2).lineLimit(2).multilineTextAlignment(.center)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 12)
        .frame(width: 168)
        .prototypeGlass(shape)
        .overlay(GlassRim(shape: shape, strength: 0.7))
    }
}

/// D · From the menu bar: a slim line of glass that drops from under Tutto's icon, one line of text.
struct ToastDrop: View {
    var sample: ToastSample

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: MenuBarGlyph.image())
                .renderingMode(.template)
                .foregroundStyle(Color.ink2)
                .frame(height: 22)
            HStack(spacing: 7) {
                ToastArt(sample: sample, size: 18, radius: 4)
                Text(sample.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(sample.urgent ? Color.themeAccent : Color.ink)
                Text(sample.detail).font(.system(size: 12)).foregroundStyle(Color.ink2).lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: 330)
            .fixedSize()
            .prototypeGlass(Capsule())
            .overlay(GlassRim(shape: Capsule(), strength: 0.7))
            .padding(.top, 4)
        }
    }
}

/// Every design, a row each, with the four messages across.
struct ToastStudyBoard: View {
    var body: some View {
        let samples = ToastSample.all
        VStack(alignment: .leading, spacing: 18) {
            row("Today") {
                ForEach(samples) { sample in
                    ToastView(content: Toast.Content(title: sample.title, detail: sample.detail, image: sample.image)) {}
                        .fixedSize()
                }
            }
            row("A · Glass pill") { ForEach(samples) { ToastPill(sample: $0).fixedSize() } }
            row("B · Notification") { ForEach(samples) { ToastBanner(sample: $0) } }
            row("C · HUD") { ForEach(samples) { ToastHUD(sample: $0) } }
            row("D · From the menu bar") { ForEach(samples) { ToastDrop(sample: $0) } }
        }
        .padding(24)
    }

    private func row<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(.black.opacity(0.55)))
            HStack(alignment: .top, spacing: 16) { content() }
        }
    }
}
#endif
