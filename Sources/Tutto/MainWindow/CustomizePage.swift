//
//  CustomizePage.swift
//  Tutto
//
//  Arrange the menu bar panel from the app's settings: which parts, readings, controls and tools
//  it shows, in what order, with the real panel beside the controls as a live preview. Nothing
//  about customizing lives in the panel itself.
//

import SwiftUI
import TuttoKit
import UniformTypeIdentifiers

struct CustomizePage: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: "Customize",
                       subtitle: "Choose what the menu bar panel shows and in what order. Drag a row to move it; the preview shows the panel as it will look.")
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 26) {
                    editors.frame(minWidth: 330, idealWidth: 370, maxWidth: .infinity)
                    PanelPreview(model: model)
                }
                VStack(alignment: .leading, spacing: 22) {
                    editors
                    PanelPreview(model: model)
                }
            }
        }
    }

    private var layout: PanelLayout { model.layout.layout }

    private var editors: some View {
        VStack(alignment: .leading, spacing: 22) {
            ArrangementEditor(
                title: "Panel",
                items: PanelLayoutStore.Section.allCases.map { .init(id: $0.rawValue, title: $0.title, detail: $0.detail, symbol: $0.symbol) },
                arrangement: layout.sections,
                change: { change in model.layout.update { change(&$0.sections) } })

            ArrangementEditor(
                title: "Readings",
                items: readings.map { .init(id: $0.rawValue, title: $0.title, detail: nil, symbol: $0.symbol) },
                arrangement: layout.readings,
                footnote: "Two to a row; an odd one out takes the whole row.",
                change: { change in model.layout.update { change(&$0.readings) } })
                .opacity(layout.sections.isShown(PanelLayoutStore.Section.readings.rawValue) ? 1 : 0.5)

            if !controls.isEmpty {
                ArrangementEditor(
                    title: "Controls",
                    items: controls.map { .init(id: $0.rawValue, title: $0.title, detail: nil, symbol: $0.symbol) },
                    arrangement: layout.controls,
                    change: { change in model.layout.update { change(&$0.controls) } })
                    .opacity(layout.sections.isShown(PanelLayoutStore.Section.controls.rawValue) ? 1 : 0.5)
            }

            let tools = ShortcutRows.rows(model)
            if !tools.isEmpty {
                ArrangementEditor(
                    title: "Tools",
                    items: tools.map { .init(id: $0.id, title: $0.title, detail: $0.action.isPlugin ? "Your plugin" : nil, symbol: $0.symbol) },
                    arrangement: layout.tools,
                    footnote: "Six to a row; more start a second row. Tools turned off and your plugins are on the Plugins page.",
                    change: { change in model.layout.update { change(&$0.tools) } })
                    .opacity(layout.sections.isShown(PanelLayoutStore.Section.tools.rawValue) ? 1 : 0.5)
            }

            HStack {
                Text("Only the panel changes here; every tool keeps working with its shortcut whatever the panel shows.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 16)
                Button("Restore Defaults") { withAnimation(Motion.snappy) { model.layout.reset() } }
                    .buttonStyle(OutlineButtonStyle(compact: true))
                    .disabled(!model.layout.isCustomized)
            }
        }
    }

    private var readings: [PanelLayoutStore.Reading] {
        PanelLayoutStore.Reading.allCases.filter { $0 != .temperature || model.sensors != nil }
    }

    private var controls: [PanelLayoutStore.Control] {
        var available: [PanelLayoutStore.Control] = []
        if model.awake != nil { available.append(.awake) }
        if model.clicker != nil { available.append(.clicker) }
        if model.sensors?.hasFans == true { available.append(.fan) }
        return available
    }
}

// MARK: - Preview

/// The real panel at 85 %, as it will look; not clickable here.
private struct PanelPreview: View {
    var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Caption("Preview")
            Scaled(scale: 0.85) {
                MenuPanel(model: model, preview: true)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.hairline))
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .fixedSize()
    }
}

