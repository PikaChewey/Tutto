//
//  StripMotion.swift
//  Tutto (scrolling strip)
//
//  The strip's motion: a critically damped spring, stepped exactly (not integrated), so it
//  is the same at 60 and 120 frames a second, starts moving the instant a key is pressed,
//  never overshoots, and picks up from wherever it is when the target changes mid-flight.
//

import CoreGraphics
import Foundation

public enum StripAnimation: String, Codable, CaseIterable, Sendable {
    case smooth, fast, instant

    /// Stiffness (radians per second); nil jumps straight there.
    public var omega: Double? {
        switch self {
        case .smooth: 28
        case .fast: 46
        case .instant: nil
        }
    }
}

public struct SpringValue: Equatable, Sendable {
    public var value: Double
    public var velocity: Double

    public init(_ value: Double, velocity: Double = 0) {
        self.value = value
        self.velocity = velocity
    }

    public mutating func step(toward target: Double, omega: Double, dt: Double) {
        let delta = value - target
        let decay = exp(-omega * dt)
        let push = (velocity + omega * delta) * dt
        value = target + (delta + push) * decay
        velocity = (velocity - omega * push) * decay
    }

    /// Within half a point and barely moving.
    public func isSettled(at target: Double) -> Bool {
        abs(value - target) < 0.5 && abs(velocity) < 30
    }

    public mutating func snap(to target: Double) {
        value = target
        velocity = 0
    }
}

/// A window frame in motion.
public struct SpringFrame: Equatable, Sendable {
    public var x: SpringValue
    public var y: SpringValue
    public var width: SpringValue
    public var height: SpringValue

    public init(_ rect: CGRect) {
        x = SpringValue(rect.minX)
        y = SpringValue(rect.minY)
        width = SpringValue(rect.width)
        height = SpringValue(rect.height)
    }

    public var rect: CGRect { CGRect(x: x.value, y: y.value, width: width.value, height: height.value) }

    /// The frame to put the window at: whole points, so it doesn't shimmer between pixels.
    public var roundedRect: CGRect {
        CGRect(x: x.value.rounded(), y: y.value.rounded(), width: width.value.rounded(), height: height.value.rounded())
    }

    public mutating func step(toward target: CGRect, omega: Double, dt: Double) {
        x.step(toward: target.minX, omega: omega, dt: dt)
        y.step(toward: target.minY, omega: omega, dt: dt)
        width.step(toward: target.width, omega: omega, dt: dt)
        height.step(toward: target.height, omega: omega, dt: dt)
    }

    public func isSettled(at target: CGRect) -> Bool {
        x.isSettled(at: target.minX) && y.isSettled(at: target.minY)
            && width.isSettled(at: target.width) && height.isSettled(at: target.height)
    }

    public mutating func snap(to target: CGRect) {
        x.snap(to: target.minX)
        y.snap(to: target.minY)
        width.snap(to: target.width)
        height.snap(to: target.height)
    }
}

/// Follows fingers on the trackpad: the offset moves with them one to one and the release
/// speed is measured over the last moments of the swipe.
public struct SwipeTracker: Sendable {
    private var samples: [(time: Double, offset: Double)] = []

    public init() {}

    public mutating func record(offset: Double, at time: Double) {
        samples.append((time, offset))
        samples.removeAll { time - $0.time > 0.1 }
    }

    /// Points per second over the last tenth of a second.
    public var velocity: Double {
        guard let first = samples.first, let last = samples.last, last.time - first.time > 0.008 else { return 0 }
        return (last.offset - first.offset) / (last.time - first.time)
    }

    public mutating func reset() { samples.removeAll() }
}
