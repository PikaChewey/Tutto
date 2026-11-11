//
//  CornerEngineTests.swift
//  CornerTests
//

import CoreGraphics
import Foundation
import Testing
@testable import TuttoKit
import CBridges

private let ms: UInt64 = 1_000_000

/// Builds touch sequences in milliseconds and asks the decider what a left click at a given time means.
private struct Scenario {
    var tracker = TouchTracker()
    var rules = RuleSet()

    mutating func frame(_ t: UInt64, _ contacts: Contact...) {
        tracker.zone = rules.zone
        tracker.update(touching: contacts, now: t * ms)
    }

    mutating func click(at t: UInt64) -> Trigger? {
        let decision = ClickDecider.decide(trackers: [tracker], now: t * ms, rules: rules)
        if decision.consumesTapOf != nil { tracker.consumeTap() }
        tracker.markPressed(rightClick: decision.trigger != nil)  // same bookkeeping as the engine
        return decision.trigger
    }
}

private func finger(_ id: Int32, _ x: Double, _ y: Double) -> Contact {
    Contact(id: id, x: x, y: y)
}

// Bottom-right corner, default 30% × 30%.
private let corner = (x: 0.88, y: 0.10)
private let middle = (x: 0.45, y: 0.50)

@Suite("Corner zone")
struct ZoneTests {
    @Test func bottomRightContains() {
        let zone = CornerZone.standard
        #expect(zone.contains(x: 0.95, y: 0.05))
        #expect(zone.contains(x: 0.55, y: 0.36))
        #expect(!zone.contains(x: 0.54, y: 0.10))
        #expect(!zone.contains(x: 0.95, y: 0.37))
        #expect(!zone.contains(x: 0.05, y: 0.05))
    }

    @Test func bottomLeftContains() {
        let zone = CornerZone(corner: .bottomLeft, width: 0.25, height: 0.2)
        #expect(zone.contains(x: 0.1, y: 0.1))
        #expect(!zone.contains(x: 0.9, y: 0.1))
        #expect(!zone.contains(x: 0.1, y: 0.25))
    }

    @Test func sizeIsClamped() {
        let tiny = CornerZone(corner: .bottomRight, width: 0.01, height: 2).clamped
        #expect(tiny.width == CornerZone.minimumSize)
        #expect(tiny.height == CornerZone.maximumSize)
    }
}

@Suite("Physical clicks")
struct ClickTests {
    @Test func clickInCornerBecomesRightClick() {
        var s = Scenario()
        s.frame(0, finger(1, corner.x, corner.y))
        s.frame(300, finger(1, corner.x, corner.y))
        #expect(s.click(at: 320) == .click)
    }

    @Test func clickElsewhereStaysLeftClick() {
        var s = Scenario()
        s.frame(0, finger(1, middle.x, middle.y))
        #expect(s.click(at: 200) == nil)
    }

    @Test func fingerThatSlidIntoTheCornerAndPressesRightClicks() {
        // Same as macOS's own bottom-corner secondary click: where you press is what counts.
        var s = Scenario()
        s.frame(0, finger(1, middle.x, middle.y))
        s.frame(400, finger(1, corner.x, corner.y))
        #expect(s.click(at: 450) == .click)
    }

    @Test func leftClickThenSlideIntoCornerRightClicks() {
        // Seen in real use: one finger stays down, left-clicks, slides into the corner and
        // presses to right-click, all without lifting. That must right-click.
        var s = Scenario()
        s.frame(0, finger(1, middle.x, middle.y))
        #expect(s.click(at: 100) == nil)
        s.frame(400, finger(1, corner.x, corner.y))
        #expect(s.click(at: 450) == .click)
    }

    @Test func pressingFingerWinsOverARestingPalm() {
        // A palm resting in the corner doesn't spread; the pressing finger does.
        var s = Scenario()
        s.frame(0, Contact(id: 1, x: 0.93, y: 0.08, size: 3.0), Contact(id: 2, x: 0.40, y: 0.50, size: 1.0))
        s.frame(100, Contact(id: 1, x: 0.93, y: 0.08, size: 3.0), Contact(id: 2, x: 0.40, y: 0.50, size: 1.6))
        #expect(s.click(at: 120) == nil)
    }