/// Draws its content smaller and takes only the smaller room (a scale effect alone keeps the
/// full-size room, so what follows would sit too far away or overlap).
private struct Scaled<Content: View>: View {
    var scale: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        ScaledLayout(scale: scale) {
            content.scaleEffect(scale, anchor: .topLeading)
        }
    }
}

private struct ScaledLayout: Layout {
    var scale: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews.first?.sizeThatFits(.unspecified) ?? .zero
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: .unspecified)
    }
}

// MARK: - Arrangement editor

/// A list of items to show or hide and drag into order (or Move Up / Move Down from a row's menu).
struct ArrangementEditor: View {
    struct Item: Identifiable, Equatable {
        var id: String
        var title: String
        var detail: String?
        var symbol: String
    }

    var title: String
    var items: [Item]
    var arrangement: Arrangement
    var footnote: String?
    var change: ((inout Arrangement) -> Void) -> Void

    @State private var dragging: String?
    @State private var target: String?

    private var available: [String] { items.map(\.id) }

    private var ordered: [Item] {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return arrangement.all(available).compactMap { byID[$0] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            InkGroup(title) {
                ForEach(Array(ordered.enumerated()), id: \.element.id) { index, item in
                    row(item, index: index, count: ordered.count)
                    if index < ordered.count - 1 { Hairline().opacity(0.6) }
                }
            }
            if let footnote {
                Text(footnote)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ink3)
                    .padding(.horizontal, 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(Motion.snappy, value: arrangement)
    }

    private func row(_ item: Item, index: Int, count: Int) -> some View {
        let shown = arrangement.isShown(item.id)
        return HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.ink4)
                .frame(width: 14)
                .help("Drag to move")
            Image(systemName: item.symbol)
                .font(.system(size: 12.5))
                .foregroundStyle(shown ? Color.ink2 : Color.ink4)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: Metrics.titleToDetail) {
                Text(item.title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(shown ? Color.ink : Color.ink3)
                if let detail = item.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            InkSwitch(isOn: Binding(get: { shown }, set: { on in change { $0.set(item.id, shown: on) } }),
                      label: "Show \(item.title)")
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .opacity(dragging == item.id ? 0.4 : 1)
        .overlay(alignment: .top) {
            // Where a dragged row will land.
            if target == item.id, dragging != item.id {
                Capsule().fill(Color.accentColor).frame(height: 2).offset(y: -1)
            }
        }
        .onDrag {
            dragging = item.id
            return NSItemProvider(object: item.id as NSString)
        }
        .onDrop(of: [.plainText], delegate: RowDrop(item: item.id, available: available, dragging: $dragging, target: $target, change: change))
        .contextMenu {
            Button("Move Up") { change { $0.move(item.id, by: -1, available: available) } }
                .disabled(index == 0)
            Button("Move Down") { change { $0.move(item.id, by: 1, available: available) } }
                .disabled(index == count - 1)
            Divider()
            Button(shown ? "Hide" : "Show") { change { $0.set(item.id, shown: !shown) } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Move Up") { change { $0.move(item.id, by: -1, available: available) } }
        .accessibilityAction(named: "Move Down") { change { $0.move(item.id, by: 1, available: available) } }
    }
}

/// Dropping a dragged row on another puts it in that row's place.
private struct RowDrop: DropDelegate {
    var item: String
    var available: [String]
    @Binding var dragging: String?
    @Binding var target: String?
    var change: ((inout Arrangement) -> Void) -> Void

    func dropEntered(info: DropInfo) { target = item }

    func dropExited(info: DropInfo) { if target == item { target = nil } }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            dragging = nil
            target = nil
        }
        guard let moving = dragging, moving != item else { return false }
        change { arrangement in
            let list = arrangement.all(available)
            guard let from = list.firstIndex(of: moving), let to = list.firstIndex(of: item) else { return }
            arrangement.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to, available: available)
        }
        return true
    }
}
