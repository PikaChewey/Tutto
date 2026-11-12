//
//  SnapZones.swift
//  Tutto
//
//  Where a window dragged to the edge of a screen lands: a corner makes a quarter, the left and
//  right edges a half, the top edge fills the screen, and the bottom edge makes thirds (the third
//  under the pointer; slide along from an outer third into the middle and it's two thirds).
//  The pointer stops at the screen's edges, so the zones are thin and still easy to hit.
//

import CoreGraphics

public enum SnapZones {
    /// How close to an edge the pointer must be, in points.
    public static let edgeMargin: CGFloat = 5
    /// How far along an edge from a corner still counts as the corner, in points.
    public static let cornerSize: CGFloat = 24

    /// `pointer` and `screen` (the display's full frame) in the same top-left coordinates.
    /// `previous`: the zone the drag was in just before, for the bottom edge's two thirds.
    public static func action(at pointer: CGPoint, screen: CGRect, previous: WindowAction? = nil) -> WindowAction? {
        guard screen.width > 0, screen.height > 0 else { return nil }
        let left = pointer.x <= screen.minX + edgeMargin
        let right = pointer.x >= screen.maxX - 1 - edgeMargin
        let top = pointer.y <= screen.minY + edgeMargin
        let bottom = pointer.y >= screen.maxY - 1 - edgeMargin
        guard left || right || top || bottom else { return nil }
        let nearLeft = pointer.x <= screen.minX + cornerSize, nearRight = pointer.x >= screen.maxX - 1 - cornerSize
        let nearTop = pointer.y <= screen.minY + cornerSize, nearBottom = pointer.y >= screen.maxY - 1 - cornerSize
        if (left && nearTop) || (top && nearLeft) { return .topLeft }
        if (right && nearTop) || (top && nearRight) { return .topRight }
        if (left && nearBottom) || (bottom && nearLeft) { return .bottomLeft }
        if (right && nearBottom) || (bottom && nearRight) { return .bottomRight }
        if left { return .leftHalf }
        if right { return .rightHalf }
        if top { return .maximize }
        // The bottom edge: thirds.
        let position = (pointer.x - screen.minX) / screen.width
        let third: WindowAction = position < 1.0 / 3 ? .leftThird : position < 2.0 / 3 ? .centerThird : .rightThird
        if third == .centerThird {
            if previous == .leftThird || previous == .leftTwoThirds { return .leftTwoThirds }
            if previous == .rightThird || previous == .rightTwoThirds { return .rightTwoThirds }
        }
        return third
    }

    /// Where a window that Tutto snapped goes when you drag it away: its size from before, placed
    /// so the pointer keeps the same spot along its title bar.
    public static func unsnapped(current: CGRect, previousSize: CGSize, pointer: CGPoint) -> CGRect {
        guard current.width > 0 else { return CGRect(origin: current.origin, size: previousSize) }
        let along = min(max((pointer.x - current.minX) / current.width, 0), 1)
        let x = pointer.x - along * previousSize.width
        return CGRect(x: x.rounded(), y: current.minY, width: previousSize.width, height: previousSize.height)
    }
}
