import Foundation

/// What the other person needs from you in one spoken round, held on this Mac only.
///
/// The round's first reply names the need (`counterpart.need`: the model's word, from a fixed list). This Mac keeps it in
/// memory, sends it back with each later answer (`X-Counterpart-Need`), and drops it when the round ends. The server
/// never stores it. Whether an answer met it, and the hedge counts, are code-measured.
public struct RoundNeed: Sendable, Equatable {
    public static let needs = ["number", "date", "decision", "owner", "example"]

    /// The need to send with the next answer, or nil before the first reply named one.
    public private(set) var need: String?
    /// The first answer code measured as meeting the need.
    public private(set) var metOn: Int?
    public private(set) var answers = 0
    private var firstHedges: Int?
    private var lastHedges: Int?

    public init() {}

    /// One reply arrived. `answer` is its place in the round (1 starts a new round). Returns the card line: "Need: a date"
    /// during the round, and at the wrap-up "Need: a date, met on answer 2, unsure words 1 → 0", after which the need
    /// is dropped. Nil when no need was named.
    public mutating func record(_ counterpart: VoiceCounterpart?, hedges: Int?, answer: Int, endsRound: Bool) -> String? {
        if answer <= 1 { reset() }
        answers = answer
        if need == nil, let named = counterpart?.need, Self.needs.contains(named) { need = named }
        if firstHedges == nil { firstHedges = hedges }
        lastHedges = hedges ?? lastHedges
        if metOn == nil, counterpart?.need_met == true, need != nil { metOn = answer }
        guard let need else { if endsRound { reset() }; return nil }
        guard endsRound else { return "Need: \(Self.phrase(need))" }
        let line = Self.line(need: need, metOn: metOn, answers: answers, firstHedges: firstHedges, lastHedges: lastHedges)
        reset()
        return line
    }

    public mutating func reset() { need = nil; metOn = nil; answers = 0; firstHedges = nil; lastHedges = nil }

    /// "Need: a date, met on answer 2, unsure words 1 → 0". "Unsure words" are the code-counted hedges.
    public static func line(need: String, metOn: Int?, answers: Int, firstHedges: Int?, lastHedges: Int?) -> String {
        var parts = ["Need: \(phrase(need))"]
        if let metOn { parts.append("met on answer \(metOn)") }
        else { parts.append("not met in \(answers) \(answers == 1 ? "answer" : "answers")") }
        if let a = firstHedges, let b = lastHedges, answers > 1 { parts.append("unsure words \(a)\u{00A0}→\u{00A0}\(b)") }
        return parts.joined(separator: ", ")
    }

    /// "a date", "an owner".
    public static func phrase(_ need: String) -> String {
        ["owner", "example"].contains(need) ? "an \(need)" : "a \(need)"
    }

    /// The card's line for a reply that no model wrote.
    public static let codeOnlyLine = "Code-only question (no model)"

    /// Where the line's parts come from: during the round only the need is shown, and it is the model's pick; at the
    /// wrap-up, whether it was met and the counts are code's.
    public static func source(endsRound: Bool, model: String) -> String {
        endsRound ? "need picked by \(model), met and counts measured by code" : "picked by \(model) from your card"
    }
}
