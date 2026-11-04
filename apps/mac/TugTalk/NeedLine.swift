import ScreenContextCore
import SwiftUI

/// The other person's need on a spoken-round card: "Need: a date" during the round, and at the wrap-up "Need: a date,
/// met on answer 2, unsure words 1 → 0". The caption says which part is whose: the need word is the model's; whether it
/// was met, and the counts, are code's. A code-only reply says so instead of naming a model.
struct NeedLine: View {
    let card: VoiceCard

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let line = card.needLine {
                VStack(alignment: .leading, spacing: 2) {
                    Text(line).font(TypeFace.body(13, weight: 650)).foregroundStyle(Color(Tok.ink))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(RoundNeed.source(endsRound: card.endsRound, model: card.modelLabel)).font(TypeFace.body(12, weight: 500)).foregroundStyle(Color(Tok.muted))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .help("The need is the word the model chose from your card. Whether an answer met it, and the unsure-word counts, are measured by code. The need stays on this Mac for the round and isn't saved.")
                .accessibilityElement(children: .combine)
            }
            if card.codeOnly {
                Text(RoundNeed.codeOnlyLine).font(TypeFace.body(12, weight: 600)).foregroundStyle(Color(Tok.muted)).lineLimit(1)
                    .accessibilityLabel("This question was written by code, with no model.")
            }
        }
    }
}
