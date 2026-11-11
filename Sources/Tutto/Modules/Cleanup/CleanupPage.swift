//
//  CleanupPage.swift
//  Tutto
//
//  Tools › Clean Up: Scan, then a list to review, grouped (left behind by removed apps, probably
//  left behind, caches, logs, developer caches), each with its size and a tick. Move to Trash
//  moves what's ticked; the Trash itself is emptied separately, after a warning.
//

import AppKit
import SwiftUI
import TuttoKit

struct CleanupPage: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Clean Up",
                       subtitle: "Leftovers from apps you removed, caches, logs and the Trash. You review everything first; what you remove goes to the Trash.",
                       module: .cleaner)
            if let cleaner = model.cleaner {
                CleanupContent(cleaner: cleaner, model: model)
            } else {
                ModuleOffView(module: .cleaner, model: model)
            }
        }
    }
}

private struct CleanupContent: View {
    @Bindable var cleaner: CleanupModule
    @Bindable var model: AppModel
    @State private var showAll: Set<CleanupCategory> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !model.permissions.fullDiskAccess { fullDiskBanner }
            if let result = cleaner.lastResult {
                Text(result)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.ink2)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Radius.of(12), style: .continuous).fill(Color.wash))
            }
            switch cleaner.state {
            case .idle: start
            case .scanning(let place): scanning(place)
            case .ready, .cleaning: results
            }
            if cleaner.state == .ready || cleaner.state == .cleaning { trashCard }
        }
        .onAppear { model.permissions.refresh() }
    }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    private var fullDiskBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.open").foregroundStyle(Color.ink2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Allow Full Disk Access to also check apps' containers and the Trash")
                    .font(.system(size: 12.5, weight: .semibold))
                Text("Optional. Without it, Clean Up checks everything else. \(Permission.fullDiskAccess.settingsPath).")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Open Settings") { model.permissions.request(.fullDiskAccess) }
                .buttonStyle(OutlineButtonStyle(compact: true))
        }
        .padding(14)
        .background(Color.wash, in: RoundedRectangle(cornerRadius: Radius.of(12), style: .continuous))
    }

    private var start: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Nothing changes until you choose. A scan takes a few seconds and only reads.")
                .font(.system(size: 12.5))
                .foregroundStyle(Color.ink2)
            Button("Scan") { cleaner.scan() }
                .buttonStyle(InkButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
    }

    private func scanning(_ place: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(place + "…")
                .font(.system(size: 12.5))
                .foregroundStyle(Color.ink2)
            Spacer()
            Button("Cancel") { cleaner.cancelScan() }
                .buttonStyle(OutlineButtonStyle(compact: true))
        }
        .padding(14)
        .background(Color.wash, in: RoundedRectangle(cornerRadius: Radius.of(12), style: .continuous))
    }

    // MARK: Results

    @ViewBuilder
    private var results: some View {
        if cleaner.items.isEmpty {
            HStack {
                Text("Nothing to clean. Apps you removed left nothing behind, and the caches are in use or small.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.ink2)
                Spacer()
                Button("Scan Again") { cleaner.scan() }
                    .buttonStyle(OutlineButtonStyle(compact: true))
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.bytes(cleaner.foundBytes))
                        .font(.figure(26, weight: .semibold))
                        .foregroundStyle(Color.ink)
                    Text("found in \(cleaner.items.count) place\(cleaner.items.count == 1 ? "" : "s") · \(Self.bytes(cleaner.selectedBytes)) ticked")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.ink3)
                }
                Spacer()
                Button("Scan Again") { cleaner.scan() }
                    .buttonStyle(OutlineButtonStyle(compact: true))
                    .disabled(cleaner.state == .cleaning)
                Button(cleaner.state == .cleaning ? "Moving…" : "Move to Trash") { cleaner.moveSelectedToTrash() }
                    .buttonStyle(InkButtonStyle(compact: true))
                    .disabled(cleaner.selected.isEmpty || cleaner.state == .cleaning)
                    .help("Everything ticked goes to the Trash, where you can put it back")
            }
            ForEach(CleanupCategory.allCases, id: \.self) { category in
                let items = cleaner.items.filter { $0.category == category }
                if !items.isEmpty { group(category, items) }
            }
            if !cleaner.skipped.isEmpty {
                Text("Not checked (needs Full Disk Access): \(cleaner.skipped.joined(separator: ", ")).")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.ink3)
            }
        }
    }

    private func group(_ category: CleanupCategory, _ items: [CleanupItem]) -> some View {
        let total = items.reduce(Int64(0)) { $0 + $1.bytes }
        let ids = Set(items.map(\.id))
        let allTicked = ids.isSubset(of: cleaner.selected)
        let shown = showAll.contains(category) ? items : Array(items.prefix(8))
        return InkGroup("\(category.title) · \(Self.bytes(total))") {
            HStack(spacing: 8) {
                Toggle(isOn: Binding(get: { allTicked }, set: { on in
                    if on { cleaner.selected.formUnion(ids) } else { cleaner.selected.subtract(ids) }
                })) {
                    Text(allTicked ? "All ticked" : "Tick all")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.ink3)
                }
                .toggleStyle(.checkbox)
                Spacer()
                if category == .developer {
                    Text("These rebuild themselves, at the cost of time")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.ink3)
                } else if category == .probableLeftover {
                    Text("Named for no app here; check before ticking")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.ink3)
                }
            }
            ForEach(shown) { item in
                Hairline().opacity(0.5)
                row(item)
            }
            if items.count > 8 {
                Hairline().opacity(0.5)
                Button(showAll.contains(category) ? "Show fewer" : "Show all \(items.count)") {
                    if showAll.contains(category) { showAll.remove(category) } else { showAll.insert(category) }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.ink2)
            }
        }
    }

    private func row(_ item: CleanupItem) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { cleaner.selected.contains(item.id) }, set: { on in
                if on { cleaner.selected.insert(item.id) } else { cleaner.selected.remove(item.id) }
            }))
            .toggleStyle(.checkbox)
            .labelsHidden()
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.paths.first?.path ?? "/"))
                .resizable()
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ink3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(Self.bytes(item.bytes))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(Color.ink2)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting(item.paths)
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.ink3)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show in Finder")
        }
    }

    // MARK: Trash

    private var trashCard: some View {
        InkGroup("The Trash") {
            if let trash = cleaner.trash {
                LabeledRow(trash.count == 0 ? "Empty" : "\(Self.bytes(trash.bytes)) in \(trash.count) item\(trash.count == 1 ? "" : "s")",
                           detail: "Space comes back when the Trash is emptied. Emptying deletes for good.") {
                    Button("Empty Trash…") { cleaner.emptyTrash() }
                        .buttonStyle(OutlineButtonStyle(compact: true))
                        .disabled(trash.count == 0)
                }
            } else {
                LabeledRow("Not measured", detail: "Tutto needs Full Disk Access to look in the Trash; you can empty it in Finder.") {
                    Button("Open the Trash") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash"))
                    }
                    .buttonStyle(OutlineButtonStyle(compact: true))
                }
            }
        }
    }
}