    @Test func pressingFingerInCornerWinsOverNewerRestingFinger() {
        var s = Scenario()
        s.frame(0, Contact(id: 1, x: 0.88, y: 0.10, size: 1.0))
        s.frame(50, Contact(id: 1, x: 0.88, y: 0.10, size: 1.0), Contact(id: 2, x: 0.30, y: 0.60, size: 1.0))
        s.frame(120, Contact(id: 1, x: 0.88, y: 0.10, size: 1.7), Contact(id: 2, x: 0.30, y: 0.60, size: 1.0))
        #expect(s.click(at: 140) == .click)
    }

    @Test func cornerFingerWinsCloseCallAgainstNewerFinger() {
        // Real capture from a hardware test (bottom-left mode): the corner finger spread a
        // little more (0.09) than a newer finger near the top (0.04). That's a right-click.
        var s = Scenario()
        s.rules.zone = CornerZone(corner: .bottomLeft, width: 0.45, height: 0.36)
        s.frame(0, Contact(id: 1, x: 0.100, y: 0.147, size: 1.0))
        s.frame(1350, Contact(id: 1, x: 0.100, y: 0.147, size: 1.0), Contact(id: 2, x: 0.599, y: 0.818, size: 1.0))
        s.frame(1826, Contact(id: 1, x: 0.100, y: 0.147, size: 1.096), Contact(id: 2, x: 0.599, y: 0.818, size: 1.043))
        #expect(s.click(at: 1830) == .click)
    }

    @Test func restingPalmInCornerStillLosesCloseCall() {
        // A palm resting in the corner doesn't spread when you press elsewhere.
        var s = Scenario()
        s.frame(0, Contact(id: 1, x: 0.90, y: 0.10, size: 3.0))
        s.frame(500, Contact(id: 1, x: 0.90, y: 0.10, size: 3.0), Contact(id: 2, x: 0.40, y: 0.60, size: 1.0))
        s.frame(900, Contact(id: 1, x: 0.90, y: 0.10, size: 3.01), Contact(id: 2, x: 0.40, y: 0.60, size: 1.05))
        #expect(s.click(at: 910) == nil)
    }

    @Test func clickJustAfterTheFingerLiftedStillCounts() {
        var s = Scenario()
        s.rules.tapEnabled = false
        s.frame(0, finger(1, corner.x, corner.y))
        s.frame(500)                              // lift frame arrives first
        #expect(s.click(at: 540) == .click)       // ...then the press, 40 ms later
        #expect(s.click(at: 560) == nil)          // and only once
    }

    @Test func rightClickThenSlideToMenuItemIsALeftClick() {
        // The complaint: right-click in the corner, nudge the same finger to a menu item, click.
        var s = Scenario()
        s.frame(0, finger(1, 0.90, 0.10))
        #expect(s.click(at: 200) == .click)
        s.frame(400, finger(1, 0.90, 0.10))
        s.frame(600, finger(1, 0.86, 0.17))   // ~7 mm nudge, still inside the zone
        #expect(s.click(at: 700) == nil)
    }

    @Test func tinyNudgeAfterRightClickIsALeftClick() {
        // Even a 3 mm nudge (one menu item over) after a corner press means "pointing now".
        var s = Scenario()
        s.frame(0, finger(1, 0.90, 0.10))
        #expect(s.click(at: 150) == .click)
        s.frame(300, finger(1, 0.90, 0.10))
        s.frame(500, finger(1, 0.90, 0.14))   // 3.1 mm up
        #expect(s.click(at: 600) == nil)
    }

    @Test func clickingAgainWithoutMovingStaysRight() {
        var s = Scenario()
        s.frame(0, finger(1, 0.90, 0.10))
        #expect(s.click(at: 150) == .click)
        s.frame(400, finger(1, 0.905, 0.105))
        #expect(s.click(at: 500) == .click)
    }

