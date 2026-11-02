import CoreGraphics
import Foundation
import XCTest
@testable import ScreenContextCore

final class DockStateTests: XCTestCase {
    func testAccessoryModeHasNoDockIconBadgeOrPanel() {
        var state = DockState(enabled: false)
        state.nudgeArrived(); state.recording = true; state.openPanel()
        XCTAssertFalse(state.showsDockIcon); XCTAssertNil(state.badge); XCTAssertFalse(state.showsLiveDot)
        XCTAssertFalse(state.panelOpen); XCTAssertTrue(state.floatingTugVisible)
    }

    func testNudgesCountUntilThePanelOpens() {
        var state = DockState(enabled: true)
        XCTAssertNil(state.badge)
        state.nudgeArrived(); state.nudgeArrived()
        XCTAssertEqual(state.badge, "2")
        state.dockIconClicked()
        XCTAssertTrue(state.panelOpen); XCTAssertNil(state.badge, "opening the panel shows the record")
        state.nudgeArrived()
        XCTAssertNil(state.badge, "a nudge while the panel is open is already seen")
        state.dockIconClicked()
        XCTAssertFalse(state.panelOpen)
    }

    func testBadgeCapsAtNinePlus() {
        var state = DockState(enabled: true)
        for _ in 0..<12 { state.nudgeArrived() }
        XCTAssertEqual(state.badge, "9+")
    }

    func testLiveDotOnlyWhileRecording() {
        var state = DockState(enabled: true)
        XCTAssertFalse(state.showsLiveDot)
        state.recording = true
        XCTAssertTrue(state.showsLiveDot)
    }

    func testTugTravelsIntoTheOpenPanelAndHidesWhilePresenting() {
        var state = DockState(enabled: true)
        XCTAssertTrue(state.floatingTugVisible)
        state.openPanel()
        XCTAssertFalse(state.floatingTugVisible)
        state.closePanel()
        XCTAssertTrue(state.floatingTugVisible)
        state.hidden = true
        XCTAssertFalse(state.floatingTugVisible)
    }

    func testTurningDockedModeOffClosesThePanelAndClearsTheCount() {
        var state = DockState(enabled: true)
        state.nudgeArrived(); state.openPanel()
        state.setEnabled(false)
        XCTAssertFalse(state.panelOpen); XCTAssertNil(state.badge); XCTAssertFalse(state.showsDockIcon)
    }
}

final class DockPlacementTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)

    func testEdgeFromTheVisibleFrame() {
        XCTAssertEqual(DockPlacement.edge(screen: screen, visible: CGRect(x: 0, y: 72, width: 1728, height: 1013)), .bottom)
        XCTAssertEqual(DockPlacement.edge(screen: screen, visible: CGRect(x: 70, y: 0, width: 1658, height: 1085)), .left)
        XCTAssertEqual(DockPlacement.edge(screen: screen, visible: CGRect(x: 0, y: 0, width: 1658, height: 1085)), .right)
        // Only the menu bar trimmed: the Dock is hidden.
        XCTAssertEqual(DockPlacement.edge(screen: screen, visible: CGRect(x: 0, y: 0, width: 1728, height: 1085)), .hidden)
    }

    func testPanelSitsAboveABottomDockCentredOnTheIcon() {
        let visible = CGRect(x: 0, y: 72, width: 1728, height: 1013)
        let origin = DockPlacement.panelOrigin(size: CGSize(width: 380, height: 420), edge: .bottom, visible: visible, pointer: CGPoint(x: 900, y: 30))
        XCTAssertEqual(origin, CGPoint(x: 710, y: 80))
    }

    func testPanelStaysOnScreenNearTheCorner() {
        let visible = CGRect(x: 0, y: 72, width: 1728, height: 1013)
        let origin = DockPlacement.panelOrigin(size: CGSize(width: 380, height: 420), edge: .bottom, visible: visible, pointer: CGPoint(x: 1720, y: 30))
        XCTAssertEqual(origin.x, 1728 - 380 - 8)
    }

    func testSideDocksAndASecondDisplay() {
        // A display to the left of the main one, with the Dock on its left edge.
        let visible = CGRect(x: -1920 + 70, y: 0, width: 1850, height: 1050)
        let left = DockPlacement.panelOrigin(size: CGSize(width: 380, height: 420), edge: .left, visible: visible, pointer: CGPoint(x: -1890, y: 500))
        XCTAssertEqual(left, CGPoint(x: -1920 + 78, y: 290))
        let right = DockPlacement.panelOrigin(size: CGSize(width: 380, height: 420), edge: .right, visible: CGRect(x: 0, y: 0, width: 1658, height: 1085), pointer: CGPoint(x: 1700, y: 1100))
        XCTAssertEqual(right, CGPoint(x: 1658 - 380 - 8, y: 1085 - 420 - 8))
    }
}

final class LatestRoundNumberTests: XCTestCase {
    private func metrics(_ json: String) throws -> VoiceMetrics { try JSONDecoder().decode(VoiceMetrics.self, from: Data(json.utf8)) }

    func testSummaryWinsWhenTheRoundIsDone() throws {
        let summary = RoundSummary.make([try metrics(#"{"filler_count":2,"hedge_count":1,"restart_count":2}"#), try metrics(#"{"filler_count":0,"hedge_count":1,"restart_count":1}"#)])
        let number = try XCTUnwrap(LatestRoundNumber.make(summary: summary, latest: nil))
        XCTAssertEqual(number.value, 0); XCTAssertEqual(number.habit, .filler); XCTAssertEqual(number.caption, "down from 2 in your first answer")
    }

    func testOtherwiseTheMostUsedHabitInTheLatestAnswer() throws {
        let number = try XCTUnwrap(LatestRoundNumber.make(summary: nil, latest: try metrics(#"{"filler_count":1,"hedge_count":3,"restart_count":0}"#)))
        XCTAssertEqual(number.value, 3); XCTAssertEqual(number.habit, .hedge)
        XCTAssertNil(LatestRoundNumber.make(summary: nil, latest: nil))
    }
}
