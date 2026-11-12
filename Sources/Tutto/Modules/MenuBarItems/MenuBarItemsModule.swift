//
//  MenuBarItemsModule.swift
//  Tutto
//
//  Menu Bar Icons: tuck away the menu bar icons you rarely use.
//
//  One extra menu bar item, a thin divider with a small chevron, sits just left of Tutto's own icon.
//  macOS lays items out from the right, so making the divider very long (10,000 pt) pushes every
//  icon to its left off the screen, and making it short again brings them back. Nothing is closed,
//  moved or restarted; the icons are only out of sight. You choose what's tucked away by holding ⌘
//  and dragging icons to the left of the divider (a macOS feature).
//
//  Costs nothing while idle: one status item, no timers, no polling. A single one-shot timer runs
//  only while the icons are showing (to hide them again), and everything is released when the
//  module is off or Tutto quits, which leaves every icon visible.
//

import AppKit
import SwiftUI
import TuttoKit

@MainActor
@Observable
final class MenuBarItemsModule: ModuleController {
    /// Collapsed: the icons left of the divider are out of sight. Expanded: everything shows.
    private(set) var divider = MenuBarDivider(isCollapsed: false)
    /// The divider's place in the menu bar, for the page. Only `.tuttoWouldBeTucked` matters.
    private(set) var order: MenuBarOrder = .unknown
    /// The divider is in the menu bar.
    private(set) var isRunning = false

    var autoHide: MenuBarAutoHide {
        didSet {
            guard autoHide != oldValue else { return }
            defaults.set(autoHide.rawValue, forKey: Keys.autoHide)
            rearmAutoHide()
        }
    }

    @ObservationIgnored private var item: NSStatusItem?
    @ObservationIgnored private let clickTarget = DividerClickTarget()
    @ObservationIgnored private var shownSince: Date?
    @ObservationIgnored private var hideWork: DispatchWorkItem?
    @ObservationIgnored private var settleWork: DispatchWorkItem?
    @ObservationIgnored private let defaults = UserDefaults.standard

    /// The name macOS saves the divider's place under, so it stays where you put it.
    static let autosaveName = "tutto.divider"
    /// Tutto's own icon is the SwiftUI menu bar item, which macOS saves under this name.
    private static let tuttoItemName = "Item-0"

    init() {
        autoHide = MenuBarAutoHide(rawValue: defaults.object(forKey: Keys.autoHide) as? Int ?? MenuBarAutoHide.standard.rawValue)
            ?? .standard
        clickTarget.onClick = { [weak self] in self?.toggle() }
    }

    // MARK: ModuleController

    /// Adds the divider and, once the menu bar has laid it out, tucks the icons away.
    func start() {
        guard item == nil else { return }
        seedPosition()
        let item = NSStatusBar.system.statusItem(withLength: MenuBarDivider.expandedLength)
        item.autosaveName = Self.autosaveName
        self.item = item
        if let button = item.button {
            // The divider's window is 10,000 pt wide while collapsed; its chevron stays at the right
            // end, next to Tutto's icon, the only part on screen.
            button.imagePosition = .imageRight
            button.alignment = .right
            button.imageScaling = .scaleNone
            button.target = clickTarget
            button.action = #selector(DividerClickTarget.clicked)
        }
        isRunning = true
        divider = MenuBarDivider(isCollapsed: false)
        apply()
        // Look at where macOS put it before hiding anything: if Tutto's own icon is on the wrong
        // side, tucking would hide that too.
        settle(attempt: 0)
    }

    /// Removes the divider. Every icon is visible again.
    func stop() {
        hideWork?.cancel()
        hideWork = nil
        settleWork?.cancel()
        settleWork = nil
        shownSince = nil
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
        isRunning = false
        order = .unknown
        divider = MenuBarDivider(isCollapsed: false)
    }

    /// Shows the tucked-away icons, or tucks them away again.
    func toggle() {
        guard item != nil else { return }
        settleWork?.cancel()
        settleWork = nil
        if divider.isCollapsed { expand() } else { collapse(byHand: true) }
    }

    // MARK: Tucking

    private func expand() {
        divider = MenuBarDivider(isCollapsed: false)
        apply()
        shownSince = Date()
        rearmAutoHide()
        refreshOrder(after: 0.3)
    }

    private func collapse(byHand: Bool) {
        hideWork?.cancel()
        hideWork = nil
        refreshOrder()
        if order == .tuttoWouldBeTucked {
            // Never hide Tutto's own icon: stay open and say why.
            if byHand {
                Toast.shared.show("Tutto's icon is left of the divider",
                                  detail: "Nothing is tucked away until it's on the right. Click for how.", duration: 5) {
                    MainWindowController.shared.show(page: .menuBarItems)
                }
            }
            return
        }
        divider = MenuBarDivider(isCollapsed: true)
        shownSince = nil
        apply()
    }

    private func apply() {
        guard let item else { return }
        item.length = divider.length
        if let button = item.button {
            button.image = DividerGlyph.image(collapsed: divider.isCollapsed)
            button.toolTip = divider.actionTitle
            button.setAccessibilityLabel(divider.actionTitle)
        }
    }

