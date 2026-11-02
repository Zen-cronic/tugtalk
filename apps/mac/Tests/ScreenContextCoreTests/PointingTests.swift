import CoreGraphics
import Foundation
import XCTest
@testable import ScreenContextCore

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../Fixtures").standardized

private func line(_ text: String, y: CGFloat) -> TextLine { TextLine(text: text, box: CGRect(x: 0.1, y: y, width: 0.6, height: 0.03)) }

final class ScreenMappingTests: XCTestCase {
    private func assertRect(_ a: CGRect, _ b: CGRect, accuracy: CGFloat = 0.001, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.minX, b.minX, accuracy: accuracy, file: file, line: line); XCTAssertEqual(a.minY, b.minY, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.width, b.width, accuracy: accuracy, file: file, line: line); XCTAssertEqual(a.height, b.height, accuracy: accuracy, file: file, line: line)
    }

    func testVisionBoxFlipsToTopLeftWindowPoints() {
        // A window at (100, 50), 800 × 600 points. Vision's box sits 10% up from the image's bottom.
        let box = CGRect(x: 0.25, y: 0.10, width: 0.5, height: 0.05)
        let rect = ScreenMapping.globalTopLeftRect(normalized: box, windowFrame: CGRect(x: 100, y: 50, width: 800, height: 600))
        // Top edge: 1 − 0.15 = 0.85 of the height below the window's top.
        assertRect(rect, CGRect(x: 300, y: 50 + 510, width: 400, height: 30))
    }

    func testTheImageScaleDropsOut() {
        // The same box gives the same points whatever the capture's pixel size (1x, 2x or shrunk to 2560 px):
        // only the window frame in points is used.
        let box = CGRect(x: 0.1, y: 0.5, width: 0.2, height: 0.1)
        let frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let rect = ScreenMapping.globalTopLeftRect(normalized: box, windowFrame: frame)
        assertRect(rect, CGRect(x: 144, y: 360, width: 288, height: 90))
    }

    func testFullBoxCoversTheWholeWindow() {
        let frame = CGRect(x: -1200, y: -300, width: 900, height: 700)
        assertRect(ScreenMapping.globalTopLeftRect(normalized: CGRect(x: 0, y: 0, width: 1, height: 1), windowFrame: frame), frame)
    }

    func testTopLeftToAppKitOnTheMainDisplay() {
        // Main display 1512 × 982. A line 100 pt below the top is 100 pt below the top in AppKit too.
        let rect = ScreenMapping.appKitRect(fromGlobalTopLeft: CGRect(x: 200, y: 100, width: 300, height: 20), mainDisplayHeight: 982)
        assertRect(rect, CGRect(x: 200, y: 982 - 120, width: 300, height: 20))
    }

    func testSecondDisplayAboveAndLeftOfTheMain() {
        // A display above the main one has negative Core Graphics y and AppKit y above the main's height.
        let above = ScreenMapping.appKitRect(fromGlobalTopLeft: CGRect(x: 40, y: -800, width: 100, height: 20), mainDisplayHeight: 982)
        assertRect(above, CGRect(x: 40, y: 982 + 780, width: 100, height: 20))
        // A display to the left keeps its negative x, and a window there maps through unchanged.
        let frame = CGRect(x: -1920, y: 0, width: 1000, height: 800)
        let line = ScreenMapping.globalTopLeftRect(normalized: CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.05), windowFrame: frame)
        assertRect(line, CGRect(x: -1420, y: 360, width: 100, height: 40))
        assertRect(ScreenMapping.appKitRect(fromGlobalTopLeft: line, mainDisplayHeight: 1080), CGRect(x: -1420, y: 680, width: 100, height: 40))
    }

    func testPixelAlignmentAtRetinaScale() {
        let rect = CGRect(x: 10.3, y: 20.6, width: 100.1, height: 18.2)
        assertRect(ScreenMapping.pixelAligned(rect, scale: 2), CGRect(x: 10, y: 20.5, width: 100.5, height: 18.5))
        assertRect(ScreenMapping.pixelAligned(rect, scale: 1), CGRect(x: 10, y: 20, width: 101, height: 19))
    }

    func testRingLeavesRoomAndMovesAreNoticed() {
        let ring = ScreenMapping.ringRect(around: CGRect(x: 100, y: 100, width: 200, height: 20))
        XCTAssertEqual(ring, CGRect(x: 91, y: 91, width: 218, height: 38), "9 pt of room on every side")
        // A line near the window's left edge: the ring stays 16 pt inside the window.
        let inside = ScreenMapping.ringRect(around: CGRect(x: 104, y: 300, width: 200, height: 20), inside: CGRect(x: 100, y: 100, width: 800, height: 600))
        XCTAssertEqual(inside.minX, 116)
        XCTAssertFalse(ScreenMapping.hasMoved(from: CGRect(x: 0, y: 0, width: 10, height: 10), to: CGRect(x: 0.2, y: 0, width: 10, height: 10)))
        XCTAssertTrue(ScreenMapping.hasMoved(from: CGRect(x: 0, y: 0, width: 10, height: 10), to: CGRect(x: 4, y: 0, width: 10, height: 10)))
    }
}

