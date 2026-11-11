//
//  PluginsPage.swift
//  Tutto
//
//  Tutto's tools as plugins you switch on and off, and your own (Bryan, 2026-11-10: "plugins that
//  add real features"): actions you run, cards for the panel with live readings, automations that
//  run when something happens, each with the settings it asks for. Each of yours is a JSON file
//  (or a folder) in the Plugins folder; this page reads the folder whenever it opens.
//

import AppKit
import SwiftUI
import TuttoKit

struct PluginsPage: View {
    @Bindable var model: AppModel
    @State private var editing: PluginDraft?
    @State private var showingGuide = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: "Plugins",
                       subtitle: "Tutto is made of plugins: switch on only what you use; anything off costs nothing. Add your own: actions you run, cards with live readings for the panel, automations that run when something happens.")
            yours
            builtIn
        }
        .onAppear { model.plugins.load() }
        .sheet(item: $editing) { draft in
            PluginEditor(model: model, draft: draft) { editing = nil }
        }
        .sheet(isPresented: $showingGuide) {
            PluginGuide { showingGuide = false }
        }
    }

    // MARK: Built in

    private var builtIn: some View {
        InkGroup("Built in") {
            ForEach(Array(ModuleID.allCases.enumerated()), id: \.element) { index, module in
                HStack(spacing: 12) {
                    Image(systemName: module.symbol)
                        .frame(width: 20)
                        .foregroundStyle(model.isEnabled(module) ? Color.ink2 : Color.ink4)
                    VStack(alignment: .leading, spacing: Metrics.titleToDetail) {
                        Text(module.title).font(.system(size: 13, weight: .medium))
                        Text(module.summary).font(.system(size: 11.5)).foregroundStyle(Color.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .help("While it's on and you're not using it: \(module.idleCost)")
                    Spacer(minLength: 12)
                    QuietButton(title: "Settings") { MainWindowController.shared.show(page: module.page) }
                    if module == .strip {
                        // It rearranges every window, so it's switched on where that's explained. Its
                        // state reads like the others, with the switch's room kept so the columns line up.
                        HStack(spacing: 6) {
                            Text(model.isEnabled(.strip) ? "On" : "Off")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Color.ink3)
                            InkSwitch(isOn: .constant(false), label: "").hidden().accessibilityHidden(true)
                        }
                        .help("It rearranges every window, so it's switched on from its own page, where that's explained.")
                    } else {
                        ModuleSwitch(model: model, module: module)
                    }
                }
                .padding(.vertical, Metrics.rowPadding)
                if index < ModuleID.allCases.count - 1 { Hairline().opacity(0.6) }
            }
        }
    }

    // MARK: Yours

    private var yours: some View {
        VStack(alignment: .leading, spacing: 8) {
            InkGroup("Your plugins", trailing: AnyView(newMenu)) {
                if model.plugins.plugins.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("None yet").font(.system(size: 12.5)).foregroundStyle(Color.ink)
                        Text("A plugin can be an action (tidy what you copied, open a project), a card with a live reading on the panel (a repository's changes, a server's ping), or an automation (a notice when the battery runs low, a sound when your agents finish). Start from a template or a blank one.")
                            .font(.system(size: 11.5)).foregroundStyle(Color.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Metrics.rowPadding)
                }
                ForEach(Array(model.plugins.plugins.enumerated()), id: \.element.id) { index, plugin in
                    PluginRow(model: model, plugin: plugin) { editing = PluginDraft(plugin: plugin, isNew: false) }
                    if index < model.plugins.plugins.count - 1 { Hairline().opacity(0.6) }
                }
            }
            if !model.plugins.problems.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(model.plugins.problems, id: \.self) { problem in
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.ink2)
                    }
                }
                .padding(.horizontal, 2)
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Each plugin is a file (or a folder with its scripts) in \(model.plugins.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")): share one by sending it, or edit it by hand and come back here. Scripts run one with `open -g \"tutto://do/plugin?name=…\"` and send events with `open -g \"tutto://do/event?name=…\"`.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 6) {
                    Button("Show Folder") {
                        try? FileManager.default.createDirectory(at: model.plugins.folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([model.plugins.folder])
                    }
                    .buttonStyle(OutlineButtonStyle(compact: true))
                    QuietButton(title: "How they work") { showingGuide = true }
                }
                .fixedSize()
            }
            .padding(.horizontal, 2)
        }
    }

    private var newMenu: some View {
        Menu {
            Button("Blank Plugin") {
                editing = PluginDraft(plugin: ScriptPlugin(name: "", command: ""), isNew: true)
            }
            ForEach(ScriptPlugin.templateGroups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.plugins, id: \.name) { template in
                        Button(template.name) {
                            var plugin = template
                            plugin.id = UUID()
                            editing = PluginDraft(plugin: plugin, isNew: true)
                        }
                    }
                }
            }
        } label: {
            Text("New Plugin")
                .font(.system(size: 11.5, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("New plugin")
    }
}

/// One of your plugins: what kind it is and when it runs, its keys, run it, switch it, edit it.
private struct PluginRow: View {
    var model: AppModel
    var plugin: ScriptPlugin
    var edit: () -> Void

    var body: some View {
        let running = model.plugins.running.contains(plugin.id)
        let standing = model.plugins.standing(plugin)
        let isNew = standing != .approved
        let on = model.plugins.isOn(plugin)
        HStack(spacing: 12) {
            Image(systemName: plugin.symbol)
                .font(.system(size: 13))
                .frame(width: 20)
                .foregroundStyle(on ? Color.ink2 : Color.ink4)
            VStack(alignment: .leading, spacing: Metrics.titleToDetail) {
                HStack(spacing: 6) {
                    Text(plugin.name).font(.system(size: 13, weight: .medium))
                    ForEach(plugin.kinds, id: \.self) { kind in Tag(text: kind) }
                    if isNew { Tag(text: standing == .changed ? "Changed" : "New", accent: true) }
                    if model.plugins.isInPanel(plugin) && plugin.hasAction {
                        Text("in the tools row").font(.system(size: 10.5)).foregroundStyle(Color.ink3)
                    }
                }
                Text(summary)
                    .font(.system(size: 11, design: plugin.triggers.isEmpty && plugin.hasAction && !plugin.hasWidget ? .monospaced : .default))
                    .foregroundStyle(Color.ink3)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if isNew {
                    Text(standing == .changed
                         ? "Changed on disk since you switched it on: see what it runs now (Edit), then switch it on again."
                         : "Added by hand: see what it runs (Edit), then switch it on.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let line = statusLine {
                    Text(line.text)
                        .font(.system(size: 10.5))
                        .foregroundStyle(line.failed ? Color.alert : Color.ink3)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            // Its keys when it has some (one is set in its editor).
            if let shortcut = model.shortcuts.shortcut(for: .plugin(plugin.id)) {
                KeyCaps(shortcut: shortcut)
            }
            if plugin.hasAction {
                Button {
                    model.plugins.run(plugin)
                } label: {
                    Group {
                        if running { ProgressView().controlSize(.small) } else { Image(systemName: "play.fill").font(.system(size: 10.5)) }
                    }
                    .frame(width: 26, height: 22)
                }
                .buttonStyle(OutlineButtonStyle(compact: true))
                .disabled(!on || running)
                .help("Run it now")
            }
            QuietButton(title: "Edit", action: edit)
            InkSwitch(isOn: Binding(get: { on }, set: { model.plugins.setEnabled(plugin, $0) }), label: "\(plugin.name) on")
        }
        .padding(.vertical, Metrics.rowPadding)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: edit)
    }

    /// When it runs, or what it runs.
    private var summary: String {
        var parts: [String] = []
        if !plugin.triggers.isEmpty { parts.append(plugin.triggers.map(\.summary).joined(separator: " · ")) }
        if let widget = plugin.widget, plugin.hasWidget {
            parts.append("Card, every \(PluginEditor.interval(widget.every))\(widget.background ? ", watched when closed" : "")")
        }
        if parts.isEmpty { parts.append(plugin.command.split(whereSeparator: \.isNewline).first.map(String.init) ?? "") }
        return parts.joined(separator: " · ")
    }

    private var statusLine: (text: String, failed: Bool)? {
        if let failure = model.plugins.cards[plugin.id]?.failure { return ("Card failed: \(failure)", true) }
        guard let result = model.plugins.lastResults[plugin.id] else { return nil }
        if result.timedOut { return ("Stopped after \(Int(plugin.timeout)) s", true) }
        let summary = result.summary(lines: 1)
        let status = result.succeeded ? "Last run" : "Failed (exit \(result.status))"
        return (summary.isEmpty ? status : "\(status): \(summary)", !result.succeeded)
    }
}

/// A small label beside a name: what kind of plugin it is.
private struct Tag: View {
    var text: String
    var accent = false

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(accent ? Color.themeAccent : Color.ink3)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(accent ? Color.themeAccent.opacity(0.12) : Color.wash))
    }
}

// MARK: - Editor

struct PluginDraft: Identifiable {
    var plugin: ScriptPlugin
    var isNew: Bool
    var id: UUID { plugin.id }
}

/// Make or change a plugin: its name and symbol, its action (command, input, output, keys, tools
/// row), its card, its triggers and its settings; try each before saving; see its recent runs.
struct PluginEditor: View {
    var model: AppModel
    @State var plugin: ScriptPlugin
    var isNew: Bool
    var done: () -> Void
    @State private var inPanel: Bool
    @State private var values: [String: String]
    @State private var problem: String?
    @State private var trial: PluginResult?
    @State private var cardTrial: PluginResult?
    @State private var trying = false
    @State private var parkedWidget: ScriptPlugin.Widget
    @FocusState private var nameFocused: Bool
    /// The sections in the order that matters for this kind of plugin (set when the sheet opens,
    /// so nothing jumps while you type).
    private let order: [Section]

    private enum Section {
        case action, card, triggers, settings
    }

    init(model: AppModel, draft: PluginDraft, done: @escaping () -> Void) {
        self.model = model
        _plugin = State(initialValue: draft.plugin)
        self.isNew = draft.isNew
        self.done = done
        _inPanel = State(initialValue: draft.isNew ? false : model.plugins.isInPanel(draft.plugin))
        _values = State(initialValue: model.plugins.environmentValues(for: draft.plugin))
        _parkedWidget = State(initialValue: draft.plugin.widget ?? ScriptPlugin.Widget(command: ""))
        let plugin = draft.plugin
        if plugin.hasWidget && !plugin.hasAction {
            order = [.card, .settings, .action, .triggers]
        } else if !plugin.triggers.isEmpty {
            order = [.action, .triggers, .settings, .card]
        } else {
            order = [.action, .settings, .card, .triggers]
        }
    }

    private static let symbols = ["puzzlepiece.extension", "terminal", "doc.on.clipboard", "doc.plaintext", "textformat",
                                  "folder", "globe", "bolt", "hammer", "wand.and.stars", "arrow.triangle.2.circlepath",
                                  "paperplane", "music.note", "camera", "lock", "moon", "chart.xyaxis.line", "bell"]

    /// Card refresh choices, in seconds.
    static let intervals: [Double] = [5, 15, 30, 60, 300, 900, 3600]

    static func interval(_ seconds: Double) -> String {
        seconds < 60 ? "\(Int(seconds)) s" : seconds < 3600 ? "\(Int(seconds / 60)) min" : "\(Int(seconds / 3600)) h"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(isNew ? "New Plugin" : "Edit Plugin")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                Text(plugin.kinds.isEmpty ? "Needs a command or a card" : plugin.kinds.joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ink3)
            }
            .padding([.horizontal, .top], 22)
            .padding(.bottom, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    basics
                    ForEach(order, id: \.self) { section in
                        switch section {
                        case .action: action
                        case .card: card
                        case .triggers: triggers
                        case .settings: if !plugin.settings.isEmpty { settings }
                        }
                    }
                    if !isNew, let runs = model.plugins.runs[plugin.id], !runs.isEmpty { recentRuns(runs) }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 620)
            footer
                .padding(22)
        }
        .frame(width: 600)
        .onAppear { if plugin.name.isEmpty { nameFocused = true } }
    }

    // MARK: Sections

    private var basics: some View {
        InkGroup {
            LabeledRow("Name") {
                TextField("What it does", text: $plugin.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                    .focused($nameFocused)
            }
            Hairline().opacity(0.6)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Symbol").font(.system(size: 12.5))
                    Spacer()
                    Image(systemName: plugin.symbol).font(.system(size: 15)).frame(width: 24)
                    TextField("SF Symbol name", text: $plugin.symbol)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }
                HStack(spacing: 4) {
                    ForEach(Self.symbols, id: \.self) { symbol in
                        Button {
                            plugin.symbol = symbol
                        } label: {
                            Image(systemName: symbol)
                                .font(.system(size: 12))
                                .frame(width: 24, height: 22)
                                .background(RoundedRectangle(cornerRadius: Radius.of(5), style: .continuous)
                                    .fill(plugin.symbol == symbol ? Color.themeAccent.opacity(0.18) : Color.clear))
                        }
                        .buttonStyle(.plain)
                        .help(symbol)
                    }
                }
            }
            .padding(.vertical, Metrics.rowPadding)
        }
    }

    private var action: some View {
        let hasAction = plugin.hasAction
        return InkGroup("When you run it") {
            VStack(alignment: .leading, spacing: 6) {
                CommandField(text: $plugin.command, placeholder: "A command, e.g. say \"hello\" (leave it empty for a card only)")
                Text("Runs with zsh in your home folder (a folder plugin: its folder), as in Terminal with your PATH; stopped after \(Int(plugin.timeout)) s. It's told why it ran: $TUTTO_REASON, $TUTTO_EVENT, $TUTTO_EVENT_INFO.")
                    .font(.system(size: 11)).foregroundStyle(Color.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, Metrics.rowPadding)
            Group {
                Hairline().opacity(0.6)
                LabeledRow("Input", detail: plugin.input == .clipboard ? "The clipboard's text arrives on standard input." : nil) {
                    InkSegmented(selection: $plugin.input, options: [(.none, "Nothing"), (.clipboard, "Clipboard")]).fixedSize()
                }
                Hairline().opacity(0.6)
                LabeledRow("Output", detail: outputDetail) {
                    InkSegmented(selection: $plugin.output, options: [(.notice, "Show"), (.clipboard, "Copy"), (.silent, "Nothing")]).fixedSize()
                }
                Hairline().opacity(0.6)
                LabeledRow("Time limit") {
                    InkStepper(label: "s", value: Int(plugin.timeout), range: 1...Int(ScriptPlugin.longestTimeout)) { plugin.timeout = Double($0) }
                }
                Hairline().opacity(0.6)
                LabeledRow("Shortcut", detail: "From any app.") {
                    ShortcutRecorder(action: .plugin(plugin.id), model: model)
                }
                Hairline().opacity(0.6)
                LabeledRow("In the panel's tools row", detail: "A tile to click (order it on the Customize page).") {
                    InkSwitch(isOn: $inPanel, label: "In the panel's tools row")
                }
            }
            .disabled(!hasAction)
            .opacity(hasAction ? 1 : 0.45)
        }
    }

    private var card: some View {
        let on = plugin.widget != nil
        return InkGroup("Card on the panel") {
            LabeledRow("Shows a card", detail: on ? nil : "A live reading among the panel's cards, from a command whose output is what it shows.") {
                InkSwitch(isOn: Binding(get: { on }, set: { show in
                    if show {
                        plugin.widget = parkedWidget
                    } else {
                        if let widget = plugin.widget { parkedWidget = widget }
                        plugin.widget = nil
                    }
                }), label: "Shows a card")
            }
            if on {
                Hairline().opacity(0.6)
                VStack(alignment: .leading, spacing: 6) {
                    CommandField(text: Binding(get: { plugin.widget?.command ?? "" }, set: { plugin.widget?.command = $0 }),
                                 placeholder: "What to show, e.g. sysctl -n vm.loadavg")
                    Text("Its first line is the value, the second a detail; or JSON for more: {\"value\": \"3\", \"unit\": \"open\", \"detail\": \"…\", \"level\": \"notice\", \"progress\": 0.4, \"series\": [1, 2, 3], \"url\": \"https://…\", \"items\": [{\"title\": \"…\"}]}.")
                        .font(.system(size: 11)).foregroundStyle(Color.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(.vertical, Metrics.rowPadding)
                Hairline().opacity(0.6)
                LabeledRow("Refresh every", detail: "While it's on screen.") {
                    Picker("", selection: Binding(get: { plugin.widget?.every ?? 30 }, set: { plugin.widget?.every = $0 })) {
                        ForEach(Self.intervals, id: \.self) { Text(Self.interval($0)).tag($0) }
                        if let every = plugin.widget?.every, !Self.intervals.contains(every) {
                            Text(Self.interval(every)).tag(every)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Hairline().opacity(0.6)
                LabeledRow("Size", detail: "Change it on the Customize page too.") {
                    InkSegmented(selection: Binding(get: { plugin.widget?.size ?? .small }, set: { plugin.widget?.size = $0 }),
                                 options: [(.small, "Small"), (.wide, "Wide")])
                }
                Hairline().opacity(0.6)
                LabeledRow("Watch it with the panel closed",
                           detail: "Keeps refreshing (at least 10 s apart) and tells you when it turns to alert, like a server going down. Uses a little battery.") {
                    InkSwitch(isOn: Binding(get: { plugin.widget?.background ?? false }, set: { plugin.widget?.background = $0 }),
                              label: "Watch it with the panel closed")
                }
                if let cardTrial {
                    Hairline().opacity(0.6)
                    CardTrialView(result: cardTrial, name: plugin.name, timeout: plugin.timeout)
                        .padding(.vertical, Metrics.rowPadding)
                }
            }
        }
    }

    private var triggers: some View {
        VStack(alignment: .leading, spacing: 8) {
            InkGroup("Runs by itself", trailing: AnyView(EventMenu(title: "Add Trigger") { plugin.triggers.append(.starting($0)) })) {
                if plugin.triggers.isEmpty {
                    Text("Only when you run it. Add a trigger to run it when something happens: on a schedule, when the battery runs low, an app opens, you copy something, your agents finish…")
                        .font(.system(size: 11.5)).foregroundStyle(Color.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, Metrics.rowPadding)
                }
                ForEach(plugin.triggers.indices, id: \.self) { index in
                    TriggerRow(trigger: $plugin.triggers[index]) { plugin.triggers.remove(at: index) }
                    if index < plugin.triggers.count - 1 { Hairline().opacity(0.6) }
                }
            }
            if !plugin.triggers.isEmpty && !plugin.hasAction {
                Text("Triggers run the command under “When you run it”: give it one.")
                    .font(.system(size: 11.5)).foregroundStyle(Color.alert)
                    .padding(.horizontal, 2)
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            InkGroup("Its settings") {
                ForEach(Array(plugin.settings.enumerated()), id: \.element.key) { index, setting in
                    SettingField(setting: setting, value: Binding(get: { values[setting.key] ?? setting.defaultValue },
                                                                  set: { values[setting.key] = $0 }))
                    if index < plugin.settings.count - 1 { Hairline().opacity(0.6) }
                }
            }
            Text("Its commands see these as $\(plugin.settings.first?.environmentName ?? "TUTTO_SETTING_…") and so on. Secrets stay in your keychain.")
                .font(.system(size: 11)).foregroundStyle(Color.ink3)
                .padding(.horizontal, 2)
        }
    }

    private func recentRuns(_ runs: [PluginRun]) -> some View {
        InkGroup("Recent runs") {
            ForEach(runs.prefix(6)) { run in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(run.date.formatted(date: .omitted, time: .standard))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Color.ink3)
                        .frame(width: 70, alignment: .leading)
                    Text(run.why)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.ink2)
                        .frame(width: 150, alignment: .leading)
                        .lineLimit(1)
                    Text(runLine(run))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(run.result.succeeded ? Color.ink3 : Color.alert)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 5)
                .help(fullText(run.result))
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let trial {
                VStack(alignment: .leading, spacing: 4) {
                    Text(trial.timedOut ? "Stopped: it ran past the time limit." : "Exit \(trial.status) in \(Int(trial.seconds * 1000)) ms")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(trial.succeeded ? Color.ink2 : Color.alert)
                    ScrollView {
                        Text(fullText(trial))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.ink2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 80)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: Radius.of(8), style: .continuous).fill(Color.wash))
            }
            if let problem = problem ?? (plugin.name.isEmpty ? nil : plugin.problem) {
                Text(problem).font(.system(size: 11.5)).foregroundStyle(Color.alert)
            }
            HStack(spacing: 8) {
                if !isNew {
                    Button("Move to Trash", role: .destructive) {
                        model.plugins.delete(plugin)
                        done()
                    }
                    .buttonStyle(OutlineButtonStyle(compact: true))
                }
                Button(trying ? "Running…" : "Try It") { tryIt(card: false) }
                    .buttonStyle(OutlineButtonStyle(compact: true))
                    .disabled(trying || !plugin.hasAction)
                    .help("Runs the command as it is now, without saving")
                if plugin.widget != nil {
                    Button("Try Card") { tryIt(card: true) }
                        .buttonStyle(OutlineButtonStyle(compact: true))
                        .disabled(trying || !plugin.hasWidget)
                        .help("Runs the card's command and shows what the card would")
                }
                Spacer()
                Button("Cancel") {
                    if isNew { model.shortcuts.reset(.plugin(plugin.id)) }
                    done()
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(OutlineButtonStyle(compact: true))
                Button(isNew ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(InkButtonStyle(compact: true))
                    .disabled(!plugin.isValid)
            }
        }
    }

    // MARK: Doing

    private var outputDetail: String {
        switch plugin.output {
        case .notice: "Its first lines in a notice."
        case .clipboard: "What it prints replaces the clipboard (nothing printed leaves it alone)."
        case .silent: "A notice only if it fails."
        }
    }

    private func runLine(_ run: PluginRun) -> String {
        if run.result.timedOut { return "stopped after the time limit" }
        let summary = run.result.summary(lines: 1)
        let status = "exit \(run.result.status), \(Int(run.result.seconds * 1000)) ms"
        return summary.isEmpty ? status : "\(status) · \(summary)"
    }

    private func fullText(_ result: PluginResult) -> String {
        let text = [result.output, result.errors].filter { !$0.isEmpty }.joined(separator: "\n")
        return text.isEmpty ? "(no output)" : text
    }

    private func tryIt(card: Bool) {
        trying = true
        if card { cardTrial = nil } else { trial = nil }
        model.plugins.trial(plugin, card: card, values: values) { result in
            if card { cardTrial = result } else { trial = result }
            trying = false
        }
    }

    private func save() {
        plugin.name = plugin.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if plugin.symbol.trimmingCharacters(in: .whitespaces).isEmpty || NSImage(systemSymbolName: plugin.symbol, accessibilityDescription: nil) == nil {
            plugin.symbol = ScriptPlugin.defaultSymbol
        }
        if let error = model.plugins.save(plugin, inPanel: plugin.hasAction ? inPanel : false, values: values) {
            problem = error
            return
        }
        done()
    }
}

/// A command to edit, monospaced, with a hint while it's empty.
private struct CommandField: View {
    @Binding var text: String
    var placeholder: String

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 12, design: .monospaced))
            .scrollContentBackground(.hidden)
            .frame(height: 74)
            .padding(4)
            .background(RoundedRectangle(cornerRadius: Radius.of(6), style: .continuous).fill(Color.wash))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.ink4)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// What a card would show for a trial run, as the card would read it.
private struct CardTrialView: View {
    var result: PluginResult
    var name: String
    var timeout: Double

    var body: some View {
        let content = PluginWidgetContent.parse(result.output)
        VStack(alignment: .leading, spacing: 6) {
            if result.succeeded {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Caption(content.title ?? name)
                    Spacer()
                    if let detail = content.detail {
                        Text(detail).font(.system(size: 10.5)).foregroundStyle(Color.ink3).lineLimit(1)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(content.value).font(.figure(21)).foregroundStyle(content.level == .alert ? Color.alert : Color.ink)
                    if let unit = content.unit { Text(unit).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.ink3) }
                    Spacer()
                    Text([content.level != .normal ? content.level.rawValue : nil,
                          content.progress.map { "progress \(Int($0 * 100)) %" },
                          content.series.isEmpty ? nil : "\(content.series.count) points",
                          content.items.isEmpty ? nil : "\(content.items.count) items",
                          content.url == nil ? nil : "opens a link"].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 10.5)).foregroundStyle(Color.ink3)
                }
            } else {
                Text("The card would show its failure: \(PluginsModel.failureLine(result, timeout: min(timeout, 20)))")
                    .font(.system(size: 11.5)).foregroundStyle(Color.alert)
            }
        }
        .padding(10)
        .background(CardSurface(radius: 10))
    }
}

/// One trigger: the event, and what it needs (minutes, a time, a percentage, an app, a name).
private struct TriggerRow: View {
    @Binding var trigger: PluginTrigger
    var remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("When").font(.system(size: 12.5)).foregroundStyle(Color.ink3)
                EventMenu(title: trigger.event.title) { event in
                    trigger = .starting(event)
                }
                parameter
                Spacer(minLength: 8)
                Button(action: remove) {
                    Image(systemName: "minus.circle").font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.ink3)
                .help("Remove this trigger")
            }
            if let note {
                Text(note)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var parameter: some View {
        switch trigger.event {
        case .every:
            InkStepper(label: "min", value: trigger.minutes ?? 30, range: 1...1440) { trigger.minutes = $0 }
        case .daily:
            DatePicker("", selection: Binding(get: { dailyDate }, set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                trigger.at = String(format: "%02d:%02d", parts.hour ?? 9, parts.minute ?? 0)
            }), displayedComponents: .hourAndMinute)
            .labelsHidden()
            .fixedSize()
        case .batteryBelow:
            InkStepper(label: "%", value: trigger.percent ?? 20, range: 2...95) { trigger.percent = $0 }
        case .appLaunched, .appQuit, .appActivated:
            TextField("Any app (or a name)", text: Binding(get: { trigger.app ?? "" }, set: { trigger.app = $0.isEmpty ? nil : $0 }))
                .textFieldStyle(.roundedBorder)
                .frame(width: 170)
        case .custom:
            TextField("event name", text: Binding(get: { trigger.name ?? "" }, set: { trigger.name = $0 }))
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
        default:
            EmptyView()
        }
    }

    private var dailyDate: Date {
        let time = trigger.dailyTime ?? (9, 0)
        return Calendar.current.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: Date()) ?? Date()
    }

    private var note: String? {
        switch trigger.event {
        case .custom:
            return "Send it from a script or an agent's hook: open -g \"tutto://do/event?name=\(trigger.name ?? "")&info=…\""
        case .agentsFinished:
            return "About 3 minutes after the last sign of work (writes to their session logs, a build they started)."
        case .clipboardChanged:
            return "Not for Tutto's own copies or private ones (passwords)."
        default:
            return trigger.event.infoDescription.map { "$TUTTO_EVENT_INFO: \($0)." }
        }
    }
}

