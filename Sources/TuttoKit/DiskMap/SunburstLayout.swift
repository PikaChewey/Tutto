//
//  SunburstLayout.swift
//  Tutto
//
//  The disk map's geometry, kept free of drawing so it can be tested: rings by depth, each
//  item's angle in proportion to its size, and the slivers too thin to see merged into one
//  "smaller items" slice per folder. Angles are radians from twelve o'clock, clockwise.
//

import Foundation

public struct SunburstSlice<Node>: Sendable where Node: Sendable {
    /// The item drawn; nil for a merged slice.
    public let node: Node?
    /// How many items a merged slice stands for (1 otherwise).
    public let count: Int
    /// Bytes in the slice.
    public let bytes: Int64
    /// 1 is the innermost ring.
    public let depth: Int
    public let start: Double
    public let end: Double
    /// Which item of the first ring this one sits under, for its colour.
    public let branch: Int

    public var isMerged: Bool { node == nil }
    public var span: Double { end - start }
    public var middle: Double { (start + end) / 2 }
}

public enum SunburstLayout {
    public static let defaultMinAngle = 1.5 * .pi / 180
    public static let defaultMaxDepth = 5

    /// Lays out the rings around `root`. `children` should be biggest first (they are sorted
    /// again either way); `sizeOf` gives bytes. Slices thinner than `minAngle` are merged into
    /// one slice at the end of their folder, so a ring's angles always add up to its parent's.
    public static func slices<Node: Sendable>(root: Node, sizeOf: (Node) -> Int64, children: (Node) -> [Node],
                                              maxDepth: Int = defaultMaxDepth,
                                              minAngle: Double = defaultMinAngle) -> [SunburstSlice<Node>] {
        var out: [SunburstSlice<Node>] = []
        func place(_ parent: Node, from start: Double, to end: Double, depth: Int, branch: Int?) {
            guard depth <= maxDepth else { return }
            let total = sizeOf(parent)
            guard total > 0, end > start else { return }
            let kids = children(parent).filter { sizeOf($0) > 0 }.sorted { sizeOf($0) > sizeOf($1) }
            let scale = (end - start) / Double(total)
            var angle = start
            var index = 0
            while index < kids.count {
                let kid = kids[index]
                let span = Double(sizeOf(kid)) * scale
                if span < minAngle { break }
                let own = branch ?? index
                out.append(SunburstSlice(node: kid, count: 1, bytes: sizeOf(kid), depth: depth, start: angle, end: angle + span, branch: own))
                place(kid, from: angle, to: angle + span, depth: depth + 1, branch: own)
                angle += span
                index += 1
            }
            if index < kids.count {
                let rest = kids[index...]
                let bytes = rest.reduce(Int64(0)) { $0 + sizeOf($1) }
                let span = Double(bytes) * scale
                out.append(SunburstSlice(node: nil, count: rest.count, bytes: bytes, depth: depth, start: angle,
                                         end: min(end, angle + span), branch: branch ?? index))
            }
        }
        place(root, from: 0, to: 2 * .pi, depth: 1, branch: nil)
        return out
    }

    /// The angle of a point from the centre: 0 at twelve o'clock, clockwise, in 0..<2π.
    /// `dy` grows downwards, as on screen.
    public static func angle(dx: Double, dy: Double) -> Double {
        let raw = atan2(dx, -dy)
        return raw < 0 ? raw + 2 * .pi : raw
    }
}

/// Ring sizes for a sunburst drawn in a square, and what's under a point.
public struct SunburstGeometry: Sendable, Equatable {
    /// The empty middle, which shows the folder's name and goes back up when clicked.
    public let centerRadius: Double
    public let ringWidth: Double
    public let rings: Int

    public init(side: Double, rings: Int) {
        let radius = side / 2
        self.rings = max(rings, 1)
        centerRadius = radius * 0.3
        ringWidth = (radius - centerRadius) / Double(self.rings)
    }

    public func inner(_ depth: Int) -> Double { centerRadius + Double(depth - 1) * ringWidth }
    public func outer(_ depth: Int) -> Double { centerRadius + Double(depth) * ringWidth }

    /// 0 for the middle, 1… for a ring, nil outside.
    public func ring(atDistance distance: Double) -> Int? {
        if distance < centerRadius { return 0 }
        let ring = Int(((distance - centerRadius) / ringWidth).rounded(.down)) + 1
        return ring <= rings ? ring : nil
    }

    /// The index of the slice under a point (relative to the centre, y down), if any.
    public func slice<Node>(atX dx: Double, y dy: Double, in slices: [SunburstSlice<Node>]) -> Int? {
        guard let depth = ring(atDistance: (dx * dx + dy * dy).squareRoot()), depth > 0 else { return nil }
        let angle = SunburstLayout.angle(dx: dx, dy: dy)
        return slices.firstIndex { $0.depth == depth && angle >= $0.start && angle < $0.end }
    }
}

/// The calm colours: one hue per item of the first ring, lighter and softer with each ring out.
public enum SunburstPalette {
    public static let hues: [Double] = [0.60, 0.47, 0.34, 0.72, 0.86, 0.97, 0.53, 0.66]

    /// Hue, saturation and brightness for a slice. Merged slices are grey.
    public static func tone(branch: Int, depth: Int, merged: Bool, dark: Bool) -> (hue: Double, saturation: Double, brightness: Double) {
        let step = Double(max(depth, 1) - 1)
        let hue = hues[((branch % hues.count) + hues.count) % hues.count]
        let brightness = dark ? min(0.42 + step * 0.08, 0.80) : min(0.70 + step * 0.06, 0.95)
        let saturation = merged ? 0 : max((dark ? 0.42 : 0.40) - step * 0.05, 0.14)
        return (hue, saturation, merged ? brightness * (dark ? 0.85 : 1.0) : brightness)
    }
}