    @Test func standardZoneCoversWhereFingersLand() {
        // Measured: a natural corner tap lands roughly 14–23 mm up from the bottom edge.
        let zone = CornerZone.standard
        let mm = TrackpadSize.macBookPro14
        #expect(zone.width * mm.width > 55)
        #expect(zone.height * mm.height > 26)
        #expect(zone.contains(x: 0.85, y: 23.0 / mm.height))
        #expect(!zone.contains(x: 0.85, y: 0.45))   // 35 mm up is the middle of the trackpad
    }

    @Test func landingJustAboveTheEdgeStillCounts() {
        // Fingers aren't precise. 2 mm above the zone is still "the corner".
        var s = Scenario()
        s.frame(0, finger(1, 0.85, 0.385))    // 1.9 mm above the zone's top edge
        s.frame(120, finger(1, 0.85, 0.383))
        #expect(s.click(at: 160) == .click)
        var far = Scenario()
        far.frame(0, finger(1, 0.85, 0.42))        // 4.6 mm above: not the corner
        #expect(far.click(at: 100) == nil)
    }

    @Test func movingAroundInsideTheCornerIsFine() {
        // Settling or rolling the finger inside the corner (8 mm here) is still a button press.
        var s = Scenario()
        s.frame(0, finger(1, 0.80, 0.12))
        s.frame(200, finger(1, 0.86, 0.10))
        #expect(s.click(at: 260) == .click)
    }

    @Test func pressingFingerMayDriftALittle() {
        var s = Scenario()
        s.frame(0, finger(1, 0.90, 0.10))
        s.frame(150, finger(1, 0.915, 0.115))  // ~2.5 mm roll while pressing
        #expect(s.click(at: 200) == .click)
    }

    @Test func pressRollingJustPastTheEdgeStillCounts() {
        var s = Scenario()
        s.rules.zone = CornerZone(corner: .bottomRight, width: 0.30, height: 0.30)
        s.frame(0, finger(1, 0.71, 0.28))
        s.frame(100, finger(1, 0.695, 0.29))   // 1.9 mm past the left edge
        #expect(s.click(at: 150) == .click)
    }

    @Test func restingThumbDoesNotBlockCornerPress() {
        var s = Scenario()
        s.frame(0, finger(1, 0.3, 0.05))                                  // thumb resting bottom-left
        s.frame(2000, finger(1, 0.3, 0.05), finger(2, corner.x, corner.y)) // index presses the corner
        #expect(s.click(at: 2200) == .click)
    }

    @Test func palmRestingInCornerDoesNotHijackNormalClicks() {
        var s = Scenario()
        s.frame(0, finger(1, 0.93, 0.08))                                  // palm already in the corner
        s.frame(1500, finger(1, 0.93, 0.08), finger(2, middle.x, middle.y))
        #expect(s.click(at: 1700) == nil)
    }

    @Test func externalMouseWithNoFingerIsIgnored() {
        var s = Scenario()
        #expect(s.click(at: 10_000) == nil)
    }

    @Test func clickRuleOffKeepsLongPressAsLeftClick() {
        var s = Scenario()
        s.rules.clickEnabled = false
        s.frame(0, finger(1, corner.x, corner.y))
        #expect(s.click(at: 900) == nil)
    }

    @Test func bottomLeftZoneWorks() {
        var s = Scenario()
        s.rules.zone = CornerZone(corner: .bottomLeft, width: 0.3, height: 0.3)
        s.frame(0, finger(1, 0.1, 0.1))
        #expect(s.click(at: 300) == .click)
        var other = Scenario()
        other.rules.zone = s.rules.zone
        other.frame(0, finger(1, corner.x, corner.y))
        #expect(other.click(at: 300) == nil)
    }
}

@Suite("Tap to click")
struct TapTests {
    @Test func cornerTapBecomesRightClick() {
        var s = Scenario()
        s.frame(0, finger(1, corner.x, corner.y))
        s.frame(80)                       // lift
        #expect(s.click(at: 95) == .tap)  // macOS's tap-to-click event
    }

