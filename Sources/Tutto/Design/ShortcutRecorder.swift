//
//  ShortcutRecorder.swift
//  Tutto
//
//  Click, press the keys you want, done. Esc cancels, ⌫ removes the shortcut.
//  While it listens, every Tutto shortcut is released so the keys reach the recorder.
//

import AppKit
import Carbon.HIToolbox
import SwiftUI
import TuttoKit

struct ShortcutRecorder: View {
    var action: ShortcutAction
    @Bindable var model: AppModel

    @State private var recording = false
    @State private var liveModifiers: KeyShortcut.Modifiers = []
    @State private var note: String?
    @State private var monitor: Any?
    @State private var hovering = false
    @State private var recordingSession: UUID?

    var body: some View {
        HStack(spacing: 8) {
            if let note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ink2)
                    .transition(.opacity)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }
            Button(action: toggle) {
                HStack(spacing: 6) {
                    if recording {
                        Text(liveModifiers.isEmpty ? "Type shortcut" : KeyShortcut(keyCode: 0xFFFF, modifiers: liveModifiers).symbols.dropLast().joined())
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Color.ink)
                    } else {
                        KeyCaps(shortcut: model.shortcuts.shortcut(for: action))
                    }
                }
                .frame(minWidth: 96, minHeight: 26)
                .padding(.horizontal, 8)
                .background(Capsule().fill(recording ? Color.wash : (hovering ? Color.wash.opacity(0.6) : .clear)))
                .overlay(Capsule().strokeBorder(recording ? Color.ink : Color.hairline, lineWidth: recording ? 1.5 : 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(recording ? "Press the new shortcut. Esc cancels, Delete removes it." : "Click to record a new shortcut")
            .accessibilityLabel("\(action.title) shortcut")
            .accessibilityValue(model.shortcuts.shortcut(for: action)?.spokenDescription ?? "None")
            .accessibilityHint("Activate, then press the new key combination")

            if model.shortcuts.custom[action.id] != nil, !recording {
                IconButton(symbol: "arrow.uturn.backward", help: "Back to the default", size: 22) {
                    model.shortcuts.reset(action)
                    model.bindShortcuts()
                    flash(nil)
                }
            }
        }
        .animation(Motion.micro, value: recording)
        .animation(Motion.snappy, value: note)
        .onDisappear { stop() }
    }

    private func toggle() {
        recording ? stop() : start()
    }

    private func start() {
        recording = true
        liveModifiers = []
        note = nil
        model.hotkeys.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handle(event)
            return nil  // swallow while recording
        }
        // A combo another app owns globally never reaches Tutto; say so instead of looking stuck.
        let session = UUID()
        recordingSession = session
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if recording, recordingSession == session, note == nil {
                flash("Nothing yet? Another app may already own that shortcut.", duration: 4)
            }
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { model.hotkeys.resume() }
        recording = false
        liveModifiers = []
    }

    private func handle(_ event: NSEvent) {
        recordingSession = nil
        let modifiers = Self.modifiers(event.modifierFlags)
        if event.type == .flagsChanged {
            liveModifiers = modifiers
            return
        }
        let outcome = ShortcutRecording.interpret(keyCode: event.keyCode, modifiers: modifiers) { shortcut in
            model.shortcuts.conflict(for: shortcut, excluding: action)?.title
        }
        let shortcut: KeyShortcut
        switch outcome {
        case .cancel:
            stop()
            return
        case .remove:
            stop()
            model.setShortcut(nil, for: action)
            flash("Removed")
            return
        case .needsModifier:
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            flash("Add ⌘, ⌃ or ⌥")
            return
        case .conflict(let other):
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            flash("Already used by “\(other)”")
            return
        case .record(let recorded):
            shortcut = recorded
        }
        stop()
        model.setShortcut(shortcut, for: action)
        if let reserved = SystemShortcuts.owner(of: shortcut) {
            flash("macOS also uses this for \(reserved)", duration: 4)
        } else if model.hotkeys.failed.contains(action.id) {
            flash("macOS refused it; another app may own it", duration: 4)
        }
    }

    private func flash(_ text: String?, duration: TimeInterval = 2.2) {
        note = text
        guard text != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            if note == text { note = nil }
        }
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> KeyShortcut.Modifiers {
        var result: KeyShortcut.Modifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.shift) { result.insert(.shift) }
        return result
    }
}
