//
//  SettingsPages.swift
//  Tutto
//
//  Overview, Shortcuts, Permissions and General.
//

import AppKit
import SwiftUI
import TuttoKit

// MARK: - Overview

struct OverviewPage: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: "Tutto", subtitle: "Every Mac utility you actually use, in one quiet app.")
            if model.menuBarIconHidden {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "menubar.rectangle").font(.system(size: 18)).foregroundStyle(Color.ink2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("The menu bar icon is hidden behind the camera notch.").font(.system(size: 13, weight: .semibold))
                        Text("Your menu bar is full, so macOS placed Tutto's icon where the notch covers it. Quitting the apps Tutto replaces frees room; you can also hold ⌘ and drag menu bar icons to reorder them, or hide others in System Settings › Menu Bar.")
                            .font(.system(size: 12)).foregroundStyle(Color.ink2).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Check Again") { model.checkMenuBarIconVisibility() }
                        .buttonStyle(OutlineButtonStyle(compact: true))
                }
                .padding(14)
                .background(Color.wash, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            if let system = model.system {
                OverviewStats(monitor: system)
                    .watching(system, [.stats])
            }
            InkGroup("Tools") {
                ForEach(ModuleID.allCases) { module in
                    HStack(spacing: 12) {
                        Image(systemName: module.symbol)
                            .font(.system(size: 14))
                            .frame(width: 22)
                            .foregroundStyle(Color.ink2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(module.title).font(.system(size: 13, weight: .medium))
                            Text(module.summary).font(.system(size: 11.5)).foregroundStyle(Color.ink3)
                        }
                        Spacer()
                        shortcutHint(for: module)
                        ModuleSwitch(model: model, module: module)
                    }
                    .padding(.vertical, 7)
                    .overlay(alignment: .bottom) { if module != ModuleID.allCases.last { Hairline().opacity(0.6) } }
                }
            }
            ReplacedAppsNote(model: model)
        }
    }

    @ViewBuilder
    private func shortcutHint(for module: ModuleID) -> some View {
        let action: ShortcutAction? = switch module {
        case .clipboard: .clipboardHistory
        case .windows: .windowPalette
        case .screenshots: .captureArea
        default: nil
        }
        if let action, model.isEnabled(module) {
            KeyCaps(shortcut: model.shortcuts.shortcut(for: action), compact: true)
        }
    }
}

private struct OverviewStats: View {
    var monitor: SystemMonitor