/// The events, grouped, to pick one.
private struct EventMenu: View {
    var title: String
    var pick: (PluginEvent) -> Void

    var body: some View {
        Menu {
            ForEach(Array(PluginEvent.menuOrder.enumerated()), id: \.offset) { _, group in
                Section {
                    ForEach(group, id: \.self) { event in
                        Button(event.title + ([.every, .daily, .batteryBelow].contains(event) ? "…" : "")) { pick(event) }
                    }
                }
            }
        } label: {
            Text(title).font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

/// A field a plugin asks for, as the kind of control it needs.
private struct SettingField: View {
    var setting: PluginSetting
    @Binding var value: String

    var body: some View {
        LabeledRow(setting.title, detail: setting.help) {
            switch setting.kind {
            case .toggle:
                InkSwitch(isOn: Binding(get: { ["true", "1", "yes", "on"].contains(value.lowercased()) },
                                        set: { value = $0 ? "true" : "false" }), label: setting.title)
            case .choice:
                Picker("", selection: $value) {
                    ForEach(setting.options, id: \.self) { Text($0).tag($0) }
                    if !setting.options.contains(value) { Text(value).tag(value) }
                }
                .labelsHidden()
                .fixedSize()
            case .folder:
                HStack(spacing: 6) {
                    TextField("Folder", text: $value)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 190)
                    Button("Choose…") { chooseFolder() }
                        .buttonStyle(OutlineButtonStyle(compact: true))
                }
            case .secret:
                SecureField("Kept in your keychain", text: $value)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            case .number:
                TextField("0", text: $value)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
            case .text:
                TextField(setting.defaultValue, text: $value)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        let expanded = (value as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expanded) { panel.directoryURL = URL(fileURLWithPath: expanded) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        value = url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

// MARK: - Guide

/// How plugins work, in one sheet: the file, a card's output, triggers, what a run is told.
private struct PluginGuide: View {
    var done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("How plugins work")
                .font(.system(size: 17, weight: .semibold))
                .padding([.horizontal, .top], 22)
                .padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section("A plugin is a file",
                            "A .json file in the Plugins folder, or a folder there with a plugin.json and its scripts (its commands then run in that folder). A name and a command, or a card, are enough; everything else is optional. Tutto draws what a plugin adds with its own controls and your theme: a plugin runs commands, never code inside Tutto.")
                    code(#"""
                    {
                      "name": "Repo Changes",
                      "symbol": "arrow.triangle.branch",
                      "command": "open -a Terminal \"$TUTTO_SETTING_FOLDER\"",
                      "widget": {"command": "./changes.sh", "every": 20, "size": "small"},
                      "triggers": [{"on": "daily", "at": "09:00"}, {"on": "battery.below", "percent": 15}],
                      "settings": [{"key": "folder", "title": "Repository", "type": "folder", "default": "~/code"}]
                    }
                    """#)
                    section("A card's output",
                            "Plain text: the first line is the value, the second a detail, more lines a list (wide cards). Or JSON: value, unit, title, detail, symbol (an SF Symbol), level (normal, notice, alert), progress (0–1), series (numbers for a line), url (opened on click), items ([{\"title\", \"detail\", \"url\"}]). A card refreshes while it's on screen; \"background\": true keeps watching it with the panel closed and tells you when it turns to alert.")
                    section("Triggers",
                            "\"on\" is one of: every (\"minutes\"), daily (\"at\": \"HH:MM\"), battery.below (\"percent\"), power.connected, power.disconnected, wake, sleep, lock, unlock, launch, app.launched / app.quit / app.activated (\"app\": a name or bundle id), clipboard.changed, network.changed, display.changed, agents.started, agents.finished, stayawake.started, stayawake.ended, custom (\"name\"; sent with open -g \"tutto://do/event?name=…&info=…\"). A trigger runs the plugin's command, at most 12 times a minute.")
                    section("Settings",
                            "\"settings\" asks for fields: text, number, toggle, choice (with \"options\"), folder or secret (kept in your keychain). They're set on the Plugins page and reach every command as $TUTTO_SETTING_<KEY>.")
                    section("What a run is told",
                            "$TUTTO_REASON (run, link, widget, trigger, test), $TUTTO_EVENT and $TUTTO_EVENT_INFO for a trigger (a battery's charge, an app's bundle id, a custom event's info), $TUTTO_PLUGIN, $TUTTO_PLUGIN_ID and, for a folder plugin, $TUTTO_PLUGIN_DIR.")
                    section("Safety",
                            "Commands run as you, like any script. A plugin dropped into the folder starts off until you've looked at what it runs, and one that changes on disk (its file or its scripts) waits for you again; ones you make or save here are on. Copies marked private (passwords) never reach a plugin. A custom event's info comes from a link anyone can open: quote it, and put -- before it in commands.")
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 560)
            HStack {
                Spacer()
                Button("Done", action: done)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(InkButtonStyle(compact: true))
            }
            .padding(22)
        }
        .frame(width: 600)
    }

    private func section(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12.5, weight: .semibold))
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Color.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private func code(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Color.ink2)
            .textSelection(.enabled)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.of(8), style: .continuous).fill(Color.wash))
    }
}
