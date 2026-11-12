//
//  KeystrokeOverlay.swift
//  Tutto
//
//  Keycaps on screen while a recording runs, so a demo shows which keys you pressed. A small
//  transparent panel sits near the bottom centre of the recorded area; a global key monitor feeds
//  it ("⌘ ⇧ 4", "×3" for a repeat, a short rolling string when typing), and it fades out about
//  a second after the last key. The panel is the one piece of Tutto left in the video: the
//  recorder keeps its window id out of the capture filter's exclusion. The monitor exists only
//  between show() and close(), so nothing runs when no recording is going. While macOS Secure
//  Input is on (a password field has the keyboard) nothing is shown.
//

import AppKit
import Carbon.HIToolbox
import SwiftUI
import TuttoKit

@MainActor
@Observable
final class KeycapModel {
    var shown: KeystrokeShown?
    var visible = false
}

@MainActor
final class KeystrokeOverlay {
    private static let fade: Duration = .milliseconds(1200)
    private static let height: CGFloat = 150

    private let panel: NSPanel
    private let model = KeycapModel()
    private var feed: KeystrokeFeed
    private var monitor: Any?
    private var fadeTask: Task<Void, Never>?

    /// The panel's window-server id, to keep it in the video.
    var windowID: CGWindowID { CGWindowID(panel.windowNumber) }

    /// `area` is the recorded area in screen points (bottom-left origin, as windows use).
    init(area: CGRect, mode: KeystrokeMode) {
        feed = KeystrokeFeed(mode: mode)
        let frame = CGRect(x: area.minX, y: area.minY + max(24, area.height * 0.05), width: area.width,
                           height: min(Self.height, area.height))
        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: KeycapRow(model: model))
        host.frame = NSRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
    }

    /// Puts the (empty, see-through) panel on screen so the recorder can find its window id.
    func show() {
        panel.orderFrontRegardless()
    }

    /// Starts listening for keys.
    func listen() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            let kind = event.type
            let code = event.keyCode
            let flags = event.modifierFlags
            let characters = event.characters
            let isRepeat = kind == .keyDown ? event.isARepeat : false
            MainActor.assumeIsolated { self?.handle(kind, code, flags, characters, isRepeat) }
        }
    }

    func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        fadeTask?.cancel()
        fadeTask = nil
        panel.orderOut(nil)
    }

    private func handle(_ kind: NSEvent.EventType, _ code: UInt16, _ flags: NSEvent.ModifierFlags,
                        _ characters: String?, _ isRepeat: Bool) {
        feed.secureInput = IsSecureEventInputEnabled()
        let modifiers = Self.modifiers(flags)
        let shown: KeystrokeShown?
        if kind == .flagsChanged {
            shown = feed.modifiersChanged(modifiers)
        } else if isRepeat {
            return
        } else {
            shown = feed.press(keyCode: code, modifiers: modifiers, characters: characters, now: ProcessInfo.processInfo.systemUptime)
        }
        guard let shown else { return }
        model.shown = shown
        withAnimation(.easeOut(duration: 0.12)) { model.visible = true }
        fadeTask?.cancel()
        fadeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.fade)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { self?.model.visible = false }
        }
    }

    private static func modifiers(_ flags: NSEvent.ModifierFlags) -> KeyShortcut.Modifiers {
        var result: KeyShortcut.Modifiers = []
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.command) { result.insert(.command) }
        return result
    }
}

/// The keycaps: dark, translucent, big enough to read in a video on a phone.
private struct KeycapRow: View {
    @Bindable var model: KeycapModel

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                switch model.shown {
                case .keys(let caps, let count)?:
                    ForEach(Array(caps.enumerated()), id: \.offset) { _, cap in Keycap(text: cap) }
                    if let badge = KeystrokeFeed.repeatBadge(count) {
                        Text(badge)
                            .font(.system(size: 30, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.themeAccent)
                            .shadow(color: .black.opacity(0.6), radius: 3)
                    }
                case .typing(let text)?:
                    Keycap(text: text, wide: true)
                case nil:
                    EmptyView()
                }
            }
            .opacity(model.visible ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct Keycap: View {
    let text: String
    var wide = false

    var body: some View {
        Text(text)
            .font(.system(size: wide ? 32 : 36, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, wide ? 22 : 16)
            .frame(minWidth: wide ? 0 : 64, minHeight: 64)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.74)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.22), lineWidth: 1.5))
    }
}
