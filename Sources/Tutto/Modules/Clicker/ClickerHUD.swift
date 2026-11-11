//
//  ClickerHUD.swift
//  Tutto
//
//  What the auto clicker shows while it works: a small pill at the top of the screen with the
//  pointer saying how to stop it (its keys, and a corner when that's on), set once when it starts,
//  which clicks pass straight through; and the overlay that takes one click to set the spot.
//

import AppKit
import Observation
import SwiftUI
import TuttoKit

@MainActor
@Observable
final class ClickerHUDModel {
    var text = ""
    /// The keys shown as keycaps after `text`, then `detail`.
    var keys: KeyShortcut?
    var detail = ""
    var live = false
}

@MainActor
final class ClickerHUD {
    private let model = ClickerHUDModel()
    private var panel: NSPanel?

    func show(countdown seconds: Int, shortcut: KeyShortcut?) {
        model.text = "Starts in \(seconds)"
        model.keys = shortcut
        model.detail = shortcut == nil ? "" : "cancels"
        model.live = false
        present()
    }

    /// While clicking: how to stop it, nothing else ("Auto clicker  ⌃⇧A or a corner stops it").
    func show(clicking settings: ClickerSettings, shortcut: KeyShortcut?) {
        model.text = "Auto clicker"
        model.keys = shortcut
        model.detail = ClickerRules.howToStop(hasShortcut: shortcut != nil, holding: settings.holdToClick, corner: settings.cornerStops)
        model.live = true
        present()
    }

    func showPicking() {
        model.text = "Click where it should click"
        model.keys = nil
        model.detail = "Esc cancels"
        model.live = false
        present()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func present() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let size = panel.contentView?.fittingSize ?? NSSize(width: 260, height: 40)
        let area = screen.visibleFrame
        panel.setFrame(NSRect(x: area.midX - size.width / 2, y: area.maxY - size.height - 10, width: size.width, height: size.height),
                       display: true)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 40),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: ClickerPill(model: model).fixedSize())
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        return panel
    }
}

struct ClickerPill: View {
    var model: ClickerHUDModel

    var body: some View {
        HStack(spacing: 8) {
            // Still: it stays up for the whole run, and motion there would cost the whole run.
            Image(systemName: "cursorarrow.click.2")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(model.live ? Color.themeAccent : Color.ink2)
            Text(model.text)
                .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.ink)
                .contentTransition(.numericText())
            HStack(spacing: 5) {
                if let keys = model.keys { KeyCaps(shortcut: keys, compact: true) }
                if !model.detail.isEmpty {
                    Text(model.detail)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.ink3)
                }
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(Color.hairline))
        .padding(4)
        .animation(Motion.micro, value: model.text)
    }
}

// MARK: - Picking the spot

/// A clear overlay over every screen that takes one click and reports where it was (global
/// top-left points), or nil on Esc.
@MainActor
final class ClickerPicker {
    static let shared = ClickerPicker()

    private var windows: [NSWindow] = []
    private var done: ((CGPoint?) -> Void)?

    func pick(_ done: @escaping (CGPoint?) -> Void) {
        finish(nil)
        self.done = done
        for screen in NSScreen.screens {
            let window = PickerWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = NSColor.black.withAlphaComponent(0.04)
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.onClick = { [weak self] in self?.finish(CGEvent(source: nil)?.location) }
            window.onCancel = { [weak self] in self?.finish(nil) }
            let view = PickerView(frame: NSRect(origin: .zero, size: screen.frame.size))
            window.contentView = view
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            windows.append(window)
        }
        NSApp.activate(ignoringOtherApps: true)
        windows.first { $0.screen == NSScreen.main }?.makeKey()
        windows.first?.makeKey()
    }

    private func finish(_ point: CGPoint?) {
        let callback = done
        done = nil
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        callback?(point)
    }
}

private final class PickerWindow: NSWindow {
    var onClick: (() -> Void)?
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }
}

private final class PickerView: NSView {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }
}
