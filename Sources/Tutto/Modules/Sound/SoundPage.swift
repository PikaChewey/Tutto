//
//  SoundPage.swift
//  Tutto
//
//  The app icon you click to mute (the menu bar panel's Sound card uses it) and Sound's
//  page in the app (every app with a switch, apps muted while closed, how it works).
//

import AppKit
import SwiftUI
import TuttoKit

// MARK: - App icon

/// One app icon. Muted: dimmed and grey with an ink speaker-slash badge. Playing: a speaker
/// badge in the accent colour. (Not a dot under it: that's the Dock's sign for a running app.)
///
/// Under the pointer it shows what a click will do, not a lens (Bryan, 2026-11-13: the tools bar's
/// glass and swell on app icons "don't make sense"; an app icon is its own tile, and a click mutes
/// it): an app that plays loses some colour and gets the mute badge, a muted one gets its colour
/// back and the speaker badge. Right after a click it shows the new state until the pointer leaves.
struct SoundAppButton: View {
    var app: SoundApp
    var muted: Bool
    var usingAudio: Bool
    /// The app's level when it isn't 100 % (a thin ring shows it).
    var level: Double? = nil
    var size: CGFloat = 20
    /// The pointer is on it (kept by the strip, which also floats the app's name above it).
    var previewing: Bool? = nil
    var hover: ((Bool) -> Void)? = nil
    var action: () -> Void
    @State private var hovering = false
    @State private var toggled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A click's result, shown while the pointer is on it.
    private var preview: Bool { (previewing ?? (hovering && !toggled)) }

    var body: some View {
        Button {
            toggled = true
            action()
        } label: {
            Image(nsImage: app.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .saturation(muted ? (preview ? 1 : 0) : (preview ? 0.35 : 1))
                .opacity(muted ? (preview ? 0.85 : 0.4) : (preview ? 0.8 : 1))
                .overlay(alignment: .bottomTrailing) {
                    if preview {
                        // What a click does: mute it, or let it play again.
                        badge(muted ? "speaker.wave.2.fill" : "speaker.slash.fill", fill: .ink)
                            .id(muted ? "unmute" : "mute")
                    } else if muted {
                        badge("speaker.slash.fill", fill: .ink)
                    } else if usingAudio {
                        badge("speaker.wave.2.fill", fill: .themeAccent)
                    }
                }
                .background {
                    if let level, !muted {
                        // A ring around the icon: part of a circle when it's turned down, the
                        // accent all round when it's boosted.
                        Circle()
                            .trim(from: 0, to: level >= 100 ? 1 : max(level / 100, 0.04))
                            .stroke(level > 100 ? Color.themeAccent : Color.ink.opacity(0.45), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: size + 5, height: size + 5)
                    }
                }
                .frame(width: size + 4, height: size + 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { inside in
            hovering = inside
            if !inside { toggled = false }
            hover?(inside)
        }
        .animation(reduceMotion ? .easeOut(duration: 0.1) : Motion.lens, value: preview)
        .animation(Motion.micro, value: muted)
        .help(muted ? "Unmute \(app.name)" : "Mute \(app.name)" + (level.map { " · level \(VolumeCurve.label($0))" } ?? ""))
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
            .transition(.scale(scale: 0.5).combined(with: .opacity))
    }
}

// MARK: - Level slider

/// An app's level, 0–300 %. The first 60 % of the track is 0–100 % (where most changes happen);
/// the rest is the boost, tinted. Let go near 100 % and it lands on it; double-click resets it.
struct VolumeSlider: View {
    var value: Double
    var width: CGFloat = 150
    var set: (Double) -> Void
    @State private var dragging = false

    private static let unityAt: CGFloat = 0.6

    static func position(_ value: Double) -> CGFloat {
        let v = min(max(value, 0), VolumeCurve.maximum)
        return v <= 100 ? CGFloat(v / 100) * unityAt : unityAt + CGFloat((v - 100) / (VolumeCurve.maximum - 100)) * (1 - unityAt)
    }

    static func value(at position: CGFloat) -> Double {
        let p = min(max(position, 0), 1)
        return p <= unityAt ? Double(p / unityAt) * 100 : 100 + Double((p - unityAt) / (1 - unityAt)) * (VolumeCurve.maximum - 100)
    }

    var body: some View {
        let x = Self.position(value) * width
        let unity = Self.unityAt * width
        ZStack(alignment: .leading) {
            Capsule().fill(Color.ink.opacity(0.1)).frame(height: 4)
            // The boost zone, faintly tinted even when unused.
            Capsule().fill(Color.themeAccent.opacity(0.14)).frame(width: width - unity, height: 4).offset(x: unity)
            Capsule().fill(Color.ink.opacity(0.75)).frame(width: min(x, unity), height: 4)
            if x > unity {
                Capsule().fill(Color.themeAccent).frame(width: x - unity, height: 4).offset(x: unity)
            }
            Rectangle().fill(Color.ink.opacity(0.35)).frame(width: 1, height: 9).offset(x: unity - 0.5)
            Circle()
                .fill(Color.white)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.15)))
                .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
                .frame(width: dragging ? 15 : 13, height: dragging ? 15 : 13)
                .offset(x: x - (dragging ? 7.5 : 6.5))
        }
        .frame(width: width, height: 18)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { drag in
                dragging = true
                set(Self.value(at: drag.location.x / width))
            }
            .onEnded { drag in
                dragging = false
                set(VolumeCurve.snapped(Self.value(at: drag.location.x / width)))
            })
        .simultaneousGesture(TapGesture(count: 2).onEnded { set(100) })
        .animation(Motion.micro, value: dragging)
        .help("Drag to set the level; past the mark is boost. Double-click for 100 %.")
        .accessibilityElement()
        .accessibilityLabel("Level")
        .accessibilityValue(VolumeCurve.label(value))
        .accessibilityAdjustableAction { direction in
            set(VolumeCurve.snapped(value + (direction == .increment ? 5 : -5)))
        }
    }
}

