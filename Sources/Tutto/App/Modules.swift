//
//  Modules.swift
//  Tutto
//
//  The seven tools inside Tutto. Each can be switched off on its own, and a module
//  that is off holds no timers, taps, hotkeys, helpers or memory.
//

import SwiftUI

enum ModuleID: String, CaseIterable, Identifiable, Codable {
    case system
    case sensors
    case clipboard
    case windows
    case screenshots
    case archives
    case cornerClick

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .sensors: "Sensors & Fans"
        case .clipboard: "Clipboard"
        case .windows: "Windows"
        case .screenshots: "Screenshots"
        case .archives: "Archives"
        case .cornerClick: "CornerClick"
        }
    }

    var symbol: String {
        switch self {
        case .system: "gauge.with.dots.needle.33percent"
        case .sensors: "fan"
        case .clipboard: "list.clipboard"
        case .windows: "rectangle.split.2x1"
        case .screenshots: "viewfinder"
        case .archives: "archivebox"
        case .cornerClick: "rectangle.inset.bottomright.filled"
        }
    }

    /// One line, shown in General and onboarding.
    var summary: String {
        switch self {
        case .system: "Battery health, CPU, GPU, memory, disk and network."
        case .sensors: "Temperatures, fan speeds and fan control."
        case .clipboard: "Searchable history of text, images, files and links."
        case .windows: "Snap windows to halves, thirds and quarters from a palette."
        case .screenshots: "Capture to clipboard, edit, draw, pick colors, copy text."
        case .archives: "Open RAR, 7z, zip and more, right from Finder."
        case .cornerClick: "Click or tap a trackpad corner to right-click."
        }
    }

    /// What it costs while it's on and you're not looking at it.
    var idleCost: String {
        switch self {
        case .system, .sensors: "Nothing. Readings are taken only while they're on screen."
        case .clipboard: "Checks the clipboard about once a second, coalesced with other system work."
        case .windows, .screenshots: "Nothing. Registered shortcuts wait for a key press."
        case .archives: "Nothing in Tutto. Finder loads the small menu extension."
        case .cornerClick: "Nothing until a finger touches the trackpad."
        }
    }

    /// The app this module replaces, for the migration notes.
    var replaces: String {
        switch self {
        case .system: "Stats"
        case .sensors: "Macs Fan Control"
        case .clipboard: "Raycast Clipboard History"
        case .windows: "Raycast Window Management"
        case .screenshots: "Shottr"
        case .archives: "The Unarchiver"
        case .cornerClick: "CornerClick"
        }
    }
}

/// A module's background half. `start()` acquires, `stop()` releases everything.
@MainActor
protocol ModuleController: AnyObject {
    func start()
    func stop()
}
