//
//  StripProxy.swift
//  Tutto (scrolling strip)
//
//  Smooth resizing for apps whose windows can't redraw as fast as a live resize asks: browsers
//  and the many apps that are web pages inside (WebEngineApps). Their page trails its window by a
//  tenth of a second or more while the window changes size (a heavy page shows its old layout cut
//  off at the moving edge, then jumps), so the strip changes the size of a picture of the window
//  instead. The picture lies exactly over the window, ordered right above it; the window waits
//  inside both its old and new frames, so the picture always covers it (ResizeCover). At the end
//  the window takes its new frame and, once it has had a moment to redraw, the picture fades.
//
//  The picture's window is see-through as far as macOS knows (not opaque): an opaque one makes
//  macOS count the window under it as hidden, and apps stop drawing windows that are hidden.
//

import AppKit
import QuartzCore
import TuttoKit

@MainActor
final class StripProxies {
    @MainActor
    private final class Proxy {
        let window: NSPanel
        let view: NSView
        /// Bumped each time it's taken up again, so a fade that ends late leaves it alone.
        var generation = 0

        init() {
            window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.ignoresMouseEvents = true
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.animationBehavior = .none
            window.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
            view = NSView()
            view.wantsLayer = true
            view.layer?.contentsGravity = .resize
            view.layer?.minificationFilter = .trilinear
            window.contentView = view
        }
    }

    private var active: [CGWindowID: Proxy] = [:]
    private var spare: [Proxy] = []

    /// A picture is over the window (while it moves, or while it redraws after).
    func covers(_ id: CGWindowID) -> Bool { active[id] != nil }

    /// Lays a picture of the window over it at `frame` (Accessibility coordinates). False when the
    /// window can't be photographed whole; the strip moves it live then.
    func begin(_ id: CGWindowID, frame: CGRect) -> Bool {
        if let proxy = active[id] {
            // Still there from its last move, waiting for the window to redraw: it carries on.
            proxy.generation += 1
            setAlpha(proxy.window, 1, duration: 0)
            proxy.window.alphaValue = 1
            move(id, to: frame)
            return true
        }
        guard let image = WindowServer.capture(id, inPixels: true), !WindowPictures.isClipped(image, frame) else { return false }
        let proxy = spare.popLast() ?? Proxy()
        proxy.generation += 1
        proxy.view.layer?.contents = image
        proxy.window.alphaValue = 1
        proxy.window.setFrame(StripDisplay.cocoa(frame), display: false)
        proxy.window.order(.above, relativeTo: Int(id))
        active[id] = proxy
        return true
    }

    func move(_ id: CGWindowID, to frame: CGRect) {
        active[id]?.window.setFrame(StripDisplay.cocoa(frame), display: false)
    }

    /// The window has its new frame: once it has had `delay` to redraw, the picture fades away.
    func finish(_ id: CGWindowID, after delay: TimeInterval) {
        guard let proxy = active[id] else { return }
        let generation = proxy.generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.active[id] === proxy, proxy.generation == generation else { return }
                self.setAlpha(proxy.window, 0, duration: 0.12) { [weak self] in
                    guard let self, self.active[id] === proxy, proxy.generation == generation else { return }
                    self.retire(id)
                }
            }
        }
    }

    /// Gone at once (the window moves live from here, or the strip is stopping).
    func end(_ id: CGWindowID) { retire(id) }

    func endAll() {
        for id in Array(active.keys) { retire(id) }
    }

    private func retire(_ id: CGWindowID) {
        guard let proxy = active.removeValue(forKey: id) else { return }
        proxy.generation += 1
        proxy.window.orderOut(nil)
        proxy.view.layer?.contents = nil
        if spare.count < 3 { spare.append(proxy) }
    }

    private func setAlpha(_ window: NSWindow, _ alpha: CGFloat, duration: TimeInterval, then: (@MainActor () -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = alpha
        }, completionHandler: {
            MainActor.assumeIsolated { then?() }
        })
    }
}
