import CoreGraphics
import Foundation

/// Picks the one line of a captured window that a context card is about, in code.
///
/// The model never chooses coordinates. It writes the card from redacted text; this matcher
/// compares the card's words with the lines Vision read on this Mac and returns the index of
/// the best line, or nil when no line is a clear match. A wrong ring is worse than none.
public enum LineMatcher {
    public struct Match: Sendable, Equatable {
        public let index: Int
        /// A short label drawn beside the ring.
        public let label: String
        /// The card words found on that line (lowercased), or the quote that matched.
        public let evidence: [String]
    }

    /// A line needs this score to be pointed at: two distinct words from the card's observation or next step.
    public static let minimumScore = 4

    /// `quotes` come first: text the card puts in quotation marks that also appears on a line.
    /// Otherwise each line scores 2 per distinct content word it shares with the observation or the
    /// next step, plus 1 per word shared only with the summary. A tie for first place returns nil.
    public static func bestLine(in lines: [TextLine], summary: String, observation: String, nextStep: String) -> Match? {
        let usable = lines.enumerated().filter { $0.element.box.width > 0 && $0.element.box.height > 0 }
        guard !usable.isEmpty else { return nil }

        // 1. A quoted span from the card, found on exactly one line.
        let quotes = [observation, nextStep, summary].flatMap(quotedSpans).sorted { $0.count > $1.count }
        for quote in quotes {
            let needle = normalized(quote)
            guard needle.split(separator: " ").count >= 1, needle.count >= 3 else { continue }
            let hits = usable.filter { normalized($0.element.text).contains(needle) }
            if hits.count == 1 {
                return Match(index: hits[0].offset, label: label(for: tokens(needle)), evidence: [needle])
            }
        }

        // 2. Shared content words.
        let strong = Set(tokens(observation) + tokens(nextStep))
        let weak = Set(tokens(summary)).subtracting(strong)
        let scored = usable.map { item -> (Int, Int, [String]) in
            let words = Set(tokens(item.element.text))
            let hitsStrong = words.intersection(strong), hitsWeak = words.intersection(weak)
            return (item.offset, hitsStrong.count * 2 + hitsWeak.count, hitsStrong.sorted())
        }.sorted { $0.1 > $1.1 }
        guard let best = scored.first, best.1 >= minimumScore, best.2.count >= 2 else { return nil }
        if scored.count > 1, scored[1].1 == best.1 { return nil }
        return Match(index: best.0, label: label(for: best.2), evidence: best.2)
    }

    /// Nouns that make a better label than "This line" when the card and the line share them.
    static let labelNouns = ["ask", "deadline", "question", "request", "point", "date", "price", "plan", "decision"]

    static func label(for words: [String]) -> String {
        for noun in labelNouns where words.contains(noun) { return "The \(noun) is here" }
        return "This line"
    }

    /// Text inside straight or curly double quotes.
    static func quotedSpans(_ text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"["“”]([^"“”]{3,120})["“”]"#) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    /// Lowercased, punctuation as spaces, single spaces.
    static func normalized(_ text: String) -> String {
        let mapped = text.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "'" ? Character($0) : " " }
        return String(mapped).split(separator: " ").joined(separator: " ")
    }

    static let stopwords: Set<String> = [
        "the", "and", "for", "you", "your", "you're", "are", "was", "were", "this", "that", "with", "from", "into", "out", "about",
        "have", "has", "had", "will", "would", "could", "should", "can", "not", "but", "its", "it's", "they", "them", "their",
        "then", "than", "there", "here", "what", "when", "where", "which", "who", "how", "why", "all", "any", "one", "two",
        "say", "said", "says", "once", "twice", "now", "right", "just", "more", "most", "very", "too", "also", "only",
        "loud", "sentence", "line", "window", "note", "text", "card", "stub", "maybe", "own", "like", "make", "get",
        // Words the coach uses about the card itself, not about the window's content.
        "goal", "selected", "linked", "practice", "practise", "habit", "next", "step",
    ]

    /// Content words: three letters or more, not a stopword, not a redaction placeholder, with a plural "s" dropped.
    static func tokens(_ text: String) -> [String] {
        let cleaned = text.replacingOccurrences(of: #"\[[a-z]+\]"#, with: " ", options: .regularExpression)
        return normalized(cleaned).split(separator: " ").map(String.init).compactMap { word in
            guard word.count >= 3, !stopwords.contains(word), word.rangeOfCharacter(from: .letters) != nil else { return nil }
            return word.count > 4 && word.hasSuffix("s") && !word.hasSuffix("ss") ? String(word.dropLast()) : word
        }
    }
}

/// Maps a Vision box on a captured window to screen points, for drawing over that window.
public enum ScreenMapping {
    /// Vision's normalized box (origin bottom left of the image) to global display points with the origin
    /// at the top left of the main display, given the window's frame in the same top-left convention.
    /// The image covers the frame exactly, so the image's pixel size (and the display's scale) drops out.
    public static func globalTopLeftRect(normalized box: CGRect, windowFrame frame: CGRect) -> CGRect {
        CGRect(x: frame.minX + box.minX * frame.width,
               y: frame.minY + (1 - box.maxY) * frame.height,
               width: box.width * frame.width,
               height: box.height * frame.height)
    }