    var body: some View {
        HStack(spacing: 0) {
            if let battery = monitor.battery {
                stat("Battery", "\(battery.percent)", "%", detail: "health \(Format.percent(battery.health, digits: 1))%", page: .battery)
                Hairline(vertical: true).padding(.vertical, 8)
            }
            stat("CPU", Format.percent(monitor.cpu.total), "%", detail: CPUReader.topology.brand, page: .cpu)
            Hairline(vertical: true).padding(.vertical, 8)
            stat("GPU", Format.percent(monitor.gpu?.utilization ?? 0), "%", detail: monitor.gpu?.model ?? "", page: .gpu)
            Hairline(vertical: true).padding(.vertical, 8)
            stat("Memory", Format.percent(monitor.memory?.usedFraction ?? 0), "%",
                 detail: monitor.memory.map { "pressure \($0.pressure.label.lowercased())" } ?? "", page: .memory)
            Hairline(vertical: true).padding(.vertical, 8)
            let free = Format.diskParts(monitor.rootVolume?.available ?? 0)
            stat("Disk", free.0, free.1, detail: "free", page: .disk)
        }
        .padding(.vertical, 6)
        .background(Color.wash.opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.hairline))
    }

    private func stat(_ caption: String, _ value: String, _ unit: String, detail: String, page: MainPage) -> some View {
        Button {
            MainWindowController.shared.navigation.page = page
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Readout(caption: caption, value: value, unit: unit, large: true)
                Text(detail).font(.system(size: 11)).foregroundStyle(Color.ink3).lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The apps Tutto replaces that are still running, with what to do about each.
struct ReplacedAppsNote: View {
    var model: AppModel
    @State private var tick = 0

    var body: some View {
        let running = model.runningReplacedApps()
        if !running.isEmpty {
            InkGroup("Still running", trailing: AnyView(Caption("replaced by Tutto"))) {
                ForEach(running) { app in
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name).font(.system(size: 13, weight: .medium))
                            Text(app.advice).font(.system(size: 11.5)).foregroundStyle(Color.ink3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if app.canQuit {
                            Button("Quit \(app.name)") {
                                model.quit(app)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { tick += 1 }
                            }
                            .buttonStyle(OutlineButtonStyle(compact: true))
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            .id(tick)
        }
    }
}

// MARK: - Shortcuts

struct ShortcutsPage: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: "Shortcuts", subtitle: "Click a shortcut, then press the keys you want. Esc cancels, Delete removes it.")
            group("Everyday", [.captureArea, .captureScreen, .captureAreaEdit, .clipboardHistory, .windowPalette])
            group("App", [.openTutto, .toggleCornerClick])
            group("Window actions", WindowAction.allCases.map { .window($0) })
            HStack {
                Spacer()
                Button("Restore Defaults") { model.resetShortcuts() }
                    .buttonStyle(OutlineButtonStyle(compact: true))
                    .disabled(!model.shortcuts.isCustomized)
            }
        }
    }

    private func group(_ title: String, _ actions: [ShortcutAction]) -> some View {
        InkGroup(title) {
            ForEach(actions) { action in
                let off = action.module.map { !model.isEnabled($0) } ?? false
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(action.title).font(.system(size: 12.5))
                        if off, let module = action.module {
                            Text("\(module.title) is off").font(.system(size: 11)).foregroundStyle(Color.ink3)
                        } else if model.hotkeys.failed.contains(action.id) {
                            Text("macOS didn't accept this shortcut").font(.system(size: 11)).foregroundStyle(Color.alert)
                        } else if let owner = ExternalShortcuts.runningOwner(of: model.shortcuts.shortcut(for: action)) {
                            Text("\(owner) is running and may also respond to this").font(.system(size: 11)).foregroundStyle(Color.ink2)
                        }
                    }
                    Spacer()
                    ShortcutRecorder(action: action, model: model)
                }
                .frame(minHeight: 34)
                .opacity(off ? 0.5 : 1)
                .overlay(alignment: .bottom) { if action != actions.last { Hairline().opacity(0.6) } }
            }
        }
    }
}

// MARK: - Permissions

struct PermissionsPage: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: "Permissions",
                       subtitle: "What macOS asks you to approve, and exactly what each one is for. Tutto has no network code.")
            InkGroup {
                ForEach(Permission.allCases) { permission in
                    PermissionRow(permission: permission, model: model)
                        .overlay(alignment: .bottom) { if permission != Permission.allCases.last { Hairline().opacity(0.6) } }
                }
            }
            InkGroup("Also good to know") {
                note("Files & folders", "The first time Tutto saves to Downloads or extracts an archive in Desktop, Documents or Downloads, macOS asks once.")
                note("Not needed", "Input Monitoring, Full Disk Access, Location, Camera, Microphone, Contacts.")
                note("Screen Recording", "macOS may ask you to re-confirm screen recording from time to time; that's macOS, not a problem with Tutto.")
            }
        }
        .background(VisibilityReader { visible in if visible { model.permissions.refresh() } })
    }

    private func note(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 12.5, weight: .medium))
            Text(text).font(.system(size: 11.5)).foregroundStyle(Color.ink3).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 7)
    }
}

struct PermissionRow: View {
    var permission: Permission
    @Bindable var model: AppModel

    var body: some View {
        let granted = model.permissions.isGranted(permission)
        let needed = permission.modules.contains { model.isEnabled($0) }
        HStack(alignment: .center, spacing: 12) {
            StatusDot(on: granted == true)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title).font(.system(size: 13, weight: .medium))
                Text(permission.powers).font(.system(size: 11.5)).foregroundStyle(Color.ink3)
                Text(permission.settingsPath).font(.mono(10)).foregroundStyle(Color.ink4)
            }
            Spacer()
            if granted == true {
                Text("Allowed").font(.system(size: 12)).foregroundStyle(Color.ink2)
            } else if !needed {
                Text("Not needed").font(.system(size: 12)).foregroundStyle(Color.ink3)
            } else {
                Button(granted == nil && permission == .finderExtension ? "Turn On" : "Allow") {
                    model.permissions.request(permission)
                }
                .buttonStyle(InkButtonStyle(compact: true))
            }
        }
        .padding(.vertical, 9)
    }
}

