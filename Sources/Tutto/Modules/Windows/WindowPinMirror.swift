//
//  WindowPinMirror.swift
//  Tutto
//
//  The live copy of a pinned window: a borderless panel that floats above other windows, sits
//  exactly over the real one and shows a ScreenCaptureKit stream of just that window (its own
//  pixels, up to 30 frames a second, frames handed to the layer as IOSurfaces with no copy).
//  The stream runs only while the copy is on screen; hidden, it's stopped and the last frame
//  is let go. Clicking the copy hands you the real window.
//

import AppKit
import os
import ScreenCaptureKit
import TuttoKit

private let log = Logger(subsystem: "ca.bryanyao.Tutto", category: "pins")

@MainActor
final class PinMirror {
    private let filter: SCContentFilter
    private let panel: PinMirrorPanel
    private let content: PinMirrorView
    private var stream: SCStream?
    private var output: PinStreamOutput?
    private var captureSize: (width: Int, height: Int)?
    /// Bumped whenever the stream is started or stopped, so a late frame from an old stream is dropped.
    private var generation = 0
    private var shadowStale = true
    private let onStop: () -> Void

    /// True while the copy should be on screen (it appears with the first frame).
    private(set) var isShowing = false

    init(filter: SCContentFilter, onClick: @escaping () -> Void, onStop: @escaping () -> Void) {
        self.filter = filter
        self.onStop = onStop
        content = PinMirrorView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        content.onClick = onClick
        panel = PinMirrorPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = content
    }

    /// Puts the copy over the window (frame in AppKit coordinates) and keeps it current.
    func show(frame: CGRect, scale: CGFloat) {
        if PinRules.needsMove(from: panel.frame, to: frame) {
            panel.setFrame(frame, display: false)
            shadowStale = true
        }
        content.surfaceScale = scale
        let size = PinRules.captureSize(points: frame.size, scale: scale)
        if !isShowing {
            isShowing = true
            startStream(size: size)
        } else if let current = captureSize, current != size, let stream {
            captureSize = size
            stream.updateConfiguration(Self.configuration(size)) { error in
                if let error { log.error("resizing the copy: \(error.localizedDescription, privacy: .public)") }
            }
        }
    }

    /// Takes the copy away and stops capturing.
    func hide() {
        guard isShowing else { return }
        isShowing = false
        generation += 1
        panel.orderOut(nil)
        content.show(nil)
        stopStream()
    }

    func close() {
        hide()
        panel.contentView = nil
        panel.close()
    }

    // MARK: Stream

    private static func configuration(_ size: (width: Int, height: Int)) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(PinRules.framesPerSecond))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.scalesToFit = true
        configuration.ignoreShadowsSingleWindow = true
        configuration.queueDepth = 3
        return configuration
    }

    private func startStream(size: (width: Int, height: Int)) {
        generation += 1
        let generation = generation
        let output = PinStreamOutput(
            frame: { [weak self] surface in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.present(surface, generation: generation) } }
            },
            stopped: { [weak self] in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.streamStopped(generation: generation) } }
            })
        let stream = SCStream(filter: filter, configuration: Self.configuration(size), delegate: output)
        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        } catch {
            log.error("adding the output: \(error.localizedDescription, privacy: .public)")
            return
        }
        self.stream = stream
        self.output = output
        captureSize = size
        Task { @MainActor [weak self] in
            do {
                try await stream.startCapture()
            } catch {
                log.error("starting the copy: \(error.localizedDescription, privacy: .public)")
            }
            // Hidden (or replaced) while it was starting: stop it now.
            if self?.stream !== stream { try? await stream.stopCapture() }
        }
    }

    private func stopStream() {
        guard let stream else { return }
        let output = output
        self.stream = nil
        self.output = nil
        captureSize = nil
        Task {
            try? await stream.stopCapture()
            withExtendedLifetime(output) {}
        }
    }

    private func present(_ surface: IOSurface, generation: Int) {
        guard generation == self.generation, isShowing else { return }
        content.show(surface)
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        if shadowStale {
            shadowStale = false
            panel.invalidateShadow()
        }
    }

    private func streamStopped(generation: Int) {
        guard generation == self.generation, isShowing else { return }
        // macOS ended the stream (the window closed, or capture was switched off).
        hide()
        onStop()
    }
}

// MARK: - The panel and its view

final class PinMirrorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The window's frames on a layer, a small pin badge in the top right corner, and a click that
/// hands you the real window.
final class PinMirrorView: NSView {
    var onClick: (() -> Void)?
    var surfaceScale: CGFloat = 2 {
        didSet { surfaceLayer.contentsScale = surfaceScale }
    }
    private let surfaceLayer = CALayer()
    private let badge: NSVisualEffectView

    override init(frame: NSRect) {
        badge = NSVisualEffectView(frame: NSRect(x: frame.width - 30, y: frame.height - 30, width: 22, height: 22))
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear
        surfaceLayer.contentsGravity = .resize
        surfaceLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        surfaceLayer.frame = bounds
        surfaceLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(surfaceLayer)

        badge.material = .hudWindow
        badge.blendingMode = .withinWindow
        badge.state = .active
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 11
        badge.layer?.masksToBounds = true
        badge.autoresizingMask = [.minXMargin, .minYMargin]
        let pin = NSImageView(frame: badge.bounds)
        pin.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        pin.contentTintColor = .white
        pin.imageScaling = .scaleNone
        pin.autoresizingMask = [.width, .height]
        badge.addSubview(pin)
        addSubview(badge)
        toolTip = "Kept on top. Click to use the window."
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Window kept on top")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ surface: IOSurface?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surfaceLayer.contents = surface
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

// MARK: - Stream output

/// Receives the stream's frames on its own queue and passes on the complete ones.
final class PinStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "ca.bryanyao.Tutto.pin", qos: .userInteractive)
    private let frame: @Sendable (IOSurface) -> Void
    private let stopped: @Sendable () -> Void

    init(frame: @escaping @Sendable (IOSurface) -> Void, stopped: @escaping @Sendable () -> Void) {
        self.frame = frame
        self.stopped = stopped
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Idle frames (nothing changed) carry no picture; only complete ones are shown.
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer,
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return }
        frame(unsafeBitCast(surface, to: IOSurface.self))
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        log.error("copy stopped: \(error.localizedDescription, privacy: .public)")
        stopped()
    }
}
