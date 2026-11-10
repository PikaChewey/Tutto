//
//  StayAwakePage.swift
//  Tutto
//
//  Stay Awake's page in the app: the session, what closing the lid does (and which apps it
//  pauses), the battery and heat rules, the end, and the hotspot option (off until turned on).
//

import AppKit
import SwiftUI
import TuttoKit

struct StayAwakePage: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: "Stay Awake",
                       subtitle: "Keep the Mac on for a time you choose, lid closed included, so agents keep working. While the lid is shut it goes easy on the battery.",
                       module: .awake)
            if let awake = model.awake {
                StayAwakeSettings(awake: awake)
            } else {
                ModuleOffView(module: .awake, model: model)
            }
        }
    }
}

private struct StayAwakeSettings: View {
    @Bindable var awake: StayAwakeModule
    @State private var apps: [(app: AwakeApp, pauses: Bool, icon: NSImage?)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            sessionGroup
            lidGroup
            appsGroup
            batteryGroup
            endGroup
            HotspotGroup(awake: awake)
            Text("Use it on a desk or another hard surface, not in a bag: a closed Mac that's working still makes heat. Scripts and agents can start it too: `open \"tutto://do/stay-awake?for=2h\"`, and end it with `tutto://do/stay-awake-end`.")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .onAppear {
            awake.refreshHelperStatus()
            apps = awake.pauseList()
        }
    }

    private var sessionGroup: some View {
        InkGroup("Now") {
            if let session = awake.session {
                LabeledRow("Awake until \(session.endsAt.formatted(date: .abbreviated, time: .shortened))",
                           detail: awake.lidSafe ? "Close the lid whenever you like." : awake.notice) {
                    HStack(spacing: 8) {
                        Button("+1h") { awake.start(for: 3600) }.buttonStyle(OutlineButtonStyle(compact: true))
                        Button("End") { awake.endNow() }.buttonStyle(OutlineButtonStyle(compact: true))
                    }
                }
            } else {
                LabeledRow("Asleep as usual", detail: awake.lastEnded.map { "Last session: \($0)." } ?? "Start one from the menu bar: type a time, or pick one.") {
                    HStack(spacing: 6) {
                        ForEach(AwakeDuration.presets, id: \.self) { seconds in
                            Button(AwakeDuration.label(seconds)) { awake.start(for: seconds) }
                                .buttonStyle(OutlineButtonStyle(compact: true))
                        }
                    }
                }
            }
        }
    }

    private var lidGroup: some View {
        InkGroup("When the lid closes") {
            LabeledRow("Keep running with the lid closed",
                       detail: awake.helperStatus == .enabled
                           ? "Tutto's helper holds sleep off for the session and lets go at its end, even if Tutto quits or stops."
                           : "Needs Tutto's helper, approved once (the same one fan control uses). Without it, the Mac stays on only while the lid is open.") {
                if awake.helperStatus == .enabled {
                    StatusDot(on: true)
                } else {
                    Button(awake.helperStatus == .requiresApproval ? "Approve" : "Set Up") { awake.setUpHelper() }
                        .buttonStyle(InkButtonStyle(compact: true))
                }
            }
            Hairline().opacity(0.6)
            toggle("Turn off the display and keyboard light", detail: DisplayBrightness.refusal ?? KeyboardLight.refusal
                       ?? "With sleep off, macOS leaves them lit under the lid. Both come back as they were.", \.darkenWhenClosed)
            Hairline().opacity(0.6)
            toggle("Low Power Mode", detail: "Slower when busy, much easier on the battery; agents mostly wait on the network. Back as it was when the lid opens.", \.lowPowerWhenClosed)
            Hairline().opacity(0.6)
            toggle("Mute the sound", detail: "Unmuted when the lid opens.", \.muteWhenClosed)
            Hairline().opacity(0.6)
            toggle("Pause apps that don't need to run", detail: "Paused apps stop using the processor and network, and carry on where they were when the lid opens.", \.pauseAppsWhenClosed)
            Text("With another display connected, closing the lid is a desk set-up, and none of this happens.")
                .font(.system(size: 11)).foregroundStyle(Color.ink3)
                .padding(.bottom, Metrics.rowPadding)
        }
    }

    private var appsGroup: some View {
        InkGroup("Apps paused while the lid is closed", trailing: AnyView(
            Button("Refresh") { apps = awake.pauseList() }.buttonStyle(OutlineButtonStyle(compact: true)))) {
            if apps.isEmpty {
                Text("No apps open.").font(.system(size: 12)).foregroundStyle(Color.ink3)
                    .padding(.vertical, Metrics.rowPadding)
            }
            ForEach(Array(apps.enumerated()), id: \.element.app.bundleID) { index, entry in
                HStack(spacing: 10) {
                    if let icon = entry.icon {
                        Image(nsImage: icon).resizable().interpolation(.high).frame(width: 18, height: 18)
                    }
                    Text(entry.app.name).font(.system(size: 12.5)).foregroundStyle(Color.ink)
                    Spacer()
                    InkSwitch(isOn: Binding(get: { entry.pauses }, set: { on in
                        awake.setPauses(entry.app, on)
                        apps = awake.pauseList()
                    }), label: "Pause \(entry.app.name)")
                }
                .padding(.vertical, 6)
                .opacity(awake.policy.pauseAppsWhenClosed ? 1 : 0.45)
                if index < apps.count - 1 { Hairline().opacity(0.6) }
            }
            Text("Chat, social, game and entertainment apps are paused unless you switch them off here; anything else only if you switch it on. macOS's own apps are never paused.")
                .font(.system(size: 11)).foregroundStyle(Color.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, Metrics.rowPadding)
        }
    }

