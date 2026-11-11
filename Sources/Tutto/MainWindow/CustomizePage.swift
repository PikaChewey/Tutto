//
//  CustomizePage.swift
//  Tutto
//
//  Arrange the menu bar panel from the app's settings (Bryan, 2026-11-10: "panel cards you can
//  move anywhere and resize"): every card in one list, in any order, small or wide, shown or
//  hidden, with the real panel beside the list as a preview you can arrange directly (drag a card
//  to move it, click one to size or hide it). Nothing about customizing lives in the panel itself.
//

import SwiftUI
import TuttoKit
import UniformTypeIdentifiers

struct CustomizePage: View {
    @Bindable var model: AppModel
    @State private var editing = PanelEditing()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: "Customize",
                       subtitle: "Arrange the menu bar panel: drag a card to move it, here or in the preview, make it small or wide, and hide what you don't use. Colours and shapes are on the Appearance page.")
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 26) {
                    editors.frame(minWidth: 330, idealWidth: 360, maxWidth: .infinity)
                    preview
                }
                VStack(alignment: .leading, spacing: 22) {
                    editors
                    preview
                }
            }
        }
        .onAppear {
            editing.move = { [model] moving, target in model.layout.move(moving, onto: target, model) }
        }
        // A card dropped outside any other stays where it was.
        .onDrop(of: [.plainText], isTargeted: nil) { _ in
            editing.dragging = nil
            editing.target = nil
            return false
        }
    }

    // MARK: Preview

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Caption("Preview")
                Spacer(minLength: 12)
                Text("Drag to move · click to select")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.ink3)
            }
            PanelPreview(model: model, editing: editing)
            if let id = editing.selected, let widget = PanelLayoutStore.Widget(id: id),
               model.layout.all(model).contains(widget) {
                SelectedCard(model: model, widget: widget, editing: editing)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(width: PanelPreview.width)
        .animation(Motion.snappy, value: editing.selected)
    }

    // MARK: Lists

    private var editors: some View {
        let cards = model.layout.all(model)
        let tools = ShortcutRows.rows(model)
        return VStack(alignment: .leading, spacing: 22) {
            ArrangementEditor(
                title: "Cards",
                items: cards.map { widget in
                    .init(id: widget.id, title: model.layout.title(of: widget, model), detail: model.layout.detail(of: widget),
                          symbol: model.layout.symbol(of: widget, model), sizes: model.layout.sizes(of: widget),
                          size: model.layout.size(of: widget, model))
                },
                arrangement: model.layout.layout.widgets,
                footnote: "Small cards sit two to a row; one on its own takes the row. Stay awake, the auto clicker and the fan share a card when they're next to each other.",
                selected: editing.selected,
                select: { editing.selected = $0 },
                setSize: { id, size in
                    guard let widget = PanelLayoutStore.Widget(id: id) else { return }
                    model.layout.setSize(size, of: widget, model)
                },
                change: { change in model.layout.update { change(&$0.widgets) } })

            if !tools.isEmpty {
                ArrangementEditor(
                    title: "Tools row",
                    items: tools.map { .init(id: $0.id, title: $0.title, detail: $0.action.isPlugin ? "Your plugin" : nil, symbol: $0.symbol) },
                    arrangement: model.layout.layout.tools,
                    footnote: "Six to a row; more start a second row. Tools turned off and your plugins are on the Plugins page.",
                    change: { change in model.layout.update { change(&$0.tools) } })
                    .opacity(model.layout.isShown(.card(.tools)) ? 1 : 0.5)
            }

            HStack {
                Text("Only the panel changes here; every tool keeps working with its shortcut whatever the panel shows.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 16)
                Button("Restore Defaults") {
                    withAnimation(Motion.snappy) { model.layout.reset() }
                    editing.selected = nil
                }
                .buttonStyle(OutlineButtonStyle(compact: true))
                .disabled(!model.layout.isCustomized)
            }
        }
    }
}

/// The card selected in the preview: its size and a way to hide it.
private struct SelectedCard: View {
    var model: AppModel
    var widget: PanelLayoutStore.Widget
    var editing: PanelEditing

    var body: some View {
        let sizes = model.layout.sizes(of: widget)
        HStack(spacing: 10) {
            Image(systemName: model.layout.symbol(of: widget, model))
                .font(.system(size: 12.5))
                .foregroundStyle(Color.ink2)
                .frame(width: 18)
            Text(model.layout.title(of: widget, model))
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 8)
            if sizes.count > 1 {
                InkSegmented(selection: Binding(get: { model.layout.size(of: widget, model) },
                                                set: { model.layout.setSize($0, of: widget, model) }),
                             options: WidgetSize.allCases.filter(sizes.contains).map { ($0, $0 == .small ? "Small" : "Wide") })
            }
            QuietButton(title: "Hide") {
                withAnimation(Motion.snappy) { model.layout.update { $0.widgets.set(widget.id, shown: false) } }
                editing.selected = nil
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(CardSurface(radius: 10))
    }
}

// MARK: - Preview

/// The real panel at 85 %, as it will look. With `editing`, its cards can be arranged in place.
struct PanelPreview: View {
    var model: AppModel
    var editing: PanelEditing?

    static let scale: CGFloat = 0.85
    static let width: CGFloat = 320 * scale

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        Scaled(scale: Self.scale) {
            MenuPanel(model: model, preview: true, editing: editing)
                .background(shape.fill(.regularMaterial))
                .clipShape(shape)
                .overlay(shape.strokeBorder(Color.hairline))
        }
        .allowsHitTesting(editing != nil)
        .accessibilityHidden(editing == nil)
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

/// A list of items to show or hide and drag into order (or Move Up / Move Down from a row's menu),
/// each small or wide where it comes in both sizes.
struct ArrangementEditor: View {
    struct Item: Identifiable, Equatable {
        var id: String
        var title: String
        var detail: String?
        var symbol: String
        var sizes: [WidgetSize] = []
        var size: WidgetSize?
    }

    var title: String
    var items: [Item]
    var arrangement: Arrangement
    var footnote: String?
    var selected: String?
    var select: ((String) -> Void)?
    var setSize: ((String, WidgetSize) -> Void)?
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
        let isSelected = selected == item.id
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
            if item.sizes.count > 1, let size = item.size, let setSize {
                InkSegmented(selection: Binding(get: { size }, set: { setSize(item.id, $0) }),
                             options: WidgetSize.allCases.filter(item.sizes.contains).map { ($0, $0 == .small ? "Small" : "Wide") })
                    .opacity(shown ? 1 : 0.5)
                    .help("How much of the panel's width it takes")
            }
            InkSwitch(isOn: Binding(get: { shown }, set: { on in change { $0.set(item.id, shown: on) } }),
                      label: "Show \(item.title)")
        }
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: Radius.of(8), style: .continuous)
                .fill(Color.themeAccent.opacity(isSelected ? 0.10 : 0))
                .padding(.horizontal, -8)
        }
        .contentShape(Rectangle())
        .onTapGesture { select?(item.id) }
        .opacity(dragging == item.id ? 0.4 : 1)
        .overlay(alignment: .top) {
            // Where a dragged row will land.
            if target == item.id, dragging != item.id {
                Capsule().fill(Color.themeAccent).frame(height: 2).offset(y: -1)
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
            if item.sizes.count > 1, let setSize {
                Divider()
                ForEach(item.sizes, id: \.self) { size in
                    Button(size == .small ? "Small" : "Wide") { setSize(item.id, size) }
                        .disabled(item.size == size)
                }
            }
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
