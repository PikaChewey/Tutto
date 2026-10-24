//
//  Onboarding.swift
//  Tutto
//
//  First run in four short steps: what's inside (switch anything off), the two
//  permissions that matter with live status, the shortcuts, and Trackpad Corner's magic
//  moment — press the corner and watch the right-click land.
//

import AppKit
import SwiftUI
import TuttoKit

enum OnboardingStep: Int, CaseIterable {
    case welcome, permissions, shortcuts, corner

    var label: String {
        switch self {
        case .welcome: "Tools"
        case .permissions: "Access"
        case .shortcuts: "Keys"
        case .corner: "Try it"
        }
    }
}

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()
    private var window: NSWindow?

    func show(step: OnboardingStep = .welcome) {
        if window == nil {
            let hosting = NSHostingController(rootView: OnboardingView(model: AppModel.shared, start: step) { [weak self] in
                guard let window = self?.window else { return }
                window.sheetParent?.endSheet(window)
                window.close()
            })
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.collectionBehavior = AppActivation.windowBehavior
            window.title = "Welcome to Tutto"
            window.delegate = self
            // Size it before centering; SwiftUI would otherwise grow it from its top-left corner later.
            window.setContentSize(hosting.view.fittingSize)
            window.center()
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        guard let window, window.sheetParent == nil else { return }
        // Opened from the main window (Welcome tour › Show): a sheet on it, so it is always on the
        // same Space. Over a full-screen app a second window of its own landed on another Space.
        if let host = MainWindowController.shared.openWindow {
            AppActivation.present(host)
            host.beginSheet(window)
        } else {
            AppActivation.present(window)
        }
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        AppModel.shared.completeOnboarding()
        DispatchQueue.main.async {
            MainActor.assumeIsolated { AppActivation.update() }
        }
    }
}

struct OnboardingView: View {
    @Bindable var model: AppModel
    var start: OnboardingStep
    var close: () -> Void

    @State private var step: OnboardingStep = .welcome
    @State private var pulseAtStart: Int?
    @State private var openAtLogin = true
    @State private var poll: Timer?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Caption("0\(step.rawValue + 1) / 0\(OnboardingStep.allCases.count)  \(step.label)")
                    .contentTransition(.numericText())
                Spacer()
                if step != .corner {
                    Button("Skip") { finish() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.ink3)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 40)

