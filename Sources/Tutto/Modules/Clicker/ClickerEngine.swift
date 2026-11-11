//
//  ClickerEngine.swift
//  Tutto
//
//  Posts the auto clicker's clicks. A thread of its own at the highest priority sleeps to each
//  click's exact time (`mach_wait_until`), so the rate holds at 100 per second and doesn't drift
//  with the main thread's work, the way a run-loop timer does. Double clicks carry the click
//  state macOS uses to tell a double click from two clicks (1, then 2).
//
//  Clicks are marked as Tutto's own, so Trackpad Corner never turns them into right-clicks.
//

import AppKit
import os
import TuttoKit

final class ClickerEngine: @unchecked Sendable {
    /// What the run did, read by the main thread a few times a second.
    struct Progress: Sendable {
        var clicks = 0
        var started = Date()
    }

    enum Ending: Sendable {
        case asked, done, corner
    }

    private let settings: ClickerSettings
    private let lock = OSAllocatedUnfairLock(initialState: (stop: false, progress: Progress()))
    private var thread: Thread?
    private let onEnd: @Sendable (Ending) -> Void

    init(settings: ClickerSettings, onEnd: @escaping @Sendable (Ending) -> Void) {
        self.settings = settings
        self.onEnd = onEnd
    }

    var progress: Progress { lock.withLock { $0.progress } }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "ca.bryanyao.Tutto.clicker"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    func stop() {
        lock.withLock { $0.stop = true }
    }

    // MARK: The loop (its own thread)

    private func run() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        func ticks(_ seconds: Double) -> UInt64 {
            UInt64(max(seconds, 0) * 1_000_000_000 * Double(timebase.denom) / Double(timebase.numer))
        }
        let begin = Date()
        lock.withLock { $0.progress = Progress(clicks: 0, started: begin) }
        let source = CGEventSource(stateID: .hidSystemState)
        let screens = Self.screens()
        var next = mach_absolute_time()
        var clicks = 0
        var ending = Ending.asked
        while true {
            if lock.withLock({ $0.stop }) { break }
            let pointer = CGEvent(source: nil)?.location ?? .zero
            if settings.cornerStops, ClickerRules.inCorner(pointer, screens: screens) {
                ending = .corner
                break
            }
            post(at: target(pointer), source: source)
            clicks += 1
            let elapsed = Date().timeIntervalSince(begin)
            lock.withLock { $0.progress.clicks = clicks }
            if ClickerRules.isDone(settings, clicks: clicks, elapsed: elapsed) {
                ending = .done
                break
            }
            // The next click is due one wait after the last one was due: lateness doesn't add up.
            next += ticks(ClickerRules.wait(settings, random: Double.random(in: 0..<1)))
            let now = mach_absolute_time()
            if next < now { next = now }  // fell behind (the Mac was busy): carry on from now
            if case .afterSeconds(let limit) = settings.stop, elapsed + Double(next - now) * Double(timebase.numer) / Double(timebase.denom) / 1e9 > limit {
                ending = .done
                break
            }
            mach_wait_until(next)
        }
        onEnd(ending)
    }

    private func target(_ pointer: CGPoint) -> CGPoint {
        switch settings.target {
        case .pointer: pointer
        case .point(let x, let y): CGPoint(x: x, y: y)
        }
    }

    private func post(at location: CGPoint, source: CGEventSource?) {
        let (down, up, button): (CGEventType, CGEventType, CGMouseButton) = switch settings.button {
        case .left: (.leftMouseDown, .leftMouseUp, .left)
        case .right: (.rightMouseDown, .rightMouseUp, .right)
        case .middle: (.otherMouseDown, .otherMouseUp, .center)
        }
        for state in settings.double ? [1, 2] : [1] {
            for type in [down, up] {
                guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: location, mouseButton: button)
                else { continue }
                event.setIntegerValueField(.mouseEventClickState, value: Int64(state))
                event.setIntegerValueField(.eventSourceUserData, value: EngineCore.syntheticMarker)
                event.post(tap: .cghidEventTap)
            }
        }
    }

    /// Every display, in the global top-left points clicks use.
    static func screens() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }
}
