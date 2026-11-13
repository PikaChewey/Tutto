//
//  ScreenRecorder.swift
//  Tutto
//
//  Screen recording to an MP4 (macOS 15 and later). ⌃⇧R opens the same picker as screenshots:
//  drag an area, click a window, or click the desktop for the whole screen. A short countdown,
//  then ScreenCaptureKit records that area at the display's own resolution and writes the movie
//  itself (H.264 plays everywhere; HEVC is smaller), with the Mac's sound and the microphone if
//  chosen. A thin outline marks the area and stays out of the video, like everything else
//  Tutto floats. ⌃⇧R again, or Stop in the menu bar panel, ends it, and a thumbnail you can drag
//  into any app appears for a few seconds.
//
//  Nothing runs until you start one.
//

import AppKit
import AVFoundation
import os
import ScreenCaptureKit
import SwiftUI
import TuttoKit

private let log = Logger(subsystem: "ca.bryanyao.Tutto", category: "recording")

enum RecordingCodec: String, CaseIterable {
    case h264, hevc

    var title: String { self == .h264 ? "H.264" : "HEVC" }
}

@MainActor
@Observable
final class ScreenRecorder {
    enum State: Equatable {
        case idle
        /// The picker is up.
        case choosing
        /// Seconds left before it starts.
        case countdown(Int)
        case recording(since: Date)
        /// Stopped; the movie is being finished.
        case saving
    }

    private(set) var state: State = .idle
    var isBusy: Bool { state != .idle }
    var recordingSince: Date? {
        if case .recording(let since) = state { return since }
        return nil
    }

    // MARK: Settings (Screenshots page)

    var recordSystemAudio: Bool { didSet { defaults.set(recordSystemAudio, forKey: Keys.systemAudio) } }
    var recordMicrophone: Bool { didSet { defaults.set(recordMicrophone, forKey: Keys.microphone) } }
    var showClicks: Bool { didSet { defaults.set(showClicks, forKey: Keys.clicks) } }
    var keystrokes: KeystrokeMode { didSet { defaults.set(keystrokes.rawValue, forKey: Keys.keystrokes) } }
    var showPointer: Bool { didSet { defaults.set(showPointer, forKey: Keys.pointer) } }
    var framesPerSecond: Int { didSet { defaults.set(framesPerSecond, forKey: Keys.fps) } }
    var codec: RecordingCodec { didSet { defaults.set(codec.rawValue, forKey: Keys.codec) } }
    var countdownSeconds: Int { didSet { defaults.set(countdownSeconds, forKey: Keys.countdown) } }

    static var isSupported: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    @ObservationIgnored weak var module: ScreenshotModule?
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var overlay: SelectionOverlay?
    @ObservationIgnored private var outline: RecordingOutline?
    @ObservationIgnored private let prompt = CapturePrompt()
    @ObservationIgnored private var countdownTimer: Timer?
    @ObservationIgnored private var session: AnyObject?
    @ObservationIgnored private var target: RecordingTarget?
    @ObservationIgnored private var recordArea: CGRect = .zero
    @ObservationIgnored private var keycaps: KeystrokeOverlay?

    init() {
        let d = UserDefaults.standard
        recordSystemAudio = d.object(forKey: Keys.systemAudio) as? Bool ?? true
        recordMicrophone = d.bool(forKey: Keys.microphone)
        showClicks = d.object(forKey: Keys.clicks) as? Bool ?? true
        keystrokes = KeystrokeMode(rawValue: d.string(forKey: Keys.keystrokes) ?? "") ?? .off
        showPointer = d.object(forKey: Keys.pointer) as? Bool ?? true
        framesPerSecond = [30, 60].contains(d.integer(forKey: Keys.fps)) ? d.integer(forKey: Keys.fps) : 60
        codec = RecordingCodec(rawValue: d.string(forKey: Keys.codec) ?? "") ?? .h264
        countdownSeconds = d.object(forKey: Keys.countdown) as? Int ?? 3
    }

    // MARK: Start and stop

    /// The shortcut, the tool tile and the panel: start a recording, or end the one going.
    func toggle() {
        switch state {
        case .idle: begin()
        case .countdown: cancel()
        case .recording: stop()
        case .choosing, .saving: break
        }
    }

