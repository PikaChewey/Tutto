//
//  KeyboardCleaner.swift
//  Tutto
//
//  Keyboard cleaning: keys and trackpad clicks are locked for 15, 30 or 60 s so you
//  can wipe them, then everything comes back by itself. A calm full-screen overlay
//  on every display counts down; nothing typed can end it early. Idle cost is zero:
//  no tap, window or timer exists outside a run.
//

import AppKit
import Observation
import SwiftUI
import TuttoKit

@MainActor
@Observable
final class KeyboardCleaner {
    static let shared = KeyboardCleaner()

    /// 15, 30 or 60; saved.
    var seconds: Int = KeyboardCleanLock.clamped(UserDefaults.standard.integer(forKey: "keyboardClean.seconds")) {
        didSet { UserDefaults.standard.set(KeyboardCleanLock.clamped(seconds), forKey: "keyboardClean.seconds") }
    }

    private(set) var isRunning = false

    @ObservationIgnored private let tap = KeyboardCleanTap()
    @ObservationIgnored private var windows: [NSWindow] = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var screenObserver: NSObjectProtocol?
    @ObservationIgnored private let state = CleaningState()

    func start() {
        guard !isRunning else { return }
        let total = KeyboardCleanLock.clamped(seconds)
        guard tap.start() else {
            Toast.shared.show("Keyboard cleaning needs Accessibility", detail: "Allow Tutto in System Settings, then try again.")
            AppModel.shared.permissions.request(.accessibility)
            return
        }
        isRunning = true
        state.total = total
        state.secondsLeft = Double(total)
        let deadline = ProcessInfo.processInfo.systemUptime + Double(total)
        showOverlays()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.showOverlays() }
        }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let left = deadline - ProcessInfo.processInfo.systemUptime
                if left <= 0 { self.finish() } else { self.state.secondsLeft = left }
            }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        tap.stop()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        isRunning = false
    }

    private func showOverlays() {
        windows.forEach { $0.orderOut(nil) }
        windows = NSScreen.screens.map { screen in
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.contentView = NSHostingView(rootView: CleaningOverlay(state: state))
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            return window
        }
    }
}

@MainActor
@Observable
final class CleaningState {
    var secondsLeft: Double = 30
    var total: Int = 30
}

/// A dark, quiet screen with the time left. Static apart from the numbers; with Reduce
/// Motion on, the ring steps instead of gliding.
struct CleaningOverlay: View {
    var state: CleaningState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let progress = KeyboardCleanLock.progress(secondsLeft: state.secondsLeft, total: state.total)
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Color.black.opacity(0.55)
            VStack(spacing: 26) {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.14), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(Color.themeAccent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(reduceMotion ? nil : .linear(duration: 0.25), value: progress)
                    Text(KeyboardCleanLock.countdownText(secondsLeft: state.secondsLeft))
                        .font(.system(size: 64, weight: .light).monospacedDigit())
                        .foregroundStyle(.white)
                }
                .frame(width: 220, height: 220)
                Text("Keys and trackpad are locked. They come back on their own.")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .combine)
    }
}
