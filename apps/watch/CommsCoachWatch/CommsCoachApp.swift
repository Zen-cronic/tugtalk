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
    /// The open drill when the recording started; the server measures this capture against its basis.
    var exerciseID: String? = nil
}

@MainActor
final class CaptureModel: ObservableObject {
    enum Phase { case loading, ready, recording, uploading, done(CaptureReceipt), failed(String) }

    @Published var phase: Phase = .loading
    @Published var goals: [GoalSummary] = []
    @Published var selectedGoal: GoalSummary? {
        didSet { if oldValue?.id != selectedGoal?.id, !isLoading { Task { await refreshDrill() } } }
    }
    /// The open drill Muse set for the selected goal (Drill.swift), or nil.
    @Published var drill: Drill?
    @Published var language = "en"
    /// Keep my recordings, as the coach server has it. Nil until read.
    @Published var settings: CoachSettings?
    @Published var settingsNote: String?
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
            phase = .done(.preview(observation: UserDefaults.standard.string(forKey: "previewObservation"), kept: arguments.contains("-previewRecordingKept")))
            return
        }
        #endif
        phase = .loading
        do {
            let api = try CoachAPI.fromBundle()
            async let setting = try? api.settings() // a failed read leaves the row saying it is checking
            goals = try await api.goals()
            settings = await setting
            settingsNote = settings == nil ? "Not available on this coach yet." : nil
            if selectedGoal == nil { selectedGoal = goals.first }
            await refreshDrill()
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
                                 language: language, occurredAt: recorder.startedAt,
                                 exerciseID: drill.flatMap { $0.goal_id == selectedGoal?.id ? $0.id : nil })
        phase = .uploading
        return true
    }

    func upload() async {
        guard let pending else { return }
        phase = .uploading
        do {
            let receipt = try await CoachAPI.fromBundle().upload(file: pending.file, idempotencyKey: pending.key, goalID: pending.goalID,
                                                                 language: pending.language, occurredAt: pending.occurredAt, exerciseID: pending.exerciseID)
            try? FileManager.default.removeItem(at: pending.file) // audio is not kept on the watch either
            self.pending = nil
            if receipt.record.drill?.status == "measured" { drill = nil } // this capture closed the drill
            phase = .done(receipt)
        } catch {
            phase = .failed(Self.plain(error)) // file and key kept; Retry resends the same request
        }
    }

    var canRetryUpload: Bool { pending != nil }

    private var isLoading: Bool { if case .loading = phase { return true } else { return false } }

    /// Reads the selected goal's open drill. A failed read hides the drill line; it never blocks recording.
    func refreshDrill() async {
        guard let goalID = selectedGoal?.id else { drill = nil; return }
        let found = try? await CoachAPI.fromBundle().openDrill(goalID: goalID)
        if selectedGoal?.id == goalID { drill = found }
    }

    /// Turns Keep my recordings on or off on the server; on a conflict or failure it reads the setting again.
    func setKeepRecordings(_ keep: Bool, deleteKept: Bool = false) async {
        guard let current = settings else { return }
        do {
            let api = try CoachAPI.fromBundle()
            settings = try await api.setKeepRecordings(keep, deleteKept: deleteKept, expectedVersion: current.version)
            settingsNote = deleteKept ? "Kept recordings deleted." : nil
        } catch {
            settingsNote = Self.plain(error)
            settings = try? await CoachAPI.fromBundle().settings()
        }
    }

    /// Network failures in plain words; any other error keeps its own message.
    static func plain(_ error: Error) -> String {
        let offline: [URLError.Code] = [.notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
                                        .cannotFindHost, .dnsLookupFailed, .timedOut, .dataNotAllowed, .internationalRoamingOff]
        if let error = error as? URLError, offline.contains(error.code) { return "Lost connection." }
        return error.localizedDescription
    }
}
