//
//  StripRules.swift
//  Tutto (scrolling strip)
//
//  Which windows join the strip, and the macOS settings it works best with.
//  Dialogs, Quick Look, picture in picture and fixed-size windows float above the strip on
//  their own; windows in native full screen are left alone entirely.
//

import CoreGraphics
import Foundation

/// What the Accessibility API says about a window, read once when it appears.
public struct StripWindowFacts: Equatable, Sendable {
    public var role: String?
    public var subrole: String?
    public var bundleID: String?
    public var size: CGSize
    /// The size can be set (false for fixed-size windows like Calculator's).
    public var canResize: Bool
    public var isFullScreen: Bool
    public var isMinimized: Bool

    public init(role: String?, subrole: String?, bundleID: String?, size: CGSize, canResize: Bool,
                isFullScreen: Bool = false, isMinimized: Bool = false) {
        self.role = role
        self.subrole = subrole
        self.bundleID = bundleID
        self.size = size
        self.canResize = canResize
        self.isFullScreen = isFullScreen
        self.isMinimized = isMinimized
    }
}

public enum StripAdmission: Equatable, Sendable {
    case tile
    /// Stays where it is, above the strip. The reason is for the log and the settings page.
    case float(String)
    /// Not a window the strip deals with at all (full screen, minimized, not a window).
    case ignore
}

public enum StripRules {
    /// System windows that should never tile.
    public static let floatingBundles: Set<String> = [
        "com.apple.quicklook.QuickLookUIService", "com.apple.quicklook.ui.helper", "com.apple.PIPAgent",
        "com.apple.ScreenSaver.Engine", "com.apple.screencaptureui", "com.apple.CharacterPaletteIM",
        "com.apple.loginwindow", "com.apple.SecurityAgent", "com.apple.UserNotificationCenter",
        "com.apple.ColorSyncCalibrator", "com.apple.coreservices.uiagent",
    ]

    public static func admission(_ facts: StripWindowFacts, floatingApps: Set<String> = [], ownBundleID: String? = nil) -> StripAdmission {
        guard facts.role == "AXWindow" else { return .ignore }
        if facts.isFullScreen || facts.isMinimized { return .ignore }
        if let bundle = facts.bundleID {
            if bundle == ownBundleID { return .float("Tutto's own window") }
            if floatingApps.contains(bundle) { return .float("you float this app") }
            if floatingBundles.contains(bundle) || bundle.hasPrefix("com.apple.quicklook") { return .float("system panel") }
        }
        guard facts.subrole == "AXStandardWindow" else { return .float("dialog or panel") }
        guard facts.canResize else { return .float("fixed size") }
        guard facts.size.width >= 160, facts.size.height >= 120 else { return .float("too small") }
        return .tile
    }
}

// MARK: - Mac Setup

/// The macOS settings that decide whether the strip behaves, read from their preference domains.
public struct MacSetupReading: Equatable, Sendable {
    /// `com.apple.spaces` › `spans-displays`: true when "Displays have separate Spaces" is off.
    public var spansDisplays: Bool?
    /// `com.apple.dock` › `mru-spaces`: "Automatically rearrange Spaces based on most recent use".
    public var rearrangesSpaces: Bool?
    /// `com.apple.WindowManager` › `GloballyEnabled`: Stage Manager.
    public var stageManager: Bool?
    /// `com.apple.WindowManager` › `EnableTilingByEdgeDrag` / `EnableTopTilingByEdgeDrag` (macOS 15 and later).
    public var edgeTiling: Bool?
    /// `com.apple.AppleMultitouchTrackpad` › `TrackpadThreeFingerHorizSwipeGesture` (2 = switch full-screen apps).
    public var threeFingerSwipe: Int?
    /// `… TrackpadFourFingerHorizSwipeGesture`.
    public var fourFingerSwipe: Int?
    /// `… TrackpadThreeFingerDrag`.
    public var threeFingerDrag: Bool?

    public init(spansDisplays: Bool? = nil, rearrangesSpaces: Bool? = nil, stageManager: Bool? = nil, edgeTiling: Bool? = nil,
                threeFingerSwipe: Int? = nil, fourFingerSwipe: Int? = nil, threeFingerDrag: Bool? = nil) {
        self.spansDisplays = spansDisplays
        self.rearrangesSpaces = rearrangesSpaces
        self.stageManager = stageManager
        self.edgeTiling = edgeTiling
        self.threeFingerSwipe = threeFingerSwipe
        self.fourFingerSwipe = fourFingerSwipe
        self.threeFingerDrag = threeFingerDrag
    }
}

public struct MacSetupCheck: Equatable, Sendable, Identifiable {
    public enum Pane: String, Sendable {
        case desktopAndDock = "x-apple.systempreferences:com.apple.Desktop-Settings.extension"
        case trackpad = "x-apple.systempreferences:com.apple.Trackpad-Settings.extension"
        case pointerControl = "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?Pointer"
    }

    public let id: String
    public let title: String
    /// What it should be and why, in one sentence.
    public let advice: String
    public let isOK: Bool
    public let pane: Pane
}

public enum MacSetup {
    /// `swipeFingers`: the strip's trackpad swipe (3, 4, or nil when it's off).
    /// `hasEdgeTiling`: macOS 15 or later, where dragging a window to a screen edge tiles it.
    public static func checks(_ reading: MacSetupReading, swipeFingers: Int?, hasEdgeTiling: Bool) -> [MacSetupCheck] {
        var checks = [
            MacSetupCheck(id: "separateSpaces", title: "Displays have separate Spaces",
                          advice: "On, so every display keeps a strip of its own. Changing it takes a log out.",
                          isOK: reading.spansDisplays != true, pane: .desktopAndDock),
            MacSetupCheck(id: "rearrangeSpaces", title: "Rearrange Spaces automatically",
                          advice: "Off, so your desktops (and their strips) stay in the order you made them.",
                          isOK: reading.rearrangesSpaces == false, pane: .desktopAndDock),
            MacSetupCheck(id: "stageManager", title: "Stage Manager",
                          advice: "Off. It moves windows into piles of its own, out from under the strip.",
                          isOK: reading.stageManager != true, pane: .desktopAndDock),
        ]
        if hasEdgeTiling {
            checks.append(MacSetupCheck(id: "edgeTiling", title: "Drag windows to screen edges to tile",
                                        advice: "Off, so dragging a window to reorder the strip doesn't tile it instead.",
                                        isOK: reading.edgeTiling == false, pane: .desktopAndDock))
        }
        if let swipeFingers {
            let macOSUses = swipeFingers == 3 ? reading.threeFingerSwipe : reading.fourFingerSwipe
            checks.append(MacSetupCheck(id: "swipe", title: "\(swipeFingers)-finger swipe between full-screen apps",
                                        advice: "Off or on the other finger count, or one swipe moves the strip and switches desktops at once.",
                                        isOK: macOSUses != 2, pane: .trackpad))
            if swipeFingers == 3 {
                checks.append(MacSetupCheck(id: "threeFingerDrag", title: "Three-finger drag",
                                            advice: "Off, or three fingers drag windows instead of swiping the strip.",
                                            isOK: reading.threeFingerDrag != true, pane: .pointerControl))
            }
        }
        return checks
    }
}