    private var batteryGroup: some View {
        InkGroup("Battery and heat") {
            LabeledRow("Low Power Mode below", detail: "On battery, lid open or closed. 0 turns it off.") {
                InkStepper(label: "%", value: awake.policy.lowPowerBelow, range: 0...95) { value in
                    awake.update { $0.lowPowerBelow = value }
                }
            }
            Hairline().opacity(0.6)
            LabeledRow("End the session below", detail: "On battery, so it's never drained flat. 0 turns it off.") {
                InkStepper(label: "%", value: awake.policy.endBelow, range: 0...50) { value in
                    awake.update { $0.endBelow = value }
                }
            }
            Hairline().opacity(0.6)
            toggle("Heat rules", detail: "Low Power Mode when the Mac runs hot; the session ends if it gets critically hot.", \.heatRules)
        }
    }

    private var endGroup: some View {
        InkGroup("At the end") {
            toggle("Sleep right away if the lid is closed", detail: "Rather than staying on until the lid is opened. Not with another display connected.", \.sleepWhenDoneClosed)
            Hairline().opacity(0.6)
            toggle("Show the time left in the menu bar", detail: "Beside Tutto's icon, in minutes.", \.showTimeInMenuBar)
        }
    }

    private func toggle(_ title: String, detail: String?, _ key: WritableKeyPath<AwakePolicy, Bool>) -> some View {
        LabeledRow(title, detail: detail) {
            InkSwitch(isOn: Binding(get: { awake.policy[keyPath: key] }, set: { on in awake.update { $0[keyPath: key] = on } }),
                      label: title)
        }
    }
}

/// The hotspot option: off until switched on. With it on, a session that loses its network joins
/// the hotspot named here.
private struct HotspotGroup: View {
    @Bindable var awake: StayAwakeModule
    @State private var ssid = ""
    @State private var password = ""
    @State private var saved: String?
    @State private var hasPassword = false

    var body: some View {
        InkGroup("Hotspot") {
            LabeledRow("Join a hotspot if the network drops",
                       detail: "During a session, after 5 s without a network, Tutto joins your phone's hotspot so agents' requests keep going through. Off unless you turn it on.") {
                InkSwitch(isOn: $awake.hotspotEnabled, label: "Join a hotspot if the network drops")
            }
            if awake.hotspotEnabled {
                Hairline().opacity(0.6)
                LabeledRow("Hotspot name", detail: "As it appears in the Wi-Fi menu.") {
                    TextField("My iPhone", text: $ssid)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                        .onSubmit(commitName)
                }
                Hairline().opacity(0.6)
                LabeledRow("Password", detail: hasPassword ? "Saved in your login keychain." : "Kept in your login keychain, never shown again.") {
                    HStack(spacing: 8) {
                        SecureField(hasPassword ? "••••••••" : "Password", text: $password)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 150)
                            .onSubmit(save)
                        Button(saved ?? "Save", action: save)
                            .buttonStyle(OutlineButtonStyle(compact: true))
                            .disabled(password.isEmpty || ssid.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Hairline().opacity(0.6)
                let location = awake.locationAccess()
                LabeledRow("Location Services", detail: "macOS shows Wi-Fi names only to apps allowed Location Services. Tutto never reads your location.") {
                    if location.isAllowed {
                        StatusDot(on: true)
                    } else if location.isDenied {
                        Button("Open Settings") { location.openSettings() }.buttonStyle(OutlineButtonStyle(compact: true))
                    } else {
                        Button("Allow") { location.request() }.buttonStyle(InkButtonStyle(compact: true))
                    }
                }
                Text("Personal Hotspot has to be on on the phone. For the Mac to also join it on its own, set System Settings › Wi-Fi › Ask to join hotspots to Automatically.")
                    .font(.system(size: 11)).foregroundStyle(Color.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, Metrics.rowPadding)
            }
        }
        .animation(Motion.snappy, value: awake.hotspotEnabled)
        .onAppear {
            ssid = awake.hotspotSSID
            hasPassword = !ssid.isEmpty && HotspotKeychain.hasPassword(for: ssid)
        }
    }

    private func commitName() {
        let name = ssid.trimmingCharacters(in: .whitespaces)
        guard name != awake.hotspotSSID else { return }
        awake.hotspotSSID = name
        hasPassword = !name.isEmpty && HotspotKeychain.hasPassword(for: name)
    }

    private func save() {
        commitName()
        let name = awake.hotspotSSID
        guard !name.isEmpty, !password.isEmpty else { return }
        if let error = HotspotKeychain.save(password, for: name) {
            saved = nil
            awake.locationAccess().request()
            NSSound.beep()
            awakeLog.error("hotspot password: \(error, privacy: .public)")
            return
        }
        password = ""
        hasPassword = true
        saved = "Saved"
        awake.locationAccess().request()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saved = nil }
    }
}
