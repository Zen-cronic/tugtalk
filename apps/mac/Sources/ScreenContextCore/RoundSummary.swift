import Foundation

/// The one number a finished spoken round is summed up with: a habit count in the first answer and in the last.
///
/// Code picks it from the code-measured metrics of each answer in the round: the habit (fillers, hedges or
/// restarts) that dropped the most, or, when none dropped, the habit with the most uses in the last answer.
public struct RoundSummary: Sendable, Equatable {
    public enum Habit: String, Sendable, CaseIterable { case filler, hedge, restart }

    public let habit: Habit
    public let first: Int
    public let last: Int
    /// Answers in the round.
    public let answers: Int

    public var dropped: Bool { last < first }

    /// "2 fillers", "1 hedge".
    public static func count(_ n: Int, _ habit: Habit) -> String { "\(n) \(n == 1 ? habit.rawValue : habit.rawValue + "s")" }

    /// Nil with fewer than two measured answers: a change needs a before and an after.
    public static func make(_ answers: [VoiceMetrics]) -> RoundSummary? {
        let measured = answers.filter { $0.filler_count != nil || $0.hedge_count != nil || $0.restart_count != nil }
        guard measured.count >= 2, let first = measured.first, let last = measured.last else { return nil }
        func value(_ m: VoiceMetrics, _ h: Habit) -> Int? {
            switch h {
            case .filler: m.filler_count
            case .hedge: m.hedge_count
            case .restart: m.restart_count
            }
        }
        let pairs = Habit.allCases.compactMap { h -> (Habit, Int, Int)? in
            guard let a = value(first, h), let b = value(last, h) else { return nil }
            return (h, a, b)
        }
        guard !pairs.isEmpty else { return nil }
        let biggestDrop = pairs.max { ($0.1 - $0.2) < ($1.1 - $1.2) }!
        let pick = biggestDrop.1 > biggestDrop.2 ? biggestDrop : pairs.max { $0.2 < $1.2 }!
        return RoundSummary(habit: pick.0, first: pick.1, last: pick.2, answers: measured.count)
    }
}
