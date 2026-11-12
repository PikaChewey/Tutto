import XCTest
@testable import TuttoKit

final class MenuBarIconRulesTests: XCTestCase {
    func testDividerLengthAndChevronFollowItsState() {
        var divider = MenuBarDivider()
        XCTAssertTrue(divider.isCollapsed, "it starts tucked away")
        XCTAssertEqual(divider.length, 10_000)
        XCTAssertEqual(divider.chevronSymbol, "chevron.left")
        XCTAssertEqual(divider.actionTitle, "Show hidden menu bar icons")
        divider = divider.toggled
        XCTAssertFalse(divider.isCollapsed)
        XCTAssertEqual(divider.length, MenuBarDivider.expandedLength)
        XCTAssertLessThan(divider.length, 40, "expanded, it's a thin divider")
        XCTAssertEqual(divider.chevronSymbol, "chevron.right")
        XCTAssertEqual(divider.actionTitle, "Hide menu bar icons")
        XCTAssertEqual(divider.toggled, MenuBarDivider(isCollapsed: true))
    }

    func testAutoHideChoices() {
        XCTAssertEqual(MenuBarAutoHide.standard.seconds, 10)
        XCTAssertEqual(MenuBarAutoHide.choices.map(\.title), ["5 s", "10 s", "30 s", "Never"])
        XCTAssertNil(MenuBarAutoHide.never.seconds)
        XCTAssertEqual(MenuBarAutoHide(rawValue: 30), .thirtySeconds)
        XCTAssertNil(MenuBarAutoHide(rawValue: 7), "an unknown saved value falls back to the default")
    }

    func testNothingHidesOnItsOwnWhenSetToNever() {
        XCTAssertEqual(MenuBarAutoHide.never.decision(shown: 9_999, pointerInMenuBar: false), .stayOpen)
    }

    func testItWaitsOutTheDelayThenHides() {
        let setting = MenuBarAutoHide.tenSeconds
        XCTAssertEqual(setting.decision(shown: 0, pointerInMenuBar: false), .checkAgain(after: 10))
        XCTAssertEqual(setting.decision(shown: 4, pointerInMenuBar: true), .checkAgain(after: 6),
                       "before the delay is up the pointer doesn't matter")
        XCTAssertEqual(setting.decision(shown: 10, pointerInMenuBar: false), .hide)
        XCTAssertEqual(setting.decision(shown: 31, pointerInMenuBar: false), .hide)
    }

    func testItStaysWhileThePointerIsInTheMenuBar() {
        let setting = MenuBarAutoHide.fiveSeconds
        XCTAssertEqual(setting.decision(shown: 5, pointerInMenuBar: true), .checkAgain(after: MenuBarAutoHide.recheckInterval))
        XCTAssertEqual(setting.decision(shown: 7, pointerInMenuBar: true), .checkAgain(after: MenuBarAutoHide.recheckInterval))
        XCTAssertEqual(setting.decision(shown: 9, pointerInMenuBar: false), .hide, "once the pointer leaves, it hides")
    }

    func testAChangedSettingCountsFromWhenTheIconsWereShown() {
        // Shown 12 s ago, then the setting goes from 30 s to 5 s: hide at once.
        XCTAssertEqual(MenuBarAutoHide.fiveSeconds.decision(shown: 12, pointerInMenuBar: false), .hide)
        XCTAssertEqual(MenuBarAutoHide.thirtySeconds.decision(shown: 12, pointerInMenuBar: false), .checkAgain(after: 18))
    }

    func testPointerInTheMenuBar() {
        // A 982 pt tall screen with a 37 pt menu bar (a notch Mac).
        XCTAssertTrue(MenuBarAutoHide.pointerIsInMenuBar(y: 981, screenTop: 982, barHeight: 37))
        XCTAssertTrue(MenuBarAutoHide.pointerIsInMenuBar(y: 945, screenTop: 982, barHeight: 37))
        XCTAssertFalse(MenuBarAutoHide.pointerIsInMenuBar(y: 944, screenTop: 982, barHeight: 37))
        XCTAssertFalse(MenuBarAutoHide.pointerIsInMenuBar(y: 400, screenTop: 982, barHeight: 24))
    }

    func testDividerStartsJustLeftOfTuttosIcon() {
        XCTAssertEqual(MenuBarDividerPosition.initial(tuttoPosition: 354), 354 + MenuBarDividerPosition.gap)
        XCTAssertGreaterThan(MenuBarDividerPosition.initial(tuttoPosition: 354)!, 354, "larger sits further left")
        XCTAssertNil(MenuBarDividerPosition.initial(tuttoPosition: nil))
        XCTAssertNil(MenuBarDividerPosition.initial(tuttoPosition: 0))
        XCTAssertEqual(MenuBarDividerPosition.defaultsKey(autosaveName: "tutto.divider"),
                       "NSStatusItem Preferred Position tutto.divider")
    }

    func testTuttosIconMustStayRightOfTheDivider() {
        let divider = CGRect(x: 1000, y: 0, width: 24, height: 24)
        let right = CGRect(x: 1026, y: 0, width: 30, height: 24)
        let left = CGRect(x: 960, y: 0, width: 30, height: 24)
        XCTAssertEqual(MenuBarOrder.check(divider: divider, tutto: right), .fine)
        XCTAssertEqual(MenuBarOrder.check(divider: divider, tutto: left), .tuttoWouldBeTucked)
        // Collapsed, the divider's window is 10,000 pt wide and ends where Tutto's icon begins.
        let collapsed = CGRect(x: 1024 - 10_000, y: 0, width: 10_000, height: 24)
        XCTAssertEqual(MenuBarOrder.check(divider: collapsed, tutto: CGRect(x: 1024, y: 0, width: 30, height: 24)), .fine)
        XCTAssertEqual(MenuBarOrder.check(divider: collapsed, tutto: CGRect(x: -9000, y: 0, width: 30, height: 24)), .tuttoWouldBeTucked)
    }

    func testOrderIsUnknownUntilBothIconsHaveAPlace() {
        let frame = CGRect(x: 100, y: 0, width: 24, height: 24)
        XCTAssertEqual(MenuBarOrder.check(divider: nil, tutto: frame), .unknown)
        XCTAssertEqual(MenuBarOrder.check(divider: frame, tutto: nil), .unknown)
        XCTAssertEqual(MenuBarOrder.check(divider: frame, tutto: .zero), .unknown)
    }
}
