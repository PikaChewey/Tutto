//
//  ClipboardPage.swift
//  Tutto
//

import AppKit
import SwiftUI
import TuttoKit
import UniformTypeIdentifiers

struct ClipboardPage: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Clipboard", subtitle: "Everything you copy — text, images, files and links — searchable from one shortcut.",
                       module: .clipboard)
            if let clipboard = model.clipboard {
                ClipboardSettings(clipboard: clipboard, model: model)
            } else {
                ModuleOffView(module: .clipboard, model: model)
            }
        }
    }
}

private struct ClipboardSettings: View {
    @Bindable var clipboard: ClipboardModule
    @Bindable var model: AppModel
    @State private var confirmClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            InkGroup {
                LabeledRow("Open clipboard history", detail: "Type to search, double-click or ↩ to paste into the app you're in, ⌘↩ to copy, ⇥ to filter by type, ⌘1–⌘9 to paste the first nine.") {
                    ShortcutRecorder(action: .clipboardHistory, model: model)
                }
                Hairline().opacity(0.6)
                LabeledRow("Record new copies", detail: clipboard.isPaused ? "Paused: nothing you copy is saved." : "On") {
                    InkSwitch(isOn: Binding(get: { !clipboard.isPaused }, set: { clipboard.isPaused = !$0 }), label: "Record new copies")
                }
                Hairline().opacity(0.6)
                LabeledRow("Keep pasted items on the clipboard",
                           detail: clipboard.keepPastedOnClipboard
                               ? "Pasting from history also replaces what's on your clipboard."
                               : "Off: double-click or ↩ pastes, and your clipboard stays as it was.") {
                    InkSwitch(isOn: $clipboard.keepPastedOnClipboard, label: "Keep pasted items on the clipboard")
                }
                Hairline().opacity(0.6)
                LabeledRow("Keep", detail: "Pinned items are always kept.") {
                    InkSegmented(selection: $clipboard.maxItems,
                                 options: [(100, "100"), (250, "250"), (500, "500"), (1000, "1,000")])
                }
            }
            InkGroup("Privacy") {
                Text("Items that password managers mark as concealed are never recorded. Copies made in these apps are ignored too:")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
                ForEach(clipboard.ignoredApps, id: \.self) { id in
                    HStack(spacing: 8) {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 16, height: 16)
                            Text(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
                                .font(.system(size: 12.5))
                        } else {
                            Image(systemName: "app.dashed").frame(width: 16).foregroundStyle(Color.ink4)
                            Text(id).font(.system(size: 12.5)).foregroundStyle(Color.ink3)
                        }
                        Spacer()
                        IconButton(symbol: "minus", help: "Stop ignoring", size: 20) {
                            clipboard.ignoredApps.removeAll { $0 == id }
                        }
                    }
                    .frame(height: 26)
                }
                HStack {
                    Button("Add App…") { addApp() }
                        .buttonStyle(OutlineButtonStyle(compact: true))
                    Spacer()
                }
                .padding(.vertical, 8)
            }
            InkGroup("History") {
                LabeledRow("\(clipboard.itemCount.formatted()) items",
                           detail: "Stored only on this Mac, in ~/Library/Application Support/Tutto/Clipboard (\(Format.bytes(Int64(clipboard.store?.totalBytes ?? 0), style: .file))).") {
                    Button("Clear History…") { confirmClear = true }
                        .buttonStyle(OutlineButtonStyle(compact: true))
                }
            }
        }
        .confirmationDialog("Clear clipboard history?", isPresented: $confirmClear) {
            Button("Clear All but Pinned", role: .destructive) { clipboard.clearHistory(keepPinned: true) }
            Button("Clear Everything", role: .destructive) { clipboard.clearHistory(keepPinned: false) }
        } message: {
            Text("This can't be undone.")
        }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !clipboard.ignoredApps.contains(id) {
                clipboard.ignoredApps.append(id)
            }
        }
    }
}