    private func begin() {
        guard Self.isSupported else {
            Toast.shared.show("Screen recording needs macOS 15", detail: "Screenshots work on this Mac; recording arrived in macOS 15.", duration: 3)
            return
        }
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
                Toast.shared.show("Couldn't start recording", detail: error.localizedDescription, duration: 3)
                return
            }
            let overlay = SelectionOverlay()
            self.overlay = overlay
            prompt.show("Record", detail: "Drag an area, click a window, or click the desktop for the whole screen · Esc cancels")
            overlay.begin(shots: shots) { [weak self] selection in
                guard let self else { return }
                self.overlay = nil
                self.prompt.hide()
                overlay.restoreFocus()
                guard let selection, RecordingRules.isRecordable(pixels: selection.rect) else {
                    self.state = .idle
                    return
                }
                self.prepare(selection)
            }
        }
    }

    private func prepare(_ selection: Selection) {
        let shot = selection.shot
        let source = RecordingRules.sourceRect(pixels: selection.rect, scale: shot.scale)
        let size = RecordingRules.videoSize(points: source.size, scale: shot.scale)
        let onScreen = CGRect(x: shot.frame.minX + source.minX, y: shot.frame.maxY - source.maxY,
                              width: source.width, height: source.height)
        let whole = source.width >= shot.frame.width - 1 && source.height >= shot.frame.height - 1
        recordArea = onScreen
        target = RecordingTarget(displayID: shot.displayID, sourceRect: source, width: size.width, height: size.height)
        outline = RecordingOutline(around: onScreen, wholeScreen: whole)
        if recordMicrophone, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            // Ask now, before the countdown, so the prompt doesn't land in the recording.
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self.countDown(on: onScreen) } }
            }
            return
        }
        countDown(on: onScreen)
    }

    private func countDown(on area: CGRect) {
        guard target != nil else { return }
        var left = countdownSeconds
        guard left > 0 else { return startRecording() }
        state = .countdown(left)
        prompt.showCountdown(left, centeredIn: area)
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, case .countdown = self.state else { return timer.invalidate() }
                left -= 1
                if left <= 0 {
                    timer.invalidate()
                    self.countdownTimer = nil
                    self.prompt.hide()
                    self.startRecording()
                } else {
                    self.state = .countdown(left)
                    self.prompt.showCountdown(left, centeredIn: area)
                }
            }
        }
    }

    private func startRecording() {
        guard #available(macOS 15.0, *), let target, let module else { return reset() }
        let url = ScreenshotNames.unique(RecordingRules.baseName(at: Date()), ext: "mp4", in: module.saveFolder) {
            FileManager.default.fileExists(atPath: $0.path)
        }
        let microphone = recordMicrophone && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if recordMicrophone && !microphone {
            Toast.shared.show("Recording without the microphone", detail: "Tutto isn't allowed to use it (Privacy & Security › Microphone).", duration: 3)
        }
        let options = RecordingSession.Options(fps: framesPerSecond, showPointer: showPointer, showClicks: showClicks,
                                               systemAudio: recordSystemAudio, microphone: microphone, codec: codec)
        // The keycap panel goes up first so its window id can stay in the capture filter.
        var keepWindow: CGWindowID?
        if keystrokes != .off {
            if AXIsProcessTrusted() {
                let keycaps = KeystrokeOverlay(area: recordArea, mode: keystrokes)
                keycaps.show()
                self.keycaps = keycaps
                keepWindow = keycaps.windowID
            } else {
                Toast.shared.show("Recording without the keys", detail: "Showing keys needs Tutto in Privacy & Security › Accessibility.", duration: 3)
            }
        }
        state = .saving  // until the stream is running
        Task { @MainActor in
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let session = try await RecordingSession.start(target: target, options: options, url: url, keeping: keepWindow) { [weak self] result in
                    self?.finished(result)
                }
                self.session = session
                self.state = .recording(since: Date())
                self.keycaps?.listen()
                self.outline?.markRecording()
                log.notice("recording \(target.width, privacy: .public)×\(target.height, privacy: .public) at \(options.fps, privacy: .public) fps to \(url.lastPathComponent, privacy: .public)")
            } catch {
                log.error("couldn't start: \(error.localizedDescription, privacy: .public)")
                self.reset()
                Toast.shared.show("Couldn't start recording", detail: error.localizedDescription, duration: 4)
            }
        }
    }

    /// Ends the recording; the movie is finished and shown when it's written.
    func stop() {
        guard case .recording = state else { return }
        state = .saving
        outline?.close()
        outline = nil
        keycaps?.close()
        keycaps = nil
        guard #available(macOS 15.0, *), let session = session as? RecordingSession else { return reset() }
        Task { await session.stop() }
    }

    /// Calls off a recording that hasn't started (the countdown).
    func cancel() {
        guard case .countdown = state else { return }
        reset()
    }

    private func finished(_ result: Result<URL, Error>) {
        session = nil
        reset()
        switch result {
        case .success(let url):
            log.notice("saved \(url.lastPathComponent, privacy: .public)")
            if module?.playSound == true { NSSound(named: "Glass")?.play() }
            RecordingThumbnail.shared.show(url)
        case .failure(let error):
            log.error("failed: \(error.localizedDescription, privacy: .public)")
            Toast.shared.show("The recording couldn't be saved", detail: error.localizedDescription, duration: 4)
        }
    }

    private func reset() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        prompt.hide()
        outline?.close()
        outline = nil
        keycaps?.close()
        keycaps = nil
        target = nil
        if session == nil { state = .idle }
    }

    private enum Keys {
        static let systemAudio = "recording.systemAudio"
        static let microphone = "recording.microphone"
        static let clicks = "recording.showClicks"
        static let keystrokes = "recording.keystrokes"
        static let pointer = "recording.showPointer"
        static let fps = "recording.fps"
        static let codec = "recording.codec"
        static let countdown = "recording.countdown"
    }
}

