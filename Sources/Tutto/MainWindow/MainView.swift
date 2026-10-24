//
//  MainView.swift
//  Tutto
//
//  The full app: every reading in depth, every tool's settings, shortcuts and
//  permissions. A standard sidebar, monochrome symbols, hairlines between things.
//

import SwiftUI
import TuttoKit

enum MainPage: String, Hashable, CaseIterable, Identifiable {
    case overview
    case battery, cpu, gpu, memory, disk, network, sensors
    case clipboard, windows, switcher, strip, screenshots, archives, corner, wordCounter, sound
    case shortcuts, permissions, general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .battery: "Battery"
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "Memory"
        case .disk: "Disk"
        case .network: "Network"
        case .sensors: "Sensors & Fans"
        case .clipboard: "Clipboard"
        case .windows: "Windows"
        case .screenshots: "Screenshots"
        case .archives: "Archives"
        case .corner: "Trackpad Corner"
        case .wordCounter: "Word Counter"
        case .sound: "Sound"
        case .switcher: "Window Switcher"
        case .strip: "Scrolling Strip"
        case .shortcuts: "Shortcuts"
        case .permissions: "Permissions"
        case .general: "General"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .battery: "battery.75percent"
        case .cpu: "cpu"
        case .gpu: "square.stack.3d.up"
        case .memory: "memorychip"
        case .disk: "internaldrive"
        case .network: "arrow.up.arrow.down"
        case .sensors: "fan"
        case .clipboard: ModuleID.clipboard.symbol
        case .windows: ModuleID.windows.symbol
        case .screenshots: ModuleID.screenshots.symbol
        case .archives: ModuleID.archives.symbol
        case .corner: ModuleID.corner.symbol
        case .wordCounter: ModuleID.wordCounter.symbol
        case .sound: ModuleID.sound.symbol
        case .switcher: ModuleID.switcher.symbol
        case .strip: ModuleID.strip.symbol
        case .shortcuts: "command"
        case .permissions: "lock.shield"
        case .general: "gearshape"
        }
    }

    var module: ModuleID? {
        switch self {
        case .battery, .cpu, .gpu, .memory, .disk, .network: .system
        case .sensors: .sensors
        case .clipboard: .clipboard
        case .windows: .windows
        case .screenshots: .screenshots
        case .archives: .archives
        case .corner: .corner
        case .wordCounter: .wordCounter
        case .sound: .sound
        case .switcher: .switcher
        case .strip: .strip
        case .overview, .shortcuts, .permissions, .general: nil
        }
    }

    static let systemPages: [MainPage] = [.battery, .cpu, .gpu, .memory, .disk, .network, .sensors]
    static let toolPages: [MainPage] = [.clipboard, .windows, .switcher, .strip, .screenshots, .archives, .corner, .wordCounter, .sound]
    static let settingsPages: [MainPage] = [.shortcuts, .permissions, .general]
}

struct MainView: View {
    @Bindable var model: AppModel
    @Bindable var navigation: MainNavigation

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { navigation.page }, set: { if let page = $0 { navigation.page = page } })) {
                row(.overview)
                Section("System") {
                    ForEach(MainPage.systemPages.filter { $0 != .battery || model.system?.hasBattery != false }) { row($0) }
                }
                Section("Tools") {
                    ForEach(MainPage.toolPages) { row($0) }
                }
                Section("Settings") {
                    ForEach(MainPage.settingsPages) { row($0) }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            ScrollView {
                page(navigation.page)
                    .padding(.horizontal, 32)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // A new scroll view per page, so every page opens at its top instead of at the
            // previous page's scroll position.
            .id(navigation.page)
            .transition(.opacity)
            .animation(.easeOut(duration: 0.12), value: navigation.page)
            // The window keeps the page name (Window menu, Mission Control, VoiceOver), but not the
            // toolbar: there it floated, faint, over the scrolling page under the page's own title.
            .navigationTitle(navigation.page.title)
            .modifier(HideToolbarTitle())
        }
        .frame(minWidth: 780, minHeight: 520)
    }

    private func row(_ page: MainPage) -> some View {
        let off = page.module.map { !model.isEnabled($0) } ?? false
        return Label {
            Text(page.title)
        } icon: {
            Image(systemName: page.symbol)
        }
        .opacity(off ? 0.45 : 1)
        .tag(page)
        .help(off ? "\(page.module!.title) is off" : page.title)
    }

    @ViewBuilder
    private func page(_ page: MainPage) -> some View {
        switch page {
        case .overview: OverviewPage(model: model)
        case .battery: BatteryPage(model: model)
        case .cpu: CPUPage(model: model)
        case .gpu: GPUPage(model: model)
        case .memory: MemoryPage(model: model)
        case .disk: DiskPage(model: model)
        case .network: NetworkPage(model: model)
        case .sensors: SensorsPage(model: model)
        case .clipboard: ClipboardPage(model: model)
        case .windows: WindowsPage(model: model)
        case .screenshots: ScreenshotsPage(model: model)
        case .archives: ArchivesPage(model: model)
        case .corner: CornerPage(model: model)
        case .wordCounter: WordCounterPage(model: model)
        case .sound: SoundPage(model: model)
        case .switcher: SwitcherPage(model: model)
        case .strip: StripPage(model: model)
        case .shortcuts: ShortcutsPage(model: model)
        case .permissions: PermissionsPage(model: model)
        case .general: GeneralPage(model: model)
        }
    }
}

private struct HideToolbarTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.toolbar(removing: .title)
        } else {
            content
        }
    }
}

// MARK: - Page scaffolding

/// Title, the module's on/off switch, and one line saying what this is.
struct PageHeader: View {
    var title: String
    var subtitle: String
    var module: ModuleID?

    var body: some View {
        let model = AppModel.shared
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 26, weight: .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(Color.ink)
                Text(subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let module {
                ModuleSwitch(model: model, module: module)
            }
        }
        .padding(.bottom, 18)
    }
}

struct ModuleSwitch: View {
    @Bindable var model: AppModel
    var module: ModuleID

    var body: some View {
        HStack(spacing: 6) {
            Text(model.isEnabled(module) ? "On" : "Off")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.ink3)
                .contentTransition(.opacity)
            InkSwitch(isOn: Binding(get: { model.isEnabled(module) }, set: { model.setEnabled(module, $0) }),
                      label: module.title)
        }
        .help("Turn \(module.title) \(model.isEnabled(module) ? "off" : "on"). When it's off it uses nothing.")
    }
}

/// Shown in place of a page whose module is switched off.
struct ModuleOffView: View {
    var module: ModuleID
    var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(module.title) is off.")
                .font(.system(size: 15, weight: .semibold))
            Text("While it's off, it uses no memory, no CPU and no battery. \(module.summary)")
                .font(.system(size: 12.5))
                .foregroundStyle(Color.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Button("Turn On") { model.setEnabled(module, true) }
                .primaryButton()
                .padding(.top, 4)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.wash, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.hairline))
    }
}
