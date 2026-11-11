//
//  TrackpadView.swift
//  Tutto
//
//  A live, to-scale mirror of your trackpad, drawn like an instrument:
//  a faint dot grid, a hatched right-click zone, and your fingers as dots.
//  Every right-click floods the zone with ink for a moment.
//

import SwiftUI
import TuttoKit

struct TrackpadView: View {
    var contacts: [Contact]
    @Binding var zone: CornerZone
    var size: TrackpadSize = .macBookPro14
    var pulse: Int = 0
    var editable = true
    var dimmed = false
    var demo = false
    /// Hold the zone in its "just right-clicked" state (inverted).
    var lit = false
    /// Called when the user resizes the zone by dragging its edges.
    var onResize: (() -> Void)?

    @State private var flash = 0.0
    @State private var ring: CGFloat = 1
    @State private var ringAt = CGPoint(x: 0.85, y: 0.12)
    @State private var lastCornerTouch: CGPoint?
    @State private var dragging = false

    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveringOtherCorner = false

    /// One physical pixel.
    private var hairline: CGFloat { 1 / max(displayScale, 1) }

    var body: some View {
        // A clear box with the trackpad's aspect ratio gives the drawing a real height
        // in any container; the drawing itself lives in an overlay of that box.
        Color.clear
            .aspectRatio(size.width / size.height, contentMode: .fit)
            .overlay(drawing)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Right-click zone")
            .accessibilityValue("\(zone.clamped.corner == .bottomRight ? "Bottom right" : "Bottom left"), \(Int(zoneMillimetres.width.rounded())) by \(Int(zoneMillimetres.height.rounded())) millimetres")
            .accessibilityAdjustableAction { direction in
                guard editable, !demo else { return }
                let presets = ZonePreset.allCases
                let current = ZonePreset.matching(zone, on: size).flatMap { presets.firstIndex(of: $0) } ?? 1
                let next = direction == .increment ? min(current + 1, presets.count - 1) : max(current - 1, 0)
                zone = presets[next].zone(corner: zone.corner, on: size)
            }
            .accessibilityAction(named: "Switch corner") { if editable && !demo { switchCorner() } }
    }

