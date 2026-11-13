//
//  ScrollCapture.swift
//  Tutto
//
//  Scrolling screenshots: ⌃⇧S, then pick the part of a window that scrolls (a web page, a chat,
//  a long document). Tutto scrolls it by itself in steps, captures each step and stitches them
//  (ScrollStitcher: rows vote on how far it moved; a sticky header and footer are kept once).
//  If the content doesn't move when Tutto scrolls, it asks you to scroll and keeps up with you.
//  It finishes by itself at the end of the page, or with Done / Return; Esc cancels.
//
//  The result is saved as a PNG in the screenshots folder, copied to the clipboard, and shown
//  in the corner: drag it into any app, or Edit it. Nothing runs until you start one.
//

import AppKit
import os
import SwiftUI
import TuttoKit

private let log = Logger(subsystem: "ca.bryanyao.Tutto", category: "scrolling")

@MainActor
@Observable
final class ScrollCapture {
    enum State: Equatable {
        case idle
        case choosing
        /// `manual`: you scroll, Tutto follows.
        case capturing(manual: Bool)
        case finishing
    }

    private(set) var state: State = .idle
    /// The picture's height so far, in pixels (shown while capturing).
    private(set) var height = 0

    /// Also put the picture on the clipboard (it's always saved as a file).
    var copiesToClipboard: Bool { didSet { defaults.set(copiesToClipboard, forKey: Keys.copy) } }

    @ObservationIgnored weak var module: ScreenshotModule?
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let prompt = CapturePrompt()
    @ObservationIgnored private let hud = ScrollHUD()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var keyMonitor: Any?
    /// Return and Esc while capturing are Tutto's alone: the app being captured never gets
    /// them (Return in a chat's message box would send what's typed there).
    @ObservationIgnored private var keyTap: ShortcutTap?
    @ObservationIgnored private var finishRequested = false
    @ObservationIgnored private var cancelled = false

    init() {
        copiesToClipboard = UserDefaults.standard.object(forKey: Keys.copy) as? Bool ?? true
    }

    /// The shortcut and the tool tile: start one, or finish the one going.
    func toggle() {
        switch state {
        case .idle: begin()
        case .capturing: finish()
        case .choosing, .finishing: break
        }
    }

    func finish() { finishRequested = true }

    func cancel() {
        cancelled = true
        finishRequested = true
    }

    private func begin() {
        guard CGPreflightScreenCaptureAccess() else {
            AppModel.shared.permissions.request(.screenRecording)
            Toast.shared.show("Screen Recording needed", detail: "Switch on Tutto in System Settings, then try again", duration: 3)
            return
        }
        state = .choosing
        Task { @MainActor in
            let shots: [DisplayShot]
            do {
                shots = try await ScreenCapturer.capture()
            } catch {
                state = .idle
                Toast.shared.show("Couldn't capture", detail: error.localizedDescription, duration: 3)
                return
            }
            let overlay = SelectionOverlay()
            prompt.show("Scrolling capture", detail: "Drag over the part that scrolls, or click a window · Esc cancels")
            overlay.begin(shots: shots) { [weak self] selection in
                guard let self else { return }
                self.prompt.hide()
                overlay.restoreFocus()
                guard let selection, selection.rect.width >= 40, selection.rect.height >= 80 else {
                    self.state = .idle
                    return
                }
                self.start(selection)
            }
        }
    }

    // MARK: Capturing

    private struct Area {
        let displayID: CGDirectDisplayID
        /// In the display's points, top-left origin.
        let rect: CGRect
        let scale: CGFloat
        /// Where scroll events go (global, top-left origin).
        let center: CGPoint
        /// On screen, for the HUD (Cocoa coordinates).
        let frame: CGRect
    }

