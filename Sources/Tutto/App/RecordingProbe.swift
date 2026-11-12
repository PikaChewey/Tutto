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
import WebKit

@MainActor
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

    /// `Tutto --scroll-probe DIR`: a test window (fixed header, 3,000-point numbered document,
    /// footer) scrolled and stitched by the real scrolling capture; DIR/scroll.png and report.txt.
    static func runScrollProbeIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--scroll-probe"), args.count > flag + 1 else { return false }
        let dir = URL(fileURLWithPath: args[flag + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let report = dir.appendingPathComponent("report.txt")
        var lines: [String] = []
        func say(_ line: String) {
            lines.append(line)
            try? lines.joined(separator: "\n").write(to: report, atomically: true, encoding: .utf8)
        }
        guard let screen = NSScreen.main else { say("no screen"); return true }
        // `web`: a page in WebKit (sticky header, fixed footer) instead of an AppKit scroll view.
        let web = args.dropFirst(flag + 2).contains("web")
        let visible = screen.visibleFrame
        let frame = NSRect(x: visible.maxX - 560, y: visible.minY + 40, width: 520, height: 420)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = true
        let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
        let page = WKWebView(frame: NSRect(origin: .zero, size: frame.size))
        let header = ProbeBar(frame: NSRect(x: 0, y: frame.height - 44, width: frame.width, height: 44), title: "Sticky header", color: .systemIndigo)
        let footer = ProbeBar(frame: NSRect(x: 0, y: 0, width: frame.width, height: 30), title: "Footer", color: .systemTeal)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 30, width: frame.width, height: frame.height - 74))
        // An overlay scroller, as in most apps: it shows while scrolling and must stay out of the picture.
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        let document = ProbeDocument(frame: NSRect(x: 0, y: 0, width: frame.width, height: 3000))
        scroll.documentView = document
        document.scroll(NSPoint(x: 0, y: document.bounds.height))  // start at the top (flipped below)
        content.addSubview(scroll)
        content.addSubview(header)
        content.addSubview(footer)
        if web {
            page.loadHTMLString(probePage(), baseURL: nil)
            window.contentView = page
        } else {
            window.contentView = content
        }
        window.orderFrontRegardless()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
        var pageHeight: Double = 0

        let rect = CGRect(x: frame.minX - screen.frame.minX, y: screen.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
        var result: CGImage?
        var done = false
        let started = Date()
        let capture = ScrollCapture()
        func save(_ image: CGImage?, _ name: String) {
            if let image, let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                try? data.write(to: dir.appendingPathComponent(name))
            }
        }
        // Where the view is scrolled to, in points from the top.
        func position() async -> Double {
            if web { return (try? await page.evaluateJavaScript("window.scrollY") as? Double) ?? -1 }
            return Double(scroll.contentView.bounds.origin.y)
        }
        func toTop() async {
            if web { _ = try? await page.evaluateJavaScript("window.scrollTo(0, 0); 0") } else {
                scroll.contentView.scroll(to: .zero)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            if web {
                for _ in 0..<50 where page.isLoading { try? await Task.sleep(for: .milliseconds(100)) }
                try? await Task.sleep(for: .milliseconds(500))
                pageHeight = (try? await page.evaluateJavaScript("document.documentElement.scrollHeight") as? Double) ?? 0
            }
            // Where the window really is, and what's on top at the area's centre.
            let center = CGPoint(x: CGDisplayBounds(screen.displayID).minX + rect.midX, y: CGDisplayBounds(screen.displayID).minY + rect.midY)
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            for info in list {
                let bounds = (info[kCGWindowBounds as String] as? [String: CGFloat]).map {
                    CGRect(x: $0["X"] ?? 0, y: $0["Y"] ?? 0, width: $0["Width"] ?? 0, height: $0["Height"] ?? 0)
                } ?? .zero
                let mine = (info[kCGWindowNumber as String] as? Int) == window.windowNumber
                guard mine || (bounds.contains(center) && (info[kCGWindowLayer as String] as? Int) == 0) else { continue }
                say("window \(mine ? "PROBE" : (info[kCGWindowOwnerName as String] as? String ?? "?")) layer \(info[kCGWindowLayer as String] ?? "?") bounds \(bounds)")
                if !mine { break }
            }
            say("area \(rect), centre \(center), window frame now \(window.frame)")
            save(try? await ScreenCapturer.captureArea(display: screen.displayID, rect: rect, scale: screen.backingScaleFactor), "before.png")
            // Does one posted scroll move the view? (It goes to the view under the pointer.)
            CGWarpMouseCursorPosition(center)
            try? await Task.sleep(for: .milliseconds(150))
            let origin = await position()
            if let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -60, wheel2: 0, wheel3: 0) {
                event.location = center
                event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                event.post(tap: .cghidEventTap)
            }
            try? await Task.sleep(for: .milliseconds(400))
            say("one posted scroll moved the view from \(origin) to \(await position()) pt; AX trusted: \(AXIsProcessTrusted())")
            await toTop()
            // Let the indicator that scroll showed fade, as it has by the time anyone picks an area.
            try? await Task.sleep(for: .milliseconds(1200))
            result = await capture.probe(display: screen.displayID, rect: rect, scale: screen.backingScaleFactor)
            save(try? await ScreenCapturer.captureArea(display: screen.displayID, rect: rect, scale: screen.backingScaleFactor), "after.png")
            done = true
        }
        // Events are handed to windows only by the app's event loop, which hasn't started yet
        // (this runs at launch): pump it, or posted scrolls never reach the window.
        let deadline = started.addingTimeInterval(60)
        while !done, Date() < deadline { pump(0.05) }
        if !done { capture.finishFromProbe() }
        while !done, Date().timeIntervalSince(started) < 70 { pump(0.05) }
        window.orderOut(nil)
        if let plan = capture.lastPlan {
            say("plan: header \(plan.header) rows, footer \(plan.footer), \(plan.steps.count) steps \(plan.steps.map(\.offset))")
        }
        guard let result else { say("FAILED: no picture"); return true }
        let scale = screen.backingScaleFactor
        let expected = web ? Int(pageHeight * scale) : Int((44 + 3000 + 30) * scale)
        say(String(format: "stitched %d × %d px in %.1f s; expected height %d (%@); off by %d px",
                   result.width, result.height, Date().timeIntervalSince(started), expected,
                   web ? "the page's scroll height" : "header + document + footer", result.height - expected))
        let url = dir.appendingPathComponent("scroll.png")
        if let data = NSBitmapImageRep(cgImage: result).representation(using: .png, properties: [:]) { try? data.write(to: url) }
        // The picture's top must be the first screen (before.png), the bottom the last (after.png):
        // the share of pixels that differ, leaving out the right edge (scroll indicators come and go).
        func pixels(_ image: CGImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            if let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return bytes
        }
        func differing(_ a: CGImage, _ b: CGImage, aTop: Int, bTop: Int, rows: Int) -> Double {
            let pa = pixels(a), pb = pixels(b)
            let width = min(a.width, b.width) - 48
            var off = 0, total = 0
            for row in 0..<rows {
                for x in 0..<width {
                    let ia = ((aTop + row) * a.width + x) * 4, ib = ((bTop + row) * b.width + x) * 4
                    total += 1
                    if (0..<3).contains(where: { abs(Int(pa[ia + $0]) - Int(pb[ib + $0])) > 24 }) { off += 1 }
                }
            }
            return total == 0 ? 1 : Double(off) / Double(total)
        }
        func load(_ name: String) -> CGImage? {
            NSImage(contentsOf: dir.appendingPathComponent(name))?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        // Both test pages leave their right edge empty (the row's own background, white or a
        // light tint) below the header and above the footer: anything else there is the scroll
        // indicator.
        let edge = pixels(result)
        var indicatorRows = 0
        let headerRows = Int((web ? 48 : 44) * scale), footerRows = Int((web ? 32 : 30) * scale)
        for row in headerRows..<(result.height - footerRows) {
            let background = (row * result.width + result.width - 26) * 4  // inside the padding, clear of text
            for x in (result.width - 24)..<result.width {
                let i = (row * result.width + x) * 4
                if (0..<3).contains(where: { abs(Int(edge[i + $0]) - Int(edge[background + $0])) > 24 }) { indicatorRows += 1; break }
            }
        }
        say("rows with the scroll indicator in the picture: \(indicatorRows)")
        if let before = load("before.png"), let after = load("after.png") {
            let rows = min(before.height, result.height) - 80
            say(String(format: "top vs the first screen: %.2f %% of pixels differ", 100 * differing(result, before, aTop: 0, bTop: 0, rows: rows)))
            say(String(format: "bottom vs the last screen: %.2f %% of pixels differ",
                       100 * differing(result, after, aTop: result.height - after.height + 100, bTop: 100, rows: after.height - 100)))
        }
        return true
    }

    /// `Tutto --scroll-events-probe DIR`: which posted scroll events move an ordinary scroll view
    /// under the pointer. Each variant from the top of a 3000 pt document; DIR/events.txt.
    static func runScrollEventsProbeIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--scroll-events-probe"), args.count > flag + 1 else { return false }
        let dir = URL(fileURLWithPath: args[flag + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var lines: [String] = []
        func say(_ line: String) {
            lines.append(line)
            try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent("events.txt"), atomically: true, encoding: .utf8)
        }
        guard let screen = NSScreen.main else { say("no screen"); return true }
        let visible = screen.visibleFrame
        let frame = NSRect(x: visible.maxX - 560, y: visible.minY + 40, width: 520, height: 420)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: frame.size))
        scroll.documentView = ProbeDocument(frame: NSRect(x: 0, y: 0, width: frame.width, height: 3000))
        window.contentView = scroll
        window.orderFrontRegardless()
        let bounds = CGDisplayBounds(screen.displayID)
        let center = CGPoint(x: bounds.minX + frame.midX - screen.frame.minX, y: bounds.minY + screen.frame.maxY - frame.midY)
        func wait(_ seconds: Double) { RecordingProbe.pump(seconds) }
        func event(_ units: CGScrollEventUnit, _ amount: Int32, continuous: Bool, phase: Int64 = 0) -> CGEvent? {
            guard let e = CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 1, wheel1: amount, wheel2: 0, wheel3: 0) else { return nil }
            e.location = center
            if continuous { e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1) }
            if phase != 0 { e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase) }
            return e
        }
        let variants: [(String, () -> Void)] = [
            ("pixel, continuous, HID tap (what ⌃⇧S posts)", { event(.pixel, -60, continuous: true)?.post(tap: .cghidEventTap) }),
            ("pixel, not continuous, HID tap", { event(.pixel, -60, continuous: false)?.post(tap: .cghidEventTap) }),
            ("line ×3, HID tap", { event(.line, -3, continuous: false)?.post(tap: .cghidEventTap) }),
            ("pixel, continuous, session tap", { event(.pixel, -60, continuous: true)?.post(tap: .cgSessionEventTap) }),
            ("pixel, continuous, phases began/changed/ended, HID tap", {
                event(.pixel, 0, continuous: true, phase: 1)?.post(tap: .cghidEventTap)
                event(.pixel, -60, continuous: true, phase: 2)?.post(tap: .cghidEventTap)
                event(.pixel, 0, continuous: true, phase: 4)?.post(tap: .cghidEventTap)
            }),
            ("mouse moved to the centre first, then pixel continuous, HID tap", {
                CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: center, mouseButton: .left)?.post(tap: .cghidEventTap)
                usleep(50_000)
                event(.pixel, -60, continuous: true)?.post(tap: .cghidEventTap)
            }),
            ("posted to this process only (pixel, continuous)", { event(.pixel, -60, continuous: true)?.postToPid(getpid()) }),
        ]
        say("window \(window.frame), centre \(center), AX trusted \(AXIsProcessTrusted())")
        for (name, post) in variants {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            CGWarpMouseCursorPosition(center)
            wait(0.4)
            post()
            wait(0.6)
            say("\(scroll.contentView.bounds.origin.y == 0 ? "NO  " : "YES ") moved \(Int(scroll.contentView.bounds.origin.y)) pt · \(name)")
        }
        window.orderOut(nil)
        return true
    }

    /// `Tutto --scroll-fade-probe DIR [web]`: after one posted scroll, when does the content stop
    /// moving, and when does the scroll indicator finish fading (the right edge stops changing)?
    /// A capture every 50 ms for 2.5 s; DIR/fade.txt.
    static func runScrollFadeProbeIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--scroll-fade-probe"), args.count > flag + 1 else { return false }
        let dir = URL(fileURLWithPath: args[flag + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let web = args.dropFirst(flag + 2).contains("web")
        var lines: [String] = []
        func say(_ line: String) {
            lines.append(line)
            try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent("fade.txt"), atomically: true, encoding: .utf8)
        }
        guard let screen = NSScreen.main else { say("no screen"); return true }
        let visible = screen.visibleFrame
        let frame = NSRect(x: visible.maxX - 560, y: visible.minY + 40, width: 520, height: 420)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        let page = WKWebView(frame: NSRect(origin: .zero, size: frame.size))
        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: frame.size))
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = ProbeDocument(frame: NSRect(x: 0, y: 0, width: frame.width, height: 3000))
        if web { page.loadHTMLString(probePage(), baseURL: nil); window.contentView = page } else { window.contentView = scroll }
        window.orderFrontRegardless()
        let rect = CGRect(x: frame.minX - screen.frame.minX, y: screen.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
        let center = CGPoint(x: CGDisplayBounds(screen.displayID).minX + rect.midX, y: CGDisplayBounds(screen.displayID).minY + rect.midY)
        func strip(_ image: CGImage, from x0: Int, to x1: Int) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            if let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            var out: [UInt8] = []
            for y in 0..<image.height { out.append(contentsOf: bytes[(y * image.width + x0) * 4 ..< (y * image.width + x1) * 4]) }
            return out
        }
        var done = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(web ? 1500 : 500))
            CGWarpMouseCursorPosition(center)
            try? await Task.sleep(for: .milliseconds(1500))  // anything showing from before fades first
            if let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -200, wheel2: 0, wheel3: 0) {
                event.location = center
                event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                event.post(tap: .cghidEventTap)
            }
            let posted = Date()
            var lastEdge: [UInt8]?, lastBody: [UInt8]?
            var edgeChanged = 0.0, bodyChanged = 0.0
            while Date().timeIntervalSince(posted) < 2.5 {
                guard let image = try? await ScreenCapturer.captureArea(display: screen.displayID, rect: rect, scale: screen.backingScaleFactor) else { break }
                let t = Date().timeIntervalSince(posted)
                let edge = strip(image, from: image.width - 40, to: image.width)
                let body = strip(image, from: 0, to: image.width - 40)
                if let lastEdge, lastEdge != edge { edgeChanged = t }
                if let lastBody, lastBody != body { bodyChanged = t }
                lastEdge = edge; lastBody = body
                try? await Task.sleep(for: .milliseconds(50))
            }
            say(String(format: "%@: content last moved at %.2f s; the right edge (scroll indicator) last changed at %.2f s",
                       web ? "WebKit" : "AppKit overlay scroller", bodyChanged, edgeChanged))
            done = true
        }
        let started = Date()
        while !done, Date().timeIntervalSince(started) < 15 { pump(0.05) }
        window.orderOut(nil)
        return true
    }

    /// A long page: a sticky header, a fixed footer, paragraphs of different lengths, every fifth
    /// tinted (rows that repeat a lot are what stitching gets wrong).
    static func probePage() -> String {
        let words = ["window", "scroll", "capture", "stitch", "header", "footer", "pixel", "frame", "row", "page", "menu",
                     "tutto", "picture", "step", "match", "offset", "quiet", "bright", "long", "short"]
        var state: UInt64 = 0x2545F4914F6CDD1D
        func next() -> Int { state ^= state << 13; state ^= state >> 7; state ^= state << 17; return Int(state % 1_000_003) }
        var paragraphs = ""
        for n in 1...90 {
            let count = 6 + next() % 40
            let text = (0..<count).map { _ in words[next() % words.count] }.joined(separator: " ")
            paragraphs += "<p><b>Paragraph \(n)</b> · \(text)</p>\n"
        }
        return """
        <!doctype html><html><head><meta charset="utf-8"><style>
        body { margin: 0; padding-bottom: 32px; font: 14px -apple-system, sans-serif; color: #222; background: #fff; }
        header { position: sticky; top: 0; height: 48px; display: flex; align-items: center; padding: 0 16px;
                 background: #5b5bd6; color: #fff; font-weight: 600; }
        footer { position: fixed; left: 0; right: 0; bottom: 0; height: 32px; display: flex; align-items: center;
                 padding: 0 16px; background: #12a594; color: #fff; }
        p { margin: 0; padding: 10px 16px; line-height: 1.45; }
        p:nth-of-type(5n) { background: #f1efff; }
        </style></head><body><header>Sticky header</header><main>
        \(paragraphs)</main><footer>Footer</footer></body></html>
        """
    }

    /// Runs the app's event loop for a while: events go to windows, main-actor work runs.
    static func pump(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let event = NSApp.nextEvent(matching: .any, until: min(end, Date().addingTimeInterval(0.05)), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
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
/// A coloured bar with a title (the probe's fixed header and footer).
private final class ProbeBar: NSView {
    private let title: String
    private let color: NSColor
    init(frame: NSRect, title: String, color: NSColor) {
        self.title = title
        self.color = color
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        bounds.fill()
        (title as NSString).draw(at: NSPoint(x: 12, y: bounds.midY - 8),
                                 withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white])
    }
}

/// A tall document of numbered lines with a stripe every fifth line, so every part looks different.
private final class ProbeDocument: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        dirtyRect.fill()
        let first = max(Int(dirtyRect.minY / 24), 0), last = Int(dirtyRect.maxY / 24) + 1
        for line in first...last {
            let y = CGFloat(line) * 24
            if line % 5 == 0 {
                NSColor(calibratedHue: CGFloat(line % 37) / 37, saturation: 0.25, brightness: 0.97, alpha: 1).setFill()
                NSRect(x: 0, y: y, width: bounds.width, height: 24).fill()
            }
            let text = "Line \(line + 1) · \(String(repeating: "abcdefghij".shuffledDeterministic(line), count: 2))"
            (text as NSString).draw(at: NSPoint(x: 16 + CGFloat(line % 7) * 9, y: y + 4),
                                    withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.black])
        }
    }
}

private extension String {
    func shuffledDeterministic(_ seed: Int) -> String {
        var chars = Array(self)
        var state = UInt64(seed + 1) &* 0x9E3779B97F4A7C15
        for i in stride(from: chars.count - 1, to: 0, by: -1) {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            chars.swapAt(i, Int(state >> 33) % (i + 1))
        }
        return String(chars)
    }
}
#endif