    private var drawing: some View {
        GeometryReader { geo in
            let bounds = geo.size
            let radius = min(bounds.width, bounds.height) * 0.1
            let pad = RoundedRectangle(cornerRadius: radius, style: .continuous)
            let rect = zoneRect(in: bounds)

            ZStack(alignment: .topLeading) {
                pad.fill(Color.surface)
                DotGrid(pitch: bounds.width / size.width * 5).allowsHitTesting(false)
                Ruler(millimetre: bounds.width / size.width).allowsHitTesting(false)

                if hoveringOtherCorner && editable && !demo {
                    // Preview of where the zone would go.
                    Hatch().opacity(0.12)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: bounds.width - rect.maxX, y: rect.minY)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                zoneLayer(rect: rect)

                Circle()
                    .strokeBorder(Color.ink, lineWidth: 1.5)
                    .frame(width: 22, height: 22)
                    .scaleEffect(0.6 + ring * 2.2)
                    .opacity(Double(1 - ring) * 0.8)
                    .position(x: ringAt.x * bounds.width, y: (1 - ringAt.y) * bounds.height)

                if demo {
                    DemoFinger(bounds: bounds, zone: zone.clamped, animated: !reduceMotion)
                } else {
                    ForEach(contacts, id: \.id) { contact in
                        FingerDot(hot: zone.contains(x: contact.x, y: contact.y))
                            .colorInvert(lit && zone.contains(x: contact.x, y: contact.y))
                            .position(x: contact.x * bounds.width, y: (1 - contact.y) * bounds.height)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
            }
            .clipShape(pad)
            .overlay(pad.strokeBorder(Color.ink.opacity(0.16), lineWidth: hairline))
            .contentShape(pad)
            .onContinuousHover(coordinateSpace: .local) { phase in
                // The whole drawing is the handle, so the cursor is a crosshair anywhere on it.
                // `set()` (not push/pop) can never leave the cursor stuck if the panel closes.
                guard editable, !demo else { return }
                let over: Bool
                if case .active(let location) = phase {
                    over = otherCornerRect(rect: rect, bounds: bounds).contains(location)
                    (over ? NSCursor.pointingHand : NSCursor.crosshair).set()
                } else {
                    over = false
                    NSCursor.arrow.set()
                }
                if over != hoveringOtherCorner { withAnimation(.easeOut(duration: 0.15)) { hoveringOtherCorner = over } }
            }
            .gesture(
                // Press anywhere and drag: the zone's inner corner follows the pointer.
                DragGesture(minimumDistance: 2, coordinateSpace: .local)
                    .onChanged { value in
                        guard editable, !demo else { return }
                        if !dragging {
                            withAnimation(Motion.snappy) {
                                dragging = true
                                hoveringOtherCorner = false
                            }
                        }
                        resize(to: value.location, bounds: bounds)
                    }
                    .onEnded { _ in
                        withAnimation(Motion.snappy) { dragging = false }
                        onResize?()  // after the drag, so nothing re-lays out under the pointer
                    }
            )
            .onTapGesture(coordinateSpace: .local) { location in
                // A plain click on the opposite bottom corner moves the zone there.
                guard editable, !demo, otherCornerRect(rect: rect, bounds: bounds).contains(location) else { return }
                switchCorner()
            }
            .help(editable && !demo ? "Drag anywhere to size the corner. Click the other corner to switch sides." : "")
            .opacity(dimmed ? 0.45 : 1)
            .animation(.easeOut(duration: 0.14), value: contacts.count)
            .animation(Motion.snappy, value: lit)
            .onChange(of: contacts) { _, newValue in
                if let hot = newValue.first(where: { zone.contains(x: $0.x, y: $0.y) }) {
                    lastCornerTouch = CGPoint(x: hot.x, y: hot.y)
                }
            }
            .onChange(of: pulse) { _, _ in firePulse() }
        }
    }

    private func otherCornerRect(rect: CGRect, bounds: CGSize) -> CGRect {
        CGRect(x: bounds.width - rect.maxX, y: rect.minY, width: rect.width, height: rect.height)
    }

    private func switchCorner() {
        let corner: Corner = zone.corner == .bottomRight ? .bottomLeft : .bottomRight
        withAnimation(Motion.smooth) {
            zone.corner = corner
            hoveringOtherCorner = false
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    private var zoneMillimetres: (width: Double, height: Double) {
        let z = zone.clamped
        return (z.width * size.width, z.height * size.height)
    }

    // MARK: Layers

    private func zoneLayer(rect: CGRect) -> some View {
        let flooded = lit || flash > 0.02
        return ZStack(alignment: zone.clamped.corner == .bottomRight ? .topLeading : .topTrailing) {
            // At rest: hatching and a hairline on the two inner edges.
            // On a right-click: a clean flood of ink, nothing showing through.
            Hatch().opacity(flooded ? 0 : (dragging ? 0.5 : 0.28))
            Rectangle().fill(Color.ink.opacity(lit ? 1 : flash))
            InnerEdges(corner: zone.clamped.corner)
                .stroke(Color.ink.opacity(flooded ? 0 : (dragging ? 0.95 : 0.55)),
                        lineWidth: dragging ? 1.5 : hairline)
            if !flooded && dragging {
                CornerBracket(corner: zone.clamped.corner)
                    .stroke(Color.ink, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .transition(.opacity)
            }
            Text(dragging ? "\(Int(zoneMillimetres.width.rounded())) × \(Int(zoneMillimetres.height.rounded())) mm" : "RIGHT-CLICK")
                .font(.geist(9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(lit ? Color.paper : Color.ink)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(lit ? Color.clear : Color.surface.opacity(0.9), in: Capsule())
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .lineLimit(1)
                .fixedSize()
                .opacity(demo || (!dragging && (rect.width < 96 || rect.height < 30)) ? 0 : 1)
        }
        .frame(width: rect.width, height: rect.height)
        .offset(x: rect.minX, y: rect.minY)
    }

    /// Sets the zone's inner corner to the pointer, in whole millimetres.
    private func resize(to location: CGPoint, bounds: CGSize) {
        let corner = zone.clamped.corner
        let x = min(max(location.x, 0), bounds.width) / bounds.width
        let y = min(max(location.y, 0), bounds.height) / bounds.height
        let widthMM = ((corner == .bottomRight ? 1 - x : x) * size.width).rounded()
        let heightMM = ((1 - y) * size.height).rounded()
        let resized = CornerZone(corner: corner, width: widthMM / size.width, height: heightMM / size.height).clamped
        guard resized != zone else { return }
        let wasAtLimit = isAtLimit(zone)
        zone = resized
        if isAtLimit(resized) && !wasAtLimit {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    private func isAtLimit(_ zone: CornerZone) -> Bool {
        let z = zone.clamped
        return [z.width, z.height].contains { $0 <= CornerZone.minimumSize + 0.001 || $0 >= CornerZone.maximumSize - 0.001 }
    }

    // MARK: Geometry & effects

    private func zoneRect(in bounds: CGSize) -> CGRect {
        let z = zone.clamped
        let width = z.width * bounds.width
        let height = z.height * bounds.height
        let x = z.corner == .bottomRight ? bounds.width - width : 0
        return CGRect(x: x, y: bounds.height - height, width: width, height: height)
    }

    private func firePulse() {
        let z = zone.clamped
        ringAt = lastCornerTouch ?? CGPoint(x: z.corner == .bottomRight ? 1 - z.width / 2 : z.width / 2,
                                            y: z.height / 2)
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            ring = 0
            flash = 0.85
        }
        if reduceMotion {
            ring = 1  // no expanding ring; the flash alone confirms it
        } else {
            withAnimation(.easeOut(duration: 0.5)) { ring = 1 }
        }
        withAnimation(.easeOut(duration: 0.24).delay(0.12)) { flash = 0 }
    }
}

// MARK: - Pieces

/// Faint dot grid, one dot every 5 mm of real trackpad.
private struct DotGrid: View {
    var pitch: CGFloat

    var body: some View {
        Canvas { context, size in
            guard pitch > 3 else { return }
            var x = pitch
            while x < size.width {
                var y = size.height - pitch
                while y > 0 {
                    context.fill(Path(ellipseIn: CGRect(x: x - 0.6, y: y - 0.6, width: 1.2, height: 1.2)),
                                 with: .color(.primary.opacity(0.1)))
                    y -= pitch
                }
                x += pitch
            }
        }
    }
}

/// Ruler ticks every 10 mm along the bottom and right edges, longer every 50 mm.
private struct Ruler: View {
    var millimetre: CGFloat

    var body: some View {
        Canvas { context, size in
            guard millimetre > 0.5 else { return }
            var path = Path()
            var mm = 10
            while CGFloat(mm) * millimetre < size.width - 4 {
                let x = CGFloat(mm) * millimetre
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x, y: size.height - (mm % 50 == 0 ? 6 : 3)))
                mm += 10
            }
            mm = 10
            while CGFloat(mm) * millimetre < size.height - 4 {
                let y = size.height - CGFloat(mm) * millimetre
                path.move(to: CGPoint(x: size.width, y: y))
                path.addLine(to: CGPoint(x: size.width - (mm % 50 == 0 ? 6 : 3), y: y))
                mm += 10
            }
            context.stroke(path, with: .color(.primary.opacity(0.22)), lineWidth: 1)
        }
    }
}

/// A short L at the zone's inner corner, drawn while you're about to resize it.
private struct CornerBracket: Shape {
    var corner: Corner

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let arm: CGFloat = 9
        if corner == .bottomRight {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + arm))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX + arm, y: rect.minY))
        } else {
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY + arm))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - arm, y: rect.minY))
        }
        return path
    }
}

