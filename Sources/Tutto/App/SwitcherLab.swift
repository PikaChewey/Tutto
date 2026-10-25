//
//  SwitcherLab.swift
//  Tutto
//
//  Debug-only: `Tutto --switcher-lab <log> <command…>` measures what the window switcher
//  relies on, with Tutto's own permissions.
//    thumbs <outdir>   captures every real window (all Spaces) at card size, with timings
//

#if DEBUG
import AppKit
import ScreenCaptureKit
import TuttoKit

@MainActor
enum SwitcherLab {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--switcher-lab"), args.count > flag + 2 else { return false }
        let log = URL(fileURLWithPath: args[flag + 1])
        let rest = Array(args[(flag + 2)...])
        var lines: [String] = []
        let started = Date()
        func say(_ s: String) {
            lines.append(String(format: "%7.1f ms  ", Date().timeIntervalSince(started) * 1000) + s)
            try? lines.joined(separator: "\n").write(to: log, atomically: true, encoding: .utf8)
        }
        let done = DispatchSemaphore(value: 0)
        Task {
            switch rest.first {
            case "thumbs":
                let out = URL(fileURLWithPath: rest[1], isDirectory: true)
                try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                do {
                    let t0 = Date()
                    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                    say("shareable content: \(content.windows.count) windows in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
                    let real = content.windows.filter {
                        $0.windowLayer == 0 && $0.frame.width >= 100 && $0.frame.height >= 100
                            && $0.owningApplication.map { NSRunningApplication(processIdentifier: $0.processID)?.activationPolicy == .regular } == true
                    }
                    say("real-looking: \(real.count)")
                    for window in real {
                        let config = SCStreamConfiguration()
                        let scale = min(640 / window.frame.width, 400 / window.frame.height)
                        config.width = Int(window.frame.width * scale)
                        config.height = Int(window.frame.height * scale)
                        config.showsCursor = false
                        config.ignoreShadowsSingleWindow = true
                        let t1 = Date()
                        do {
                            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window),
                                                                                   configuration: config)
                            let ms = Int(Date().timeIntervalSince(t1) * 1000)
                            let rep = NSBitmapImageRep(cgImage: image)
                            let file = out.appendingPathComponent("w\(window.windowID).png")
                            try? rep.representation(using: .png, properties: [:])?.write(to: file)
                            say("id=\(window.windowID) \(window.owningApplication?.applicationName ?? "?") onScreen=\(window.isOnScreen) \(image.width)x\(image.height) \(ms) ms '\(window.title ?? "")'")
                        } catch {
                            say("id=\(window.windowID) \(window.owningApplication?.applicationName ?? "?") FAILED \(error.localizedDescription)")
                        }
                    }
                } catch {
                    say("shareable content failed: \(error.localizedDescription)")
                }
            case "windows":
                // windows: every window of every regular app as the switcher sees it (flags, admitted
                // or not, Space, on screen), a picture attempt for each admitted one, and what the
                // switcher takes for the window you're in.
                let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
                let names = Dictionary(apps.map { ($0.processIdentifier, $0.localizedName ?? "?") }, uniquingKeysWith: { a, _ in a })
                let spaces = WindowServer.spaces()
                let onScreen = Set((CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
                    .compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
                say("front app: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"); front window: \(WindowServer.frontWindow().map { "\($0.id) (pid \($0.pid))" } ?? "none")")
                for window in WindowServer.windows(of: Set(names.keys)).sorted(by: { $0.zIndex < $1.zIndex }) {
                    let admitted = WindowAdmission.admits(window)
                    let space = WindowServer.space(of: window.id)
                    let kind = space.flatMap { spaces[$0] }.map { $0.isFullScreen ? "full-screen" : "desktop \($0.desktopNumber)" } ?? "no space"
                    var line = "\(admitted ? "CARD" : "    ") id=\(window.id) z=\(window.zIndex) \(names[window.pid] ?? "?") '\(window.title)' "
                    line += "\(Int(window.frame.width))x\(Int(window.frame.height))@\(Int(window.frame.minX)),\(Int(window.frame.minY)) "
                    line += "layer=\(window.layer) alpha=\(window.alpha) parent=\(window.parent) tags=0x\(String(window.tags, radix: 16)) "
                    line += "attrs=0x\(String(window.attributes, radix: 16)) space=\(space.map(String.init) ?? "-") (\(kind)) onscreen=\(onScreen.contains(window.id))"
                    if admitted {
                        let t = Date()
                        let raw = WindowServer.capture(window.id)
                        let clipped = raw.map { WindowPictures.isClipped($0, window.frame) } ?? true
                        let whole = clipped ? WholeWindowCapture.image(of: window.id, fitting: CGSize(width: 480, height: 300)) : nil
                        let rawText = raw.map { "\($0.width)x\($0.height)\(clipped ? " clipped" : "")" } ?? "nil"
                        line += " | server \(rawText), whole \(whole.map { "\($0.width)x\($0.height)" } ?? (clipped ? "nil" : "-")) in \(Int(Date().timeIntervalSince(t) * 1000)) ms"
                    }
                    say(line)
                }
                let cards = WindowServer.windows(of: Set(names.keys)).filter { WindowAdmission.admits($0) }
                let current = SwitcherOrder.current(onScreen: WindowServer.onScreenWindows(),
                                                    frontApp: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                                    cards: cards.map { ($0.id, $0.pid) })
                say("the window you're in: \(current.map(String.init) ?? "none")")
            case "film":
                // film <seconds> <outdir>: every frame of Tutto's switcher window while it's on screen,
                // straight from the window server, with timestamps (what the eye would see).
                let seconds = Double(rest[1])!, out = URL(fileURLWithPath: rest[2], isDirectory: true)
                try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                // Captures the panel's surface whether or not it's on screen (so the frame shown at the
                // instant it appears is recorded), marking each frame on- or off-screen.
                let end = Date().addingTimeInterval(seconds)
                let started = Date()
                var frame = 0
                while Date() < end {
                    let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
                    let overlay = all.first { ($0[kCGWindowOwnerName as String] as? String) == "Tutto" && ($0[kCGWindowLayer as String] as? Int ?? 0) == 101 }
                    if let id = overlay?[kCGWindowNumber as String] as? CGWindowID {
                        let onScreen = overlay?[kCGWindowIsOnscreen as String] as? Bool ?? false
                        if let image = WindowServer.capture(id), let small = ThumbnailStore.scaled(image, to: CGSize(width: 1000, height: 220)) {
                            let ms = Int(Date().timeIntervalSince(started) * 1000)
                            try? NSBitmapImageRep(cgImage: small).representation(using: .png, properties: [:])?
                                .write(to: out.appendingPathComponent(String(format: "f%03d-%04dms-%@.png", frame, ms, onScreen ? "ON" : "off")))
                            frame += 1
                        }
                    }
                    Thread.sleep(forTimeInterval: 0.006)
                }
                say("\(frame) frames")
            case "axmove", "axbench", "axinfo":
                // axmove <pid> <wid> <x> <y> [w h]: move (and resize) by AX, then read back the window
                // server's frame. axbench <pid> <wid> <n>: time n position sets. axinfo: AX attributes.
                let pid = pid_t(rest[1])!, wid = CGWindowID(rest[2])!
                guard let element = WindowElements.element(for: wid, pid: pid, budget: 0.5) else { say("no element"); break }
                func frame() -> String {
                    let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], wid) as? [[String: Any]])?.first
                    let b = info?[kCGWindowBounds as String] as? [String: Double] ?? [:]
                    return "x=\(b["X"] ?? -1) y=\(b["Y"] ?? -1) w=\(b["Width"] ?? -1) h=\(b["Height"] ?? -1) onscreen=\(info?[kCGWindowIsOnscreen as String] as? Bool ?? false)"
                }
                func set(_ x: Double, _ y: Double) -> AXError {
                    var p = CGPoint(x: x, y: y)
                    return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &p)!)
                }
                switch rest[0] {
                case "axmove":
                    say("before: \(frame())")
                    if rest.count > 6 {
                        var size = CGSize(width: Double(rest[5])!, height: Double(rest[6])!)
                        say("size -> \(AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!).rawValue)")
                    }
                    say("position -> \(set(Double(rest[3])!, Double(rest[4])!).rawValue)")
                    Thread.sleep(forTimeInterval: 0.15)
                    say("after: \(frame())")
                case "axbench":
                    let n = Int(rest[3])!
                    let t1 = Date()
                    for i in 0..<n { _ = set(100 + Double(i % 2) * 40, 200) }
                    say("\(n) moves in \(Int(Date().timeIntervalSince(t1) * 1000)) ms")
                default:
                    var names: CFArray?
                    AXUIElementCopyAttributeNames(element, &names)
                    for name in (names as? [String] ?? []) {
                        var value: CFTypeRef?
                        AXUIElementCopyAttributeValue(element, name as CFString, &value)
                        var settable: DarwinBoolean = false
                        AXUIElementIsAttributeSettable(element, name as CFString, &settable)
                        say("\(name)\(settable.boolValue ? " (settable)" : ""): \(String(describing: value).prefix(80))")
                    }
                }
            case "ownfocus":
                // Tutto's own window raised the way the switcher raises any window: element found,
                // then focus from a background queue. That aborted Tutto ("Must only be used from the
                // main thread": the raise runs in-process, on the calling thread).
                let window = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 420, height: 260),
                                      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                window.title = "Tutto own-window test"
                window.isReleasedWhenClosed = false
                window.orderFrontRegardless()
                try? await Task.sleep(nanoseconds: 400_000_000)
                let id = CGWindowID(window.windowNumber)
                let element = WindowElements.element(for: id, pid: getpid(), budget: 0.5)
                say("own window \(id), element found: \(element != nil)")
                nonisolated(unsafe) let unsafeElement = element
                let raised: Bool = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInteractive).async {
                        continuation.resume(returning: WindowFocus.focus(window: id, pid: getpid(), element: unsafeElement))
                    }
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
                say("focus from a background queue returned \(raised); Tutto still running; test window visible: \(window.isVisible)")
                window.close()
            case "hwcapture":
                // The window server's own capture, by window ID (works for other Spaces?).
                typealias Capture = @convention(c) (Int32, UnsafeMutablePointer<UInt32>, Int32, UInt32) -> Unmanaged<CFArray>?
                typealias MainConnection = @convention(c) () -> Int32
                let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
                let cid = unsafeBitCast(dlsym(sky, "SLSMainConnectionID")!, to: MainConnection.self)()
                guard let symbol = dlsym(sky, "SLSHWCaptureWindowList") else { say("no SLSHWCaptureWindowList"); break }
                let capture = unsafeBitCast(symbol, to: Capture.self)
                let out = URL(fileURLWithPath: rest[1], isDirectory: true)
                try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                for id in rest.dropFirst(2).compactMap(UInt32.init) {
                    var wid = id
                    let t1 = Date()
                    // ignoreGlobalClipShape (1<<11) | nominalResolution (1<<9)
                    let images = capture(cid, &wid, 1, (1 << 11) | (1 << 9))?.takeRetainedValue() as? [CGImage]
                    let ms = Int(Date().timeIntervalSince(t1) * 1000)
                    if let image = images?.first {
                        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                            .write(to: out.appendingPathComponent("hw\(id).png"))
                        say("id=\(id) \(image.width)x\(image.height) \(ms) ms")
                    } else {
                        say("id=\(id) nothing (\(ms) ms)")
                    }
                }
            case "focus":
                // focus <windowID> <pid>: make that exact window key and frontmost, even on another Space.
                let wid = UInt32(rest[1])!, pid = pid_t(rest[2])!
                let before = WindowServer.frontWindow().map { ($0.id, $0.pid) }
                say("front before: \(before.map { "\($0.0) pid \($0.1)" } ?? "none")")
                let t1 = Date()
                let element = WindowElements.element(for: wid, pid: pid, budget: 0.5)
                say("ax element: \(element != nil)")
                let ok = WindowFocus.focus(window: wid, pid: pid, element: element)
                say("focus call returned \(ok) in \(Int(Date().timeIntervalSince(t1) * 1000)) ms")
                for step in 1...12 {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    let front = WindowServer.frontWindow().map { ($0.id, $0.pid) }
                    say("t+\(step * 150) ms front: \(front.map { "\($0.0) pid \($0.1)" } ?? "none") app=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
                    if front?.0 == wid { break }
                }
            case "tags":
                // Window-server metadata for every layer-0 window of regular apps.
                typealias MainConnection = @convention(c) () -> Int32
                typealias Query = @convention(c) (Int32, CFArray, Int32) -> Unmanaged<CFTypeRef>?
                typealias CopyWindows = @convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?
                typealias Advance = @convention(c) (CFTypeRef) -> Bool
                typealias Get32 = @convention(c) (CFTypeRef) -> UInt32
                typealias Get64 = @convention(c) (CFTypeRef) -> UInt64
                typealias CopySpaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
                let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
                func f<T>(_ name: String, _ t: T.Type) -> T { unsafeBitCast(dlsym(sky, name)!, to: t) }
                let cid = f("SLSMainConnectionID", MainConnection.self)()
                let regular = Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map(\.processIdentifier))
                let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
                let mine = all.filter { regular.contains($0[kCGWindowOwnerPID as String] as! pid_t) && ($0[kCGWindowLayer as String] as? Int) == 0 }
                let ids = mine.map { $0[kCGWindowNumber as String] as! UInt32 }
                guard let query = f("SLSWindowQueryWindows", Query.self)(cid, ids.map { NSNumber(value: $0) } as CFArray, Int32(ids.count))?.takeRetainedValue(),
                      let it = f("SLSWindowQueryResultCopyWindows", CopyWindows.self)(query)?.takeRetainedValue() else { say("query failed"); break }
                let advance = f("SLSWindowIteratorAdvance", Advance.self)
                let wid = f("SLSWindowIteratorGetWindowID", Get32.self), parent = f("SLSWindowIteratorGetParentID", Get32.self)
                let tags = f("SLSWindowIteratorGetTags", Get64.self), attrs = f("SLSWindowIteratorGetAttributes", Get64.self)
                let copySpaces = f("SLSCopySpacesForWindows", CopySpaces.self)
                var meta: [UInt32: (UInt32, UInt64, UInt64)] = [:]
                while advance(it) { meta[wid(it)] = (parent(it), tags(it), attrs(it)) }
                for w in mine {
                    let id = w[kCGWindowNumber as String] as! UInt32
                    let b = w[kCGWindowBounds as String] as! [String: Double]
                    let m = meta[id]
                    let sp = (copySpaces(cid, 0x7, [NSNumber(value: id)] as CFArray)?.takeRetainedValue() as? [NSNumber])?.map(\.uint64Value) ?? []
                    say(String(format: "%@ id=%u %dx%d alpha=%.1f parent=%u tags=0x%016llx attrs=0x%llx spaces=%@ '%@'",
                               (w[kCGWindowOwnerName as String] as? String ?? "?").padding(toLength: 10, withPad: " ", startingAt: 0),
                               id, Int(b["Width"]!), Int(b["Height"]!), w[kCGWindowAlpha as String] as? Double ?? 1,
                               m?.0 ?? 0, m?.1 ?? 0, m?.2 ?? 0, "\(sp)", String((w[kCGWindowName as String] as? String ?? "").prefix(40))))
                }
            case "axresolve", "minimize", "hide":
                let pid = pid_t(rest[1])!
                if rest[0] == "hide" {
                    let app = NSRunningApplication(processIdentifier: pid)
                    let ok = rest[2] == "1" ? app?.hide() : app?.unhide()
                    say("hide=\(rest[2]) -> \(ok ?? false)")
                    break
                }
                let wid = UInt32(rest[2])!
                let t1 = Date()
                guard let element = WindowElements.element(for: wid, pid: pid, budget: Double(rest.count > 3 ? rest[3] : "0.5") ?? 0.5) else {
                    say("not found in \(Int(Date().timeIntervalSince(t1) * 1000)) ms"); break
                }
                say("resolved in \(Int(Date().timeIntervalSince(t1) * 1000)) ms")
                if rest[0] == "minimize" {
                    let err = AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, (rest[3] == "1") as CFBoolean)
                    say("set minimized=\(rest[3]) -> \(err.rawValue)")
                }
            case "inventory":
                // The list the switcher would show right now, with how long it took.
                let module = SwitcherModule(model: AppModel.shared)
                for _ in 0..<2 {
                    let t1 = Date()
                    let items = module.buildItems()
                    say("built \(items.count) cards in \(String(format: "%.1f", Date().timeIntervalSince(t1) * 1000)) ms")
                    if lines.count > 4 { continue }
                    for item in items {
                        say("  \(item.appName) | \(item.displayTitle) | min=\(item.isMinimized) hid=\(item.isHidden) place=\(item.place ?? "-") id=\(item.windowID.map(String.init) ?? "app")")
                    }
                }
            default:
                say("unknown command")
            }
            say("done")
            done.signal()
        }
        while done.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return true
    }
}
#endif
