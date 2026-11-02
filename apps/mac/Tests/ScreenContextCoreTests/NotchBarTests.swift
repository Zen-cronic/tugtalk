import CoreGraphics
import XCTest
@testable import ScreenContextCore

final class NotchBarPlacementTests: XCTestCase {
    // A 16-inch MacBook Pro: 1728 × 1117 points, a 32 pt safe area at the top, the housing from 771 to 956.
    let notched = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    let notchedVisible = CGRect(x: 0, y: 0, width: 1728, height: 1084)
    let auxLeft = CGRect(x: 0, y: 1085, width: 771, height: 32)
    let auxRight = CGRect(x: 956, y: 1085, width: 772, height: 32)
    var housing: CGRect { NotchBarPlacement.housing(screen: notched, safeTop: 32, auxLeft: auxLeft, auxRight: auxRight)! }

    func testHousingComesFromTheSafeAreaAndTheAreasBesideIt() {
        XCTAssertEqual(housing, CGRect(x: 771, y: 1085, width: 185, height: 32))
    }

    func testNoHousingWithoutASafeAreaOrSideAreas() {
        XCTAssertNil(NotchBarPlacement.housing(screen: notched, safeTop: 0, auxLeft: auxLeft, auxRight: auxRight))
        XCTAssertNil(NotchBarPlacement.housing(screen: notched, safeTop: 32, auxLeft: nil, auxRight: auxRight))
        XCTAssertNil(NotchBarPlacement.housing(screen: notched, safeTop: 32, auxLeft: auxLeft, auxRight: nil))
    }

    func testOnANotchTheBarIsExactlyTheMenuBarsHeightAndHugsTheHousing() {
        let bar = NotchBarPlacement.collapsed(screen: notched, visible: notchedVisible, housing: housing, left: 96, right: 40)
        XCTAssertEqual(bar.frame.height, 32, "no overhang below the menu bar")
        XCTAssertEqual(bar.frame.maxY, 1117, "flush with the top edge")
        XCTAssertEqual(bar.frame.minX, 771 - 96, "the left wing ends at the housing")
        XCTAssertEqual(bar.frame.maxX, 956 + 40, "the right wing starts at the housing")
        XCTAssertEqual(bar.housing, CGRect(x: 96, y: 0, width: 185, height: 32))
    }

    func testContentNeverComesWithinEightPointsOfTheHousing() {
        // The left wing is the content plus its outer inset plus the gap, so the content ends 8 pt short of the housing.
        for content in [40.0, 63.5, 110.0] {
            let wing = NotchBarPlacement.wing(content: content, inset: 10, notch: true)
            let bar = NotchBarPlacement.collapsed(screen: notched, visible: notchedVisible, housing: housing, left: wing, right: 0)
            let contentEnd = bar.frame.minX + 10 + content
            XCTAssertLessThanOrEqual(contentEnd, housing.minX - NotchBarPlacement.notchGap + 0.001, "\(content)")
        }
    }

    func testAnEmptyWingTakesNoRoom() {
        XCTAssertEqual(NotchBarPlacement.wing(content: 0, inset: 10, notch: true), 0)
        let bar = NotchBarPlacement.collapsed(screen: notched, visible: notchedVisible, housing: housing, left: 90, right: 0)
        XCTAssertEqual(bar.frame.maxX, housing.maxX, "Ready has no right wing")
    }

    func testTheRightWingHidesWhenStatusItemsReachTheNotch() {
        XCTAssertTrue(NotchBarPlacement.rightWingFits(statusItemsMinX: nil, housingMaxX: 956, width: 40))
        XCTAssertTrue(NotchBarPlacement.rightWingFits(statusItemsMinX: 1200, housingMaxX: 956, width: 40))
        XCTAssertFalse(NotchBarPlacement.rightWingFits(statusItemsMinX: 980, housingMaxX: 956, width: 40), "a crowded menu bar")
    }