/// The two edges of the zone that face into the trackpad (the others are the trackpad's own edge).
private struct InnerEdges: Shape {
    var corner: Corner

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let inset: CGFloat = 0.25
        if corner == .bottomRight {
            path.move(to: CGPoint(x: rect.minX + inset, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + inset, y: rect.minY + inset))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + inset))
        } else {
            path.move(to: CGPoint(x: rect.maxX - inset, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.minY + inset))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + inset))
        }
        return path
    }
}

/// Diagonal hairline hatching for the right-click zone.
private struct Hatch: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            let step: CGFloat = 5
            var offset: CGFloat = -size.height
            while offset < size.width {
                path.move(to: CGPoint(x: offset, y: size.height))
                path.addLine(to: CGPoint(x: offset + size.height, y: 0))
                offset += step
            }
            context.stroke(path, with: .color(.primary), lineWidth: 0.6)
        }
        .clipped()
    }
}

struct FingerDot: View {
    var hot: Bool

    var body: some View {
        ZStack {
            Circle().fill(Color.ink)
            Circle().strokeBorder(Color.surface, lineWidth: 2)
            if hot {
                Circle().strokeBorder(Color.ink.opacity(0.35), lineWidth: 1).padding(-4)
            }
        }
        .frame(width: 16, height: 16)
        .animation(Motion.snappy, value: hot)
    }
}

