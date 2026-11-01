import SwiftUI

@main
struct CommsCoachApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

/// A finished recording waiting to upload. The idempotency key is fixed at capture
/// time so every retry of the same file is the same request to the backend.
struct PendingCapture {
    let file: URL
    let key: String
    let goalID: String?
    let language: String
    let occurredAt: Date
}

@MainActor
final class CaptureModel: ObservableObject {
    enum Phase { case loading, ready, recording, uploading, done(CaptureReceipt), failed(String) }

    @Published var phase: Phase = .loading
    @Published var goals: [GoalSummary] = []
    @Published var selectedGoal: GoalSummary?
    @Published var language = "en"
    let recorder = Recorder()
    private var pending: PendingCapture?

    func load() async {
        phase = .loading
        do {
            goals = try await CoachAPI.fromBundle().goals()
            if selectedGoal == nil { selectedGoal = goals.first }
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func startRecording() async {
        guard await recorder.requestPermission() else { phase = .failed("Microphone access is off. Enable it in Settings."); return }
        do {
            _ = try recorder.start()
            phase = .recording
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func stopAndUpload() async {
        guard let file = recorder.stop() else { return }
        pending = PendingCapture(file: file, key: "watch-\(UUID().uuidString)", goalID: selectedGoal?.id,
                                 language: language, occurredAt: recorder.startedAt)
        await upload()
    }

    func upload() async {
        guard let pending else { return }
        phase = .uploading
        do {
            let receipt = try await CoachAPI.fromBundle().upload(file: pending.file, idempotencyKey: pending.key, goalID: pending.goalID,
                                                                 language: pending.language, occurredAt: pending.occurredAt)
            try? FileManager.default.removeItem(at: pending.file) // audio is not kept on the watch either
            self.pending = nil
            phase = .done(receipt)
        } catch {
            phase = .failed(error.localizedDescription) // file and key kept; Retry resends the same request
        }
    }

    var canRetryUpload: Bool { pending != nil }
}
