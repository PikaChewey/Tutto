//
//  Modules.swift
//  Tutto
//
//  The thirteen tools inside Tutto. Each can be switched off on its own, and a module
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
    case corner
    case wordCounter
    case sound
    case switcher
    case strip
    case awake
    case clicker
    case converter
    case cleaner
    case menuBarItems
    case agents

    var id: String { rawValue }

    /// On for a new install (and when a new tool arrives). The strip rearranges every window,
    /// so it waits until you ask for it.
    var isOnByDefault: Bool { self != .strip && self != .menuBarItems }

    /// The tools listed with on/off switches in Overview, General and the welcome window. The
    /// strip is switched on and off on its own page only.
    static var listed: [ModuleID] { allCases.filter { $0 != .strip } }

    var title: String {
        switch self {
        case .system: "System"
        case .sensors: "Sensors & Fans"
        case .clipboard: "Clipboard"
        case .windows: "Windows"
        case .screenshots: "Screenshots"
        case .archives: "Archives"
        case .corner: "Trackpad Corner"
        case .wordCounter: "Word Counter"
        case .sound: "Sound"
        case .switcher: "Window Switcher"
        case .strip: "Scrolling Strip"
        case .awake: "Stay Awake"
        case .clicker: "Auto Clicker"
        case .converter: "Convert"
        case .cleaner: "Clean Up"
        case .menuBarItems: "Menu Bar Icons"
        case .agents: "Agents"
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
        case .corner: "rectangle.inset.bottomright.filled"
        case .wordCounter: "text.word.spacing"
        case .sound: "speaker.slash"
        case .switcher: "rectangle.stack"
        case .strip: "rectangle.split.3x1"
        case .awake: "cup.and.heat.waves"
        case .clicker: "cursorarrow.click.2"
        case .converter: "arrow.triangle.2.circlepath"
        case .cleaner: "sparkles"
        case .menuBarItems: "menubar.rectangle"
        case .agents: "terminal"
        }
    }

    /// One line, shown in General and onboarding.
    var summary: String {
        switch self {
        case .system: "Battery health, CPU, GPU, memory, disk and network."
        case .sensors: "Temperatures, fan speeds and fan control."
        case .clipboard: "Searchable history of text, images, files and links."
        case .windows: "Snap windows to halves, thirds and quarters from a palette."
        case .screenshots: "Capture to clipboard, edit, draw, pick colors, copy text; record the screen to MP4."
        case .archives: "Open RAR, 7z, zip and more, right from Finder."
        case .corner: "Click or tap a trackpad corner to right-click; click with three fingers to middle-click."
        case .wordCounter: "Words, characters and reading time of any text."
        case .sound: "Mute any app at the speakers; it still plays to recorders."
        case .switcher: "⌘Tab shows every window, not just every app."
        case .strip: "Windows side by side on one strip that scrolls. ⌃⌥ ← → to move along it."
        case .awake: "Keep the Mac on for a time you type, lid closed included, easy on the battery."
        case .clicker: "Clicks for you at the speed you set. ⌃⇧A or a switch in the menu bar starts and stops it."
        case .converter: "Pictures, video, sound, PDFs and documents into other formats, or smaller. Tap ⇧ while dragging files."
        case .cleaner: "Leftovers from removed apps, caches, logs and the Trash. You review it all; it goes to the Trash."
        case .menuBarItems: "Tuck away the menu bar icons you rarely use; one click brings them back."
        case .agents: "Claude Code and Codex: which need you (one click opens that session), what each costs, what they left running, and their limits."
        }
    }

    /// What it costs while it's on and you're not looking at it.
    var idleCost: String {
        switch self {
        case .system, .sensors: "Nothing. Readings are taken only while they're on screen."
        case .clipboard: "Checks the clipboard about once a second, coalesced with other system work."
        case .windows, .wordCounter: "Nothing. Registered shortcuts wait for a key press."
        case .screenshots: "Nothing. Registered shortcuts wait for a key press; a recording runs only while you record."
        case .archives: "Nothing in Tutto. Finder loads the small menu extension."
        case .corner: "Nothing until a finger touches the trackpad."
        case .sound: "Nothing until a muted app plays a sound."
        case .switcher: "Nothing but a key filter that waits for ⌘Tab. Windows are listed only when you press it."
        case .strip: "Nothing while windows sit still: macOS tells it when one changes, and it moves only then."
        case .awake: "Nothing until you start a timer. During one, a tick a minute for the time left."
        case .clicker: "Nothing but its shortcut until you start it."
        case .converter: "Nothing but a glance at each mouse press and modifier key, for the wheel. Work runs only when you convert."
        case .cleaner: "Nothing. It looks only when you scan."
        case .menuBarItems: "Nothing. Its divider waits for a click."
        case .agents: "Nothing until an agent writes: macOS reports its files changing. Its processes are read only while the card or page shows, and once a minute while one works. The first launch reads Claude's logs once (a few seconds); after that, only what's new."
        }
    }
}

/// A module's background half. `start()` acquires, `stop()` releases everything.
@MainActor
protocol ModuleController: AnyObject {
    func start()
    func stop()
}
