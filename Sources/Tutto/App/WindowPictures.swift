//
//  WindowPictures.swift
//  Tutto
//
//  Pictures of whole windows, wherever they are.
//
//  The window server's own capture is fast and reaches windows on other Spaces (full-screen
//  apps), but it only returns the part of a window that's on screen: a window the scrolling
//  strip has tucked out of view comes back as a sliver one point wide. ScreenCaptureKit draws
//  the whole window wherever it sits (it can't reach other Spaces). So: the window server
//  first, ScreenCaptureKit when that picture is clipped, and nothing (the app's icon) when
//  neither gives the whole window. A clipped picture is never kept or shown.
//
//  The strip also keeps the picture it took of each window just before tucking it away,
//  for the switcher and the strip bar. In memory only, for the most recent few dozen windows.
//

import AppKit
import os
import ScreenCaptureKit
import TuttoKit

#if DEBUG
private let pictureLog = Logger(subsystem: "ca.bryanyao.Tutto", category: "pictures")
#endif

@MainActor
final class WindowPictures {
    static let shared = WindowPictures()

    private var pictures: [CGWindowID: NSImage] = [:]
    private var order: [CGWindowID] = []
    private let limit = 48

    func store(_ picture: NSImage, for window: CGWindowID) {
        pictures[window] = picture
        order.removeAll { $0 == window }
        order.append(window)
        if order.count > limit { pictures[order.removeFirst()] = nil }
    }

    func picture(for window: CGWindowID) -> NSImage? { pictures[window] }

    func forget(_ window: CGWindowID) {
        pictures[window] = nil
        order.removeAll { $0 == window }
    }

    /// Whether macOS lets Tutto take pictures of other apps' windows (Screen Recording).
    static var canCapture: Bool { CGPreflightScreenCaptureAccess() }

    /// The whole window now, scaled to fit `pixels` (shown at half that size in points), or nil
    /// when only part of it could be captured. Blocks for 5–80 ms; call off the main thread.
    nonisolated static func capture(_ window: CGWindowID, fitting pixels: CGSize = CGSize(width: 480, height: 300)) -> NSImage? {
        let bounds = Self.bounds(of: window)
        if let image = WindowServer.capture(window), !isClipped(image, bounds) {
            note(window, "window server", image, bounds)
            return picture(image, fitting: pixels)
        }
        if let image = WholeWindowCapture.image(of: window, fitting: pixels), !isClipped(image, bounds) {
            note(window, "whole window", image, bounds)
            return picture(image, fitting: pixels)
        }
        note(window, "none", nil, bounds)
        return nil
    }

    /// Debug builds log every picture against its window's shape (live tests check them).
    nonisolated private static func note(_ window: CGWindowID, _ source: String, _ image: CGImage?, _ bounds: CGRect?) {
        #if DEBUG
        let size = image.map { "\($0.width)x\($0.height)" } ?? "-"
        let frame = bounds.map { "\(Int($0.width))x\(Int($0.height))" } ?? "?"
        pictureLog.notice("picture \(window) \(source, privacy: .public) \(size, privacy: .public) window \(frame, privacy: .public)")
        #endif
    }

    /// A capture whose shape differs from the window's by more than 15% only got part of it.
    nonisolated static func isClipped(_ image: CGImage, _ bounds: CGRect?) -> Bool {
        guard let bounds, bounds.width > 1, bounds.height > 1, image.height > 0 else { return false }
        let captured = Double(image.width) / Double(image.height)
        let window = Double(bounds.width / bounds.height)
        return abs(captured - window) / window > 0.15
    }

    nonisolated private static func picture(_ image: CGImage, fitting pixels: CGSize) -> NSImage? {
        guard let scaled = ThumbnailStore.scaled(image, to: pixels) else { return nil }
        return NSImage(cgImage: scaled, size: NSSize(width: CGFloat(scaled.width) / 2, height: CGFloat(scaled.height) / 2))
    }

    nonisolated private static func bounds(of window: CGWindowID) -> CGRect? {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], window) as? [[String: Any]])?.first,
              let bounds = info[kCGWindowBounds as String] as? [String: Double] else { return nil }
        return CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
    }
}

/// ScreenCaptureKit's picture of one window on its own, independent of where it is on screen.
enum WholeWindowCapture {
    private final class Box: @unchecked Sendable {
        var image: CGImage?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var content: (windows: [SCWindow], taken: Date)?

    /// Blocks until the picture is ready (or 1 s passes). Call off the main thread.
    static func image(of window: CGWindowID, fitting pixels: CGSize) -> CGImage? {
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            defer { done.signal() }
            guard let scWindow = await Self.window(window) else { return }
            let frame = scWindow.frame
            guard frame.width > 1, frame.height > 1 else { return }
            let scale = min(pixels.width / frame.width, pixels.height / frame.height, 2)
            let configuration = SCStreamConfiguration()
            configuration.width = max(Int(frame.width * scale), 1)
            configuration.height = max(Int(frame.height * scale), 1)
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true
            box.image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: scWindow),
                                                                    configuration: configuration)
        }
        _ = done.wait(timeout: .now() + 1)
        return box.image
    }

    /// The window as ScreenCaptureKit knows it. The list of windows is asked for at most every
    /// 1.5 s (it's the slow part), and again when the window isn't in it yet.
    private static func window(_ id: CGWindowID) async -> SCWindow? {
        let cached = lock.withLock { content }
        if let cached, Date().timeIntervalSince(cached.taken) < 1.5, let window = cached.windows.first(where: { $0.windowID == id }) {
            return window
        }
        guard let fresh = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return nil }
        lock.withLock { content = (fresh.windows, Date()) }
        return fresh.windows.first { $0.windowID == id }
    }
}