    func testWithoutANotchTheBarHangsUnderTheMenuBarAtItsHeight() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let visible = CGRect(x: 0, y: 0, width: 1920, height: 1056) // 24 pt menu bar
        let bar = NotchBarPlacement.collapsed(screen: screen, visible: visible, housing: nil, left: 100, right: 36)
        XCTAssertNil(bar.housing)
        XCTAssertEqual(bar.frame, CGRect(x: 892, y: 1032, width: 136, height: 24))
        XCTAssertEqual(bar.band, 24)
    }

    func testWithAHiddenMenuBarTheBarMeetsTheTopEdgeAtTheStandardHeight() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let bar = NotchBarPlacement.collapsed(screen: screen, visible: screen, housing: nil, left: 100, right: 0)
        XCTAssertEqual(bar.frame.maxY, 900)
        XCTAssertEqual(bar.frame.height, NotchBarPlacement.standardMenuBar)
    }

    func testASecondDisplayToTheLeftKeepsItsOwnCoordinates() {
        let screen = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let visible = CGRect(x: -1920, y: 0, width: 1920, height: 1055)
        let bar = NotchBarPlacement.collapsed(screen: screen, visible: visible, housing: nil, left: 60, right: 60)
        XCTAssertEqual(bar.frame.midX, -960)
    }

    func testThePanelGrowsFromTugsCornerAndKeepsTheHousingInPlace() {
        let bar = NotchBarPlacement.collapsed(screen: notched, visible: notchedVisible, housing: housing, left: 96, right: 0)
        let open = NotchBarPlacement.expanded(from: bar, size: CGSize(width: 420, height: 300), screen: notched)
        XCTAssertEqual(open.frame.maxY, bar.frame.maxY, "same top edge")
        XCTAssertEqual(open.frame.minX, bar.frame.minX, "Tug's corner does not move")
        XCTAssertEqual(open.frame.size, CGSize(width: 420, height: 300))
        XCTAssertEqual(open.housing, CGRect(x: 96, y: 0, width: 185, height: 32))
    }

    func testThePanelIsNeverNarrowerThanTheBarNorOffTheScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1280, height: 400)
        let bar = NotchBarPlacement.collapsed(screen: screen, visible: CGRect(x: 0, y: 0, width: 1280, height: 376), housing: nil, left: 300, right: 200)
        let open = NotchBarPlacement.expanded(from: bar, size: CGSize(width: 300, height: 900), screen: screen)
        XCTAssertEqual(open.frame.width, 500)
        XCTAssertEqual(open.frame.minY, 0, "clipped to the screen's bottom edge")
        let edge = NotchBarPlacement.Layout(frame: CGRect(x: 1100, y: 376, width: 100, height: 24), housing: nil, band: 24)
        XCTAssertEqual(NotchBarPlacement.expanded(from: edge, size: CGSize(width: 420, height: 200), screen: screen).frame.maxX, 1280)
    }
}

final class TugHomeTests: XCTestCase {
    func testTheTopBarIsTheStandardHome() {
        XCTAssertEqual(TugHome.resolve(stored: nil, legacyDockMode: false), .topBar)
    }

    func testTheOlderShowInDockSwitchStillMeansTheDock() {
        XCTAssertEqual(TugHome.resolve(stored: nil, legacyDockMode: true), .dock)
    }

    func testAStoredChoiceWinsAndAnUnknownOneFallsBack() {
        XCTAssertEqual(TugHome.resolve(stored: "floating", legacyDockMode: true), .floating)
        XCTAssertEqual(TugHome.resolve(stored: "attic", legacyDockMode: false), .topBar)
    }

    func testEachHomeShowsExactlyItsOwnSurfaces() {
        XCTAssertTrue(TugHome.topBar.showsTopBar); XCTAssertFalse(TugHome.topBar.floatsTug); XCTAssertFalse(TugHome.topBar.showsDockIcon)
        XCTAssertFalse(TugHome.floating.showsTopBar); XCTAssertTrue(TugHome.floating.floatsTug); XCTAssertFalse(TugHome.floating.showsDockIcon)
        XCTAssertFalse(TugHome.dock.showsTopBar); XCTAssertTrue(TugHome.dock.floatsTug); XCTAssertTrue(TugHome.dock.showsDockIcon)
    }

