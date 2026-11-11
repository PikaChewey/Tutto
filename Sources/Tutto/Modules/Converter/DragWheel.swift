//
//  DragWheel.swift
//  Tutto
//
//  Start dragging files anywhere (Finder, the desktop, a mail), tap ⇧, and a wheel of what
//  they can become opens around the pointer: formats on the ring, Compress in the middle. Drop
//  on one and the copy appears beside the original. Drop anywhere else, or tap ⇧ again, and it
//  closes; it never takes the drag from where it was going.
//
//  How it knows a file drag is on: the drag pasteboard changes when a drag starts, so its change
//  count at the last mouse press is remembered; a ⇧ tap with the button still down and a newer
//  change count holding file URLs means files are being dragged right now. The two event monitors
//  this needs do an integer compare per mouse press and per modifier change.
//

import AppKit
import TuttoKit

@MainActor
final class DragWheel {
    private weak var module: ConverterModule?
    private var monitors: [Any] = []
    private var changeCountAtPress = -1
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func start(module: ConverterModule) {
        self.module = module
        guard monitors.isEmpty else { return }
        if let press = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.changeCountAtPress = NSPasteboard(name: .drag).changeCount }
        }) { monitors.append(press) }
        if let modifiers = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.modifiersChanged(event) }
        }) { monitors.append(modifiers) }
        if let release = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleHide() }
        }) { monitors.append(release) }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        hide()
    }

    private func modifiersChanged(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .function, .numericPad])
        guard flags == .shift else { return }
        // ⇧ again while it's open closes it.
        if panel?.isVisible == true { return hide() }
        guard NSEvent.pressedMouseButtons & 1 == 1 else { return }
        let pasteboard = NSPasteboard(name: .drag)
        guard pasteboard.changeCount != changeCountAtPress,
              let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return }
        show(for: urls, at: NSEvent.mouseLocation)
    }

    private func show(for urls: [URL], at point: NSPoint) {
        let kinds = urls.map(FileKind.of)
        let items: [WheelView.Item] = ConvertPlanner.targets(for: kinds).prefix(8).map { format in
            WheelView.Item(title: ConvertPlanner.combines(kinds, into: format) ? "One PDF" : format.title, action: .convert(format))
        }
        let compress = kinds.contains(where: ConvertPlanner.canCompress)
        guard !items.isEmpty || compress else { return }
        let size: CGFloat = 300
        let frame = NSRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
        let panel = self.panel ?? NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.panel = panel
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = WheelView(frame: NSRect(origin: .zero, size: frame.size), items: items, center: compress ? .compress : nil) { [weak self] action, dropped in
            self?.hide()
            self?.module?.run(action, on: dropped)
        }
        panel.contentView = view
        panel.setFrame(frame, display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.05 : 0.14
            panel.animator().alphaValue = 1
        }
    }

    /// The drop lands first; closing waits a moment after the button comes up.
    private func scheduleHide() {
        guard panel?.isVisible == true else { return }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.hide() } }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        panel?.orderOut(nil)
        panel?.contentView = nil
    }
}

/// The ring: segments of formats around a middle disc (Compress). The one under the drag lights up.
final class WheelView: NSView {
    struct Item {
        let title: String
        let action: ConvertAction
    }

    private let items: [Item]
    private let centerAction: ConvertAction?
    private let drop: (ConvertAction, [URL]) -> Void
    private var highlighted: Int?   // -1: the middle
    private let inner: CGFloat = 54
    private let outer: CGFloat = 140

    init(frame: NSRect, items: [Item], center: ConvertAction?, highlighted: Int? = nil, drop: @escaping (ConvertAction, [URL]) -> Void) {
        self.items = items
        self.centerAction = center
        self.drop = drop
        self.highlighted = highlighted
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { nil }

    private var middle: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }

    /// Which segment a point is on (-1 the middle), or nil off the wheel.
    private func target(at point: CGPoint) -> Int? {
        let dx = point.x - middle.x, dy = point.y - middle.y
        let distance = (dx * dx + dy * dy).squareRoot()
        if distance <= inner - 4 { return centerAction == nil ? nil : -1 }
        guard distance <= outer + 6, !items.isEmpty else { return nil }
        // Segment 0 is centred at the top, going clockwise.
        var angle = atan2(dx, dy)
        if angle < 0 { angle += 2 * .pi }
        let span = 2 * .pi / CGFloat(items.count)
        return Int(((angle + span / 2).truncatingRemainder(dividingBy: 2 * .pi)) / span) % items.count
    }

    override func draw(_ dirtyRect: NSRect) {
        let ring = NSBezierPath()
        ring.appendOval(in: NSRect(x: middle.x - outer, y: middle.y - outer, width: outer * 2, height: outer * 2))
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 18
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.set()
        NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill()
        ring.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        ring.lineWidth = 1
        ring.stroke()

        let span = 360 / CGFloat(max(items.count, 1))
        for (index, item) in items.enumerated() {
            // AppKit angles run counter-clockwise from the right; segment 0 is at the top.
            let centre = 90 - CGFloat(index) * span
            if highlighted == index {
                let segment = NSBezierPath()
                segment.appendArc(withCenter: middle, radius: outer - 3, startAngle: centre - span / 2 + 1, endAngle: centre + span / 2 - 1)
                segment.appendArc(withCenter: middle, radius: inner + 3, startAngle: centre + span / 2 - 1, endAngle: centre - span / 2 + 1, clockwise: true)
                segment.close()
                NSColor.controlAccentColor.setFill()
                segment.fill()
            }
            if items.count > 1 {
                let edge = (centre + span / 2) * .pi / 180
                let line = NSBezierPath()
                line.move(to: CGPoint(x: middle.x + cos(edge) * (inner + 2), y: middle.y + sin(edge) * (inner + 2)))
                line.line(to: CGPoint(x: middle.x + cos(edge) * (outer - 2), y: middle.y + sin(edge) * (outer - 2)))
                NSColor.separatorColor.setStroke()
                line.lineWidth = 1
                line.stroke()
            }
            let radians = centre * .pi / 180
            let radius = (inner + outer) / 2
            let label = item.title as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: items.count > 6 ? 12 : 13, weight: .semibold),
                .foregroundColor: highlighted == index ? NSColor.white : NSColor.labelColor,
            ]
            let size = label.size(withAttributes: attributes)
            label.draw(at: CGPoint(x: middle.x + cos(radians) * radius - size.width / 2, y: middle.y + sin(radians) * radius - size.height / 2),
                       withAttributes: attributes)
        }

        // The middle: Compress, or a quiet "drop on a format".
        let disc = NSBezierPath(ovalIn: NSRect(x: middle.x - inner, y: middle.y - inner, width: inner * 2, height: inner * 2))
        (highlighted == -1 ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.06)).setFill()
        disc.fill()
        NSColor.separatorColor.setStroke()
        disc.stroke()
        let title = (centerAction == nil ? "Drop on\na format" : "Compress") as NSString
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: centerAction == nil ? 11 : 12.5, weight: centerAction == nil ? .medium : .semibold),
            .foregroundColor: highlighted == -1 ? NSColor.white : (centerAction == nil ? NSColor.secondaryLabelColor : NSColor.labelColor),
            .paragraphStyle: paragraph,
        ]
        let rect = title.boundingRect(with: NSSize(width: inner * 1.7, height: inner * 2), options: .usesLineFragmentOrigin, attributes: attributes)
        title.draw(with: NSRect(x: middle.x - inner * 0.85, y: middle.y - rect.height / 2, width: inner * 1.7, height: rect.height),
                   options: .usesLineFragmentOrigin, attributes: attributes)
    }

    // MARK: Dragging

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { update(sender) }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        highlighted = nil
        needsDisplay = true
    }

    private func update(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        let now = target(at: point)
        if now != highlighted {
            highlighted = now
            needsDisplay = true
            if now != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        }
        return now == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let point = convert(sender.draggingLocation, from: nil)
        guard let index = target(at: point),
              let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        let action = index == -1 ? centerAction : items[index].action
        guard let action else { return false }
        drop(action, urls)
        return true
    }
}