// MARK: - General

struct GeneralPage: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: "General", subtitle: "Turn any tool off and it stops completely: no memory, no CPU, no battery.")
            InkGroup("Tools") {
                ForEach(ModuleID.allCases) { module in
                    HStack(spacing: 12) {
                        Image(systemName: module.symbol).frame(width: 20).foregroundStyle(Color.ink2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(module.title).font(.system(size: 13, weight: .medium))
                            Text(module.idleCost).font(.system(size: 11.5)).foregroundStyle(Color.ink3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        ModuleSwitch(model: model, module: module)
                    }
                    .padding(.vertical, 8)
                    .overlay(alignment: .bottom) { if module != ModuleID.allCases.last { Hairline().opacity(0.6) } }
                }
            }
            InkGroup("App") {
                LabeledRow("Open at login", detail: "Tutto starts quietly in the menu bar.") {
                    InkSwitch(isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }),
                              label: "Open at login")
                }
                LabeledRow("Welcome tour", detail: "Permissions, shortcuts and the CornerClick test again.") {
                    Button("Show") { OnboardingWindowController.shared.show() }
                        .buttonStyle(OutlineButtonStyle(compact: true))
                }
            }
            ReplacedAppsNote(model: model)
            AboutFooter()
        }
    }
}

private struct AboutFooter: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: MenuBarGlyph.image()).renderingMode(.template).foregroundStyle(Color.ink3)
            Text("Tutto \(Bundle.main.shortVersion) · Made by Bryan Yao · No analytics, no network code")
                .font(.system(size: 11))
                .foregroundStyle(Color.ink3)
        }
        .padding(.top, 6)
    }
}

extension Bundle {
    var shortVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0" }
}

// MARK: - CornerClick

struct CornerClickPage: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: "CornerClick",
                       subtitle: "Click or tap a bottom corner of the trackpad to right-click. Two-finger right-click keeps working.",
                       module: .cornerClick)
            if let module = model.cornerClick {
                CornerClickPageContent(module: module)
            } else {
                ModuleOffView(module: .cornerClick, model: model)
            }
        }
    }
}

private struct CornerClickPageContent: View {
    @Bindable var module: CornerClickModule

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if module.status == .needsPermission {
                AccessibilityCard(purpose: "CornerClick needs Accessibility access to turn a corner click into a right-click. It never reads what you type, and nothing leaves your Mac.")
            }
            HStack(alignment: .top, spacing: 28) {
                CornerClickEditor(module: module)
                    .frame(maxWidth: 420)
                VStack(alignment: .leading, spacing: 14) {
                    LabeledRow("Active", detail: module.statusText) {
                        InkSwitch(isOn: $module.isEnabled, label: "CornerClick",
                                  active: module.status.isRunning || !module.isEnabled)
                    }
                    Hairline()
                    Text("Put a finger on the trackpad and watch it appear. Drag anywhere on the drawing to size the corner, or click the other corner to switch sides.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Set Up & Test…") { OnboardingWindowController.shared.show(step: .cornerClick) }
                        .buttonStyle(OutlineButtonStyle(compact: true))
                }
            }
            InkGroup("Troubleshooting") {
                LabeledRow("Diagnostics log",
                           detail: "One line per trackpad click (finger positions and decisions only) in ~/Library/Logs/CornerClick/clicks.log.") {
                    HStack(spacing: 8) {
                        if module.diagnostics {
                            Button("Reveal") {
                                NSWorkspace.shared.activateFileViewerSelecting([CornerClickDiagnostics.fileURL])
                            }
                            .buttonStyle(OutlineButtonStyle(compact: true))
                        }
                        InkSwitch(isOn: $module.diagnostics, label: "Diagnostics log")
                    }
                }
                Hairline().opacity(0.6)
                LabeledRow("Reset corner size", detail: "Back to Medium.") {
                    Button("Reset") { module.zoneIsCustom = false; module.resetZone() }
                        .buttonStyle(OutlineButtonStyle(compact: true))
                }
            }
        }
    }
}
