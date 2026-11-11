//
//  ClickerPage.swift
//  Tutto
//
//  The auto clicker's page: start and stop, speed, which button and how, where, when it stops,
//  its shortcut and the ways out.
//

import AppKit
import SwiftUI
import TuttoKit

struct ClickerPage: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: "Auto Clicker",
                       subtitle: "Clicks for you at the speed you set, at the pointer or one spot, until you stop it or it reaches its limit.",
                       module: .clicker)
            if let clicker = model.clicker {
                ClickerSettingsView(clicker: clicker, model: model)
            } else {
                ModuleOffView(module: .clicker, model: model)
            }
        }
    }
}

private struct ClickerSettingsView: View {
    @Bindable var clicker: ClickerModule
    @Bindable var model: AppModel

    private var settings: ClickerSettings { clicker.settings }
    private var shortcut: String? { model.shortcuts.shortcut(for: .toggleClicker)?.displayString }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            InkGroup("Now") {
                LabeledRow(stateTitle, detail: clicker.notice ?? clicker.lastRun ?? "Starting here waits 2 s, so you can put the pointer where it should click.") {
                    Button(clicker.isOn ? "Stop" : "Start") { clicker.toggle(fromPanel: true) }
                        .buttonStyle(InkButtonStyle(compact: true))
                }
            }
            InkGroup("Speed") {
                LabeledRow("Clicks per second", detail: "One every \(Int((settings.interval * 1000).rounded())) ms. Up to 100.") {
                    InkStepper(label: "CPS", value: Int(settings.clicksPerSecond.rounded()), range: 1...100) { value in
                        clicker.update { $0.clicksPerSecond = Double(value) }
                    }
                }
                Hairline().opacity(0.6)
                LabeledRow("Random spread", detail: "Each wait varies a little, so the clicks aren't perfectly even. Some games look for that.") {
                    InkSegmented(selection: Binding(get: { spreadChoice }, set: { value in clicker.update { $0.jitter = value } }),
                                 options: [(0.0, "Off"), (0.1, "±10 %"), (0.25, "±25 %")])
                        .fixedSize()
                }
            }
            InkGroup("Clicks") {
                LabeledRow("Button") {
                    InkSegmented(selection: Binding(get: { settings.button }, set: { value in clicker.update { $0.button = value } }),
                                 options: ClickButton.allCases.map { ($0, $0.title) })
                        .fixedSize()
                }
                Hairline().opacity(0.6)
                LabeledRow("Each click", detail: settings.double ? "Two clicks, as a double click." : nil) {
                    InkSegmented(selection: Binding(get: { settings.double }, set: { value in clicker.update { $0.double = value } }),
                                 options: [(false, "Single"), (true, "Double")])
                        .fixedSize()
                }
                Hairline().opacity(0.6)
                LabeledRow("Where", detail: whereDetail) {
                    HStack(spacing: 8) {
                        InkSegmented(selection: Binding(get: { isPoint }, set: { point in
                            if point { clicker.pickPoint() } else { clicker.update { $0.target = .pointer } }
                        }), options: [(false, "Pointer"), (true, "One spot")])
                            .fixedSize()
                        if isPoint {
                            Button("Pick Again") { clicker.pickPoint() }
                                .buttonStyle(OutlineButtonStyle(compact: true))
                                .fixedSize()
                        }
                    }
                }
            }
            InkGroup("Stopping") {
                LabeledRow("Stop by itself", detail: stopDetail) {
                    HStack(spacing: 8) {
                        if case .afterClicks(let n) = settings.stop {
                            InkStepper(label: "clicks", value: n, range: 1...1_000_000) { value in clicker.update { $0.stop = .afterClicks(value) } }
                        }
                        if case .afterSeconds(let s) = settings.stop {
                            InkStepper(label: "s", value: Int(s), range: 1...86_400) { value in clicker.update { $0.stop = .afterSeconds(Double(value)) } }
                        }
                        InkSegmented(selection: Binding(get: { stopChoice }, set: { setStop($0) }),
                                     options: [(0, "Never"), (1, "Clicks"), (2, "Time")])
                            .fixedSize()
                    }
                }
                Hairline().opacity(0.6)
                LabeledRow("Shortcut", detail: settings.holdToClick ? "Clicks while you hold it." : "Starts and stops it, from any app (games too). An F-key works as well.") {
                    ShortcutRecorder(action: .toggleClicker, model: model)
                }
                Hairline().opacity(0.6)
                LabeledRow("Hold to click", detail: "The shortcut clicks only while it's held, instead of turning clicking on and off.") {
                    InkSwitch(isOn: Binding(get: { settings.holdToClick }, set: { on in clicker.update { $0.holdToClick = on } }),
                              label: "Hold to click")
                }
                Hairline().opacity(0.6)
                LabeledRow("A screen corner stops it", detail: "Push the pointer into any corner of the screen to stop, whatever app is in front.") {
                    InkSwitch(isOn: Binding(get: { settings.cornerStops }, set: { on in clicker.update { $0.cornerStops = on } }),
                              label: "A screen corner stops it")
                }
                Hairline().opacity(0.6)
                LabeledRow("Start delay", detail: "Wait before the first click when started with the shortcut. From the menu bar it always waits at least 2 s.") {
                    InkStepper(label: "s", value: Int(settings.startDelay), range: 0...10) { value in clicker.update { $0.startDelay = Double(value) } }
                }
            }
            Text("Some online games forbid auto clickers. Check a game's rules before you use one there.")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.ink3)
        }
    }

    private var stateTitle: String {
        switch clicker.state {
        case .idle: "Off"
        case .countdown(let n): "Clicking in \(n)…"
        case .clicking: "Clicking: \(clicker.clicks.formatted()) so far"
        }
    }

    private var spreadChoice: Double {
        [0.0, 0.1, 0.25].min { abs($0 - settings.jitter) < abs($1 - settings.jitter) } ?? 0
    }

    private var isPoint: Bool {
        if case .point = settings.target { return true }
        return false
    }

    private var whereDetail: String {
        if clicker.isPicking { return "Click anywhere to set the spot · Esc cancels." }
        if case .point(let x, let y) = settings.target { return "At \(Int(x)), \(Int(y)) on screen." }
        return "Wherever the pointer is at each click."
    }

    private var stopChoice: Int {
        switch settings.stop {
        case .never: 0
        case .afterClicks: 1
        case .afterSeconds: 2
        }
    }

    private var stopDetail: String {
        switch settings.stop {
        case .never: "Runs until you stop it (shortcut, corner or the switch in the menu bar)."
        case .afterClicks(let n): "Stops after \(n.formatted()) click\(n == 1 ? "" : "s")."
        case .afterSeconds(let s): "Stops after \(ClickerRules.duration(s))."
        }
    }

    private func setStop(_ choice: Int) {
        clicker.update {
            switch choice {
            case 1: if case .afterClicks = $0.stop {} else { $0.stop = .afterClicks(100) }
            case 2: if case .afterSeconds = $0.stop {} else { $0.stop = .afterSeconds(60) }
            default: $0.stop = .never
            }
        }
    }
}
