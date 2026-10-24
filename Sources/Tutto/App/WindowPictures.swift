//
//  WindowPictures.swift
//  Tutto
//
//  Pictures of windows taken while they could be seen. A window the scrolling strip has
//  tucked out of view stops drawing, so a picture taken then can be stale or empty; the strip
//  photographs a window just before tucking it away, and the window switcher and the strip
//  bar show that picture instead. Kept in memory only, for the most recent few dozen windows.
//

import AppKit
import TuttoKit

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

    /// A picture of the window now, scaled to fit `pixels`. Blocks for 5–60 ms; call off the
    /// main thread.
    nonisolated static func capture(_ window: CGWindowID, fitting pixels: CGSize = CGSize(width: 480, height: 300)) -> NSImage? {
        guard let image = WindowServer.capture(window), let scaled = ThumbnailStore.scaled(image, to: pixels) else { return nil }
        return NSImage(cgImage: scaled, size: NSSize(width: CGFloat(scaled.width) / 2, height: CGFloat(scaled.height) / 2))
    }
}
