//
//  SoundPage.swift
//  Tutto
//
//  The app icon you click to mute (the menu bar panel's Sound card uses it) and Sound's
//  page in the app (every app with a switch, apps muted while closed, how it works).
//

import AppKit
import SwiftUI

// MARK: - App icon

/// One app icon. Muted: dimmed and grey with an ink speaker-slash badge. Playing: a speaker
/// badge in the accent colour. (Not a dot under it: that's the Dock's sign for a running app.)
struct SoundAppButton: View {
    var app: SoundApp
    var muted: Bool
    var usingAudio: Bool
    var size: CGFloat = 20
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(nsImage: app.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .saturation(muted ? 0 : 1)
                .opacity(muted ? 0.4 : 1)
                .overlay(alignment: .bottomTrailing) {
                    if muted {
                        badge("speaker.slash.fill", fill: .ink)
                    } else if usingAudio {
                        badge("speaker.wave.2.fill", fill: .accentColor)
                    }
                }
                .scaleEffect(hovering ? 1.06 : 1)
                .frame(width: size + 4, height: size + 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.micro, value: hovering)
        .animation(Motion.micro, value: muted)
        .help(muted ? "Unmute \(app.name)" : "Mute \(app.name)")
        .accessibilityLabel(app.name)
        .accessibilityValue(muted ? "Muted" : (usingAudio ? "Playing" : "Not muted"))
        .accessibilityHint(muted ? "Unmute" : "Mute at the speakers")
    }

    private func badge(_ symbol: String, fill: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.3, weight: .bold))
            .foregroundStyle(fill == .ink ? Color.paper : .white)
            .frame(width: size * 0.52, height: size * 0.52)
            .background(Circle().fill(fill))
            .overlay(Circle().strokeBorder(Color.paper.opacity(0.9), lineWidth: 1))
            .offset(x: 3, y: 3)
            .transition(.scale.combined(with: .opacity))
    }
}

// MARK: - Page

struct SoundPage: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: "Sound",
                       subtitle: "Mute any app at your speakers and headphones. It keeps playing for anything that records it.",
                       module: .sound)
            if !SoundModule.isSupported {
                Text("Muting single apps needs macOS 14.2 or later.")
                    .font(.system(size: 13)).foregroundStyle(Color.ink2)
            } else if let sound = model.sound {
                SoundSettings(sound: sound, model: model)
            } else {
                ModuleOffView(module: .sound, model: model)
            }
        }
    }
}

private struct SoundSettings: View {
    @Bindable var sound: SoundModule
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let problem = sound.problem {
                InkGroup {
                    LabeledRow(problem, detail: "Privacy & Security › Screen & System Audio Recording › System Audio Recording Only") {
                        Button("Allow") { model.permissions.request(.systemAudio) }
                            .buttonStyle(InkButtonStyle(compact: true))
                    }
                }
            }
            InkGroup("Apps", trailing: sound.muted.isEmpty ? nil : AnyView(
                Button("Unmute All") { withAnimation(Motion.micro) { sound.unmuteAll() } }
                    .buttonStyle(OutlineButtonStyle(compact: true)))) {
                if sound.apps.isEmpty {
                    Text("No apps open.").font(.system(size: 12)).foregroundStyle(Color.ink3)
                        .padding(.vertical, Metrics.rowPadding)
                }
                ForEach(Array(sound.apps.enumerated()), id: \.element.id) { index, app in
                    row(app)
                    if index < sound.apps.count - 1 { Hairline().opacity(0.6) }
                }
            }
            if !sound.mutedClosed.isEmpty {
                InkGroup("Muted while closed") {
                    ForEach(Array(sound.mutedClosed.enumerated()), id: \.element) { index, id in
                        LabeledRow(Self.name(for: id), detail: "Stays muted when it opens.") {
                            Button("Unmute") { withAnimation(Motion.micro) { sound.setMuted(id, false) } }
                                .buttonStyle(OutlineButtonStyle(compact: true))
                        }
                        if index < sound.mutedClosed.count - 1 { Hairline().opacity(0.6) }
                    }
                }
            }
            InkGroup {
                LabeledRow("Mute or unmute the front app", detail: "Whatever app you're in. A small note confirms it.") {
                    ShortcutRecorder(action: .muteFrontApp, model: model)
                }
            }
            InkGroup("How it works") {
                note("Only your speakers", "Tutto holds a muted app's sound back before it reaches the output device: built-in speakers, headphones, AirPods or a display. The app itself keeps playing normally.")
                Hairline().opacity(0.6)
                note("Still heard by recorders", "Screen recordings and tools that listen to an app, like an assistant working in it, still get its sound. Nothing is recorded or saved by Tutto.")
                Hairline().opacity(0.6)
                note("Helpers included", "Sound from an app's helper processes, like Discord's or a browser's, is muted with the app. Muted apps stay muted when they restart.")
                Hairline().opacity(0.6)
                note("Costs nothing while quiet", "Nothing runs until a muted app plays a sound, and it stops half a second after.")
            }
        }
        .background(VisibilityReader { visible in
            if visible { sound.begin() } else { sound.end() }
        })
    }

    private func row(_ app: SoundApp) -> some View {
        let muted = sound.isMuted(app.bundleID)
        let using = sound.usingAudio.contains(app.bundleID)
        return HStack(spacing: 12) {
            Image(nsImage: app.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 24, height: 24)
                .saturation(muted ? 0 : 1)
                .opacity(muted ? 0.45 : 1)
            VStack(alignment: .leading, spacing: Metrics.titleToDetail) {
                Text(app.name).font(.system(size: 13, weight: .medium))
                Text(muted ? (using ? "Muted · playing silently" : "Muted") : (using ? "Playing" : "Quiet"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.ink3)
            }
            Spacer()
            InkSwitch(isOn: Binding(get: { muted }, set: { sound.setMuted(app.bundleID, $0) }), label: "Mute \(app.name)",
                      active: sound.problem == nil)
                .help(muted ? "Unmute \(app.name)" : "Mute \(app.name)")
        }
        .padding(.vertical, Metrics.rowPadding - 2)
    }

    private func note(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: Metrics.titleToDetail) {
            Text(title).font(.system(size: 12.5, weight: .medium))
            Text(text).font(.system(size: 11.5)).lineSpacing(2).foregroundStyle(Color.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, Metrics.rowPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func name(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}