/// What to record: an area of one display, in its points, and the video's size in pixels.
struct RecordingTarget: Sendable {
    let displayID: CGDirectDisplayID
    let sourceRect: CGRect
    let width: Int
    let height: Int
}

// MARK: - The stream and the movie

@available(macOS 15.0, *)
final class RecordingSession: NSObject, SCStreamDelegate, SCRecordingOutputDelegate, @unchecked Sendable {
    struct Options: Sendable {
        var fps: Int
        var showPointer: Bool
        var showClicks: Bool
        var systemAudio: Bool
        var microphone: Bool
        var codec: RecordingCodec
    }

    private let url: URL
    private let finish: @MainActor (Result<URL, Error>) -> Void
    private let state = OSAllocatedUnfairLock(initialState: (done: false, streamError: Error?.none))
    private var stream: SCStream?

    private init(url: URL, finish: @escaping @MainActor (Result<URL, Error>) -> Void) {
        self.url = url
        self.finish = finish
    }

    static func start(target: RecordingTarget, options: Options, url: URL, keeping keepWindow: CGWindowID? = nil,
                      finish: @escaping @MainActor (Result<URL, Error>) -> Void) async throws -> RecordingSession {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == target.displayID }) else {
            throw CaptureError.noDisplays
        }
        // Tutto's floating bits (the outline, the panel, toasts) stay out, except the keycaps
        // (`keepWindow`); its own windows are in.
        let own = Bundle.main.bundleIdentifier
        let floating = content.windows.filter { $0.owningApplication?.bundleIdentifier == own && $0.windowLayer != 0 && $0.windowID != keepWindow }
        let filter = SCContentFilter(display: display, excludingWindows: floating)

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = target.sourceRect
        configuration.width = target.width
        configuration.height = target.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
        configuration.showsCursor = options.showPointer
        configuration.showMouseClicks = options.showClicks
        configuration.capturesAudio = options.systemAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.queueDepth = 8
        if options.microphone {
            configuration.captureMicrophone = true
            configuration.microphoneCaptureDeviceID = AVCaptureDevice.default(for: .audio)?.uniqueID
        }

        let recording = SCRecordingOutputConfiguration()
        recording.outputURL = url
        recording.outputFileType = .mp4
        recording.videoCodecType = options.codec == .hevc ? .hevc : .h264

        let session = RecordingSession(url: url, finish: finish)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: session)
        let output = SCRecordingOutput(configuration: recording, delegate: session)
        try stream.addRecordingOutput(output)
        try await stream.startCapture()
        session.stream = stream
        return session
    }

    func stop() async {
        do {
            try await stream?.stopCapture()
        } catch {
            log.error("stopping: \(error.localizedDescription, privacy: .public)")
        }
        // The movie's "finished" call normally follows; if it never comes, settle by what's on disk.
        try? await Task.sleep(for: .seconds(4))
        complete(FileManager.default.fileExists(atPath: url.path) ? .success(url) : .failure(CaptureError.failed("No movie was written.")))
    }

    private func complete(_ result: Result<URL, Error>) {
        let first = state.withLock { state -> Bool in
            defer { state.done = true }
            return !state.done
        }
        guard first else { return }
        let finish = finish
        DispatchQueue.main.async { MainActor.assumeIsolated { finish(result) } }
    }

    // SCRecordingOutputDelegate

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        complete(.success(url))
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        complete(.failure(error))
    }

    // SCStreamDelegate: the display went away, or macOS stopped the stream.

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        log.error("stream stopped: \(error.localizedDescription, privacy: .public)")
        state.withLock { $0.streamError = error }
        let url = url
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.complete(FileManager.default.fileExists(atPath: url.path) ? .success(url) : .failure(error))
        }
    }
}

