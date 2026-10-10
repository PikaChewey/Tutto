//
//  ScreenCapturer.swift
//  Tutto
//
//  Still images of displays through ScreenCaptureKit, at native resolution, in sRGB
//  (so picked colors match what designers expect), with Tutto's own windows excluded.
//

import AppKit
import ScreenCaptureKit

struct DisplayShot {
    let displayID: CGDirectDisplayID
    /// The display's frame in Cocoa global coordinates (points, bottom-left origin).
    let frame: CGRect
    let scale: CGFloat
    let image: CGImage
}

enum CaptureError: LocalizedError {
    case permissionDenied
    case noDisplays
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Screen Recording is off for Tutto."
        case .noDisplays: "No display to capture."
        case .failed(let message): message
        }
    }
}

enum ScreenCapturer {
    /// Captures the given displays (all when nil), in parallel.
    static func capture(displays wanted: Set<CGDirectDisplayID>? = nil) async throws -> [DisplayShot] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CGPreflightScreenCaptureAccess() ? CaptureError.failed(error.localizedDescription) : CaptureError.permissionDenied
        }
        let ownBundle = Bundle.main.bundleIdentifier
        let ownApps = content.applications.filter { $0.bundleIdentifier == ownBundle }
        let screens = await MainActor.run {
            NSScreen.screens.map { (id: $0.displayID, frame: $0.frame, scale: $0.backingScaleFactor) }
        }
        let displays = content.displays.filter { wanted == nil || wanted!.contains($0.displayID) }
        guard !displays.isEmpty else { throw CaptureError.noDisplays }

        return try await withThrowingTaskGroup(of: DisplayShot?.self) { group in
            for display in displays {
                guard let screen = screens.first(where: { $0.id == display.displayID }) else { continue }
                group.addTask {
                    let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
                    let configuration = SCStreamConfiguration()
                    configuration.width = Int((screen.frame.width * screen.scale).rounded())
                    configuration.height = Int((screen.frame.height * screen.scale).rounded())
                    configuration.showsCursor = false
                    configuration.captureResolution = .best
                    configuration.colorSpaceName = CGColorSpace.sRGB
                    configuration.ignoreShadowsDisplay = false
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                    return DisplayShot(displayID: display.displayID, frame: screen.frame, scale: screen.scale, image: image)
                }
            }
            var shots: [DisplayShot] = []
            for try await shot in group {
                if let shot { shots.append(shot) }
            }
            return shots
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

extension CGImage {
    /// The sRGB color of one pixel (image coordinates, top-left origin).
    func color(atX x: Int, y: Int) -> NSColor? {
        guard x >= 0, y >= 0, x < width, y < height,
              let pixel = cropping(to: CGRect(x: x, y: y, width: 1, height: 1)),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return NSColor(srgbRed: CGFloat(bytes[0]) / 255, green: CGFloat(bytes[1]) / 255, blue: CGFloat(bytes[2]) / 255, alpha: 1)
    }

    var pngData: Data? {
        let rep = NSBitmapImageRep(cgImage: self)
        return rep.representation(using: .png, properties: [:])
    }

    func jpegData(quality: Double = 0.9) -> Data? {
        let rep = NSBitmapImageRep(cgImage: self)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}

extension NSColor {
    /// "#1A2B3C" in sRGB.
    var hexString: String {
        let color = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X", Int((color.redComponent * 255).rounded()),
                      Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
    }
}
