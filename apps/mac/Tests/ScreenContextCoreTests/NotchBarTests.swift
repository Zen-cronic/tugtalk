import CoreGraphics
import XCTest
@testable import ScreenContextCore

final class NotchBarPlacementTests: XCTestCase {
    // A 16-inch MacBook Pro: 1728 × 1117 points, a 32 pt safe area at the top, the housing from 771 to 956.
    let notched = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    let notchedVisible = CGRect(x: 0, y: 0, width: 1728, height: 1084)
    let auxLeft = CGRect(x: 0, y: 1085, width: 771, height: 32)
    let auxRight = CGRect(x: 956, y: 1085, width: 772, height: 32)

    func testHousingComesFromTheSafeAreaAndTheAreasBesideIt() {
        let housing = NotchBarPlacement.housing(screen: notched, safeTop: 32, auxLeft: auxLeft, auxRight: auxRight)
        XCTAssertEqual(housing, CGRect(x: 771, y: 1085, width: 185, height: 32))
    }

    func testNoHousingWithoutASafeAreaOrSideAreas() {
        XCTAssertNil(NotchBarPlacement.housing(screen: notched, safeTop: 0, auxLeft: auxLeft, auxRight: auxRight))
        XCTAssertNil(NotchBarPlacement.housing(screen: notched, safeTop: 32, auxLeft: nil, auxRight: auxRight))
        XCTAssertNil(NotchBarPlacement.housing(screen: notched, safeTop: 32, auxLeft: auxLeft, auxRight: nil))
    }

    func testOnANotchTheBarWrapsTheHousingFlushWithTheTop() {
        let housing = NotchBarPlacement.housing(screen: notched, safeTop: 32, auxLeft: auxLeft, auxRight: auxRight)
        let bar = NotchBarPlacement.collapsed(screen: notched, visible: notchedVisible, housing: housing, wing: 124, below: 6, plain: CGSize(width: 232, height: 30))
        XCTAssertEqual(bar.frame.width, 185 + 2 * 124)
        XCTAssertEqual(bar.frame.height, 38)
        XCTAssertEqual(bar.frame.maxY, 1117, "flush with the top edge, over the menu bar")
        XCTAssertEqual(bar.frame.midX, housing!.midX, accuracy: 0.001, "centred on the housing, not the screen")
        XCTAssertEqual(bar.housing, CGRect(x: 124, y: 0, width: 185, height: 32), "the housing between the wings, at the window's top")
        XCTAssertEqual(bar.band, 32)
    }

