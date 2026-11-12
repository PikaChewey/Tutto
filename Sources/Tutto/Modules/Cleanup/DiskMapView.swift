//
//  DiskMapView.swift
//  Tutto
//
//  Clean Up › Disk map: Scan, then rings of what fills the disk (the folder in the middle, what's
//  inside it around, up to five levels out) beside a list of the biggest items. Hover a slice for
//  its name and size, click a folder to go into it, click the middle or the trail to go back up.
//  Drawn in one Canvas with no animation, so it costs nothing while you're only looking.
//

import AppKit
import SwiftUI
import TuttoKit

struct DiskMapView: View {
    @Bindable var map: DiskMapModel
    var fullDiskAccess: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch map.state {
            case .idle: start
            case .scanning: scanning
            case .ready: summary
            }
            if let note = map.lastResult {
                Text(note)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.ink2)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Radius.of(12), style: .continuous).fill(Color.wash))
            }
            if map.state != .idle, let focus = map.focus {
                if map.trail.count > 1 { trail }
                HStack(alignment: .top, spacing: 20) {
                    SunburstView(map: map, focus: focus)
                        .frame(width: 300, height: 300)
                    BiggestList(map: map, focus: focus)
                }
                .opacity(map.state == .scanning ? 0.5 : 1)
                .allowsHitTesting(map.state != .scanning)
            }
        }
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    @ViewBuilder
    private var scopePicker: some View {
        if fullDiskAccess {
            InkSegmented(selection: $map.scope, options: [(.home, "Home"), (.wholeDisk, "Whole disk")])
                .fixedSize()
                .help("What to map")
        }
    }

    private var start: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("See what's filling your disk. A scan only reads; a home folder takes a minute or so.")
                .font(.system(size: 12.5))
                .foregroundStyle(Color.ink2)
            HStack(spacing: 10) {
                Button("Scan") { map.scan(fullDiskAccess: fullDiskAccess) }
                    .buttonStyle(InkButtonStyle())
                    .keyboardShortcut(.defaultAction)
                scopePicker
            }
            if !fullDiskAccess {
                Text("To map the whole disk, allow Full Disk Access (\(Permission.fullDiskAccess.settingsPath)).")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.ink3)
            }
        }
    }

    private var scanning: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("\(map.scannedItems.formatted()) items · \(Self.bytes(map.scannedBytes))")
                .font(.system(size: 12.5).monospacedDigit())
                .foregroundStyle(Color.ink2)
            Spacer()
            Button("Cancel") { map.cancel() }
                .buttonStyle(OutlineButtonStyle(compact: true))
        }
        .padding(14)
        .background(Color.wash, in: RoundedRectangle(cornerRadius: Radius.of(12), style: .continuous))
    }

    private var summary: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let root = map.root {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.bytes(root.bytes))
                        .font(.figure(26, weight: .semibold))
                        .foregroundStyle(Color.ink)
                    Text(detail(root))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.ink3)
                }
            }
            Spacer()
            scopePicker
            Button("Scan Again") { map.scan(fullDiskAccess: fullDiskAccess) }
                .buttonStyle(OutlineButtonStyle(compact: true))
        }
    }

    private func detail(_ root: DiskNode) -> String {
        var text = "in \(root.items.formatted()) items · \(root.name) · \(String(format: "%.0f", max(map.seconds, 1))) s"
        if map.unreadable > 0 {
            text += " · \(map.unreadable.formatted()) couldn't be read"
            if !fullDiskAccess { text += " (Full Disk Access reaches them)" }
        }
        return text
    }

    /// Where you are, from the scanned folder down; each step goes back there.
    private var trail: some View {
        let steps = map.trail
        return HStack(spacing: 4) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, node in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.ink3)
                }
                let last = index == steps.count - 1
                Button(node.name) { map.show(node) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: last ? .semibold : .regular))
                    .foregroundStyle(last ? Color.ink : Color.ink2)
                    .lineLimit(1)
                    .disabled(last)
            }
        }
    }
}

// MARK: - The rings

private struct SunburstView: View {
    @Bindable var map: DiskMapModel
    let focus: DiskNode
    @State private var hovered: Int?
    @Environment(\.colorScheme) private var scheme

    private let side: CGFloat = 300

    private var geometry: SunburstGeometry {
        SunburstGeometry(side: side, rings: map.slices.map(\.depth).max() ?? 1)
    }