final class LineMatcherTests: XCTestCase {
    let lines = [
        line("Meeting prep: 1:1 with Dana Whitfield", y: 0.9),
        line("Goal: ask to own the Q1 launch", y: 0.8),
        line("Shipped the beta two weeks early", y: 0.6),
        line("The ask (at the end): could I maybe lead the launch?", y: 0.2),
    ]

    func testSharedWordsPickTheBuriedAsk() throws {
        let match = try XCTUnwrap(LineMatcher.bestLine(in: lines, summary: "You're preparing to ask to own the Q1 launch in a 1:1.",
                                                       observation: "For \"Answer clearly\", lead with the ask; right now it's buried at the end.",
                                                       nextStep: "Say the ask in one sentence, out loud, twice."))
        XCTAssertEqual(match.index, 3)
        XCTAssertEqual(match.label, "The ask is here")
    }

    func testAQuotedSpanOnOneLineWins() throws {
        let match = try XCTUnwrap(LineMatcher.bestLine(in: lines, summary: "", observation: "You wrote “two weeks early”: lead with it.", nextStep: ""))
        XCTAssertEqual(match.index, 2)
        XCTAssertEqual(match.label, "This line")
    }

    func testNoClearMatchMeansNoRing() {
        // The local test server's card shares one word with two lines: no ring rather than a guess.
        XCTAssertNil(LineMatcher.bestLine(in: lines, summary: "Stub card: a meeting prep note of 70 words.",
                                          observation: "Stub: this is linked to \"Answer clearly\".", nextStep: "Stub: say your main ask in one sentence."))
        XCTAssertNil(LineMatcher.bestLine(in: [], summary: "x", observation: "lead the ask", nextStep: "the end"))
        // Without a goal the server's test card says so; the word "goal" is about the card, not the window.
        XCTAssertNil(LineMatcher.bestLine(in: lines, summary: "Stub card: a meeting prep note of 70 words.",
                                          observation: "Stub: no goal was selected.", nextStep: "Stub: say your main ask in one sentence."))
    }

    func testLinesWithoutBoxesAreNeverPicked() {
        let boxless = lines.map { TextLine(text: $0.text, box: .zero) }
        XCTAssertNil(LineMatcher.bestLine(in: boxless, summary: "", observation: "lead with the ask; it's buried at the end", nextStep: ""))
    }

    func testPlaceholdersAndStopwordsDoNotCount() {
        XCTAssertEqual(LineMatcher.tokens("Ask [person] about the plans, then say it"), ["ask", "plan"])
    }

    func testOnTheRenderedFixtureTheRingLandsOnTheAskLine() throws {
        let image = try ImageLoading.cgImage(at: fixtures.appending(path: "meeting-prep.png"))
        let read = try VisionTextReader().readLines(image)
        XCTAssertFalse(read.isEmpty)
        XCTAssertTrue(read.allSatisfy { $0.box.width > 0 && $0.box.maxY <= 1.0001 && $0.box.minX >= -0.0001 })
        let match = try XCTUnwrap(LineMatcher.bestLine(in: read, summary: "You're preparing to ask to own the Q1 launch in a 1:1.",
                                                       observation: "For \"Answer clearly\", lead with the ask; right now it's buried at the end.",
                                                       nextStep: "Say the ask in one sentence, out loud, twice."))
        XCTAssertTrue(read[match.index].text.lowercased().contains("could i maybe lead"), read[match.index].text)
        // It is the last line of the note, so its box is the lowest one (Vision's y grows upwards).
        XCTAssertEqual(read[match.index].box.midY, read.map(\.box.midY).min()!, accuracy: 0.0001)
    }
}

