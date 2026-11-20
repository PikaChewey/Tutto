//
//  ThinScrollArea.swift
//  Tutto
//
//  The panel's scrolling (Bryan, 2026-11-13: the scroll bar "is very fat and takes up a lot of the
//  UI ... covers over some stuff. Make it like right next to the border of the outer frame, and
//  make it like way thinner ... [wider] when you hover over it"). The system's scroller sat on the
//  cards' right edge, 11 pt wide over their numbers. This one runs in the panel's margin, along the
//  frame: a 3 pt line while you scroll (and once when the panel opens, to say it scrolls), 7 pt
//  under the pointer, which drags it or clicks the lane to jump. Content fades into the header and
//  footer only on the side there's more of it. Nothing runs while it's still: one delayed fade.
//

import SwiftUI

enum ThinScrollStage {
    /// Snapshots: the line drawn (`scroll-line`), wide as under the pointer (`scroll-wide`), the
    /// content scrolled halfway (`scroll-mid`).
    nonisolated(unsafe) static var shown = false
    nonisolated(unsafe) static var wide = false
    nonisolated(unsafe) static var middle = false
    /// Snapshots: the cards' height limit (`scroll-limit:<pt>`), so a render scrolls.
    nonisolated(unsafe) static var limit: CGFloat?
}

struct ThinScrollArea<Content: View>: View {
    /// The lane's width, right of the scroll view's edge (the panel's margin, to the frame).
    var lane: CGFloat
    /// From the frame's edge to the line.
    var edgeInset: CGFloat = 3
    /// Content fades out at an edge that has more beyond it.
    var fadesEdges = true
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 15, *) {
            ThinScrollView(lane: lane, edgeInset: edgeInset, fadesEdges: fadesEdges) { content }
        } else {
            ScrollView(.vertical) { content }
                .scrollIndicators(.never)
        }
    }
}

/// Where the content is: how far it's scrolled, how tall it is, how much shows.
private struct ScrollMetrics: Equatable {
    var offset: CGFloat = 0
    var content: CGFloat = 0
    var visible: CGFloat = 0

    var maxOffset: CGFloat { max(content - visible, 0) }
    var overflows: Bool { maxOffset > 1 }
    var progress: CGFloat { maxOffset > 0 ? min(max(offset / maxOffset, 0), 1) : 0 }
}

@available(macOS 15, *)
private struct ThinScrollView<Content: View>: View {
    var lane: CGFloat
    var edgeInset: CGFloat
    var fadesEdges: Bool
    @ViewBuilder var content: Content

    @State private var position = ScrollPosition(edge: .top)
    @State private var metrics = ScrollMetrics()
    @State private var scrolling = false
    @State private var hovering = false
    @State private var dragging = false
    @State private var dragStart: CGFloat?
    @State private var settle: DispatchWorkItem?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static var fade: CGFloat { 14 }

    var body: some View {
        // `.never`, not `.hidden`: with a mouse connected (or "Show scroll bars: Always") macOS keeps
        // its legacy scroller under `.hidden`, a fat bar over the cards that also takes 15 pt of
        // width and pushed the whole panel against the frame's left edge (Bryan, 2026-11-20).
        ScrollView(.vertical) { content }
            .scrollIndicators(.never)
            .scrollPosition($position)
            .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
                ScrollMetrics(offset: geometry.contentOffset.y + geometry.contentInsets.top,
                              content: geometry.contentSize.height, visible: geometry.containerSize.height)
            } action: { old, new in
                metrics = new
                if abs(old.offset - new.offset) > 0.5, old.content > 0 { wake() }
                // The first time it's measured and it overflows: show the line once, so it reads as scrolling.
                if old.content == 0, new.overflows {
                    wake(for: 1.2)
                    if ThinScrollStage.middle { DispatchQueue.main.async { position.scrollTo(y: new.maxOffset / 2) } }
                }
            }
            .mask { if fadesEdges { edgeMask } else { Rectangle() } }
            .overlay(alignment: .topTrailing) {
                if metrics.overflows {
                    laneView
                        .frame(width: lane)
                        .offset(x: lane)
                }
            }
    }

    // MARK: The fades

    private var edgeMask: some View {
        let top = metrics.offset > 1 ? Self.fade : 0
        let bottom = metrics.offset < metrics.maxOffset - 1 ? Self.fade : 0
        return VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom).frame(height: top)
            Rectangle()
            LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom).frame(height: bottom)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: top)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: bottom)
    }

    // MARK: The line

    private var shown: Bool { scrolling || hovering || dragging || ThinScrollStage.shown }
    private var wide: Bool { hovering || dragging || ThinScrollStage.wide }

    private var laneView: some View {
        GeometryReader { proxy in
            let track = max(proxy.size.height - 8, 1)
            let length = min(max(track * metrics.visible / max(metrics.content, 1), 28), track)
            let travel = max(track - length, 0)
            let width: CGFloat = wide ? 7 : 3
            ZStack(alignment: .topTrailing) {
                // The lane itself: a faint groove under the line while the pointer is on it.
                Capsule()
                    .fill(Color.ink.opacity(wide ? 0.07 : 0))
                    .frame(width: 9)
                    .padding(.trailing, edgeInset - 1)
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                Capsule()
                    .fill(Color.ink.opacity(dragging ? 0.62 : (wide ? 0.48 : 0.36)))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
                    .frame(width: width, height: length)
                    .padding(.trailing, edgeInset + (wide ? 0 : 2))
                    .offset(y: 4 + travel * metrics.progress)
                    .gesture(drag(travel: travel))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { point in
                // A click on the lane: the line's middle goes there.
                guard travel > 0 else { return }
                let target = (point.y - 4 - length / 2) / travel * metrics.maxOffset
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { position.scrollTo(y: min(max(target, 0), metrics.maxOffset)) }
                wake()
            }
        }
        .opacity(shown ? 1 : 0)
        .animation(reduceMotion ? nil : .spring(duration: 0.25, bounce: 0.12), value: wide)
        .animation(reduceMotion ? nil : .easeOut(duration: shown ? 0.12 : 0.35), value: shown)
        .onHover { inside in
            hovering = inside
            if !inside { wake() }
        }
        .accessibilityHidden(true)
    }

    private func drag(travel: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStart == nil { dragStart = metrics.offset }
                dragging = true
                guard travel > 0, let start = dragStart else { return }
                let target = start + value.translation.height / travel * metrics.maxOffset
                position.scrollTo(y: min(max(target, 0), metrics.maxOffset))
            }
            .onEnded { _ in
                dragStart = nil
                dragging = false
                wake()
            }
    }

    /// Shows the line, and hides it once nothing has moved for a moment.
    private func wake(for seconds: Double = 0.9) {
        scrolling = true
        settle?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { scrolling = false } }
        settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}
