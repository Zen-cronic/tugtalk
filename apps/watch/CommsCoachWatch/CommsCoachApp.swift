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
    private(set) var isPreview = false
    private(set) var scrollToObservation = false
    private(set) var scrollToActions = false
    private(set) var scrollToTry = false

    init() {
        // At the cap the recorder stops itself; the capture goes to upload exactly as a Stop tap would.
        recorder.onAutoStop = { [weak self] file in
            guard let self else { return }
            if self.capture(file) { Task { await self.upload() } }
        }
    }

    func load() async {
        #if DEBUG
        // Debug builds only: show the result screen with fixed sample data, without recording or uploading.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-coachTextCheck") {
            let failures = CoachText.selfCheck()
            print(failures.isEmpty ? "coach text check: all cases pass" : "coach text check failed:\n" + failures.joined(separator: "\n"))
        }
        if arguments.contains("-previewResult") {
            isPreview = true
            scrollToObservation = arguments.contains("-scrollToObservation")
            scrollToActions = arguments.contains("-scrollToActions") // the result's buttons, at the end of the screen
            scrollToTry = arguments.contains("-scrollToTry") // the short exercise line and its More button
            // `-previewObservation "<text>"` swaps in another observation, to check the verdict line on the wrist.
            phase = .done(.preview(observation: UserDefaults.standard.string(forKey: "previewObservation")))
            return
        }
        #endif
        phase = .loading
        do {
            goals = try await CoachAPI.fromBundle().goals()
            if selectedGoal == nil { selectedGoal = goals.first }
            phase = .ready
        } catch {
            phase = .failed(Self.plain(error))
        }
        #if DEBUG
        // Debug builds only: start one recording without a tap, for simulator checks of the cap.
        // `-stopAfterSeconds N` then calls the Stop button's action N seconds later (before, at or after the cap).
        if case .ready = phase, ProcessInfo.processInfo.arguments.contains("-recordOnLaunch") {
            await startRecording()
            let stopAfter = UserDefaults.standard.double(forKey: "stopAfterSeconds")
            if stopAfter > 0 {
                try? await Task.sleep(for: .seconds(stopAfter))
                await stopAndUpload()
            }
        }
        #endif
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
        if let file = recorder.stop() {
            if capture(file) { await upload() }
        } else if case .recording = phase {
            // The recorder is gone but the screen still says Recording: never leave Stop doing nothing.
            if pending != nil { await upload() } else { phase = .failed("The recording stopped before it was saved. Record again.") }
        }
    }

    /// Keeps a finished recording as the pending capture, with its idempotency key fixed now.
    /// Synchronous on the main actor, so a Stop tap and an auto-stop can never both claim the file.
    /// Returns false when this recording was already handed over.
    @discardableResult
    func capture(_ file: URL) -> Bool {
        guard case .recording = phase else { return false }
        pending = PendingCapture(file: file, key: "watch-\(UUID().uuidString)", goalID: selectedGoal?.id,
                                 language: language, occurredAt: recorder.startedAt)
        phase = .uploading
        return true
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
            phase = .failed(Self.plain(error)) // file and key kept; Retry resends the same request
        }
    }

    var canRetryUpload: Bool { pending != nil }

    /// Network failures in plain words; any other error keeps its own message.
    static func plain(_ error: Error) -> String {
        let offline: [URLError.Code] = [.notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
                                        .cannotFindHost, .dnsLookupFailed, .timedOut, .dataNotAllowed, .internationalRoamingOff]
        if let error = error as? URLError, offline.contains(error.code) { return "Lost connection." }
        return error.localizedDescription
    }
}
