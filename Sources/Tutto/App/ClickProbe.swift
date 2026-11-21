//
//  ClickProbe.swift
//  Tutto
//
//  Debug-only: `Tutto --click-probe <dir> [trials]` puts the real panel in an off-screen window and
//  clicks the control chips the way a hand does (pointer arrives, sometimes clicks at once, sometimes
//  rests; holds 20-250 ms; sometimes drifts 1-4 pt while held), at random spots on each chip, and
//  counts the clicks that didn't open or close the control. Nothing is clicked on screen.
//

#if DEBUG
import AppKit
import SwiftUI

@MainActor
enum ClickProbe {
    nonisolated(unsafe) static var running = false
    nonisolated(unsafe) static var opened: [String] = []
    nonisolated(unsafe) static var frames: [String: CGRect] = [:]

    /// `--modules-probe`: every tool off in turn, in memory; any shortcut of that tool still bound fails.
    static func runModulesIfRequested() -> Bool {
        guard CommandLine.arguments.contains("--modules-probe") else { return false }
        let model = AppModel.shared
        AppModel.rendersOffscreen = true
        model.launch(quietly: true)
        model.bindShortcuts()
        var failures = 0
        for module in ModuleID.allCases where model.isEnabled(module) {
            model.probeSetEnabled(module, false)
            let leaks = ShortcutAction.all.filter { $0.module == module && model.hotkeys.isBound($0.id) }
            let others = ShortcutAction.all.filter { $0.module != module && $0.module.map(model.isEnabled) ?? false
                && model.shortcuts.shortcut(for: $0) != nil && !model.hotkeys.isBound($0.id) }
            if !leaks.isEmpty || !others.isEmpty { failures += 1 }
            print("\(module.rawValue) off: still bound \(leaks.map(\.id)), others lost \(others.map(\.id))")
            model.probeSetEnabled(module, true)
        }
        for action in ShortcutAction.all { model.hotkeys.unbind(action.id) }
        print("RESULT \(failures) tools with a wrong shortcut state")
        return true
    }

    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--click-probe"), args.count > flag + 1 else { return false }
        let dir = URL(fileURLWithPath: args[flag + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let trials = args.count > flag + 2 ? Int(args[flag + 2]) ?? 200 : 200
        var lines: [String] = []
        func say(_ line: String) { lines.append(line); print(line) }

        let model = AppModel.shared
        AppModel.rendersOffscreen = true
        model.launch(quietly: true)
        ThemeStore.shared.apply(.liquidGlass, remember: false)
        ThinScrollStage.limit = 5_000
        running = true
        // Pinned to the top of a window taller than it ever gets, so opening a control never moves the chips.
        let host = NSHostingView(rootView: MenuPanel(model: model, preview: true).frame(maxHeight: .infinity, alignment: .top))
        var size = host.fittingSize
        size.height = 1_600
        let window = NSWindow(contentRect: NSRect(x: -6000, y: 200, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        RecordingProbe.pump(1.5)

        var generator = SystemRandomNumberGenerator()
        var failures: [String: Int] = [:], attempts: [String: Int] = [:]
        var expected: String? = nil
        func send(_ type: NSEvent.EventType, _ point: NSPoint) {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                 clickCount: type == .mouseMoved ? 0 : 1, pressure: type == .leftMouseUp ? 0 : 1) else { return }
            window.sendEvent(event)
        }
        /// A hand's click at a random spot: the pointer arrives, maybe rests, holds 20-250 ms and may
        /// drift 1-4 pt toward the middle while held (a drift off the edge rightly cancels a click).
        func click(_ frame: CGRect, avoiding holes: [CGRect] = []) -> CGPoint {
            var x = 0.0, y = 0.0
            repeat {
                x = CGFloat.random(in: frame.minX + 1...frame.maxX - 1, using: &generator)
                y = CGFloat.random(in: frame.minY + 1...frame.maxY - 1, using: &generator)
            } while holes.contains { $0.insetBy(dx: -3, dy: -3).contains(CGPoint(x: x, y: y)) }
            let height = host.bounds.height
            let point = NSPoint(x: x, y: height - y)
            let rest = [0.0, 0.0, 0.03, 0.08, 0.3].randomElement(using: &generator)!
            let hold = Double.random(in: 0.02...0.25, using: &generator)
            let drift = Bool.random(using: &generator) ? CGFloat.random(in: 1...4, using: &generator) * (x < frame.midX ? 1 : -1) : 0
            send(.mouseMoved, point)
            if rest > 0 { RecordingProbe.pump(rest) }
            send(.leftMouseDown, point)
            RecordingProbe.pump(hold / 2)
            if drift != 0 { send(.leftMouseDragged, NSPoint(x: point.x + drift, y: point.y)) }
            RecordingProbe.pump(hold / 2)
            send(.leftMouseUp, NSPoint(x: point.x + drift, y: point.y))
            RecordingProbe.pump(0.3)
            return CGPoint(x: x - frame.minX, y: y - frame.minY)
        }
        // The chips: each click opens its control, or closes it when it's the open one.
        for trial in 0..<trials {
            let chips = frames.filter { $0.key.hasPrefix("chip.") }
            guard let key = chips.keys.sorted().randomElement(using: &generator), let frame = chips[key] else { say("no chips"); break }
            let id = String(key.dropFirst(5))
            let at = click(frame)
            expected = expected == id ? nil : id
            attempts[key, default: 0] += 1
            let got = ControlStripView.probeOpen
            if got != expected {
                failures[key, default: 0] += 1
                say(String(format: "MISS #%d %@ at (%.0f,%.0f): open=%@ expected=%@", trial, id, at.x, at.y, got ?? "nil", expected ?? "nil"))
                expected = got
            }
        }
        // Close whatever is open, so the cards below sit where they were measured.
        if let open = expected, let frame = frames["chip.\(open)"] { _ = click(frame) }
        RecordingProbe.pump(0.5)
        // The battery card (anywhere but its Show button) and the readings' tiles: each click opens one page.
        let pages = frames.filter { $0.key == "battery" || $0.key.hasPrefix("tile.") }
        for trial in 0..<(trials / 2) {
            guard let key = pages.keys.sorted().randomElement(using: &generator), let frame = frames[key] else { say("no cards"); break }
            let before = opened.count
            let at = click(frame, avoiding: key == "battery" ? [frames["battery.show"]].compactMap { $0 } : [])
            attempts[key, default: 0] += 1
            if opened.count != before + 1 {
                failures[key, default: 0] += 1
                say(String(format: "MISS #%d %@ at (%.0f,%.0f): opened %d pages", trial, key, at.x, at.y, opened.count - before))
            }
        }
        let total = failures.values.reduce(0, +), clicks = attempts.values.reduce(0, +)
        say("chips: " + attempts.keys.sorted().map { "\($0) \(failures[$0, default: 0])/\(attempts[$0]!)" }.joined(separator: ", "))
        say("RESULT \(total) misses in \(clicks) clicks")
        try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent("clicks.txt"), atomically: true, encoding: .utf8)
        return true
    }
}
#endif
