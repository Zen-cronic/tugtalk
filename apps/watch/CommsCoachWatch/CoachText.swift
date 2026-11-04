import Foundation
import NaturalLanguage

/// Splits coach text for the wrist. Nothing is reworded: a lead is the coach's own opening words.
enum CoachText {
    /// Short words that end with a full stop without ending a sentence.
    static let abbreviations: Set<String> = ["e.g", "i.e", "etc", "vs", "dr", "mr", "mrs", "ms", "prof", "st", "approx", "no", "fig", "cf"]

    /// The observation's opening clause (up to the first comma, or the end of the first sentence) when it is
    /// short, and the rest of it. Sentences are found with `NLTokenizer`, so "2.5", "2,500", "e.g." and "Dr."
    /// do not end the lead. When the cut is doubtful, there is no lead: the screen shows the whole text instead.
    static func lead(of text: String, maxWords: Int) -> (lead: String, rest: String)? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        guard let sentence = tokenizer.tokens(for: text.startIndex..<text.endIndex).first else { return nil }

        // The first comma inside the sentence that ends a clause: followed by a space, not a digit group.
        var cut: String.Index?
        var i = sentence.lowerBound
        while i < sentence.upperBound {
            let next = text.index(after: i)
            if text[i] == ",", next < text.endIndex, text[next].isWhitespace { cut = i; break }
            i = next
        }
        let lead: Substring, rest: Substring
        if let cut {
            lead = text[..<cut]
            rest = text[text.index(after: cut)...]
        } else {
            // The end of the first sentence, which must end with a full stop, "!" or "?".
            let body = text[sentence].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let last = body.last, ".!?".contains(last) else { return nil }
            lead = Substring(body.dropLast())
            rest = text[sentence.upperBound...]
            // A next sentence that starts in lower case means the split was a guess.
            if let first = rest.first(where: { !$0.isWhitespace }), first.isLowercase { return nil }
        }
        let leadText = lead.trimmingCharacters(in: .whitespaces), restText = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        // Unsure: the lead ends on an abbreviation ("e.g.,"), or the cut sits inside a number.
        if let lastWord = leadText.split(separator: " ").last?.lowercased(),
           abbreviations.contains(String(lastWord.trimmingCharacters(in: CharacterSet(charactersIn: ".")))) { return nil }
        if let a = leadText.last, let b = restText.first, a.isNumber, b.isNumber { return nil }
        let words = leadText.split(separator: " ").count
        guard words >= 2, words <= maxWords, !restText.isEmpty else { return nil }
        return (leadText, restText.prefix(1).uppercased() + restText.dropFirst())
    }

    /// The observation shortened for the wrist, never reworded: its first sentence when that fits in
    /// `maxCharacters`, otherwise its first words up to a word break, with "…". `cut` is true when text was left out.
    static func short(_ text: String, maxCharacters: Int) -> (text: String, cut: Bool) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > maxCharacters else { return (text, false) }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        if let sentence = tokenizer.tokens(for: text.startIndex..<text.endIndex).first {
            let first = text[sentence].trimmingCharacters(in: .whitespacesAndNewlines)
            if first.count <= maxCharacters, let last = first.last, ".!?".contains(last) { return (first, true) }
        }
        var words = text.prefix(maxCharacters).split(separator: " ", omittingEmptySubsequences: true)
        if text[text.index(text.startIndex, offsetBy: maxCharacters)] != " ", words.count > 1 { words.removeLast() } // no half words
        let head = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-–—'\"("))
        return (head + "…", true)
    }

    /// The exercise's name (before any colon or bracket), or its first words when it has no name.
    static func headline(of text: String, maxWords: Int) -> String {
        let name = text.prefix { $0 != ":" && $0 != "(" && $0 != "." }.trimmingCharacters(in: .whitespaces)
        let words = name.split(separator: " ")
        if !words.isEmpty, words.count <= maxWords { return name }
        let all = text.split(separator: " ")
        return all.prefix(maxWords).joined(separator: " ") + (all.count > maxWords ? "…" : "")
    }

    #if DEBUG
    /// Cases the verdict line must get right; returns the failures. Debug builds run it with the
    /// `-coachTextCheck` launch argument and print the result. This file has no watch-only imports, so
    /// `swiftc -D DEBUG CoachText.swift main.swift` on a Mac checks it too, with a main.swift that prints it.
    static func selfCheck() -> [String] {
        let cases: [(String, String?)] = [
            ("You met the goal after restarting, stating the main point.", "You met the goal after restarting"),
            ("Your pace was 2.5 words a second. Slow the opening.", "Your pace was 2.5 words a second"),
            ("In 2,500 words you paused twice, both before the ask.", "In 2,500 words you paused twice"),
            ("Lead with one fact, e.g. the launch date, then the ask.", "Lead with one fact"),
            ("Say it like Dr. Lee did. Then stop.", "Say it like Dr. Lee did"),
            ("Use a hedge only once, e.g., at the end.", "Use a hedge only once"),
            ("Add a pause e.g., before the ask.", nil),
            ("Good.", nil),
            ("No punctuation in this observation at all", nil),
            ("This one sentence is far too long to fit as a lead on a small watch screen, so no lead.", nil),
        ]
        let shorts: [(String, String)] = [
            ("Clear and steady delivery throughout. This short test clip doesn't yet show the pause habit you set.",
             "Clear and steady delivery throughout."),
            ("Short note.", "Short note."),
            ("In 40 words at 166 wpm you had 2 fillers, 1 hedge, and 2 restarts including 'Sorry, let me restart'.",
             "In 40 words at 166 wpm you had 2 fillers, 1 hedge, and 2 restarts including…"),
        ]
        let shortFailures = shorts.compactMap { text, expected in
            let got = short(text, maxCharacters: 80).text
            return got == expected ? nil : "short: \(text) -> \(got), expected \(expected)"
        }
        return cases.compactMap { text, expected in
            let got = lead(of: text, maxWords: 7)?.lead
            return got == expected ? nil : "\(text) -> \(got ?? "nil"), expected \(expected ?? "nil")"
        } + shortFailures
    }
    #endif
}