final class RoundSummaryTests: XCTestCase {
    private func metrics(_ fillers: Int?, _ hedges: Int?, _ restarts: Int?) throws -> VoiceMetrics {
        var parts: [String] = []
        if let fillers { parts.append(#""filler_count":\#(fillers)"#) }
        if let hedges { parts.append(#""hedge_count":\#(hedges)"#) }
        if let restarts { parts.append(#""restart_count":\#(restarts)"#) }
        return try JSONDecoder().decode(VoiceMetrics.self, from: Data("{\(parts.joined(separator: ","))}".utf8))
    }

    func testTheBiggestDropIsTheNumber() throws {
        let summary = try XCTUnwrap(RoundSummary.make([metrics(2, 1, 2), metrics(1, 1, 1), metrics(0, 1, 1)]))
        XCTAssertEqual(summary.habit, .filler); XCTAssertEqual(summary.first, 2); XCTAssertEqual(summary.last, 0)
        XCTAssertEqual(summary.answers, 3); XCTAssertTrue(summary.dropped)
    }

    func testWithNoDropTheMostUsedHabitIsShown() throws {
        let summary = try XCTUnwrap(RoundSummary.make([metrics(1, 0, 0), metrics(1, 2, 0)]))
        XCTAssertEqual(summary.habit, .hedge); XCTAssertEqual(summary.last, 2); XCTAssertFalse(summary.dropped)
    }

    func testOneAnswerHasNoSummary() throws {
        XCTAssertNil(RoundSummary.make([try metrics(2, 1, 2)]))
        XCTAssertNil(RoundSummary.make([try metrics(nil, nil, nil), try metrics(1, 1, 1)]))
    }

    func testSingularAndPlural() {
        XCTAssertEqual(RoundSummary.count(1, .hedge), "1 hedge")
        XCTAssertEqual(RoundSummary.count(0, .filler), "0 fillers")
        XCTAssertEqual(RoundSummary.count(2, .restart), "2 restarts")
    }
}

final class PointingGateTests: XCTestCase {
    typealias W = PointingGate.WindowRecord
    let bounds = CGRect(x: 100, y: 100, width: 800, height: 600)
    let ring = CGRect(x: 120, y: 500, width: 400, height: 30)
    var target: W { W(id: 10, pid: 42, bounds: bounds, layer: 0, alpha: 1) }

    func testSameWindowNothingAboveIsClear() {
        XCTAssertEqual(PointingGate.evaluate(target: target, expectedPID: 42, expectedBounds: bounds, above: [], ring: ring), .clear)
    }

    func testFailsClosedWhenTheWindowIsGoneOrReused() {
        XCTAssertEqual(PointingGate.evaluate(target: nil, expectedPID: 42, expectedBounds: bounds, above: [], ring: ring), .gone)
        let reused = W(id: 10, pid: 77, bounds: bounds, layer: 0, alpha: 1)
        XCTAssertEqual(PointingGate.evaluate(target: reused, expectedPID: 42, expectedBounds: bounds, above: [], ring: ring), .gone)
    }

    func testAMovedWindowGetsNoRing() {
        let moved = W(id: 10, pid: 42, bounds: bounds.offsetBy(dx: 30, dy: 0), layer: 0, alpha: 1)
        XCTAssertEqual(PointingGate.evaluate(target: moved, expectedPID: 42, expectedBounds: bounds, above: [], ring: ring), .moved)
    }

    func testAWindowOverTheLineCoversIt() {
        let card = W(id: 55, pid: 1, bounds: CGRect(x: 400, y: 480, width: 360, height: 300), layer: 3, alpha: 1)
        XCTAssertEqual(PointingGate.evaluate(target: target, expectedPID: 42, expectedBounds: bounds, above: [card], ring: ring), .covered(by: 55))
        // Our own ring window is ignored, and so are system chrome, invisible windows and windows elsewhere.
        XCTAssertEqual(PointingGate.evaluate(target: target, expectedPID: 42, expectedBounds: bounds, above: [card], ring: ring, ignoring: [55]), .clear)
        let dock = W(id: 2, pid: 9, bounds: CGRect(x: 0, y: 0, width: 2000, height: 2000), layer: 20, alpha: 1)
        let invisible = W(id: 3, pid: 9, bounds: ring, layer: 0, alpha: 0)
        let elsewhere = W(id: 4, pid: 9, bounds: CGRect(x: 1000, y: 100, width: 200, height: 200), layer: 0, alpha: 1)
        XCTAssertEqual(PointingGate.evaluate(target: target, expectedPID: 42, expectedBounds: bounds, above: [dock, invisible, elsewhere], ring: ring), .clear)
    }
}
