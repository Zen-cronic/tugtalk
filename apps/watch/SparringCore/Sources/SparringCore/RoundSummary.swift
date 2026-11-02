import Foundation

/// The one number a finished round is summed up with. Both counts are the server's own measurements of two
/// answers (the first and the last); nothing here is estimated or scored on the watch.
///
/// The habit is picked the way the Mac picks it (apps/mac/Sources/ScreenContextCore/RoundSummary.swift): the one
/// that dropped the most from the first answer to the last, or, when none dropped, the one used most in the last.
public struct RoundSummary: Sendable, Equatable {
    public enum Habit: String, Sendable, CaseIterable {
        case filler, hedge, restart

        /// Plain words on screen: a hedge is an "unsure word" ("I think", "maybe"). The data key stays `hedge_count`.
        public func label(_ n: Int) -> String {
            switch self {
            case .filler: n == 1 ? "filler" : "fillers"
            case .hedge: n == 1 ? "unsure word" : "unsure words"
            case .restart: n == 1 ? "restart" : "restarts"
            }
        }
    }

    public let habit: Habit
    /// Nil with a single measured answer: there is nothing to compare it with.
    public let first: Int?
    public let last: Int
    /// Measured answers in the round.
    public let answers: Int

    public var dropped: Bool { first.map { last < $0 } ?? false }

    /// "1 filler", "2 unsure words".
    public static func count(_ n: Int, _ habit: Habit) -> String { "\(n) \(habit.label(n))" }

    /// Beside the big number: the habit, singular or plural. "0 unsure words".
    public var unit: String { habit.label(last) }

    /// Under it: which answer it counts, and the first answer's count of the same habit.
    public var comparison: String {
        guard let first else { return "In your answer" }
        if last < first { return "In your last answer, down from \(first) in your first" }
        if last > first { return "In your last answer, up from \(first) in your first" }
        return "In your last answer, the same as your first"
    }

    /// Where the numbers come from.
    public var source: String {
        answers == 1 ? "Counted by the server in 1 answer" : "Counted by the server in answers 1 and \(answers)"
    }

    public static func make(_ answers: [VoiceMetrics]) -> RoundSummary? {
        let measured = answers.filter { $0.filler_count != nil || $0.hedge_count != nil || $0.restart_count != nil }
        guard let first = measured.first, let last = measured.last else { return nil }
        func value(_ m: VoiceMetrics, _ h: Habit) -> Int? {
            switch h {
            case .filler: m.filler_count
            case .hedge: m.hedge_count
            case .restart: m.restart_count
            }
        }
        if measured.count == 1 {
            // One answer: report its most-used habit, fillers first on a tie. No comparison is made.
            let pairs = Habit.allCases.compactMap { h in value(last, h).map { (h, $0) } }
            guard let top = pairs.max(by: { $0.1 < $1.1 }) else { return nil } // the first of equal counts
            return RoundSummary(habit: top.0, first: nil, last: top.1, answers: 1)
        }
        let pairs = Habit.allCases.compactMap { h -> (Habit, Int, Int)? in
            guard let a = value(first, h), let b = value(last, h) else { return nil }
            return (h, a, b)
        }
        guard !pairs.isEmpty else { return nil }
        // Ties keep the first habit in the list (filler, then unsure word, then restart).
        let biggestDrop = pairs.reduce(pairs[0]) { ($1.1 - $1.2) > ($0.1 - $0.2) ? $1 : $0 }
        let pick = biggestDrop.1 > biggestDrop.2 ? biggestDrop : pairs.reduce(pairs[0]) { $1.2 > $0.2 ? $1 : $0 }
        return RoundSummary(habit: pick.0, first: pick.1, last: pick.2, answers: measured.count)
    }
}
