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
    static let labelNouns = ["ask", "deadline", "goal", "question", "request", "point", "date", "price", "plan", "decision"]

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

    /// The ring around a line: the line's box with room around the glyphs.
    public static func ringRect(around line: CGRect) -> CGRect {
        line.insetBy(dx: -max(8, line.height * 0.45), dy: -max(5, line.height * 0.35))
    }

    /// True when a window has moved or resized since it was captured (more than half a point).
    public static func hasMoved(from old: CGRect, to new: CGRect) -> Bool {
        abs(old.minX - new.minX) > 0.5 || abs(old.minY - new.minY) > 0.5 || abs(old.width - new.width) > 0.5 || abs(old.height - new.height) > 0.5
    }
}