    var body: some View {
        let geometry = geometry
        let slices = map.slices
        let accent = Color.themeAccent
        let dark = scheme == .dark
        ZStack {
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                // Each slice is filled, then outlined by cutting a thin gap, so slices read apart
                // on any background.
                for (index, slice) in slices.enumerated() {
                    let path = Self.sector(slice, geometry, center)
                    let fill: Color
                    if index == hovered {
                        fill = accent
                    } else {
                        let tone = SunburstPalette.tone(branch: slice.branch, depth: slice.depth, merged: slice.isMerged || slice.node?.kind == .smaller, dark: dark)
                        fill = Color(hue: tone.hue, saturation: tone.saturation, brightness: tone.brightness)
                    }
                    context.fill(path, with: .color(fill))
                }
                context.blendMode = .destinationOut
                for slice in slices {
                    context.stroke(Self.sector(slice, geometry, center), with: .color(.black), lineWidth: 1)
                }
            }
            .compositingGroup()
            .accessibilityLabel("Map of \(focus.name)")

            centerLabel(geometry)
        }
        .contentShape(Circle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let point):
                let index = geometry.slice(atX: point.x - side / 2, y: point.y - side / 2, in: slices)
                if index != hovered { hovered = index }
            case .ended:
                if hovered != nil { hovered = nil }
            }
        }
        .onTapGesture(coordinateSpace: .local) { point in
            let dx = point.x - side / 2, dy = point.y - side / 2
            if geometry.ring(atDistance: (dx * dx + dy * dy).squareRoot()) == 0 {
                map.goUp()
            } else if let index = geometry.slice(atX: dx, y: dy, in: slices), let node = slices[index].node, node.canOpen {
                hovered = nil
                map.show(node)
            }
        }
        .onChange(of: focus.id) { hovered = nil }
    }

    private func centerLabel(_ geometry: SunburstGeometry) -> some View {
        let slice = hovered.flatMap { $0 < map.slices.count ? map.slices[$0] : nil }
        let name = slice.map(Self.name) ?? focus.name
        let bytes = slice?.bytes ?? focus.bytes
        let share = focus.bytes > 0 ? Double(bytes) / Double(focus.bytes) : 0
        return VStack(spacing: 2) {
            Text(name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.ink)
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(DiskMapView.bytes(bytes))
                .font(.figure(13))
                .foregroundStyle(Color.ink2)
            if slice != nil {
                Text(share.formatted(.percent.precision(.fractionLength(share < 0.1 ? 1 : 0))))
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(Color.ink3)
            } else if map.trail.count > 1 {
                Image(systemName: "arrow.up")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.ink3)
                    .help("Click the middle to go up")
            }
        }
        .frame(width: geometry.centerRadius * 1.7)
        .allowsHitTesting(false)
    }

    static func name(_ slice: SunburstSlice<DiskNode>) -> String {
        guard let node = slice.node else { return "\(slice.count.formatted()) smaller items" }
        return node.kind == .smaller ? "Smaller items" : node.name
    }

    static func sector(_ slice: SunburstSlice<DiskNode>, _ geometry: SunburstGeometry, _ center: CGPoint) -> Path {
        let start = Angle(radians: slice.start - .pi / 2)
        let end = Angle(radians: slice.end - .pi / 2)
        var path = Path()
        path.addArc(center: center, radius: geometry.outer(slice.depth), startAngle: start, endAngle: end, clockwise: false)
        path.addArc(center: center, radius: geometry.inner(slice.depth), startAngle: end, endAngle: start, clockwise: true)
        path.closeSubpath()
        return path
    }
}

// MARK: - The biggest items

private struct BiggestList: View {
    @Bindable var map: DiskMapModel
    let focus: DiskNode

    private static let shown = 12

    var body: some View {
        let items = Array(focus.children.prefix(Self.shown))
        let largest = max(items.map(\.bytes).max() ?? 1, 1)
        InkGroup("Biggest in \(focus.name)") {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, node in
                if index > 0 { Hairline().opacity(0.5) }
                BiggestRow(map: map, node: node, share: Double(node.bytes) / Double(largest))
            }
            if focus.children.count > Self.shown {
                Hairline().opacity(0.5)
                Text("\(focus.children.count - Self.shown) more, smaller")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ink3)
                    .padding(.vertical, 8)
            }
            if items.isEmpty {
                Text("Nothing inside")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.ink3)
                    .padding(.vertical, 10)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct BiggestRow: View {
    @Bindable var map: DiskMapModel
    let node: DiskNode
    let share: Double
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            icon
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(node.kind == .smaller ? "Smaller items" : node.name)
                        .font(.system(size: 12.5))
                        .foregroundStyle(node.kind == .smaller ? Color.ink2 : Color.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if node.canOpen {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(Color.ink3)
                    }
                    Spacer(minLength: 6)
                    Text(DiskMapView.bytes(node.bytes))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(Color.ink2)
                }
                GeometryReader { proxy in
                    Capsule().fill(Color.ink4.opacity(0.35))
                        .overlay(alignment: .leading) {
                            Capsule().fill(Color.ink3).frame(width: max(proxy.size.width * share, 2))
                        }
                }
                .frame(height: 3)
            }
            .contentShape(Rectangle())
            .onTapGesture { if node.canOpen { map.show(node) } }
            if node.kind != .smaller {
                actions
            } else {
                Color.clear.frame(width: 48, height: 22)
            }
        }
        .padding(.vertical, 7)
        .onHover { hovering = $0 }
        .help(node.kind == .smaller ? "\(node.items.formatted()) items, each too small to show" : node.path)
    }

    @ViewBuilder
    private var icon: some View {
        if node.kind == .smaller {
            Image(systemName: "square.stack")
                .font(.system(size: 12))
                .foregroundStyle(Color.ink3)
                .frame(width: 20, height: 20)
        } else {
            Image(nsImage: NSWorkspace.shared.icon(forFile: node.path))
                .resizable()
                .frame(width: 20, height: 20)
        }
    }

    private var actions: some View {
        let refusal = map.refusal(node)
        return HStack(spacing: 2) {
            IconButton(symbol: "magnifyingglass", help: "Show in Finder", size: 22) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)])
            }
            IconButton(symbol: "trash", help: refusal.map { "Stays: \($0.sentence)" } ?? "Move to Trash…", size: 22) {
                map.moveToTrash(node)
            }
            .disabled(refusal != nil)
            .opacity(refusal != nil ? 0.35 : 1)
        }
        .opacity(hovering ? 1 : 0.75)
    }
}