    func testSwitchingHomesKeepsTheDockRulesConsistent() {
        // The app turns docked mode on only for the Dock home; leaving it closes the panel and clears the count.
        var dock = DockState(enabled: TugHome.dock.showsDockIcon)
        dock.nudgeArrived(); dock.openPanel()
        dock.setEnabled(TugHome.topBar.showsDockIcon)
        XCTAssertFalse(dock.showsDockIcon); XCTAssertFalse(dock.panelOpen); XCTAssertNil(dock.badge)
    }

    func testTitlesArePlainWords() {
        XCTAssertEqual(TugHome.allCases.map(\.title), ["Top bar", "Floating", "Dock"])
    }
}

final class NotchBarStatusTests: XCTestCase {
    func testTheSixTurnWords() {
        XCTAssertEqual(NotchBarStatus.make(.idle).word, "Ready")
        XCTAssertEqual(NotchBarStatus.make(.voiceListening(seconds: 4)).word, "Listening")
        XCTAssertEqual(NotchBarStatus.make(.thinking).word, "Thinking")
        XCTAssertEqual(NotchBarStatus.make(.voiceReply(finished: false, endsRound: false)).word, "Speaking")
        XCTAssertEqual(NotchBarStatus.make(.voiceReply(finished: true, endsRound: false)).word, "Your turn")
        XCTAssertEqual(NotchBarStatus.make(.offline(retryable: true)).word, "Offline")
    }

    func testReadyHasNoRightWingAndEachLiveStateOneMark() {
        XCTAssertEqual(NotchBarStatus.make(.idle).mark, .none, "the keys are in the panel, not the bar")
        XCTAssertEqual(NotchBarStatus.make(.voiceListening(seconds: 64)).mark, .recordLight("1:04"))
        XCTAssertEqual(NotchBarStatus.make(.thinking).mark, .dots)
        XCTAssertEqual(NotchBarStatus.make(.voiceReply(finished: false, endsRound: false)).mark, .wave)
        XCTAssertEqual(NotchBarStatus.make(.voiceReply(finished: true, endsRound: false)).mark, .none)
        XCTAssertEqual(NotchBarStatus.make(.offline(retryable: false)).mark, .symbol("wifi.slash"))
    }

    func testTugsFaceCarriesTheState() {
        XCTAssertEqual(NotchBarStatus.make(.idle).face, .rest)
        XCTAssertEqual(NotchBarStatus.make(.voiceListening(seconds: 1)).face, .listening)
        XCTAssertEqual(NotchBarStatus.make(.thinking).face, .thinking)
        XCTAssertEqual(NotchBarStatus.make(.voiceReply(finished: false, endsRound: false)).face, .speaking)
        XCTAssertEqual(NotchBarStatus.make(.contextCard(talking: true)).face, .speaking)
        XCTAssertEqual(NotchBarStatus.make(.voiceReply(finished: true, endsRound: false)).face, .turn)
        XCTAssertEqual(NotchBarStatus.make(.offline(retryable: true)).face, .still)
    }

    func testOnlyYourTurnPutsTheWordInAChip() {
        XCTAssertTrue(NotchBarStatus.make(.voiceReply(finished: true, endsRound: false)).wordChip)
        let others: [NotchBarInput] = [.idle, .voiceListening(seconds: 0), .thinking, .voiceReply(finished: false, endsRound: false),
                                       .voiceReply(finished: true, endsRound: true), .offline(retryable: true), .permission]
        for input in others { XCTAssertFalse(NotchBarStatus.make(input).wordChip, "\(input)") }
    }

    func testTheRecordLightIsOnlyForListening() {
        let all: [NotchBarInput] = [.idle, .readingWindow, .thinking, .contextCard(talking: true), .contextCard(talking: false),
                                    .voiceReply(finished: false, endsRound: false), .voiceReply(finished: true, endsRound: true),
                                    .nudge(opened: false), .blocked, .offline(retryable: true), .voiceError(retryable: true), .permission, .notice, .hidden]
        for input in all {
            if case .recordLight = NotchBarStatus.make(input).mark { XCTFail("\(input) shows the record light") }
        }
    }

