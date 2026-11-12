//
//  WindowDragSnap.swift
//  Tutto
//
//  Drag a window to a screen edge or corner and it snaps there (SnapZones), with an outline
//  showing where before you let go; Esc during the drag cancels. Drag a window Tutto snapped
//  and it gets its old size back. Three passive mouse monitors: nothing happens until a window
//  actually moves, and nothing at all while macOS's own edge tiling is on (the two would fight).
//

import AppKit
import ApplicationServices
import SwiftUI
import TuttoKit

@MainActor
final class WindowDragSnap {
    private weak var module: WindowModule?
    private var monitors: [Any] = []
    private var keyMonitor: Any?
    private let preview = SnapPreview()

    // The drag in progress.
    private var windowID: CGWindowID?
    private var startBounds: CGRect?
    private var element: AXUIElement?
    private var app: NSRunningApplication?
    private var moving = false
    private var cancelled = false
    private var zone: WindowAction?
    private var zoneScreen: WindowModule.ScreenArea?

    init(module: WindowModule) {
        self.module = module
    }

    var isRunning: Bool { !monitors.isEmpty }

    func start() {
        guard monitors.isEmpty else { return }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) {
            monitors.append(monitor)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        reset()
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            reset()
            guard let cg = event.cgEvent else { return }
            var id = cg.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent)
            if id <= 0 { id = cg.getIntegerValueField(.mouseEventWindowUnderMousePointer) }
            guard id > 0, let info = Self.info(of: CGWindowID(id)), info.layer == 0, info.pid != getpid() else { return }
            windowID = CGWindowID(id)
            startBounds = info.bounds
        case .leftMouseDragged:
            guard let windowID, let startBounds, !cancelled, let pointer = event.cgEvent?.location else { return }
            if !moving {
                guard let now = Self.info(of: windowID)?.bounds else { return }
                if now.size != startBounds.size { self.windowID = nil; return }  // resizing, not moving
                guard now.origin != startBounds.origin else { return }
                guard let module, module.canSnapByDragging else { self.windowID = nil; return }
                moving = true
                element = Self.window(at: pointer)
                app = Self.info(of: windowID).flatMap { NSRunningApplication(processIdentifier: $0.pid) }
                if let element { module.dragStarted(window: element, id: windowID, app: app, frame: now, pointer: pointer) }
                keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] key in
                    MainActor.assumeIsolated {
                        guard key.keyCode == 53, let self else { return }  // Esc
                        self.cancelled = true
                        self.zone = nil
                        self.preview.hide()
                    }
                }
            }
            updateZone(pointer)
        case .leftMouseUp:
            defer { reset() }
            guard moving, !cancelled, let element, let module else { return }
            if let pointer = event.cgEvent?.location { updateZone(pointer) }
            guard let zone, let zoneScreen else { return }
            // Let the app finish its own drag before the window is placed.
            let app = self.app
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                MainActor.assumeIsolated { module.snapDropped(element, app: app, action: zone, screen: zoneScreen) }
            }
        default:
            break
        }
    }

    private func updateZone(_ pointer: CGPoint) {
        guard let module else { return }
        let screens = WindowModule.screensInAXSpace()
        guard let screen = screens.first(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(pointer) }) else { return }
        let action = SnapZones.action(at: pointer, screen: screen.frame, previous: zone)
        guard action != zone || screen.frame != zoneScreen?.frame else { return }
        zone = action
        zoneScreen = screen
        if let action {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            preview.show(module.snapFrame(for: action, on: screen))
        } else {
            preview.hide()
        }
    }

    private func reset() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if zone != nil || moving { preview.hide() }
        windowID = nil
        startBounds = nil
        element = nil
        app = nil
        moving = false
        cancelled = false
        zone = nil
        zoneScreen = nil
    }

    // MARK: Window lookups

    private struct Info {
        var bounds: CGRect
        var layer: Int
        var pid: pid_t
    }

    /// The window server's view of one window (cheap, no Accessibility call).
    private static func info(of id: CGWindowID) -> Info? {
        guard let list = CGWindowListCreateDescriptionFromArray([NSNumber(value: id)] as CFArray) as? [[String: Any]],
              let first = list.first,
              let boundsDictionary = first[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary) else { return nil }
        return Info(bounds: bounds, layer: first[kCGWindowLayer as String] as? Int ?? 0,
                    pid: pid_t(first[kCGWindowOwnerPID as String] as? Int ?? 0))
    }

    /// The Accessibility window under the pointer (the title bar being dragged belongs to it).
    private static func window(at point: CGPoint) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, let hit else { return nil }
        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(hit, kAXRoleAttribute as CFString, &role) == .success, (role as? String) == kAXWindowRole {
            return hit
        }
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(hit, kAXWindowAttribute as CFString, &window) == .success, let window,
              CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        return (window as! AXUIElement)
    }
}

/// The outline of where the window will go: the theme's accent, faint, with rounded corners.
/// It moves smoothly from zone to zone (instantly with Reduce Motion) and never takes clicks.
@MainActor
final class SnapPreview {
    private var panel: NSPanel?

    func show(_ axFrame: CGRect) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let frame = WindowLayout.flip(axFrame, primaryHeight: primaryHeight).insetBy(dx: 2, dy: 2)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if let panel, panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = reduceMotion ? 0 : 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
                panel.animator().alphaValue = 1
            }
            return
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setFrame(frame, display: true)
        panel.alphaValue = reduceMotion ? 1 : 0
        panel.orderFrontRegardless()
        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { if panel.alphaValue < 0.05 { panel.orderOut(nil) } }
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        let view = NSView()
        view.wantsLayer = true
        let accent = NSColor(Color.themeAccent)
        view.layer?.backgroundColor = accent.withAlphaComponent(0.16).cgColor
        view.layer?.borderColor = accent.withAlphaComponent(0.7).cgColor
        view.layer?.borderWidth = 2
        view.layer?.cornerRadius = 12
        view.layer?.cornerCurve = .continuous
        panel.contentView = view
        return panel
    }
}
