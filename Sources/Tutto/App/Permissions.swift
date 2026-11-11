//
//  Permissions.swift
//  Tutto
//
//  Live status of everything macOS asks the user to approve, with what each one powers.
//  Nothing polls: status is re-read when macOS announces a change, when Tutto becomes
//  active, or when a permissions view is on screen. The Finder extension's state takes a
//  `pluginkit` run to read, so that one is re-read only where it's shown, or at most every
//  10 minutes otherwise (opening the menu bar panel makes Tutto active each time).
//

import AppKit
import ApplicationServices
import CoreGraphics
import Observation
import ServiceManagement

enum Permission: String, CaseIterable, Identifiable {
    case accessibility
    case screenRecording
    case systemAudio
    case finderExtension
    case fanHelper
    case fullDiskAccess

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accessibility: "Accessibility"
        case .screenRecording: "Screen Recording"
        case .systemAudio: "System Audio Recording"
        case .finderExtension: "Finder extension"
        case .fanHelper: "Tutto's helper"
        case .fullDiskAccess: "Full Disk Access"
        }
    }

    /// What breaks without it, in plain words.
    var powers: String {
        switch self {
        case .accessibility: "Trackpad Corner, the window switcher, the scrolling strip, moving windows, pasting from clipboard history, and the auto clicker."
        case .screenRecording: "Screenshots, color picking, text recognition, and window titles and pictures in the switcher."
        case .systemAudio: "Muting apps in Sound. Tutto holds their sound back; nothing is recorded."
        case .finderExtension: "Extract and Compress in Finder's right-click menu."
        case .fanHelper: "Setting fan speeds, and Stay Awake with the lid closed. Reading temperatures and fans doesn't need it."
        case .fullDiskAccess: "Clean Up's look into apps' containers and the Trash. Optional: without it, Clean Up checks everything else."
        }
    }

    var modules: [ModuleID] {
        switch self {
        case .accessibility: [.corner, .windows, .switcher, .strip, .clipboard, .clicker, .converter]
        case .screenRecording: [.screenshots, .switcher]
        case .systemAudio: [.sound]
        case .finderExtension: [.archives]
        case .fanHelper: [.sensors, .awake]
        case .fullDiskAccess: [.cleaner]
        }
    }

    /// Where to switch it on, as the user will see it on macOS 26.
    var settingsPath: String {
        switch self {
        case .accessibility: "Privacy & Security › Accessibility"
        case .screenRecording: "Privacy & Security › Screen & System Audio Recording"
        case .systemAudio: "Privacy & Security › Screen & System Audio Recording › System Audio Recording Only"
        case .finderExtension: "General › Login Items & Extensions › Extensions"
        case .fanHelper: "General › Login Items & Extensions › App Background Activity"
        case .fullDiskAccess: "Privacy & Security › Full Disk Access"
        }
    }
}

@MainActor
@Observable
final class Permissions {
    private(set) var accessibility = AXIsProcessTrusted()
    private(set) var screenRecording = CGPreflightScreenCaptureAccess()
    private(set) var systemAudio = SystemAudioAccess.status()
    private(set) var finderExtension: Bool?
    private(set) var fanHelper: SMAppService.Status = .notRegistered
    private(set) var fullDiskAccess = Permissions.hasFullDiskAccess()

    nonisolated static let finderExtensionID = "ca.bryanyao.Tutto.FinderExtension"
    nonisolated static let helperPlist = "ca.bryanyao.Tutto.helper.plist"

    init() {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            // The trust database settles a moment after the announcement.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func isGranted(_ permission: Permission) -> Bool? {
        switch permission {
        case .accessibility: accessibility
        case .screenRecording: screenRecording
        case .systemAudio: systemAudio == .unknown ? nil : systemAudio == .granted
        case .finderExtension: finderExtension
        case .fanHelper: fanHelper == .enabled
        case .fullDiskAccess: fullDiskAccess
        }
    }

    /// Full Disk Access has no call to ask about it; opening a file only it can read tells.
    nonisolated static func hasFullDiskAccess() -> Bool {
        let probe = "/Library/Application Support/com.apple.TCC/TCC.db"
        guard let handle = FileHandle(forReadingAtPath: probe) else { return false }
        try? handle.close()
        return true
    }

    /// `finderMaxAge`: re-read the Finder extension only when its state is older than this.
    func refresh(finderMaxAge: TimeInterval = 600) {
        accessibility = AXIsProcessTrusted()
        screenRecording = CGPreflightScreenCaptureAccess()
        systemAudio = SystemAudioAccess.status()
        fanHelper = SMAppService.daemon(plistName: Self.helperPlist).status
        fullDiskAccess = Self.hasFullDiskAccess()
        if finderCheckedAt.map({ -$0.timeIntervalSinceNow >= finderMaxAge }) ?? true { refreshFinderExtension() }
    }

    private var finderCheckedAt: Date?

    /// `pluginkit -m` lists the extension with a leading "+" when it's switched on.
    func refreshFinderExtension() {
        finderCheckedAt = Date()
        Task.detached(priority: .utility) {
            let output = Shell.run("/usr/bin/pluginkit", ["-m", "-i", Self.finderExtensionID])
            let enabled: Bool? = output.isEmpty ? nil : output.trimmingCharacters(in: .whitespaces).hasPrefix("+")
            await MainActor.run { self.finderExtension = enabled }
        }
    }

    // MARK: Requests

    func request(_ permission: Permission) {
        switch permission {
        case .accessibility:
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            if !AXIsProcessTrustedWithOptions(options) {
                open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            }
        case .screenRecording:
            // The first request shows macOS's own prompt; after that it only opens Settings.
            if !CGRequestScreenCaptureAccess() {
                open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            }
        case .systemAudio:
            if systemAudio == .denied {
                open("x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")
            } else {
                SystemAudioAccess.request { _ in
                    Task { @MainActor in AppModel.shared.permissions.refresh() }
                }
            }
        case .finderExtension:
            setFinderExtension(enabled: true)
            open("x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
        case .fanHelper:
            do {
                try SMAppService.daemon(plistName: Self.helperPlist).register()
            } catch {
                NSLog("Tutto: helper registration: \(error.localizedDescription)")
            }
            fanHelper = SMAppService.daemon(plistName: Self.helperPlist).status
            if fanHelper == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        case .fullDiskAccess:
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        }
        refresh()
    }

    /// Turns the Finder extension on or off for this user (no admin rights needed).
    func setFinderExtension(enabled: Bool) {
        Task.detached(priority: .utility) {
            if let path = Bundle.main.builtInPlugInsURL?.appendingPathComponent("TuttoFinder.appex").path {
                _ = Shell.run("/usr/bin/pluginkit", ["-a", path])
            }
            _ = Shell.run("/usr/bin/pluginkit", ["-e", enabled ? "use" : "ignore", "-i", Self.finderExtensionID])
            await MainActor.run { self.refreshFinderExtension() }
        }
    }

    private func open(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }
}

/// Runs a short command and returns its output. Only for quick system tools (pluginkit).
enum Shell {
    @discardableResult
    static func run(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