            Group {
                switch step {
                case .welcome: welcome
                case .permissions: permissions
                case .shortcuts: shortcuts
                case .corner: corner
                }
            }
            .id(step)
            .transition(reduceMotion ? .opacity : .entrance)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 32)
            .padding(.top, 18)

            footer
                .padding(.horizontal, 32)
                .padding(.bottom, 28)
        }
        .frame(width: 480, height: 600)
        .background(Color.canvas)
        .animation(Motion.smooth, value: step)
        .onAppear {
            step = start
            if step == .corner, model.corner == nil { step = .shortcuts }
        }
        .onChange(of: step) { _, newValue in
            pollPermissions(newValue == .permissions)
            if newValue == .corner { pulseAtStart = model.corner?.pulse }
        }
        .onDisappear { pollPermissions(false) }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("One app, all of it.")
                    .font(.system(size: 30, weight: .semibold))
                    .tracking(-0.6)
                Text("Eleven quiet tools in your menu bar. Keep what you use — anything you switch off uses nothing.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Color.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                ForEach(ModuleID.allCases) { module in
                    HStack(spacing: 12) {
                        Image(systemName: module.symbol).frame(width: 20).foregroundStyle(Color.ink2)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(module.title).font(.system(size: 13, weight: .medium))
                            Text(module.summary).lineLimit(1).font(.system(size: 11)).foregroundStyle(Color.ink3)
                        }
                        Spacer()
                        InkSwitch(isOn: Binding(get: { model.isEnabled(module) }, set: { model.setEnabled(module, $0) }),
                                  label: module.title)
                    }
                    .frame(height: 44)
                    .overlay(alignment: .bottom) { if module != ModuleID.allCases.last { Hairline().opacity(0.6) } }
                }
            }
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("A few switches in Settings.")
                    .font(.system(size: 30, weight: .semibold))
                    .tracking(-0.6)
                Text("macOS asks you to approve these yourself. Each one powers only what it says. No network, no analytics.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Color.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                ForEach([Permission.accessibility, .screenRecording, .finderExtension]) { permission in
                    PermissionRow(permission: permission, model: model)
                        .overlay(alignment: .bottom) { if permission != .finderExtension { Hairline().opacity(0.6) } }
                }
            }
            Text("Fan control asks for its own approval later, only if you use it.")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.ink3)
        }
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Six keys to remember.")
                    .font(.system(size: 30, weight: .semibold))
                    .tracking(-0.6)
                Text("The same ones you already use. Change any of them later in Tutto › Shortcuts.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Color.ink2)
            }
            VStack(spacing: 0) {
                ForEach([ShortcutAction.captureArea, .captureScreen, .captureAreaEdit, .clipboardHistory, .windowPalette, .wordCounter]) { action in
                    HStack {
                        Text(action.title).font(.system(size: 13))
                        Spacer()
                        KeyCaps(shortcut: model.shortcuts.shortcut(for: action))
                    }
                    .frame(height: 40)
                    .opacity(action.module.map { model.isEnabled($0) } ?? true ? 1 : 0.35)
                    .overlay(alignment: .bottom) { if action != .windowPalette { Hairline().opacity(0.6) } }
                }
            }
            Text("Click the menu bar icon any time for battery, system load, Trackpad Corner and these shortcuts.")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.ink3)
        }
    }

    @ViewBuilder
    private var corner: some View {
        if let module = model.corner {
            let landed = pulseAtStart.map { module.pulse > $0 } ?? false
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(landed ? "That's a right-click." : "Now press the corner.")
                        .font(.system(size: 30, weight: .semibold))
                        .tracking(-0.6)
                        .contentTransition(.opacity)
                    Text(landed
                         ? "Resize the corner or switch sides any time from the menu bar."
                         : "Put a finger on your trackpad and watch it appear. Then click or tap the \(module.cornerName) corner.")
                        .font(.system(size: 13.5))
                        .foregroundStyle(Color.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if module.status == .needsPermission {
                    AccessibilityCard(purpose: "Trackpad Corner needs Accessibility access to turn a corner press into a right-click.")
                } else {
                    TrackpadView(contacts: module.contacts, zone: Binding(get: { module.zone }, set: { module.zone = $0 }),
                                 size: module.trackpadSize, pulse: module.pulse, editable: false, lit: landed)
                        .background(VisibilityReader { visible in visible ? module.beginWatching() : module.endWatching() })
                }
                if landed {
                    InkCheck(title: "Open Tutto at login", isOn: $openAtLogin)
                }
            }
            .onChange(of: landed) { _, newValue in
                if newValue {
                    NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                    NSSound(named: "Tink")?.play()
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if step != .welcome {
                QuietButton(title: "Back") {
                    if let previous = OnboardingStep(rawValue: step.rawValue - 1) { step = previous }
                }
            }
            Spacer()
            Button {
                advance()
            } label: {
                Text(nextTitle).frame(minWidth: 120)
            }
            .primaryButton()
            .keyboardShortcut(.defaultAction)
        }
    }

    private var nextTitle: String {
        switch step {
        case .corner: "Done"
        case .shortcuts: model.corner == nil ? "Done" : "Continue"
        default: "Continue"
        }
    }

    private func advance() {
        if step == .corner || (step == .shortcuts && model.corner == nil) {
            finish()
        } else if let next = OnboardingStep(rawValue: step.rawValue + 1) {
            step = next
        }
    }

    private func finish() {
        if !model.hasCompletedOnboarding && openAtLogin && !model.launchAtLogin {
            model.setLaunchAtLogin(true)
        }
        model.completeOnboarding()
        close()
    }

    /// Screen Recording has no change notification; check once a second, only on this step.
    private func pollPermissions(_ on: Bool) {
        poll?.invalidate()
        poll = nil
        guard on else { return }
        model.permissions.refresh()
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { model.permissions.refresh() }
        }
    }
}