    /// Core Graphics global coordinates (top left of the main display, y down) to AppKit screen
    /// coordinates (bottom left of the main display, y up). `mainDisplayHeight` is the height of the
    /// display whose frame origin is zero: `NSScreen.screens[0].frame.height`.
    public static func appKitRect(fromGlobalTopLeft rect: CGRect, mainDisplayHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: mainDisplayHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Rounds a rectangle outwards to whole device pixels, so a 2 pt ring stays crisp at any scale.
    public static func pixelAligned(_ rect: CGRect, scale: CGFloat) -> CGRect {
        guard scale > 0 else { return rect }
        let minX = (rect.minX * scale).rounded(.down) / scale, minY = (rect.minY * scale).rounded(.down) / scale
        let maxX = (rect.maxX * scale).rounded(.up) / scale, maxY = (rect.maxY * scale).rounded(.up) / scale
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The ring around a line: the line's box with 9 pt of room on every side. When `window` is given, the
    /// ring is kept at least 16 pt inside its edges, so it never sits on the window's frame.
    public static func ringRect(around line: CGRect, inside window: CGRect? = nil) -> CGRect {
        let ring = line.insetBy(dx: -9, dy: -9)
        guard let window else { return ring }
        let room = window.insetBy(dx: 16, dy: 16)
        guard room.width > 0, room.height > 0 else { return ring }
        let clipped = ring.intersection(room)
        return clipped.isNull || clipped.isEmpty ? ring : clipped
    }

    /// True when a window has moved or resized since it was captured (more than half a point).
    public static func hasMoved(from old: CGRect, to new: CGRect) -> Bool {
        abs(old.minX - new.minX) > 0.5 || abs(old.minY - new.minY) > 0.5 || abs(old.width - new.width) > 0.5 || abs(old.height - new.height) > 0.5
    }
}

/// Decides, right before each draw and on every check after, whether a ring may be shown: the captured
/// window must still be the same window (same owner, same bounds), and no other window may cover the ring.
/// It fails closed: a window it cannot read means no ring. It reads only window numbers, owners, layers
/// and bounds, which need no permission; titles are never read.
public enum PointingGate {
    public struct WindowRecord: Sendable, Equatable {
        public let id: UInt32
        public let pid: Int32
        public let bounds: CGRect
        public let layer: Int
        public let alpha: Double
        public init(id: UInt32, pid: Int32, bounds: CGRect, layer: Int, alpha: Double) {
            self.id = id; self.pid = pid; self.bounds = bounds; self.layer = layer; self.alpha = alpha
        }
    }

    public enum Verdict: Equatable, Sendable {
        case clear
        /// The window is gone, or its number now belongs to another app.
        case gone
        case moved
        /// Another window covers the ring.
        case covered(by: UInt32)
    }

    /// Windows at these layers and above are system chrome (the Dock, the menu bar, status items); they
    /// sit at the screen's edges and do not count as covering a line of the window.
    public static let chromeLayer = 20

    /// `target` is the window record read now by its number; `above` are the on-screen windows above it,
    /// front to back. `ignoring` holds our own ring window. All rectangles are global, top-left points.
    public static func evaluate(target: WindowRecord?, expectedPID: Int32, expectedBounds: CGRect,
                                above: [WindowRecord], ring: CGRect, ignoring: Set<UInt32> = []) -> Verdict {
        guard let target, target.pid == expectedPID else { return .gone }
        if ScreenMapping.hasMoved(from: expectedBounds, to: target.bounds) { return .moved }
        for window in above where !ignoring.contains(window.id) && window.id != target.id {
            guard window.layer >= 0, window.layer < chromeLayer, window.alpha > 0.01 else { continue }
            if window.bounds.intersects(ring) { return .covered(by: window.id) }
        }
        return .clear
    }
}

/// Moving our own floating card off a ring, for the time the ring shows. AppKit coordinates (y up).
public enum CardAvoidance {
    /// The vertical shift that clears `avoid`: up first, else down, keeping the card inside `visible`.
    /// Zero when they do not overlap; nil when no shift on this display clears it, so the ring is skipped
    /// rather than drawn under our card.
    public static func verticalShift(card: CGRect, avoid: CGRect, visible: CGRect) -> CGFloat? {
        guard card.intersects(avoid) else { return 0 }
        let up = avoid.maxY - card.minY
        if card.maxY + up <= visible.maxY { return up }
        let down = card.maxY - avoid.minY
        if card.minY - down >= visible.minY { return -down }
        return nil
    }
}