// MARK: - Welcome demo

/// A looping, scripted finger that presses the corner and pops a context menu.
private struct DemoFinger: View {
    var bounds: CGSize
    var zone: CornerZone
    var animated = true

    enum Phase: CaseIterable { case away, approach, press, menu, linger }

    var body: some View {
        let target = CGPoint(
            x: (zone.corner == .bottomRight ? 1 - zone.width / 2 : zone.width / 2) * bounds.width,
            y: (1 - zone.height / 2) * bounds.height
        )
        let start = CGPoint(x: bounds.width * 0.4, y: bounds.height * 0.4)

        if animated {
            PhaseAnimator(Phase.allCases) { phase in
                frame(phase, target: target, start: start)
            } animation: { phase in
                switch phase {
                case .away: .easeOut(duration: 0.4)
                case .approach: .spring(response: 0.7, dampingFraction: 0.85)
                case .press: .easeOut(duration: 0.1)
                case .menu: .spring(response: 0.3, dampingFraction: 0.82)
                case .linger: .linear(duration: 1.3)
                }
            }
        } else {
            frame(.menu, target: target, start: start)  // Reduce Motion: one still frame
        }
    }

    private func frame(_ phase: Phase, target: CGPoint, start: CGPoint) -> some View {
        let pressed = phase == .press || phase == .menu
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.ink.opacity(pressed ? 1 : 0))
                .frame(width: zone.width * bounds.width, height: zone.height * bounds.height)
                .offset(x: zone.corner == .bottomRight ? bounds.width * (1 - zone.width) : 0,
                        y: bounds.height * (1 - zone.height))

            FingerDot(hot: pressed)
                .colorInvert(pressed)
                .scaleEffect(phase == .press ? 0.8 : 1)
                .opacity(phase == .away ? 0 : 1)
                .position(phase == .away ? start : target)

            MiniContextMenu()
                .scaleEffect(phase == .menu || phase == .linger ? 1 : 0.94, anchor: .bottomTrailing)
                .opacity(phase == .menu || phase == .linger ? 1 : 0)
                .position(x: target.x - 58, y: target.y - 52)
        }
    }
}

extension View {
    @ViewBuilder
    func colorInvert(_ on: Bool) -> some View {
        if on { self.colorInvert() } else { self }
    }
}

struct MiniContextMenu: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(["Open", "Get Info", "Rename", "Copy"], id: \.self) { item in
                let selected = item == "Get Info"
                Text(item)
                    .font(.system(size: 9.5))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(selected ? Color.ink : .clear, in: RoundedRectangle(cornerRadius: Radius.of(4), style: .continuous))
                    .foregroundStyle(selected ? Color.paper : Color.ink)
            }
        }
        .padding(4)
        .frame(width: 96)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.of(7), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.of(7), style: .continuous).strokeBorder(Color.hairline))
    }
}