// MARK: - The outline around the area

/// A thin outline just outside the area being recorded: grey while counting down, red while
/// recording. Clicks pass through it, and it's left out of the video.
@MainActor
final class RecordingOutline {
    private let panel: NSPanel
    private let layer = CAShapeLayer()
    private static let inset: CGFloat = 3

    init(around area: CGRect, wholeScreen: Bool) {
        let frame = area.insetBy(dx: -Self.inset, dy: -Self.inset)
        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        layer.frame = view.bounds
        layer.fillColor = nil
        layer.lineWidth = 1.5
        layer.lineDashPattern = [6, 4]
        layer.strokeColor = NSColor.white.withAlphaComponent(0.8).cgColor
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.5
        layer.shadowRadius = 1.5
        layer.shadowOffset = .zero
        layer.path = CGPath(rect: view.bounds.insetBy(dx: 1, dy: 1), transform: nil)
        view.layer?.addSublayer(layer)
        panel.contentView = view
        // The whole screen needs no outline (it would sit off the edges anyway).
        if !wholeScreen { panel.orderFrontRegardless() }
    }

    func markRecording() {
        layer.strokeColor = NSColor.systemRed.cgColor
        layer.lineDashPattern = nil
    }

    func close() {
        panel.orderOut(nil)
    }
}

// MARK: - The prompt and the countdown

/// A small pill: what the picker is for while it's up, then the countdown, centred in the area.
@MainActor
final class CapturePrompt {
    private var panel: NSPanel?
    private let model = CapturePromptModel()

    func show(_ title: String, detail: String) {
        model.title = title
        model.detail = detail
        model.big = nil
        present(centeredIn: nil)
    }

    func showCountdown(_ seconds: Int, centeredIn area: CGRect) {
        model.title = ""
        model.detail = "\(AppModel.shared.shortcuts.shortcut(for: .recordScreen)?.displayString ?? "Esc") cancels"
        model.big = seconds
        present(centeredIn: area)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func present(centeredIn area: CGRect?) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let size = panel.contentView?.fittingSize ?? NSSize(width: 320, height: 40)
        let frame: NSRect
        if let area {
            frame = NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
        } else {
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
            let visible = screen?.visibleFrame ?? .zero
            let top = screen?.hudTop ?? visible.maxY
            frame = NSRect(x: visible.midX - size.width / 2, y: top - size.height - 14, width: size.width, height: size.height)
        }
        panel.setFrame(frame.integral, display: true)
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 40),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Above the picker (screen-saver level), and out of every capture.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: CapturePromptView(model: model).fixedSize())
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        return panel
    }
}

@MainActor
@Observable
final class CapturePromptModel {
    var title = ""
    var detail = ""
    var big: Int?
}

struct CapturePromptView: View {
    var model: CapturePromptModel

    var body: some View {
        Group {
            if let big = model.big {
                VStack(spacing: 2) {
                    Text("\(big)")
                        .font(.system(size: 44, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color.ink)
                        .contentTransition(.numericText(countsDown: true))
                    Text(model.detail)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.ink3)
                }
                .frame(width: 120, height: 104)
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.regularMaterial))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.hairline))
                .animation(Motion.micro, value: big)
            } else {
                HStack(spacing: 8) {
                    Text(model.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.ink)
                    Text(model.detail)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.ink3)
                }
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(Capsule().fill(.regularMaterial))
                .overlay(Capsule().strokeBorder(Color.hairline))
            }
        }
        .padding(4)
    }
}