    @Test func tapIsUsedOnlyOnce() {
        var s = Scenario()
        s.frame(0, finger(1, corner.x, corner.y))
        s.frame(80)
        #expect(s.click(at: 95) == .tap)
        #expect(s.click(at: 120) == nil)
    }

    @Test func tapElsewhereIsConsumedAndStaysLeft() {
        var s = Scenario()
        s.frame(0, finger(1, middle.x, middle.y))
        s.frame(70)
        #expect(s.click(at: 90) == nil)
    }

    @Test func staleTapIsIgnored() {
        var s = Scenario()
        s.frame(0, finger(1, corner.x, corner.y))
        s.frame(80)
        #expect(s.click(at: 80 + 600) == nil)
    }

    @Test func tapToDragDelayIsTolerated() {
        // With "Dragging" on, macOS holds tap clicks back by up to ~0.8 s.
        var s = Scenario()
        s.rules.tapClickWindow = ClickDecider.dragDelayedTapClickWindow
        s.frame(0, finger(1, corner.x, corner.y))
        s.frame(80)
        #expect(s.click(at: 80 + 700) == .tap)
    }

    @Test func tapWithRestingThumbStillWorks() {
        var s = Scenario()
        s.frame(0, finger(1, 0.3, 0.05))
        s.frame(1000, finger(1, 0.3, 0.05), finger(2, corner.x, corner.y))
        s.frame(1090, finger(1, 0.3, 0.05))
        #expect(s.click(at: 1100) == .tap)
    }

    @Test func twoFingerTapIsLeftToMacOS() {
        var s = Scenario()
        s.frame(0, finger(1, corner.x, corner.y), finger(2, 0.75, 0.2))
        s.frame(90)
        #expect(s.tracker.lastTap == nil)
    }

    @Test func slowPressIsNotATap() {
        var s = Scenario()
        s.frame(0, finger(1, corner.x, corner.y))
        s.frame(700)
        #expect(s.tracker.lastTap == nil)
    }

    @Test func physicalClickIsNeverAlsoATap() {
        var s = Scenario()
        s.frame(0, finger(1, corner.x, corner.y))
        #expect(s.click(at: 120) == .click)
        s.frame(200)
        #expect(s.tracker.lastTap == nil)
    }

    @Test func tapThatSlidOutOfTheCornerIsLeft() {
        var s = Scenario()
        s.frame(0, finger(1, 0.56, 0.10))
        s.frame(60, finger(1, 0.515, 0.10))   // drifted 4.4 mm past the edge before lifting
        s.frame(90)
        #expect(s.click(at: 100) == nil)
    }

    @Test func swipeIsNotATap() {
        var s = Scenario()
        s.frame(0, finger(1, 0.75, 0.25))
        s.frame(60, finger(1, 0.95, 0.05))
        s.frame(100)
        #expect(s.tracker.lastTap == nil)
    }

    @Test func tapRuleOffLeavesTapAsLeftClick() {
        var s = Scenario()
        s.rules.tapEnabled = false
        s.frame(0, finger(1, corner.x, corner.y))
        s.frame(80)
        #expect(s.click(at: 95) == nil)
    }

    @Test func clickRaceAheadOfLiftCountsAsTap() {
        // The click for a tap can arrive before the lift frame. With only "Tap" on,
        // a short, still touch in the corner must still count.
        var s = Scenario()
        s.rules.clickEnabled = false
        s.frame(0, finger(1, corner.x, corner.y))
        #expect(s.click(at: 85) == .tap)
    }

    @Test func newFingerAfterTapIsAFreshClick() {
        var s = Scenario()
        s.frame(0, finger(1, corner.x, corner.y))
        s.frame(80)
        s.frame(150, finger(2, middle.x, middle.y))   // a different finger lands and presses
        #expect(s.click(at: 200) == nil)
    }
}