    /// Waits for the menu bar to lay the new item out, then tucks away. Gives up waiting after a
    /// second and a half: with no Tutto icon on screen, there is nothing to protect.
    private func settle(attempt: Int) {
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.item != nil else { return }
                self.refreshOrder()
                if self.order == .tuttoWouldBeTucked {
                    self.shownSince = Date()   // stays open; nothing to hide again
                } else if self.order == .unknown && attempt < 2 {
                    self.settle(attempt: attempt + 1)
                } else {
                    self.collapse(byHand: false)
                }
            }
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0.4 : 0.6), execute: work)
    }

    // MARK: Auto-hide

    /// One timer, only while the icons are showing.
    private func rearmAutoHide() {
        hideWork?.cancel()
        hideWork = nil
        guard !divider.isCollapsed, let since = shownSince else { return }
        switch autoHide.decision(shown: Date().timeIntervalSince(since), pointerInMenuBar: false) {
        case .stayOpen: break
        case .hide: scheduleAutoHideCheck(after: 0)
        case .checkAgain(let seconds): scheduleAutoHideCheck(after: seconds)
        }
    }

    private func scheduleAutoHideCheck(after seconds: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.autoHideCheck() }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func autoHideCheck() {
        hideWork = nil
        guard !divider.isCollapsed, let since = shownSince else { return }
        switch autoHide.decision(shown: Date().timeIntervalSince(since), pointerInMenuBar: Self.pointerIsInMenuBar()) {
        case .stayOpen: break
        case .hide: collapse(byHand: false)
        case .checkAgain(let seconds): scheduleAutoHideCheck(after: seconds)
        }
    }

    private static func pointerIsInMenuBar() -> Bool {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) ?? NSScreen.main else { return false }
        // With a notch the bar is taller than the status item; with the bar set to auto-hide the
        // visible frame doesn't show it at all, so never less than a status item's height.
        let bar = max(screen.frame.maxY - screen.visibleFrame.maxY, NSStatusBar.system.thickness)
        return MenuBarAutoHide.pointerIsInMenuBar(y: pointer.y, screenTop: screen.frame.maxY, barHeight: bar)
    }

    // MARK: Position

    /// The window of the divider, so Tutto's other menu bar checks can tell it from Tutto's icon.
    var dividerWindow: NSWindow? { item?.button?.window }

    /// Tutto's own menu bar icon (the SwiftUI item), never the divider.
    static func tuttoIconWindow(excluding divider: NSWindow?) -> NSWindow? {
        NSApp.windows.first { $0.className.contains("StatusBarWindow") && $0 !== divider }
    }

    /// Reads where the divider and Tutto's icon are now.
    func refreshOrder() {
        guard let divider = dividerWindow else { return }
        let tutto = Self.tuttoIconWindow(excluding: divider)
        order = MenuBarOrder.check(divider: divider.frame, tutto: tutto?.frame)
    }

    private func refreshOrder(after seconds: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            MainActor.assumeIsolated { self?.refreshOrder() }
        }
    }

    /// Puts the divider back just left of Tutto's icon (when it ended up on the wrong side).
    func putDividerBack() {
        guard isRunning else { return }
        stop()
        defaults.removeObject(forKey: MenuBarDividerPosition.defaultsKey(autosaveName: Self.autosaveName))
        start()
    }

    /// First run only: the divider starts next to Tutto's icon. After that macOS keeps the place you
    /// give it. Tutto's own defaults only.
    private func seedPosition() {
        let key = MenuBarDividerPosition.defaultsKey(autosaveName: Self.autosaveName)
        guard defaults.object(forKey: key) == nil else { return }
        let tutto = defaults.object(forKey: MenuBarDividerPosition.defaultsKey(autosaveName: Self.tuttoItemName)) as? NSNumber
        if let position = MenuBarDividerPosition.initial(tuttoPosition: tutto?.doubleValue) {
            defaults.set(position, forKey: key)
        }
    }

    #if DEBUG
    /// Offscreen renders: the page in a state, with no menu bar item made.
    func previewState(collapsed: Bool, order: MenuBarOrder) {
        divider = MenuBarDivider(isCollapsed: collapsed)
        self.order = order
        isRunning = true
    }
    #endif

    private enum Keys {
        static let autoHide = "menuBarItems.autoHideSeconds"
    }
}

/// A status item's button needs an Objective-C object to call.
@MainActor
final class DividerClickTarget: NSObject {
    var onClick: (() -> Void)?
    @objc func clicked() { onClick?() }
}

