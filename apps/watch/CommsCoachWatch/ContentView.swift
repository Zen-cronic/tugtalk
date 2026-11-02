import SwiftUI

struct ContentView: View {
    @StateObject private var model = CaptureModel()

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 10) { content }
                        .frame(maxWidth: .infinity)
                }
                .task {
                    await model.load()
                    if model.scrollToObservation {
                        try? await Task.sleep(for: .milliseconds(400)) // let the result lay out first
                        proxy.scrollTo("observation", anchor: .bottom)
                    }
                }
            }
            .navigationTitle(model.isPreview ? "Preview" : "Coach")
            .navigationBarTitleDisplayMode(showingResult ? .inline : .automatic) // the hero number is the headline
        }
    }

    private var showingResult: Bool {
        if case .done = model.phase { return true }
        return false
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView("Loading goals")
        case .ready:
            setup
            Button { Task { await model.startRecording() } } label: {
                Label("Record", systemImage: "mic.fill").frame(maxWidth: .infinity)
            }
            .tint(.red)
        case .recording:
            ElapsedLabel(recorder: model.recorder)
            Text(model.selectedGoal?.title ?? "No goal").font(.footnote).foregroundStyle(.secondary)
            Button { Task { await model.stopAndUpload() } } label: {
                Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
            }
        case .uploading:
            ProgressView("Analyzing")
            Text("Meta transcription and coaching").font(.footnote).foregroundStyle(.secondary)
        case .done(let receipt):
            result(receipt)
            Button("New capture") { model.phase = .ready }
        case .failed(let message):
            Text(message).font(.footnote).multilineTextAlignment(.center)
            if model.canRetryUpload {
                Button("Retry upload") { Task { await model.upload() } }
            }
            Button("Reload") { Task { await model.load() } }
        }
    }

    private var setup: some View {
        VStack(spacing: 6) {
            Picker("Goal", selection: $model.selectedGoal) {
                Text("No goal").tag(GoalSummary?.none)
                ForEach(model.goals) { goal in Text(goal.title).tag(GoalSummary?.some(goal)) }
            }
            Picker("Language", selection: $model.language) {
                Text("English").tag("en")
                Text("Français").tag("fr")
            }
        }
        .pickerStyle(.navigationLink)
    }

    /// One hero number, three secondary numbers, then the model's words.
    /// The hero is always fillers so the screen reads the same way after every capture.
    private func result(_ receipt: CaptureReceipt) -> some View {
        let m = receipt.record.metrics
        let analysis = receipt.record.analysis
        return VStack(spacing: 6) {
            VStack(spacing: 0) {
                Text("\(m.filler_count)")
                    .font(.system(size: 64, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Palette.filler)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(.vertical, -8) // trim the font's line padding so the secondary row stays above the fold
                Text(m.filler_count == 1 ? "FILLER" : "FILLERS")
                    .font(.caption2.weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(Palette.filler)
                Text("in \(m.word_count) words")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)

            HStack(spacing: 4) {
                SmallMetric(value: "\(m.hedge_count)", label: "hedges", color: Palette.hedge)
                SmallMetric(value: "\(m.restart_count)", label: "restarts", color: Palette.restart)
                SmallMetric(value: m.words_per_minute.map(String.init) ?? "–", label: "wpm", color: .white)
            }

            VStack(alignment: .leading, spacing: 6) {
                if let observation = analysis.observation {
                    Text(observation).font(.footnote)
                } else {
                    Text("No observation this time; the counts are saved.").font(.footnote).foregroundStyle(.secondary)
                }
                if let exercise = analysis.suggested_exercise {
                    Text("Try: \(exercise)").font(.footnote).foregroundStyle(.secondary)
                }
                Text("Also in Muse on your phone and Mac.").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .id("observation")
        }
    }

}

/// Habit colours shared with the landing page (site/styles.css).
enum Palette {
    static let filler = Color(red: 1.0, green: 0.835, blue: 0.290)   // #FFD54A
    static let hedge = Color(red: 0.663, green: 0.824, blue: 1.0)    // #A9D2FF
    static let restart = Color(red: 1.0, green: 0.690, blue: 0.769)  // #FFB0C4
}

private struct SmallMetric: View {
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 0) {
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// Observes the recorder itself: a nested ObservableObject's changes do not
/// propagate through CaptureModel, so reading it from ContentView never redraws.
private struct ElapsedLabel: View {
    @ObservedObject var recorder: Recorder

    var body: some View {
        let t = Int(recorder.elapsed)
        Text(String(format: "%d:%02d", t / 60, t % 60))
            .font(.title2.monospacedDigit())
            .contentTransition(.numericText())
    }
}
