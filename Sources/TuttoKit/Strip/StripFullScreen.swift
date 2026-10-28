//
//  StripFullScreen.swift
//  TuttoKit
//
//  Full windows: every window on the strip goes into native full screen, as its green button
//  would send it, one after another; Strip brings back exactly the windows Full sent (an app you
//  keep in full screen yourself stays there).
//

import Foundation

public enum StripFullScreen {
    /// A window Full sent into full screen, kept across launches to bring it back.
    public struct Sent: Equatable, Codable, Sendable {
        public var window: StripWindow
        public var pid: Int32

        public init(window: StripWindow, pid: Int32) {
            self.window = window
            self.pid = pid
        }
    }

    /// The window you're on first (it goes full screen in front of you), then the others behind it.
    public static func sendingOrder(_ windows: [StripWindow], focused: StripWindow?) -> [StripWindow] {
        guard let focused, windows.contains(focused) else { return windows }
        return [focused] + windows.filter { $0 != focused }
    }

    /// The windows Full sent that still exist, in the order they went.
    public static func toBringBack(_ sent: [Sent], existing: Set<StripWindow>) -> [Sent] {
        var seen = Set<StripWindow>()
        return sent.filter { existing.contains($0.window) && seen.insert($0.window).inserted }
    }

    /// The stored form (for UserDefaults).
    public static func store(_ sent: [Sent]) -> Data? {
        try? JSONEncoder().encode(sent)
    }

    public static func load(_ data: Data?) -> [Sent] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([Sent].self, from: data)) ?? []
    }
}