    func testRepliesOpenCompactAndCardsThatNeedAnActionOpenInFull() {
        XCTAssertTrue(NotchBarStatus.make(.voiceReply(finished: false, endsRound: false)).compact)
        XCTAssertTrue(NotchBarStatus.make(.contextCard(talking: false)).compact)
        XCTAssertFalse(NotchBarStatus.make(.permission).compact)
        XCTAssertFalse(NotchBarStatus.make(.offline(retryable: true)).compact)
        XCTAssertFalse(NotchBarStatus.make(.voiceError(retryable: true)).compact)
    }

    func testCardsThatNeedAnActionStayOpen() {
        XCTAssertNil(NotchBarStatus.make(.permission).linger)
        XCTAssertNil(NotchBarStatus.make(.offline(retryable: true)).linger)
        XCTAssertNil(NotchBarStatus.make(.voiceError(retryable: true)).linger)
        XCTAssertNil(NotchBarStatus.make(.voiceReply(finished: false, endsRound: false)).linger, "open while the question plays")
        XCTAssertEqual(NotchBarStatus.make(.voiceReply(finished: true, endsRound: false)).linger, 1, "folds about 1 s after it is spoken")
        XCTAssertFalse(NotchBarStatus.make(.voiceListening(seconds: 0)).showsCard, "never covers the screen while you talk")
    }

    func testOneWordPerStateExceptTheYourTurnCue() {
        let inputs: [NotchBarInput] = [.idle, .readingWindow, .voiceListening(seconds: 0), .thinking, .contextCard(talking: false), .contextCard(talking: true),
                                       .voiceReply(finished: false, endsRound: false), .voiceReply(finished: true, endsRound: true),
                                       .nudge(opened: true), .blocked, .offline(retryable: true), .voiceError(retryable: false), .permission, .notice, .hidden]
        for input in inputs {
            let word = NotchBarStatus.make(input).word
            XCTAssertFalse(word.contains(" "), "\(word) is more than one word")
            XCTAssertLessThanOrEqual(word.count, 9, word)
        }
        XCTAssertEqual(NotchBarStatus.make(.permission).word, "Setup")
    }
}

final class NotchBarExpansionTests: XCTestCase {
    func testHoverOpensOnlyAfterTheDelayAndClosesWhenThePointerLeaves() {
        var e = NotchBarExpansion()
        e.pointerEntered()
        XCTAssertFalse(e.expanded, "passing over the bar opens nothing")
        e.hoverDwelled()
        XCTAssertEqual(e.reason, .hover)
        e.pointerLeft()
        XCTAssertFalse(e.expanded)
    }

    func testADwellAfterThePointerLeftOpensNothing() {
        var e = NotchBarExpansion()
        e.pointerEntered(); e.pointerLeft(); e.hoverDwelled()
        XCTAssertFalse(e.expanded)
    }

    func testAClickTogglesAndEscCloses() {
        var e = NotchBarExpansion()
        e.clicked(); XCTAssertEqual(e.reason, .click)
        e.clicked(); XCTAssertFalse(e.expanded)
        e.clicked(); e.close(); XCTAssertFalse(e.expanded)
    }

    func testAKeyboardOpenedPanelClosesWhenItLosesTheKeyboard() {
        var e = NotchBarExpansion()
        e.clicked(); e.resignedKey()
        XCTAssertFalse(e.expanded)
        var hovered = NotchBarExpansion()
        hovered.pointerEntered(); hovered.clicked(); hovered.resignedKey()
        XCTAssertTrue(hovered.expanded, "the pointer is still over it")
    }

    func testACardOpensItAndItsLingerClosesIt() {
        var e = NotchBarExpansion()
        e.cardShown(); XCTAssertEqual(e.reason, .card)
        e.pointerLeft(); XCTAssertTrue(e.expanded, "a card stays for its linger, not for the pointer")
        e.cardCleared(); XCTAssertFalse(e.expanded)
    }

    func testACardUnderThePointerStaysOpenAsAHover() {
        var e = NotchBarExpansion()
        e.cardShown(); e.pointerEntered(); e.cardCleared()
        XCTAssertEqual(e.reason, .hover)
    }

    func testACardDoesNotTakeOverAnOpenPanel() {
        var e = NotchBarExpansion()
        e.clicked(); e.cardShown(); e.cardCleared()
        XCTAssertEqual(e.reason, .click)
    }
}