    func testWithoutANotchTheBarHangsUnderTheMenuBar() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let visible = CGRect(x: 0, y: 0, width: 1920, height: 1055) // 25 pt menu bar
        let bar = NotchBarPlacement.collapsed(screen: screen, visible: visible, housing: nil, wing: 124, below: 6, plain: CGSize(width: 232, height: 30))
        XCTAssertNil(bar.housing)
        XCTAssertEqual(bar.frame, CGRect(x: 844, y: 1025, width: 232, height: 30))
        XCTAssertEqual(bar.band, 30)
    }

    func testWithAHiddenMenuBarTheBarMeetsTheTopEdge() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let bar = NotchBarPlacement.collapsed(screen: screen, visible: screen, housing: nil, wing: 124, below: 6, plain: CGSize(width: 232, height: 30))
        XCTAssertEqual(bar.frame.maxY, 900)
    }

    func testASecondDisplayToTheLeftKeepsItsOwnCoordinates() {
        let screen = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let visible = CGRect(x: -1920, y: 0, width: 1920, height: 1055)
        let bar = NotchBarPlacement.collapsed(screen: screen, visible: visible, housing: nil, wing: 124, below: 6, plain: CGSize(width: 232, height: 30))
        XCTAssertEqual(bar.frame.midX, -960)
    }

    func testThePanelGrowsDownFromTheBarAndKeepsTheHousingInPlace() {
        let housing = NotchBarPlacement.housing(screen: notched, safeTop: 32, auxLeft: auxLeft, auxRight: auxRight)
        let bar = NotchBarPlacement.collapsed(screen: notched, visible: notchedVisible, housing: housing, wing: 124, below: 6, plain: .zero)
        let open = NotchBarPlacement.expanded(from: bar, size: CGSize(width: 456, height: 420), screen: notched)
        XCTAssertEqual(open.frame.maxY, bar.frame.maxY, "same top edge")
        XCTAssertEqual(open.frame.midX, bar.frame.midX, accuracy: 0.001)
        XCTAssertEqual(open.frame.size, CGSize(width: 456, height: 420))
        XCTAssertEqual(open.housing?.minX ?? 0, (456 - 185) / 2, accuracy: 0.001)
        XCTAssertEqual(open.housing?.minY, 0)
    }

    func testThePanelIsNeverNarrowerThanTheBarNorTallerThanTheScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1280, height: 400)
        let bar = NotchBarPlacement.collapsed(screen: screen, visible: CGRect(x: 0, y: 0, width: 1280, height: 375), housing: nil, wing: 0, below: 0,
                                              plain: CGSize(width: 500, height: 30))
        let open = NotchBarPlacement.expanded(from: bar, size: CGSize(width: 300, height: 900), screen: screen)
        XCTAssertEqual(open.frame.width, 500)
        XCTAssertEqual(open.frame.minY, 0, "clipped to the screen's bottom edge")
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

    func testEachTurnHasItsOwnMark() {
        XCTAssertEqual(NotchBarStatus.make(.idle).mark, .keycaps("⌃⌥T", cue: false))
        XCTAssertEqual(NotchBarStatus.make(.voiceListening(seconds: 64)).mark, .recordLight("1:04"))
        XCTAssertEqual(NotchBarStatus.make(.thinking).mark, .dots)
        XCTAssertEqual(NotchBarStatus.make(.voiceReply(finished: false, endsRound: false)).mark, .wave)
        XCTAssertEqual(NotchBarStatus.make(.voiceReply(finished: true, endsRound: false)).mark, .keycaps("⌃⌥T", cue: true))
        XCTAssertEqual(NotchBarStatus.make(.offline(retryable: false)).mark, .symbol("wifi.slash"))
    }

    func testTheRecordLightIsOnlyForListening() {
        let all: [NotchBarInput] = [.idle, .readingWindow, .thinking, .contextCard(talking: true), .contextCard(talking: false),
                                    .voiceReply(finished: false, endsRound: false), .voiceReply(finished: true, endsRound: true),
                                    .nudge(opened: false), .blocked, .offline(retryable: true), .voiceError(retryable: true), .permission, .notice, .hidden]
        for input in all {
            if case .recordLight = NotchBarStatus.make(input).mark { XCTFail("\(input) shows the record light") }
        }
    }

    func testCardsThatNeedAnActionStayOpen() {
        XCTAssertNil(NotchBarStatus.make(.permission).linger)
        XCTAssertNil(NotchBarStatus.make(.offline(retryable: true)).linger)
        XCTAssertNil(NotchBarStatus.make(.voiceError(retryable: true)).linger)
        XCTAssertNil(NotchBarStatus.make(.voiceReply(finished: false, endsRound: false)).linger, "open while the question plays")
        XCTAssertEqual(NotchBarStatus.make(.voiceReply(finished: true, endsRound: false)).linger, 1, "folds about 1 s after it is spoken")
        XCTAssertFalse(NotchBarStatus.make(.voiceListening(seconds: 0)).showsCard, "never covers the screen while you talk")
    }

    func testWordsFitTheBarWithoutCoinedTerms() {
        let words = [NotchBarInput.idle, .readingWindow, .voiceListening(seconds: 0), .thinking, .contextCard(talking: false), .contextCard(talking: true),
                     .voiceReply(finished: false, endsRound: false), .voiceReply(finished: true, endsRound: false), .offline(retryable: true), .notice,
                     .voiceReply(finished: true, endsRound: true), .nudge(opened: true), .blocked, .voiceError(retryable: false), .permission, .hidden]
            .map { NotchBarStatus.make($0).word }
        for word in words { XCTAssertLessThanOrEqual(word.count, 9, "\(word) would run under the notch") }
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