    private func start(_ selection: Selection) {
        let shot = selection.shot
        let rect = RecordingRules.sourceRect(pixels: selection.rect, scale: shot.scale)
        let bounds = CGDisplayBounds(shot.displayID)
        let area = Area(displayID: shot.displayID, rect: rect, scale: shot.scale,
                        center: CGPoint(x: bounds.minX + rect.midX, y: bounds.minY + rect.midY),
                        frame: CGRect(x: shot.frame.minX + rect.minX, y: shot.frame.maxY - rect.maxY, width: rect.width, height: rect.height))
        finishRequested = false
        cancelled = false
        height = 0
        state = .capturing(manual: false)
        hud.show(near: area.frame, capture: self)
        let tap = ShortcutTap { [weak self] id, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { id == "cancel" ? self?.cancel() : self?.finish() }
            }
        }
        tap.bindings = [KeyShortcut(keyCode: 53, modifiers: []): "cancel",   // Esc
                        KeyShortcut(keyCode: 36, modifiers: []): "finish",   // Return
                        KeyShortcut(keyCode: 76, modifiers: []): "finish"]   // Enter
        if tap.start(name: "Scrolling capture keys") {
            keyTap = tap
        } else {
            // No tap (Accessibility off): the keys still work, but the app sees them too.
            keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                MainActor.assumeIsolated {
                    switch event.keyCode {
                    case 53: self?.cancel()           // Esc
                    case 36, 76: self?.finish()       // Return, Enter
                    default: break
                    }
                }
            }
        }
        let pointer = CGEvent(source: nil)?.location
        // Scroll events go to the view under the pointer.
        CGWarpMouseCursorPosition(area.center)
        task = Task { @MainActor in
            let image = await run(area)
            if let pointer { CGWarpMouseCursorPosition(pointer) }
            end(with: image)
        }
    }

    /// Scrolls and captures until the end of the content, Done, or Esc; returns the picture.
    private func run(_ area: Area) async -> CGImage? {
        // Every frame kept is copied at once: a capture's buffer can be reused by the next one,
        // and a frame held as it came could show later content by the time it's stitched.
        guard let captured = try? await ScreenCapturer.captureArea(display: area.displayID, rect: area.rect, scale: area.scale),
              let first = Self.ownCopy(of: captured), let firstPrints = Self.fingerprints(first) else { return nil }
        var plan = StitchPlan(frameHeight: first.height)
        var pieces: [Int: (image: CGImage, top: Int)] = [0: (first, 0)]
        var previous = firstPrints
        var frameIndex = 0
        var manual = false
        var stillCount = 0
        var lastOffset = 0
        var lastScroll = Date()
        height = first.height

        while !finishRequested {
            let pixelsVisible = max(first.height - plan.header - plan.footer, 40)
            // A little under half the view: every new row is seen twice (low in the frame that
            // brings it, higher up in the next), so it can be read from wherever the scroll
            // indicator isn't.
            let stepPoints = max(40, (CGFloat(pixelsVisible) / area.scale * 0.48).rounded())
            if !manual {
                Self.scroll(by: stepPoints, at: area.center)
                lastScroll = Date()
                try? await Task.sleep(for: .milliseconds(140))
            } else {
                try? await Task.sleep(for: .milliseconds(220))
            }
            guard !finishRequested else { break }
            // Wait for smooth scrolling to settle: two captures in a row that agree.
            var frame: CGImage?
            var prints: ScrollStitcher.Fingerprints?
            for _ in 0..<5 {
                guard let image = try? await ScreenCapturer.captureArea(display: area.displayID, rect: area.rect, scale: area.scale),
                      let next = Self.fingerprints(image) else { break }
                if let earlier = prints, ScrollStitcher.match(earlier, next)?.offset == 0 { frame = image; prints = next; break }
                frame = image
                prints = next
                if manual { break }
                try? await Task.sleep(for: .milliseconds(90))
            }
            guard let frame, let prints else { break }
            let expected = manual ? nil : Int(stepPoints * area.scale)
            guard let match = ScrollStitcher.match(previous, prints, expected: expected) else {
                if manual { continue }
                // The view changed entirely (a page loaded, a tab switched): keep what's there.
                log.notice("lost track after \(plan.steps.count, privacy: .public) steps")
                break
            }
            if match.offset == 0 {
                stillCount += 1
                if !manual && plan.steps.isEmpty && stillCount >= 2 {
                    // It doesn't scroll for Tutto: let the person scroll.
                    manual = true
                    state = .capturing(manual: true)
                    stillCount = 0
                    continue
                }
                if !manual && stillCount >= 2 { break }  // the end of the content
                if !manual && lastOffset > 0 && lastOffset < Int(Double(expected ?? 0) * 0.5) { break }
                continue
            }
            stillCount = 0
            let previousStep = plan.steps.last?.offset ?? 0
            lastOffset = match.offset
            if manual { lastScroll = Date() }
            if plan.steps.isEmpty || plan.footer > 0 || plan.header > 0 {
                let bands = ScrollStitcher.fixedBands(previous, prints, offset: match.offset)
                plan.setBands(top: bands.top, bottom: bands.bottom, offset: match.offset)
            }
            frameIndex += 1
            guard plan.add(frame: frameIndex, offset: match.offset) else {
                Toast.shared.show("That's as tall as it gets", detail: "\(StitchPlan.maximumHeight.formatted()) pixels", duration: 3)
                break
            }
            previous = prints
            height = plan.height
            // Keep the rows this frame brought, the footer, and the rows the previous frame
            // brought as they look here (moved up), copied.
            let keepFrom = max(frame.height - plan.footer - match.offset - previousStep - 2, 0)
            guard let kept = Self.ownCopy(of: frame, rows: keepFrom..<frame.height) else { break }
            pieces[frameIndex] = (kept, keepFrom)
        }
        guard !cancelled else { return nil }
        // The last view once more after the scroll indicator has faded (macOS shows it for about
        // a second after scrolling): the picture's last screen and footer come from it.
        var finalFrame: Int?
        if !plan.steps.isEmpty {
            state = .finishing
            let wait = Self.indicatorFade - Date().timeIntervalSince(lastScroll)
            if wait > 0 { try? await Task.sleep(for: .milliseconds(Int(wait * 1000))) }
            if !cancelled, let image = try? await ScreenCapturer.captureArea(display: area.displayID, rect: area.rect, scale: area.scale),
               let prints = Self.fingerprints(image), ScrollStitcher.match(previous, prints)?.offset == 0,
               let copy = Self.ownCopy(of: image) {
                finalFrame = frameIndex + 1
                pieces[frameIndex + 1] = (copy, 0)
            }
        }
        guard !cancelled else { return nil }
        #if DEBUG
        lastPlan = plan
        #endif
        var slices = plan.sources(minimumThumb: Int(20 * area.scale), finalFrame: finalFrame)
        let kept = slices.allSatisfy { slice in
            guard let piece = pieces[slice.frame] else { return false }
            return slice.rows.lowerBound >= piece.top && slice.rows.upperBound <= piece.top + piece.image.height
        }
        if !kept {
            log.error("rows to read around the scroll indicator weren't kept; each step from its own frame")
            slices = plan.slices
        }
        log.notice("stitched \(plan.steps.count + 1, privacy: .public) frames into \(plan.height, privacy: .public) px")
        return Self.compose(slices, height: plan.height, pieces: pieces, width: first.width)
    }

    /// Seconds after the last scroll by which the scroll indicator has faded.
    private static let indicatorFade = 1.1

    private static func scroll(by points: CGFloat, at location: CGPoint) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                  wheel1: Int32(-points), wheel2: 0, wheel3: 0) else { return }
        event.location = location
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.post(tap: .cghidEventTap)
    }

    /// The image (or some of its rows) in memory of its own.
    private static func ownCopy(of image: CGImage, rows: Range<Int>? = nil) -> CGImage? {
        let rows = rows ?? 0..<image.height
        guard !rows.isEmpty, let crop = image.cropping(to: CGRect(x: 0, y: rows.lowerBound, width: image.width, height: rows.count)),
              let context = CGContext(data: nil, width: crop.width, height: crop.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        return context.makeImage()
    }

    private static func fingerprints(_ image: CGImage) -> ScrollStitcher.Fingerprints? {
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        // A bitmap context's buffer holds the image's top row first.
        return ScrollStitcher.fingerprints(pixels: UnsafeRawBufferPointer(start: data, count: width * 4 * height),
                                           width: width, height: height, bytesPerRow: width * 4)
    }

    private static func compose(_ slices: [StitchPlan.Slice], height total: Int, pieces: [Int: (image: CGImage, top: Int)], width: Int) -> CGImage? {
        guard total > 0, let context = CGContext(data: nil, width: width, height: total, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var y = 0  // from the top of the picture
        for slice in slices {
            guard let piece = pieces[slice.frame] else { continue }
            let from = slice.rows.lowerBound - piece.top
            guard from >= 0, let rows = piece.image.cropping(to: CGRect(x: 0, y: from, width: piece.image.width, height: slice.rows.count)) else { continue }
            // Core Graphics draws bottom-up.
            context.draw(rows, in: CGRect(x: 0, y: total - y - slice.rows.count, width: width, height: slice.rows.count))
            y += slice.rows.count
        }
        return context.makeImage()
    }

    private func end(with image: CGImage?) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        keyTap?.stop()
        keyTap = nil
        hud.hide()
        task = nil
        state = .idle
        guard let image, let module else { return }
        if copiesToClipboard { module.copyToClipboard(image) }
        if let url = module.save(image) {
            RecordingThumbnail.shared.show(url, image: image)
        } else if copiesToClipboard {
            Toast.shared.show("Copied", detail: "\(image.width) × \(image.height) pixels")
        }
    }

    private enum Keys {
        static let copy = "scrolling.copy"
    }

    #if DEBUG
    /// The scroll probe: captures this area of this display (points, top-left origin) as ⌃⇧S
    /// would after the picker, and hands back the picture instead of saving it.
    func probe(display: CGDirectDisplayID, rect: CGRect, scale: CGFloat) async -> CGImage? {
        let bounds = CGDisplayBounds(display)
        let area = Area(displayID: display, rect: rect, scale: scale,
                        center: CGPoint(x: bounds.minX + rect.midX, y: bounds.minY + rect.midY), frame: .zero)
        finishRequested = false
        cancelled = false
        state = .capturing(manual: false)
        CGWarpMouseCursorPosition(area.center)
        let image = await run(area)
        state = .idle
        return image
    }

    /// Ends a probe run as Done would.
    func finishFromProbe() { finishRequested = true }

    /// The last run's plan, for the probe's report.
    @ObservationIgnored private(set) var lastPlan: StitchPlan?
    #endif
}