// MARK: - The thumbnail after saving

/// The finished movie (or tall scrolling capture) in the corner of the screen for a few seconds:
/// drag it into any app, click it to open, or Show in Finder, Copy, Edit (a picture) or Delete.
/// It stays while the pointer is on it.
@MainActor
final class RecordingThumbnail {
    static let shared = RecordingThumbnail()

    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private let model = RecordingThumbnailModel()

    func show(_ url: URL, image: CGImage? = nil) {
        model.url = url
        model.poster = image.map { Self.poster(from: $0) }
        model.duration = nil
        model.isPicture = image != nil
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let size = panel.contentView?.fittingSize ?? NSSize(width: 236, height: 196)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrame(NSRect(x: visible.maxX - size.width - 16, y: visible.minY + 16, width: size.width, height: size.height), display: true)
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.1 : 0.2
            panel.animator().alphaValue = 1
        }
        scheduleHide()
        guard image == nil else { return }
        Task { @MainActor in
            let asset = AVURLAsset(url: url)
            if let seconds = try? await asset.load(.duration).seconds, seconds.isFinite {
                model.duration = RecordingRules.elapsed(seconds.rounded(.up))
            }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 440, height: 440)
            if let image = try? await generator.image(at: CMTime(seconds: 0.3, preferredTimescale: 600)).image {
                model.poster = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            }
        }
    }

    /// A small copy for the card: the top of a tall picture, scaled to the card's width.
    private static func poster(from image: CGImage) -> NSImage {
        let visibleHeight = min(image.height, image.width * 120 / 212)
        let top = image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: visibleHeight)) ?? image
        return NSImage(cgImage: top, size: NSSize(width: top.width, height: top.height))
    }

    func hide() {
        hideWork?.cancel()
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.model.hovering { self.scheduleHide() } else { self.hide() }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 236, height: 196),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let host = NSHostingView(rootView: RecordingThumbnailView(model: model) { [weak self] in self?.hide() }.fixedSize())
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        return panel
    }
}

@MainActor
@Observable
final class RecordingThumbnailModel {
    var url: URL?
    var poster: NSImage?
    var duration: String?
    var hovering = false
    /// A picture (a scrolling capture) rather than a movie: it can be edited.
    var isPicture = false
}

struct RecordingThumbnailView: View {
    var model: RecordingThumbnailModel
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let poster = model.poster {
                        Image(nsImage: poster).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: 212, height: 120, alignment: .top)
                    } else {
                        Rectangle().fill(Color.ink.opacity(0.08))
                    }
                }
                .frame(width: 212, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                if let duration = model.duration {
                    Text(duration)
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.black.opacity(0.55)))
                        .padding(6)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { if let url = model.url { NSWorkspace.shared.open(url); close() } }
            .onDrag {
                guard let url = model.url else { return NSItemProvider() }
                return NSItemProvider(contentsOf: url) ?? NSItemProvider(object: url as NSURL)
            }
            .help(model.isPicture ? "Drag into any app, or click to open" : "Drag into any app, or click to play")
            HStack(spacing: 6) {
                Text(model.url?.deletingPathExtension().lastPathComponent ?? "")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.ink2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
            }
            HStack(spacing: 6) {
                action("Show", "folder") {
                    if let url = model.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    close()
                }
                if model.isPicture {
                    action("Edit", "pencil.and.scribble") {
                        if let url = model.url, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                            AppModel.shared.screenshots?.openEditor(with: image)
                        }
                        close()
                    }
                } else {
                    action("Copy", "doc.on.doc") {
                        if let url = model.url {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.writeObjects([url as NSURL])
                            Toast.shared.show("Copied", detail: "Paste it into a message or a folder")
                        }
                        close()
                    }
                }
                action("Delete", "trash") {
                    if let url = model.url { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
                    close()
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.hairline))
        .onHover { model.hovering = $0 }
    }

    private func action(_ title: String, _ symbol: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .medium))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(Color.ink2)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.ink.opacity(0.07)))
        }
        .buttonStyle(.plain)
    }
}