@Suite("Multiple trackpads")
struct MultiTrackpadTests {
    @Test func newestFingerAcrossTrackpadsWins() {
        var builtIn = TouchTracker()
        var magic = TouchTracker()
        builtIn.update(touching: [finger(1, middle.x, middle.y)], now: 0)
        magic.update(touching: [finger(1, corner.x, corner.y)], now: 500 * ms)
        let decision = ClickDecider.decide(trackers: [builtIn, magic], now: 600 * ms, rules: RuleSet())
        #expect(decision.trigger == .click)
    }
}

@Suite("Three-finger middle click: which fingers count")
struct MiddleClickTests {
    private func middle(_ frames: [(UInt64, [Contact])], at t: UInt64) -> Bool {
        var tracker = TouchTracker()
        for (time, contacts) in frames { tracker.update(touching: contacts, now: time * ms) }
        return ClickDecider.isMiddleClick(trackers: [tracker], rules: RuleSet(middleClick: true))
    }

    @Test func threeFingersLandingTogether() {
        #expect(middle([(0, [finger(1, 0.3, 0.5)]),
                        (80, [finger(1, 0.3, 0.5), finger(2, 0.45, 0.55), finger(3, 0.6, 0.5)]),
                        (900, [finger(1, 0.3, 0.5), finger(2, 0.45, 0.55), finger(3, 0.6, 0.5)])], at: 920))
    }

    @Test func aRestingThumbPlusTwoFingersIsNot() {
        // The thumb lay at the bottom for a second and a half before two fingers came down to click.
        #expect(!middle([(0, [finger(1, 0.5, 0.05)]),
                         (1500, [finger(1, 0.5, 0.05), finger(2, 0.4, 0.5), finger(3, 0.55, 0.5)])], at: 1600))
    }

    @Test func aRestingThumbPlusThreeFingersIsNot() {
        // Four contacts: not exactly three, so it stays an ordinary click (as macOS would make it).
        #expect(!middle([(0, [finger(1, 0.5, 0.05)]),
                         (1500, [finger(1, 0.5, 0.05), finger(2, 0.3, 0.5), finger(3, 0.45, 0.55), finger(4, 0.6, 0.5)])],
                        at: 1600))
    }

    @Test func fingersPlacedOneByOneSlowlyAreNot() {
        #expect(!middle([(0, [finger(1, 0.3, 0.5)]),
                         (700, [finger(1, 0.3, 0.5), finger(2, 0.45, 0.55)]),
                         (1400, [finger(1, 0.3, 0.5), finger(2, 0.45, 0.55), finger(3, 0.6, 0.5)])], at: 1500))
    }

    @Test func offMeansNever() {
        var tracker = TouchTracker()
        tracker.update(touching: [finger(1, 0.3, 0.5), finger(2, 0.45, 0.55), finger(3, 0.6, 0.5)], now: 0)
        #expect(!ClickDecider.isMiddleClick(trackers: [tracker], rules: RuleSet()))
    }
}

@Suite("Engine: real CGEvents through the tap handler")
struct EngineCoreTests {
    /// Pretends macOS "Tap to click" is on and never posts real clicks from a test.
    private func makeCore(tapToClick: Bool = true, posted: Counter = Counter(), middleClick: Bool = false,
                          threeFingerDrag: Bool = false) -> EngineCore {
        var system = EngineCore.System()
        system.tapToClickEnabled = { _ in tapToClick }
        system.recentlyTyped = { false }
        system.postRightClick = { posted.increment(); return true }
        system.menuUnderPointer = { _ in false }
        system.threeFingerDragEnabled = { threeFingerDrag }
        let core = EngineCore(system: system) { _ in }
        core.resetTouches(sizes: [.macBookPro14])
        core.setRules(RuleSet(middleClick: middleClick))
        return core
    }

    // MARK: Three-finger middle click

