import SwiftUI

struct ContentView: View {
    @StateObject private var model = CaptureModel()

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 8) { content }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 6) // keeps cards clear of the screen's rounded corners
                }
                .task {
                    await model.load()
                    if model.scrollToObservation || model.scrollToActions {
                        try? await Task.sleep(for: .milliseconds(400)) // let the result lay out first
                        proxy.scrollTo(model.scrollToActions ? "actions" : "observation", anchor: .bottom)
                    }
                }
            }
            .navigationTitle(model.isPreview ? "Preview" : "Coach")
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let t = Int(seconds)
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView { Text("Loading goals").face(.text, 15) }
                .tint(Palette.inkDark)
                .foregroundStyle(Palette.inkDark)
        case .ready:
            setup
            Button { Task { await model.startRecording() } } label: {
                Label { Text("Record") } icon: { RecordLamp(lit: false) }
            }
            .buttonStyle(CoachButtonStyle())
        case .recording:
            recording
            Button { Task { await model.stopAndUpload() } } label: {
                Label { Text("Stop") } icon: { RoundedRectangle(cornerRadius: 2).frame(width: 12, height: 12) }
            }
            .buttonStyle(CoachButtonStyle())
            Text(model.selectedGoal?.title ?? "No goal")
                .face(.text, 14, relativeTo: .footnote)
                .foregroundStyle(Palette.mutedDark)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
        case .uploading:
            VStack(spacing: 6) {
                TugWorking(size: 50)
                    .padding(.bottom, 6)
                Text("Analyzing").face(.display, 20, relativeTo: .title3)
                    .foregroundStyle(Palette.inkDark)
                Text("Meta transcription and coaching")
                    .face(.text, 14, weight: 500, relativeTo: .footnote)
                    .foregroundStyle(Palette.mutedDark)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 8)
        case .done(let receipt):
            result(receipt)
            Button { Task { await model.startRecording() } } label: {
                Label { Text("Record again") } icon: { RecordLamp(lit: false) }
            }
            .buttonStyle(CoachButtonStyle())
            Button("Change goal") { model.phase = .ready }
                .buttonStyle(CoachButtonStyle(primary: false))
                .id("actions")
        case .failed(let message):
            failure(message)
            if model.canRetryUpload {
                Button("Retry upload") { Task { await model.upload() } }
                    .buttonStyle(CoachButtonStyle())
                Text("Your recording is still on the watch.")
                    .face(.text, 13, weight: 500, relativeTo: .caption)
                    .foregroundStyle(Palette.mutedDark)
                    .multilineTextAlignment(.center)
            }
            Button("Reload") { Task { await model.load() } }
                .buttonStyle(CoachButtonStyle(primary: !model.canRetryUpload))
        }
    }

    private var setup: some View {
        VStack(spacing: 6) {
            ChoiceRow(label: "Goal", value: model.selectedGoal?.title ?? "No goal",
                      options: [ChoiceOption(id: "", title: "No goal")] + model.goals.map { ChoiceOption(id: $0.id, title: $0.title) },
                      selected: model.selectedGoal?.id ?? "") { id in
                model.selectedGoal = model.goals.first { $0.id == id }
            }
            ChoiceRow(label: "Language", value: model.language == "fr" ? "Français" : "English",
                      options: [ChoiceOption(id: "en", title: "English"), ChoiceOption(id: "fr", title: "Français")],
                      selected: model.language) { id in
                model.language = id
            }
        }
    }

    /// The recording card: the light is on, the clock runs, and the cap is stated up front.
    private var recording: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                RecordLamp(lit: true)
                Text("Recording").face(.text, 15, weight: 700, relativeTo: .headline)
            }
            .foregroundStyle(Palette.inkDark)
            ElapsedLabel(recorder: model.recorder)
            Text("Stops at \(Self.clock(Recorder.maxSeconds))")
                .face(.text, 13, weight: 500, relativeTo: .caption)
                .foregroundStyle(Palette.mutedDark)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Palette.rack, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// One hero number, then the two other habits and pace, then the coach's words.
    /// The hero is always fillers so the screen reads the same way after every capture.
    private func result(_ receipt: CaptureReceipt) -> some View {
        let m = receipt.record.metrics
        let analysis = receipt.record.analysis
        return VStack(alignment: .leading, spacing: 8) {
            CartChip(fill: Palette.filler, edge: Palette.fillerEdge, radius: 16, edgeHeight: 5) {
                HStack(alignment: .center, spacing: 6) {
                    Text("\(m.filler_count)")
                        .face(.display, 48, relativeTo: .largeTitle)
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(m.filler_count == 1 ? "filler" : "fillers").face(.text, 18, weight: 700, relativeTo: .headline)
                        Text("in \(m.word_count) words").face(.text, 14, weight: 500, relativeTo: .footnote)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 2)
            }
            .accessibilityElement(children: .combine)
            .slotIn()

            HStack(spacing: 6) {
                SmallMetric(value: m.hedge_count, singular: "hedge", plural: "hedges", fill: Palette.hedge, edge: Palette.hedgeEdge)
                SmallMetric(value: m.restart_count, singular: "restart", plural: "restarts", fill: Palette.restart, edge: Palette.restartEdge)
                PaceMetric(wpm: m.words_per_minute)
            }
            .slotIn()

            VStack(alignment: .leading, spacing: 10) {
                if let observation = analysis.observation {
                    Text(observation)
                        .face(.text, 15, relativeTo: .body)
                        .foregroundStyle(Palette.inkDark)
                } else {
                    Text("No observation this time; the counts are saved.")
                        .face(.text, 15, relativeTo: .body)
                        .foregroundStyle(Palette.mutedDark)
                }
                if let exercise = analysis.suggested_exercise {
                    // An instruction is a quote with a rule on the left, never a filled block that looks like a button.
                    HStack(alignment: .top, spacing: 8) {
                        Capsule().fill(Palette.inkDark).frame(width: 3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Try").face(.display, 15, relativeTo: .headline)
                            Text(exercise).face(.text, 15, weight: 500, relativeTo: .body)
                        }
                        .foregroundStyle(Palette.inkDark)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
                }
                HStack(alignment: .center, spacing: 4) {
                    TugGlyph(size: 28, reach: 8, endY: 0.6, pull: 1)
                    Text("Also in Muse on your phone and Mac.")
                        .face(.text, 13, weight: 500, relativeTo: .caption)
                        .foregroundStyle(Palette.mutedDark)
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .id("observation")
        }
    }

    /// Tug with a cut string and the error itself. What is still safe sits under Retry upload.
    private func failure(_ message: String) -> some View {
        VStack(spacing: 6) {
            TugGlyph(size: 32, reach: 14, cut: true)
            Text(message)
                .face(.text, 15, relativeTo: .body)
                .foregroundStyle(Palette.inkDark)
                .multilineTextAlignment(.center)
        }
        .padding(.bottom, 2)
    }
}

private struct SmallMetric: View {
    let value: Int
    let singular: String
    let plural: String
    let fill: Color
    let edge: Color

    var body: some View {
        CartChip(fill: fill, edge: edge) {
            VStack(spacing: 0) {
                Text("\(value)").face(.display, 22, relativeTo: .title3).monospacedDigit()
                Text(value == 1 ? singular : plural).face(.text, 12, weight: 700, relativeTo: .caption2)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Pace is context, not a habit: neutral ink, no chip, and narrower than the habit chips.
private struct PaceMetric: View {
    let wpm: Int?

    var body: some View {
        VStack(spacing: 0) {
            Text(wpm.map(String.init) ?? "–").face(.text, 18, weight: 700, relativeTo: .headline).monospacedDigit()
                .foregroundStyle(Palette.pace)
            Text("wpm").face(.text, 12, weight: 500, relativeTo: .caption2)
                .foregroundStyle(Palette.mutedDark)
        }
        .frame(width: 38)
        .accessibilityElement(children: .combine)
    }
}

/// The recording light. Unlit it is a ring; lit it fills and breathes. With Reduce Motion it stays on, still.
private struct RecordLamp: View {
    let lit: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        ZStack {
            Circle().strokeBorder(lit ? Palette.recordDot : Palette.ink, lineWidth: 2) // unlit, it sits on an ink-dark button
            if lit { Circle().fill(Palette.recordDot).padding(2).opacity(dim ? 0.45 : 1) }
        }
        .frame(width: 13, height: 13)
        .onAppear {
            guard lit, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever()) { dim = true }
        }
        .accessibilityHidden(true)
    }
}

struct ChoiceOption: Identifiable, Hashable {
    let id: String
    let title: String
}

/// A setup choice on the sunflower field. Opens a plain list; picking an option comes straight back.
private struct ChoiceRow: View {
    let label: String
    let value: String
    let options: [ChoiceOption]
    let selected: String
    let choose: (String) -> Void

    var body: some View {
        NavigationLink {
            ChoiceList(title: label, options: options, selected: selected, choose: choose)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).face(.text, 13, weight: 600, relativeTo: .caption)
                    .foregroundStyle(Palette.muted)
                Text(value).face(.text, 16, weight: 700, relativeTo: .headline)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Palette.field, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityValue(value)
    }
}

private struct ChoiceList: View {
    let title: String
    let options: [ChoiceOption]
    let selected: String
    let choose: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(options) { option in
            Button {
                choose(option.id)
                dismiss()
            } label: {
                HStack {
                    Text(option.title).face(.text, 16, relativeTo: .body)
                    Spacer(minLength: 4)
                    if option.id == selected { Image(systemName: "checkmark").foregroundStyle(Palette.field) }
                }
            }
            .accessibilityAddTraits(option.id == selected ? .isSelected : [])
        }
        .navigationTitle(title)
    }
}

/// Observes the recorder itself: a nested ObservableObject's changes do not
/// propagate through CaptureModel, so reading it from ContentView never redraws.
private struct ElapsedLabel: View {
    @ObservedObject var recorder: Recorder

    var body: some View {
        Text(ContentView.clock(recorder.elapsed))
            .face(.display, 34, relativeTo: .title)
            .monospacedDigit()
            .foregroundStyle(Palette.inkDark)
            .contentTransition(.numericText())
    }
}
