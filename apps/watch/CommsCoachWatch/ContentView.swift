import SwiftUI

struct ContentView: View {
    @StateObject private var model = CaptureModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) { content }
                    .frame(maxWidth: .infinity)
            }
            .navigationTitle("Coach")
        }
        .task { await model.load() }
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
            Text(timeString(model.recorder.elapsed)).font(.title2.monospacedDigit())
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

    private func result(_ receipt: CaptureReceipt) -> some View {
        let m = receipt.record.metrics
        return VStack(alignment: .leading, spacing: 6) {
            Text("Saved").font(.headline)
            Grid(alignment: .leading) {
                GridRow { Text("Fillers"); Text("\(m.filler_count)").bold() }
                GridRow { Text("Hedges"); Text("\(m.hedge_count)").bold() }
                GridRow { Text("Restarts"); Text("\(m.restart_count)").bold() }
                GridRow { Text("Pace"); Text(m.words_per_minute.map { "\($0) wpm" } ?? "–").bold() }
            }
            .font(.footnote)
            if let observation = receipt.record.analysis.observation {
                Text(observation).font(.footnote)
            }
            if let exercise = receipt.record.analysis.suggested_exercise {
                Text("Try: \(exercise)").font(.footnote).foregroundStyle(.secondary)
            }
            Text("Also in Muse on your phone and Mac.").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }
}