    @Test func threeFingerClickBecomesMiddleDownDragUp() {
        let core = makeCore(middleClick: true)
        touch(core, [(0.3, 0.5, 4), (0.45, 0.55, 4), (0.6, 0.5, 4)])
        let down = core.handleMouseEvent(type: .leftMouseDown, event: mouse(.leftMouseDown))
        #expect(down.type == .otherMouseDown)
        #expect(button(down) == 2)
        let drag = core.handleMouseEvent(type: .leftMouseDragged, event: mouse(.leftMouseDragged))
        #expect(drag.type == .otherMouseDragged)
        #expect(button(drag) == 2)
        let up = core.handleMouseEvent(type: .leftMouseUp, event: mouse(.leftMouseUp))
        #expect(up.type == .otherMouseUp)
        #expect(button(up) == 2)
        // The next one-finger click is an ordinary click again.
        touch(core, [(0.4, 0.5, 4)])
        #expect(core.handleMouseEvent(type: .leftMouseDown, event: mouse(.leftMouseDown)).type == .leftMouseDown)
        #expect(core.handleMouseEvent(type: .leftMouseUp, event: mouse(.leftMouseUp)).type == .leftMouseUp)
    }

    @Test func threeFingersInTheCornerAreStillAMiddleClick() {
        let core = makeCore(middleClick: true)
        touch(core, [(0.9, 0.1, 4), (0.8, 0.15, 4), (0.7, 0.12, 4)])
        #expect(core.handleMouseEvent(type: .leftMouseDown, event: mouse(.leftMouseDown)).type == .otherMouseDown)
    }

    @Test func twoOrFourFingersAreNotAMiddleClick() {
        let core = makeCore(middleClick: true)
        touch(core, [(0.3, 0.5, 4), (0.45, 0.55, 4)])
        #expect(core.handleMouseEvent(type: .leftMouseDown, event: mouse(.leftMouseDown)).type == .leftMouseDown)
        _ = core.handleMouseEvent(type: .leftMouseUp, event: mouse(.leftMouseUp))
        touch(core, [(0.3, 0.5, 4), (0.45, 0.55, 4), (0.6, 0.5, 4), (0.75, 0.45, 4)])
        #expect(core.handleMouseEvent(type: .leftMouseDown, event: mouse(.leftMouseDown)).type == .leftMouseDown)
    }

    @Test func middleClickIsOffUntilSwitchedOn() {
        let core = makeCore()
        touch(core, [(0.3, 0.5, 4), (0.45, 0.55, 4), (0.6, 0.5, 4)])
        #expect(core.handleMouseEvent(type: .leftMouseDown, event: mouse(.leftMouseDown)).type == .leftMouseDown)
    }

    @Test func threeFingerDragLeavesThreeFingersAlone() {
        // macOS's three-finger drag starts with a three-finger "click"; it must stay a drag.
        let core = makeCore(middleClick: true, threeFingerDrag: true)
        touch(core, [(0.3, 0.5, 4), (0.45, 0.55, 4), (0.6, 0.5, 4)])
        #expect(core.handleMouseEvent(type: .leftMouseDown, event: mouse(.leftMouseDown)).type == .leftMouseDown)
        #expect(core.handleMouseEvent(type: .leftMouseDragged, event: mouse(.leftMouseDragged)).type == .leftMouseDragged)
    }

    /// Sends one raw trackpad frame, exactly as MultitouchSupport would.
    private func touch(_ core: EngineCore, _ contacts: [(x: Float, y: Float, state: Int32)]) {
        var raw = contacts.enumerated().map { index, c in
            CCContact(identifier: Int32(index + 1), state: c.state, x: c.x, y: c.y,
                      size: 1, majorAxis: 8, minorAxis: 7)
        }
        raw.withUnsafeMutableBufferPointer { buffer in
            core.handleFrame(deviceIndex: 0, contacts: UnsafePointer(buffer.baseAddress), count: buffer.count)
        }
    }

