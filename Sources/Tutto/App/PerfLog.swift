//
//  PerfLog.swift
//  Tutto
//
//  Opt-in timing of main-thread work, for finding what makes an animation hitch:
//
//      defaults write ca.bryanyao.Tutto debug.perf -bool true    (then relaunch Tutto)
//      log stream --predicate 'subsystem == "ca.bryanyao.Tutto" AND category == "perf"'
//
//  Off, it costs one Bool check per measured piece of work. On, anything slow is logged by
//  name, and a watchdog reports every time the main thread answers late (whatever held it).
//

import Foundation
import os
import QuartzCore

enum PerfLog {
    static let enabled = UserDefaults.standard.bool(forKey: "debug.perf")
    private static let log = Logger(subsystem: "ca.bryanyao.Tutto", category: "perf")

    /// Runs `body`, logging it when it takes longer than `threshold` seconds.
    @inline(__always)
    static func measure<T>(_ label: @autoclosure () -> String, over threshold: Double = 0.008, _ body: () throws -> T) rethrows -> T {
        guard enabled else { return try body() }
        let start = CACurrentMediaTime()
        defer {
            let took = CACurrentMediaTime() - start
            if took > threshold {
                let text = label()
                log.notice("\(text, privacy: .public) took \(Int(took * 1000)) ms")
            }
        }
        return try body()
    }

    /// For work with early returns: `let timing = PerfLog.begin("…"); defer { timing.end() }`.
    struct Timing {
        fileprivate let label: String?
        fileprivate let start: CFTimeInterval
        fileprivate let threshold: Double

        func end() {
            guard let label else { return }
            let took = CACurrentMediaTime() - start
            if took > threshold { PerfLog.log.notice("\(label, privacy: .public) took \(Int(took * 1000)) ms") }
        }
    }

    static func begin(_ label: @autoclosure () -> String, over threshold: Double = 0.008) -> Timing {
        guard enabled else { return Timing(label: nil, start: 0, threshold: 0) }
        return Timing(label: label(), start: CACurrentMediaTime(), threshold: threshold)
    }

    /// Every 10 ms a background thread asks the main thread to answer; an answer more than 30 ms
    /// late means the main thread was busy (or blocked) that long.
    static func startWatchdog() {
        guard enabled else { return }
        let thread = Thread {
            while true {
                let sent = CACurrentMediaTime()
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async {
                    let late = CACurrentMediaTime() - sent
                    if late > 0.03 { log.notice("main thread late by \(Int(late * 1000)) ms") }
                    answered.signal()
                }
                answered.wait()
                usleep(10_000)
            }
        }
        thread.name = "Perf watchdog"
        thread.qualityOfService = .utility
        thread.start()
    }
}