/// The divider's picture: a thin line and a small chevron, as a template image so macOS tints it
/// for light and dark menu bars.
enum DividerGlyph {
    static func image(collapsed: Bool) -> NSImage {
        let name = collapsed ? "chevron.left" : "chevron.right"
        let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        let image = NSImage(size: NSSize(width: 14, height: 16), flipped: false) { _ in
            NSColor.black.withAlphaComponent(0.5).setStroke()
            let line = NSBezierPath()
            line.lineWidth = 1
            line.lineCapStyle = .round
            line.move(to: NSPoint(x: 1.5, y: 2))
            line.line(to: NSPoint(x: 1.5, y: 14))
            line.stroke()
            if let symbol {
                let size = symbol.size
                symbol.draw(in: NSRect(x: 5 + (8 - size.width) / 2, y: (16 - size.height) / 2, width: size.width, height: size.height))
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = collapsed ? "Show hidden menu bar icons" : "Hide menu bar icons"
        return image
    }
}

// MARK: - Page

struct MenuBarItemsPage: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: "Menu Bar Icons", subtitle: ModuleID.menuBarItems.summary, module: .menuBarItems)
            if let module = model.menuBarItems {
                MenuBarItemsSettings(module: module, model: model)
            } else {
                ModuleOffView(module: .menuBarItems, model: model)
            }
        }
    }
}

struct MenuBarItemsSettings: View {
    @Bindable var module: MenuBarItemsModule
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            InkGroup("How it works") {
                MenuBarSketch(collapsed: module.divider.isCollapsed)
                    .padding(.vertical, 14)
                Hairline().opacity(0.6)
                LabeledRow(module.divider.isCollapsed ? "Tucked-away icons are hidden" : "Tucked-away icons are showing",
                           detail: "Hold ⌘ and drag an icon to the left of the divider to tuck it away. Click the divider, or use the shortcut, to show or hide them.") {
                    Button(module.divider.isCollapsed ? "Show" : "Hide") { module.toggle() }
                        .buttonStyle(OutlineButtonStyle(compact: true))
                        .disabled(!module.isRunning)
                }
            }
            if module.order == .tuttoWouldBeTucked {
                notice(symbol: "arrow.left.arrow.right", title: "Tutto's own icon is left of the divider.",
                       detail: "So nothing is tucked away, and the icons stay showing. Hold ⌘ and drag Tutto's icon to the right of the divider, or put the divider back next to it.",
                       button: "Put Divider Back") { module.putDividerBack() }
            }
            if model.menuBarIconHidden {
                notice(symbol: "menubar.rectangle", title: "The camera notch is covering Tutto's icon.",
                       detail: "Your menu bar is full. Tuck away the icons you rarely use to make room: hold ⌘, drag them left of the divider, then hide them.",
                       button: "Check Again") { model.checkMenuBarIconVisibility() }
            }
            InkGroup("Settings") {
                LabeledRow("Hide again after", detail: "Tucked-away icons hide by themselves, unless the pointer is in the menu bar.") {
                    InkSegmented(selection: $module.autoHide,
                                 options: MenuBarAutoHide.choices.map { ($0, $0.title) })
                        .fixedSize()
                }
                Hairline().opacity(0.6)
                LabeledRow("Shortcut", detail: "Shows or hides them.") {
                    ShortcutRecorder(action: .showMenuBarIcons, model: model)
                }
            }
            Text("Tutto's own icon always stays showing. Turning this off, or quitting Tutto, brings every icon back. Scripts can use `open -g tutto://do/menu-bar-icons`.")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { module.refreshOrder() }
    }

    private func notice(symbol: String, title: String, detail: String, button: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(Color.ink2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(Color.ink2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(button, action: action).buttonStyle(OutlineButtonStyle(compact: true))
        }
        .padding(14)
        .background(Color.wash, in: RoundedRectangle(cornerRadius: Radius.of(12), style: .continuous))
    }
}

/// A tiny menu bar: icons, the divider, then the icons that stay with Tutto's own. The ones left
/// of the divider fade while they're tucked away.
private struct MenuBarSketch: View {
    var collapsed: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            column(label: "Left of the divider: tucked away") {
                HStack(spacing: 9) {
                    fakeIcon(.circle); fakeIcon(.square); fakeIcon(.pill)
                }
                .opacity(collapsed ? 0.25 : 1)
                .animation(Motion.snappy, value: collapsed)
            }
            column(label: "Divider") {
                Image(nsImage: DividerGlyph.image(collapsed: collapsed))
                    .renderingMode(.template)
                    .foregroundStyle(Color.ink)
                    .frame(height: 16)
            }
            column(label: "Right of it: always showing") {
                HStack(spacing: 9) {
                    fakeIcon(.square); fakeIcon(.circle)
                    Image(nsImage: MenuBarGlyph.image()).renderingMode(.template).foregroundStyle(Color.ink)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("A menu bar: icons you tuck away, then the divider, then icons that always show, ending with Tutto's own.")
    }

    private enum Shape { case circle, square, pill }

    private func fakeIcon(_ shape: Shape) -> some View {
        Group {
            switch shape {
            case .circle: Circle().fill(Color.ink3).frame(width: 13, height: 13)
            case .square: RoundedRectangle(cornerRadius: 3.5, style: .continuous).fill(Color.ink3).frame(width: 13, height: 13)
            case .pill: Capsule().fill(Color.ink3).frame(width: 20, height: 11)
            }
        }
        .frame(height: 16)
    }

    private func column<Icons: View>(label: String, @ViewBuilder icons: () -> Icons) -> some View {
        VStack(spacing: 8) {
            icons()
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Color.ink3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }
}
