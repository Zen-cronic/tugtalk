import SparringCore
import SwiftUI

/// "Practise this answer": up to four spoken answers, each followed by the other person's question.
/// Tap Record, answer out loud, tap Stop. Tug thinks, then asks; you answer again.
struct SparringView: View {
    @StateObject private var model: SparringModel
    @State private var scrolled = false

    init(goal: GoalSummary?, latestCard: ScreenCard? = nil, language: String) {
        _model = StateObject(wrappedValue: SparringModel(goal: goal, latestCard: latestCard, language: language))
    }

    var body: some View {
        VStack(spacing: 4) {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 8) { content }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 6) // keeps cards clear of the screen's rounded corners
            }
            .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > 4 } action: { _, now in
                scrolled = now
            }
            .overlay(alignment: .top) { HeaderFade(active: scrolled) }
            .onChange(of: model.phase.name) { _, name in
                #if DEBUG
                // `-sparringScrollToEnd YES`: shows the end of each step, for simulator captures.
                // `-sparringScrollTo source`: centres that part of each step instead (here, Round done's source line).
                if let anchor = UserDefaults.standard.string(forKey: "sparringScrollTo") {
                    Task { try? await Task.sleep(for: .milliseconds(300)); proxy.scrollTo(anchor, anchor: .center) }
                    return
                }
                if UserDefaults.standard.bool(forKey: "sparringScrollToEnd") {
                    Task { try? await Task.sleep(for: .milliseconds(300)); withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
                    return
                }
                #endif
                // Each new step starts at the top, so the question or the number shows first. On "Your turn" the
                // question moves to the top. The jump is not animated, so no scroll is still moving when a button is tapped.
                if name == "your turn" { proxy.scrollTo("question", anchor: .top) } else { proxy.scrollTo("top", anchor: .top) }
            }
        }
            // Stop, and Record on a question, sit below the scroll view, never inside it: on the real watch (build 9)
            // both did nothing when tapped inside it, right after the step changed and the content scrolled.
            pinnedAction
                .padding(.horizontal, 6)
        }
        .navigationTitle("Practise")
        .task {
            #if DEBUG
            model.autoplayIfAsked()
            #endif
        }
        .onDisappear { model.leave() }
    }

    @ViewBuilder private var content: some View {
        Color.clear.frame(height: 0).id("top")
        switch model.phase {
        case .ready(let answer):
            ready(answer)
        case .recording(let answer, _):
            recording(answer)
        case .thinking(let answer, _):
            thinking(answer)
        case .replying(let shown):
            replying(shown)
        case .failed(let answer, let failure, let upload):
            failed(answer, failure, canRetry: upload != nil)
        case .done(let summary, let lastQuestion, let note, let closedBy):
            done(summary, lastQuestion: lastQuestion, note: note, closedBy: closedBy)
        }
        Color.clear.frame(height: 0).id("end")
    }

    private func counter(_ answer: Int) -> String { "Answer \(answer)" }

    /// The step's main button, outside the scroll view: Stop while recording, Record on a question.
    @ViewBuilder private var pinnedAction: some View {
        switch model.phase {
        case .recording:
            Button { model.stop() } label: {
                Label { Text("Stop") } icon: { RoundedRectangle(cornerRadius: 2).frame(width: 12, height: 12) }
            }
            .buttonStyle(CoachButtonStyle())
            .handGestureShortcut(.primaryAction) // double tap, on watches that have it: a second way to stop
        case .replying(let shown) where !shown.endsRound:
            recordButton(shown.spoken ? "Record" : "Answer now")
                .handGestureShortcut(.primaryAction)
        default:
            EmptyView()
        }
    }

    // Your turn, before the first answer

    private func ready(_ answer: Int) -> some View {
        Group {
            StatusRow(title: "Your turn", detail: counter(answer)) { TugGlyph(size: 30, reach: 6, endY: 0.66) }
            VStack(alignment: .leading, spacing: 4) {
                Text("Answer out loud, up to \(SparringMachine.maxAnswers) times.")
                    .face(.text, 15, relativeTo: .body)
                    .foregroundStyle(Palette.inkDark)
                    .fixedSize(horizontal: false, vertical: true)
                if let goal = model.goalTitle {
                    Text("Goal: \(goal)")
                        .face(.text, 13, weight: 600, relativeTo: .caption)
                        .foregroundStyle(Palette.mutedDark)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            recordButton("Record")
        }
    }

    // Recording

    private func recording(_ answer: Int) -> some View {
        Group {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    RecordLamp(lit: true)
                    Text("Recording").face(.text, 15, weight: 700, relativeTo: .headline)
                }
                HStack(alignment: .center, spacing: 4) {
                    ElapsedLabel(recorder: model.recorder)
                        .lineLimit(1)
                        .fixedSize()
                    Spacer(minLength: 0)
                    TugListening(size: 34, reach: 4)
                }
            }
            .foregroundStyle(Palette.inkDark)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Palette.rack, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Recording. \(counter(answer)).")
            Text(counter(answer))
                .face(.text, 13, weight: 600, relativeTo: .caption)
                .foregroundStyle(Palette.mutedDark)
        }
    }

    // Thinking

    private func thinking(_ answer: Int) -> some View {
        VStack(spacing: 6) {
            TugWorking(size: 50, face: .thinking)
                .padding(.bottom, 4)
            Text("Thinking").face(.display, 20, relativeTo: .title3)
                .foregroundStyle(Palette.inkDark)
            Text("Picking a follow-up")
                .face(.text, 14, weight: 500, relativeTo: .footnote)
                .foregroundStyle(Palette.mutedDark)
                .multilineTextAlignment(.center)
            ProgressDots()
                .padding(.top, 2)
            Text(counter(answer))
                .face(.text, 13, weight: 600, relativeTo: .caption)
                .foregroundStyle(Palette.mutedDark)
        }
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
    }

    // The question

    private func replying(_ shown: SparringMachine.Shown) -> some View {
        Group {
            StatusRow(title: shown.spoken ? "Your turn" : "Speaking", detail: counter(shown.answer)) {
                TugSpeaking(size: 30, talking: !shown.spoken, reach: 6)
            }
            Text(shown.question)
                .face(.text, 16, weight: 700, relativeTo: .headline)
                .foregroundStyle(Palette.inkDark)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
                .accessibilityLabel("Question: \(shown.question)")
                .id("question")
                .slotIn()
            if shown.endsRound {
                Button("See result") { model.seeResult() }
                    .buttonStyle(CoachButtonStyle())
            }
            if let quote = shown.quote { QuoteCard(quote: quote).slotIn() }
            VStack(alignment: .leading, spacing: 2) {
                if let label = shown.voice?.label {
                    Text(label)
                        .face(.text, 12, weight: 600, relativeTo: .caption2)
                        .foregroundStyle(Palette.mutedDark)
                }
                if let note = shown.mediaNote {
                    Text(note)
                        .face(.text, 12, weight: 600, relativeTo: .caption2)
                        .foregroundStyle(Palette.mutedDark)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            if !shown.endsRound {
                Button("End round") { model.endRound() }
                    .buttonStyle(CoachButtonStyle(.secondary))
            }
        }
    }

    // Round done

    /// Why the round ended, in code's terms (the server's move gate), or nil when the coach wrapped up on its own.
    private func ending(_ closedBy: String?) -> String? {
        switch closedBy {
        case "measured_close": "Ended by code: no unsure words in your last answer."
        case "answer_cap": "Ended at answer \(SparringMachine.maxAnswers), the limit."
        default: nil
        }
    }

    private func done(_ summary: RoundSummary?, lastQuestion: String?, note: String?, closedBy: String?) -> some View {
        Group {
            StatusRow(title: "Round done", detail: nil) { TugGlyph(size: 30, reach: 6, endY: 0.66, pull: 1) }
            if let summary {
                let tint = HabitTint(summary.habit)
                VStack(alignment: .leading, spacing: 4) {
                    CartChip(fill: tint.fill, edge: tint.edge, radius: 16, edgeHeight: 5) {
                        HStack(alignment: .center, spacing: 6) {
                            Text("\(summary.last)")
                                .face(.display, 44, relativeTo: .largeTitle)
                                .monospacedDigit()
                                .minimumScaleFactor(0.6)
                                .lineLimit(1)
                            Text(summary.unit)
                                .face(.text, 14, weight: 700, relativeTo: .footnote)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, -2)
                    }
                    .slotIn()
                    Text(summary.comparison)
                        .face(.text, 15, weight: 700, relativeTo: .body)
                        .foregroundStyle(Palette.inkDark)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                    if let ending = ending(closedBy) {
                        Text(ending)
                            .fixedSize(horizontal: false, vertical: true)
                            .id("source")
                            .face(.text, 12, weight: 600, relativeTo: .caption2)
                            .foregroundStyle(Palette.mutedDark)
                            .padding(.horizontal, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            } else {
                Text("No answers measured.")
                    .face(.text, 15, relativeTo: .body)
                    .foregroundStyle(Palette.mutedDark)
            }
            recordButton("Record again")
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 4) {
                    TugGlyph(size: 28, reach: 8, endY: 0.6, pull: 1)
                    Text("Also in Muse on your phone and Mac.")
                        .face(.text, 13, weight: 600, relativeTo: .caption)
                        .foregroundStyle(Palette.inkDark)
                }
                if let note {
                    Text(note)
                        .face(.text, 13, weight: 600, relativeTo: .caption)
                        .foregroundStyle(Palette.mutedDark)
                }
                if let lastQuestion {
                    HStack(alignment: .top, spacing: 8) {
                        Capsule().fill(Palette.inkDark).frame(width: 3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Last question").face(.text, 13, weight: 700, relativeTo: .caption)
                            Text(lastQuestion).face(.text, 14, weight: 500, relativeTo: .footnote)
                        }
                        .foregroundStyle(Palette.inkDark)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
    }

    // Errors

    private func failed(_ answer: Int, _ failure: RoundFailure, canRetry: Bool) -> some View {
        Group {
            VStack(spacing: 4) {
                TugGlyph(size: 32, reach: 14, cut: failure.kind == .offline, worried: true)
                Text(failure.message)
                    .face(.text, 15, relativeTo: .body)
                    .foregroundStyle(Palette.inkDark)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if canRetry {
                    Text("Answer saved on the watch.")
                        .face(.text, 13, weight: 600, relativeTo: .caption)
                        .foregroundStyle(Palette.mutedDark)
                        .multilineTextAlignment(.center)
                }
            }
            if canRetry {
                Button("Try again") { model.retry() }
                    .buttonStyle(CoachButtonStyle())
            } else if failure.kind == .micOff || failure.kind == .tooShort || failure.kind == .unusableAudio || failure.kind == .noQuestion {
                recordButton("Try again")
            }
            if failure.kind != .notSignedIn {
                Button(model.answeredAny ? "End round" : "Back to start") { model.endRound() }
                    .buttonStyle(CoachButtonStyle(.secondary))
            }
            Text(counter(answer))
                .face(.text, 13, weight: 600, relativeTo: .caption)
                .foregroundStyle(Palette.mutedDark)
        }
    }

    private func recordButton(_ title: String) -> some View {
        Button { Task { await model.record() } } label: {
            Label { Text(title) } icon: { RecordLamp(lit: false) }
        }
        .buttonStyle(CoachButtonStyle())
        .id("record")
    }
}

/// Tug at the left, a plain-word status and the answer count beside it.
private struct StatusRow<Mascot: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let mascot: Mascot

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            mascot
            VStack(alignment: .leading, spacing: 0) {
                Text(title).face(.display, 17, relativeTo: .headline)
                    .foregroundStyle(Palette.inkDark)
                    .minimumScaleFactor(0.7)
                if let detail {
                    Text(detail).face(.text, 13, weight: 600, relativeTo: .caption)
                        .foregroundStyle(Palette.mutedDark)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Your own words, quoted back in the transcript face, with an ink rule on the left. Shown only when code on
/// the server found them word for word in what you said.
private struct QuoteCard: View {
    let quote: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Capsule().fill(Palette.inkDark).frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text("You said").face(.text, 12, weight: 700, relativeTo: .caption2)
                    .foregroundStyle(Palette.mutedDark)
                Text("\u{201C}\(quote)\u{201D}").face(.mono, 13, relativeTo: .footnote)
                    .foregroundStyle(Palette.inkDark)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }
}

/// The metric token for the round's habit: the same fill and edge as on the result screen.
private struct HabitTint {
    let fill: Color
    let edge: Color

    init(_ habit: RoundSummary.Habit) {
        switch habit {
        case .filler: fill = Palette.filler; edge = Palette.fillerEdge
        case .hedge: fill = Palette.hedge; edge = Palette.hedgeEdge
        case .restart: fill = Palette.restart; edge = Palette.restartEdge
        }
    }
}