    private func mouse(_ type: CGEventType) -> CGEvent {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: 400, y: 300), mouseButton: .left)!
    }

    private func button(_ event: CGEvent) -> Int64 {
        event.getIntegerValueField(.mouseEventButtonNumber)
    }

    @Test func cornerPressBecomesRightClickDownDragUp() {
        let core = makeCore()
        touch(core, [(0.9, 0.1, 4)])
        let down = core.handleMouseEvent(type: .leftMouseDown, event: mouse(.leftMouseDown))
        #expect(down.type == .rightMouseDown)
        #expect(button(down) == 1)
        let drag = core.handleMouseEvent(type: .leftMouseDragged, event: mouse(.leftMouseDragged))
        #expect(drag.type == .rightMouseDragged)
        let up = core.handleMouseEvent(type: .leftMouseUp, event: mouse(.leftMouseUp))
        #expect(up.type == .rightMouseUp)
        #expect(button(up) == 1)
        // The next ordinary click is untouched.
        touch(core, [(0.4, 0.5, 4)])
        #expect(core.handleMouseEvent(type: .leftMouseDown, event: mouse(.leftMouseDown)).type == .leftMouseDown)
        #expect(core.handleMouseEvent(type: .leftMouseUp, event: mouse(.leftMouseUp)).type == .leftMouseUp)
    }

    @Test func clickOutsideCornerStaysLeft() {
        let core = makeCore()
        touch(core, [(0.5, 0.5, 4)])
        let down = core.handleMouseEvent(type: .leftMouseDown, event: mouse(.leftMouseDown))
        #expect(down.type == .leftMouseDown)
        #expect(button(down) == 0)
    }

    @Test func hoveringOrLiftingContactsDoNotCount() {
        // States 1/2 (hovering) and 5–7 (lifting) are not fingers on the glass.
        let core = makeCore()
        touch(core, [(0.9, 0.1, 2), (0.92, 0.08, 7)])
        #expect(core.handleMouseEvent(type: .leftMouseDown, event: mouse(.leftMouseDown)).type == .leftMouseDown)
    }

    @Test func cornerTapConvertsMacOSTapClick() {
        let core = makeCore()
        touch(core, [(0.88, 0.12, 3)])
        touch(core, [(0.88, 0.12, 4)])
        touch(core, [(0.88, 0.12, 5)])  // lifting: no longer touching
        touch(core, [])
        let down = core.handleMouseEvent(type: .leftMouseDown, event: mouse(.leftMouseDown))
        #expect(down.type == .rightMouseDown)
        #expect(core.handleMouseEvent(type: .leftMouseUp, event: mouse(.leftMouseUp)).type == .rightMouseUp)
    }

    @Test func tapWithTapToClickOffMakesItsOwnRightClick() async throws {
        let posted = Counter()
        let core = makeCore(tapToClick: false, posted: posted)
        touch(core, [(0.88, 0.12, 4)])
        touch(core, [])
        try await Task.sleep(for: .milliseconds(100))  // the click is posted on the main queue
        #expect(posted.value == 1)
        // macOS sends no click of its own here, and a later normal click must stay a left click.
        #expect(core.handleMouseEvent(type: .leftMouseDown, event: mouse(.leftMouseDown)).type == .leftMouseDown)
    }

    @Test func tapWithTapToClickOnWaitsForMacOS() async throws {
        let posted = Counter()
        let core = makeCore(tapToClick: true, posted: posted)
        touch(core, [(0.88, 0.12, 4)])
        touch(core, [])
        try await Task.sleep(for: .milliseconds(100))
        #expect(posted.value == 0)
    }

    @Test func ownSyntheticEventsPassThrough() {
        let core = makeCore()
        touch(core, [(0.9, 0.1, 4)])
        let event = mouse(.leftMouseDown)
        event.setIntegerValueField(.eventSourceUserData, value: EngineCore.syntheticMarker)
        #expect(core.handleMouseEvent(type: .leftMouseDown, event: event).type == .leftMouseDown)
    }

    @Test func noFingerNoConversion() {
        let core = makeCore()
        #expect(core.handleMouseEvent(type: .leftMouseDown, event: mouse(.leftMouseDown)).type == .leftMouseDown)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