// MARK: - The bar while capturing

/// Beside the area: what's happening, how tall it is so far, Done and Cancel. Clicks reach it
/// without taking focus from the app being captured, and it's left out of the capture.
@MainActor
final class ScrollHUD {
    private var panel: NSPanel?

    func show(near area: CGRect, capture: ScrollCapture) {
        let panel = self.panel ?? NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 40),
                                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.panel = panel
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: ScrollHUDView(capture: capture).fixedSize())
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        let size = host.fittingSize
        // Above the area if there's room, else just inside its top; never under the menu bar or
        // the notch (an area or a full-screen window can reach the top edge).
        let screen = NSScreen.screens.first { $0.frame.intersects(area) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? area
        let top = screen?.hudTop ?? visible.maxY
        var y = area.maxY + 8
        if y + size.height > top - 6 { y = min(area.maxY, top) - size.height - 8 }
        let x = min(max(area.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height).integral, display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }
}

private struct ScrollHUDView: View {
    var capture: ScrollCapture

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.themeAccent)
            VStack(alignment: .leading, spacing: 1) {
                Text(capture.state == .finishing ? "Finishing…" : manual ? "Scroll it yourself" : "Scrolling…")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.ink)
                Text("\(capture.height.formatted()) px · Return finishes · Esc cancels")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color.ink3)
            }
            Button("Done") { capture.finish() }
                .buttonStyle(OutlineButtonStyle(compact: true))
                .disabled(capture.state == .finishing)
            Button("Cancel") { capture.cancel() }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.ink3)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(Color.hairline))
        .padding(4)
    }

    private var manual: Bool {
        if case .capturing(manual: true) = capture.state { return true }
        return false
    }
}
