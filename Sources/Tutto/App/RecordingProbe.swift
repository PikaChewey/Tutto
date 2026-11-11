//
//  RecordingProbe.swift
//  Tutto
//
//  Debug builds only: `Tutto --record-probe DIR [h264|hevc] [30|60]` opens a small test window
//  with a moving bar, records exactly that window's area for three seconds through the same
//  session the ⌃⇧R recorder uses, checks the movie with AVFoundation and writes DIR/report.txt.
//  Only the test window is in the picture (it's a normal window, in front).
//

#if DEBUG
import AppKit
import AVFoundation
import QuartzCore
import TuttoKit

enum RecordingProbe {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--record-probe"), args.count > flag + 1 else { return false }
        let dir = URL(fileURLWithPath: args[flag + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let report = dir.appendingPathComponent("report.txt")
        var lines: [String] = []
        func say(_ line: String) {
            lines.append(line)
            try? lines.joined(separator: "\n").write(to: report, atomically: true, encoding: .utf8)
        }
        guard #available(macOS 15.0, *) else {
            say("needs macOS 15")
            return true
        }
        let codec: RecordingCodec = args.contains("hevc") ? .hevc : .h264
        let fps = args.contains("30") ? 30 : 60
        guard let screen = NSScreen.main else { say("no screen"); return true }

        // The test window: 320 × 200 points in the bottom-right corner, a bar sweeping across.
        let visible = screen.visibleFrame
        let frame = NSRect(x: visible.maxX - 360, y: visible.minY + 40, width: 320, height: 200)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = true
        window.backgroundColor = .black
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        let bar = CALayer()
        bar.backgroundColor = NSColor.systemOrange.cgColor
        bar.frame = CGRect(x: 0, y: 0, width: 40, height: frame.height)
        view.layer?.addSublayer(bar)
        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = 20
        sweep.toValue = frame.width - 20
        sweep.duration = 1
        sweep.autoreverses = true
        sweep.repeatCount = .infinity
        bar.add(sweep, forKey: "sweep")
        window.contentView = view
        window.orderFrontRegardless()

        let source = CGRect(x: frame.minX - screen.frame.minX, y: screen.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
        let size = RecordingRules.videoSize(points: source.size, scale: screen.backingScaleFactor)
        let target = RecordingTarget(displayID: screen.displayID, sourceRect: source, width: size.width, height: size.height)
        let url = dir.appendingPathComponent("probe-\(codec.rawValue)-\(fps).mp4")
        try? FileManager.default.removeItem(at: url)
        say("recording \(size.width)×\(size.height) \(codec.rawValue) \(fps) fps → \(url.lastPathComponent)")

        var outcome: Result<URL, Error>?
        let started = Date()
        Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(400))  // the window is on screen
                let options = RecordingSession.Options(fps: fps, showPointer: false, showClicks: false,
                                                       systemAudio: true, microphone: false, codec: codec)
                let session = try await RecordingSession.start(target: target, options: options, url: url) { outcome = $0 }
                say(String(format: "started after %.2f s", Date().timeIntervalSince(started)))
                try await Task.sleep(for: .seconds(3))
                await session.stop()
            } catch {
                outcome = .failure(error)
            }
        }
        while outcome == nil, Date().timeIntervalSince(started) < 20 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        window.orderOut(nil)
        switch outcome {
        case .success(let movie):
            say(String(format: "finished after %.2f s", Date().timeIntervalSince(started)))
            describe(movie, say: say)
        case .failure(let error):
            say("FAILED: \(error.localizedDescription)")
        case nil:
            say("FAILED: timed out")
        }
        return true
    }

    private static func describe(_ url: URL, say: (String) -> Void) {
        let asset = AVURLAsset(url: url)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        say("file: \(bytes) bytes")
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var info: [String] = []
        Task.detached {
            do {
                let duration = try await asset.load(.duration).seconds
                info.append(String(format: "duration: %.2f s", duration))
                for track in try await asset.load(.tracks) {
                    let kind = track.mediaType.rawValue
                    let formats = try await track.load(.formatDescriptions)
                    let codes = formats.map { description -> String in
                        let code = CMFormatDescriptionGetMediaSubType(description)
                        return String(bytes: [UInt8(code >> 24 & 255), UInt8(code >> 16 & 255), UInt8(code >> 8 & 255), UInt8(code & 255)],
                                      encoding: .ascii) ?? "?"
                    }
                    if track.mediaType == .video {
                        let size = try await track.load(.naturalSize)
                        let rate = try await track.load(.nominalFrameRate)
                        info.append("video: \(Int(size.width))×\(Int(size.height)) \(codes.joined(separator: ",")) \(String(format: "%.1f", rate)) fps")
                    } else {
                        info.append("\(kind): \(codes.joined(separator: ","))")
                    }
                }
            } catch {
                info.append("unreadable: \(error.localizedDescription)")
            }
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        info.forEach(say)
    }
}
#endif
