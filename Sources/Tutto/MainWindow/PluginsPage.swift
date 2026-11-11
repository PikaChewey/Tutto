//
//  PluginsPage.swift
//  Tutto
//
//  Tutto's tools as plugins you switch on and off, and your own: small actions Tutto runs for you
//  as a shell command, from a shortcut, a link or (if you put it there) the panel's tools row.
//  Each of yours is a JSON file in the Plugins folder; this page reads the folder whenever it opens.
//

import AppKit
import SwiftUI
import TuttoKit

struct PluginsPage: View {
    @Bindable var model: AppModel
    @State private var editing: PluginDraft?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: "Plugins",
                       subtitle: "Tutto is made of plugins: switch on only what you use, and anything off costs nothing. Add your own too: a command Tutto runs for you.")
            yours
            builtIn
        }
        .onAppear { model.plugins.load() }
        .sheet(item: $editing) { draft in
            PluginEditor(model: model, draft: draft) { editing = nil }
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
                        Text("A plugin runs a command for you: tidy what you copied, open a project, start a script. Start from a template or a blank one.")
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
                Text("Each plugin is a file in \(model.plugins.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")): share one by sending its file, or edit it by hand and come back here. Scripts can run one with `open -g \"tutto://do/plugin?name=…\"`.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 12)
                Button("Show Folder") {
                    try? FileManager.default.createDirectory(at: model.plugins.folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([model.plugins.folder])
                }
                .buttonStyle(OutlineButtonStyle(compact: true))
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
            Divider()
            Section("Templates") {
                ForEach(ScriptPlugin.templates, id: \.name) { template in
                    Button(template.name) {
                        var plugin = template
                        plugin.id = UUID()
                        editing = PluginDraft(plugin: plugin, isNew: true)
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

/// One of your plugins: what it is, its keys, run it, switch it, edit it.
private struct PluginRow: View {
    var model: AppModel
    var plugin: ScriptPlugin
    var edit: () -> Void
    @State private var hovering = false

    var body: some View {
        let running = model.plugins.running.contains(plugin.id)
        HStack(spacing: 12) {
            Image(systemName: plugin.symbol)
                .font(.system(size: 13))
                .frame(width: 20)
                .foregroundStyle(plugin.enabled ? Color.ink2 : Color.ink4)
            VStack(alignment: .leading, spacing: Metrics.titleToDetail) {
                HStack(spacing: 6) {
                    Text(plugin.name).font(.system(size: 13, weight: .medium))
                    if model.plugins.isInPanel(plugin) {
                        Text("in the panel").font(.system(size: 10.5)).foregroundStyle(Color.ink3)
                    }
                }
                Text(plugin.command.split(whereSeparator: \.isNewline).first.map(String.init) ?? "")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.ink3)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let result = model.plugins.lastResults[plugin.id] {
                    Text(resultLine(result))
                        .font(.system(size: 10.5))
                        .foregroundStyle(result.succeeded ? Color.ink3 : Color.alert)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            // Its keys when it has some (one is set in its editor).
            if let shortcut = model.shortcuts.shortcut(for: .plugin(plugin.id)) {
                KeyCaps(shortcut: shortcut)
            }
            Button {
                model.plugins.run(plugin)
            } label: {
                Group {
                    if running { ProgressView().controlSize(.small) } else { Image(systemName: "play.fill").font(.system(size: 10.5)) }
                }
                .frame(width: 26, height: 22)
            }
            .buttonStyle(OutlineButtonStyle(compact: true))
            .disabled(!plugin.enabled || running)
            .help("Run it now")
            QuietButton(title: "Edit", action: edit)
            InkSwitch(isOn: Binding(get: { plugin.enabled }, set: { model.plugins.setEnabled(plugin, $0) }), label: "\(plugin.name) on")
        }
        .padding(.vertical, Metrics.rowPadding)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: edit)
    }

    private func resultLine(_ result: PluginResult) -> String {
        if result.timedOut { return "Stopped after \(Int(plugin.timeout)) s" }
        let summary = result.summary(lines: 1)
        let status = result.succeeded ? "Last run" : "Failed (exit \(result.status))"
        return summary.isEmpty ? status : "\(status): \(summary)"
    }
}

// MARK: - Editor

struct PluginDraft: Identifiable {
    var plugin: ScriptPlugin
    var isNew: Bool
    var id: UUID { plugin.id }
}

/// Make or change a plugin: its name and symbol, the command, what goes in and comes out, its
/// shortcut, the tools row, and a trial run before saving.
struct PluginEditor: View {
    var model: AppModel
    @State var plugin: ScriptPlugin
    var isNew: Bool
    var done: () -> Void
    @State private var inPanel: Bool
    @State private var problem: String?
    @State private var trial: PluginResult?
    @State private var trying = false
    @FocusState private var nameFocused: Bool

    init(model: AppModel, draft: PluginDraft, done: @escaping () -> Void) {
        self.model = model
        _plugin = State(initialValue: draft.plugin)
        self.isNew = draft.isNew
        self.done = done
        _inPanel = State(initialValue: draft.isNew ? false : model.plugins.isInPanel(draft.plugin))
    }

    private static let symbols = ["puzzlepiece.extension", "terminal", "doc.on.clipboard", "doc.plaintext", "textformat",
                                  "folder", "globe", "bolt", "hammer", "wand.and.stars", "arrow.triangle.2.circlepath",
                                  "paperplane", "music.note", "camera", "lock", "moon"]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(isNew ? "New Plugin" : "Edit Plugin")
                .font(.system(size: 17, weight: .semibold))
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
            InkGroup("Command") {
                VStack(alignment: .leading, spacing: 6) {
                    TextEditor(text: $plugin.command)
                        .font(.system(size: 12, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .frame(height: 74)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: Radius.of(6), style: .continuous).fill(Color.wash))
                    Text("Runs with zsh in your home folder, as in Terminal (your PATH included), stopped after \(Int(plugin.timeout)) s.")
                        .font(.system(size: 11)).foregroundStyle(Color.ink3)
                }
                .padding(.vertical, Metrics.rowPadding)
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
            }
            InkGroup("Running it") {
                LabeledRow("Shortcut", detail: "From any app.") {
                    ShortcutRecorder(action: .plugin(plugin.id), model: model)
                }
                Hairline().opacity(0.6)
                LabeledRow("In the menu bar's tools", detail: "A tile in the panel's tools row, to click (order it on the Customize page).") {
                    InkSwitch(isOn: $inPanel, label: "In the menu bar's tools")
                }
            }
            if let trial {
                VStack(alignment: .leading, spacing: 4) {
                    Text(trial.timedOut ? "Stopped: it ran past the time limit." : "Exit \(trial.status) in \(Int(trial.seconds * 1000)) ms")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(trial.succeeded ? Color.ink2 : Color.alert)
                    ScrollView {
                        Text(trialText(trial))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.ink2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 90)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: Radius.of(8), style: .continuous).fill(Color.wash))
            }
            if let problem {
                Text(problem).font(.system(size: 11.5)).foregroundStyle(Color.alert)
            }
            HStack(spacing: 8) {
                if !isNew {
                    Button("Delete", role: .destructive) {
                        model.plugins.delete(plugin)
                        done()
                    }
                    .buttonStyle(OutlineButtonStyle(compact: true))
                }
                Button(trying ? "Running…" : "Try It") { tryIt() }
                    .buttonStyle(OutlineButtonStyle(compact: true))
                    .disabled(trying || plugin.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Runs the command as it is now, without saving")
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
        .padding(22)
        .frame(width: 560)
        .onAppear { if plugin.name.isEmpty { nameFocused = true } }
    }

    private var outputDetail: String {
        switch plugin.output {
        case .notice: "Its first lines in a notice."
        case .clipboard: "What it prints replaces the clipboard."
        case .silent: "A notice only if it fails."
        }
    }

    private func trialText(_ result: PluginResult) -> String {
        let text = [result.output, result.errors].filter { !$0.isEmpty }.joined(separator: "\n")
        return text.isEmpty ? "(no output)" : text
    }

    private func tryIt() {
        trying = true
        trial = nil
        let command = plugin.command, timeout = plugin.timeout, name = plugin.name
        let input = plugin.input == .clipboard ? (NSPasteboard.general.string(forType: .string) ?? "") : nil
        Task.detached(priority: .userInitiated) {
            let result = PluginRunner.run(command, input: input, timeout: timeout, name: name)
            await MainActor.run {
                trial = result
                trying = false
            }
        }
    }

    private func save() {
        plugin.name = plugin.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if plugin.symbol.trimmingCharacters(in: .whitespaces).isEmpty || NSImage(systemSymbolName: plugin.symbol, accessibilityDescription: nil) == nil {
            plugin.symbol = ScriptPlugin.defaultSymbol
        }
        if let error = model.plugins.save(plugin, inPanel: inPanel) {
            problem = error
            return
        }
        done()
    }
}
