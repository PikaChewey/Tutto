//
//  ScreenTop.swift
//  Tutto
//
//  Where a bar along the top of the screen may go: under the menu bar, and under the camera
//  housing (the notch) too. In a full-screen app the menu bar hides and `visibleFrame` reaches the
//  top edge, but the notch is still there: `safeAreaInsets.top` covers it.
//

import AppKit

extension NSScreen {
    /// The highest y a panel's top edge may reach without sitting under the menu bar or the notch.
    var hudTop: CGFloat {
        min(visibleFrame.maxY, frame.maxY - safeAreaInsets.top)
    }
}