// MARK: - Page

struct SoundPage: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: "Sound",
                       subtitle: "Set any app's own level, up to 300 % for quiet ones, or mute it at your speakers and headphones. It keeps playing for anything that records it.",
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
            InkGroup("Apps", trailing: sound.muted.isEmpty && sound.volumes.isEmpty ? nil : AnyView(
                HStack(spacing: 6) {
                    if !sound.volumes.isEmpty {
                        Button("Levels to 100 %") { withAnimation(Motion.micro) { sound.resetVolumes() } }
                            .buttonStyle(OutlineButtonStyle(compact: true))
                    }
                    if !sound.muted.isEmpty {
                        Button("Unmute All") { withAnimation(Motion.micro) { sound.unmuteAll() } }
                            .buttonStyle(OutlineButtonStyle(compact: true))
                    }
                })) {
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
                note("Levels and boost", "Each app's own level, from silent to 300 %. Past 100 % a limiter keeps boosted sound from distorting. An app at 100 % goes straight to the speakers, untouched.")
                Hairline().opacity(0.6)
                note("Costs nothing while quiet", "Nothing runs until a muted or adjusted app plays a sound, and it stops half a second after. While one plays, macOS shows its audio-in-use dot.")
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
            VolumeSlider(value: sound.volume(of: app.bundleID), width: 170) { sound.setVolume(app.bundleID, $0) }
                .disabled(muted)
                .opacity(muted ? 0.4 : 1)
            Text(VolumeCurve.label(sound.volume(of: app.bundleID)))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(sound.volume(of: app.bundleID) > 100 ? Color.themeAccent : Color.ink2)
                .frame(width: 46, alignment: .trailing)
            Button {
                withAnimation(Motion.micro) { sound.setMuted(app.bundleID, !muted) }
            } label: {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(muted ? Color.ink : Color.ink3)
                    .frame(width: 30, height: 26)
                    .background(RoundedRectangle(cornerRadius: Radius.of(7), style: .continuous).fill(Color.ink.opacity(muted ? 0.1 : 0)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(muted ? "Unmute \(app.name)" : "Mute \(app.name)")
            .accessibilityLabel(muted ? "Unmute \(app.name)" : "Mute \(app.name)")
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
