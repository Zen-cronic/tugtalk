import AVFoundation
import Foundation
import SparringCore

/// One spoken practice round on the wrist. `SparringMachine` (SparringCore) decides each step; this performs it:
/// the microphone, the upload to `POST /v1/voice-rounds`, and speaking the question, with the coach's
/// Wit.ai voice for English and the watch's own voice for French or when the coach voice fails.
/// The rounds are saved on the coach server, in the same record the Mac and Muse read.
@MainActor
final class SparringModel: ObservableObject {
    @Published private(set) var phase: SparringMachine.Phase
    let goalTitle: String?
    let recorder = Recorder()
    private var machine: SparringMachine
    private let client: RoundClient?
    private let speaker = RoundSpeaker()
    /// Finished recordings by idempotency key, kept until the server has replied (so Retry can resend them).
    private var files: [String: URL] = [:]
    /// The answer uploading now. Its value is the server's receipt, or nil when the upload failed.
    private var uploadTask: Task<VoiceRoundReceipt?, Never>?
    private var speechTask: Task<Void, Never>?
    /// The last round end sent to the server (`POST /v1/voice-rounds/end`). The next answer waits for it.
    private var endTask: Task<Void, Never>?

    /// `latestCard`: the account's newest screen card from the overview. With the goal's own card it decides which card,
    /// if any, the round is about (`ScreenCard.pick`), so the round's first reply picks the other person's need from it.
    init(goal: GoalSummary?, latestCard: ScreenCard? = nil, language: String) {
        goalTitle = goal?.title
        var language = language
        #if DEBUG
        // `-sparringLanguage fr`: a French round without opening Setup, for simulator runs.
        if let forced = UserDefaults.standard.string(forKey: "sparringLanguage") { language = forced }
        #endif
        let card = ScreenCard.pick(goalCard: goal?.latest_screen_context, latest: latestCard, goalID: goal?.id, now: Date())
        machine = SparringMachine(goalID: goal?.id, language: VoiceLanguage(rawValue: language) ?? .en, screenContextID: card)
        if let api = try? CoachAPI.fromBundle() {
            client = RoundClient(requests: RoundRequests(baseURL: api.baseURL, token: api.token))
        } else {
            client = nil
        }
        phase = machine.phase
        if client == nil { phase = .failed(answer: 1, failure: .notSignedIn, upload: nil) }
        // At the cap the recorder stops itself; the answer goes up exactly as a Stop tap would send it. A call or Siri
        // that cuts the recording short counts as a Stop tap, so a near-empty answer is not sent.
        recorder.onAutoStop = { [weak self] _, capped in
            guard let self else { return }
            self.apply(self.machine.stop(at: Date(), capped: capped))
        }
    }

    var language: VoiceLanguage { machine.language }
    /// At least one answer got its reply in this round.
    var answeredAny: Bool { machine.answered > 0 }

    // Actions

    func record() async {
        guard client != nil else { return }
        if case .recording = machine.phase { return }
        if fixture == nil, !(await recorder.requestPermission()) {
            apply(machine.refuse(.micOff))
            return
        }
        apply(machine.record(at: Date()))
    }

    func stop() { apply(machine.stop(at: Date())) }
    func retry() { apply(machine.retry()) }
    func seeResult() { apply(machine.skipToResult()) }
    func endRound() { apply(machine.endRound()) }

    /// The screen closed: nothing keeps recording or speaking, and no recording is left behind. A round the server
    /// still holds open is ended there, so the next round, on any device, starts at answer 1. An answer still
    /// uploading is not cancelled (the server may save it); once it is saved, one round end follows it.
    func leave() {
        let left: String? = if case .thinking(_, let upload) = machine.phase { upload.idempotencyKey } else { nil }
        apply(machine.leave())
        _ = recorder.stop()
        speaker.stop()
        speechTask?.cancel()
        if let left, let client, let upload = uploadTask {
            let after = machine // this screen's round only: nothing is kept for the next screen
            Task {
                var machine = after
                let receipt = await upload.value
                for case .endRoundOnServer(let key) in machine.leftUploadFinished(key: left, receipt) {
                    _ = try? await client.endRound(idempotencyKey: key)
                }
            }
        } else {
            uploadTask?.cancel()
        }
        for url in files.values { try? FileManager.default.removeItem(at: url) }
        files = [:]
        #if DEBUG
        driver?.cancel()
        #endif
    }

    // Effects

    private func apply(_ effects: [SparringMachine.Effect]) {
        for effect in effects { perform(effect) }
        phase = machine.phase
    }

    private func perform(_ effect: SparringMachine.Effect) {
        switch effect {
        case .startRecording(let key):
            do {
                #if DEBUG
                if case .recording(let answer, _) = machine.phase, let list = fixture, !list.isEmpty {
                    files[key] = try recorder.startFixture(list[min(answer, list.count) - 1]); return
                }
                #endif
                files[key] = try recorder.start()
            } catch {
                apply(machine.recordingFailed(RoundFailure(kind: .micOff, message: "Mic didn't start.")))
            }
        case .stopRecording(let key):
            if let url = recorder.stop() { files[key] = url }
        case .upload(let upload):
            send(upload)
        case .discard(let key):
            if let url = files.removeValue(forKey: key) { try? FileManager.default.removeItem(at: url) } // audio is not kept on the watch
        case .fetchSpeech(let roundID):
            fetchSpeech(roundID)
        case .speakOnDevice(let text, let language):
            guard case .replying(let shown) = machine.phase else { return }
            let roundID = shown.roundID
            speaker.say(text, language: language) { [weak self] in
                guard let self else { return }
                self.apply(self.machine.speechFinished(roundID: roundID, at: Date()))
            }
        case .stopSpeech:
            speechTask?.cancel()
            speaker.stop()
        case .endRoundOnServer(let key):
            endRound(key)
        }
    }

    private func send(_ upload: AnswerUpload) {
        guard let client, let file = files[upload.idempotencyKey] else {
            apply(machine.uploadFailed(key: upload.idempotencyKey, RoundFailure(kind: .tooShort, message: "Recording not saved.")))
            return
        }
        let ending = endTask
        uploadTask = Task { [weak self] in
            // A round end on its way goes first, so the server counts this answer as answer 1 of the new round.
            await ending?.value
            do {
                let wav = try Data(contentsOf: file)
                let receipt = try await client.send(upload, wav: wav)
                self?.apply(self?.machine.replied(key: upload.idempotencyKey, receipt) ?? [])
                return receipt
            } catch is CancellationError {
                return nil
            } catch {
                self?.apply(self?.machine.uploadFailed(key: upload.idempotencyKey, RoundFailure.from(error)) ?? [])
                return nil
            }
        }
    }

    /// Ends the round on the server, after any end already on its way. Unconfirmed, the machine sends it again with the
    /// same key before the next round's first answer.
    private func endRound(_ key: String) {
        guard let client else { return }
        let previous = endTask
        endTask = Task { [weak self] in
            await previous?.value
            guard (try? await client.endRound(idempotencyKey: key)) != nil else { return }
            self?.machine.roundEndSent(key: key)
        }
    }

    /// The coach voice gets this long to arrive before the watch voice says the question instead.
    static let speechWait: Duration = .seconds(6)

    private func fetchSpeech(_ roundID: String) {
        guard let client else { return }
        Task { [weak self] in
            try? await Task.sleep(for: Self.speechWait)
            guard let self, case .replying(let shown) = self.machine.phase, shown.roundID == roundID, shown.voice == nil else { return }
            self.speechTask?.cancel()
            self.apply(self.machine.speechFailed(roundID: roundID, reason: "the coach voice took over 6 s"))
        }
        speechTask = Task { [weak self] in
            do {
                let clip = try await client.speech(roundID: roundID)
                guard let self, !Task.isCancelled else { return }
                try self.speaker.play(clip.data) { [weak self] in
                    guard let self else { return }
                    self.apply(self.machine.speechFinished(roundID: roundID, at: Date()))
                }
                self.apply(self.machine.speechStarted(roundID: roundID, provider: clip.provider))
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.apply(self.machine.speechFailed(roundID: roundID, reason: SpeechFailure.reason(for: error)))
            }
        }
    }

    // Debug fixtures

    /// DEBUG `-sparringFixtureWAV a.wav,b.wav,c.wav`: answer n uses the n-th file (the last one repeats).
    private var fixture: [URL]? {
        #if DEBUG
        guard let raw = UserDefaults.standard.string(forKey: "sparringFixtureWAV"), !raw.isEmpty else { return nil }
        return raw.split(separator: ",").map { URL(fileURLWithPath: String($0)) }
        #else
        return nil
        #endif
    }

    #if DEBUG
    private var driver: Task<Void, Never>?

    /// DEBUG `-sparringAutoplay YES`: plays the whole round without taps, for simulator captures. Each answer
    /// records for `-sparringHoldSeconds` (default 3), and waits `-sparringPauseSeconds` (default 3) on
    /// "Your turn" before the next. It calls the same actions the buttons call.
    func autoplayIfAsked() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "sparringAutoplay"), driver == nil else { return }
        let hold = defaults.double(forKey: "sparringHoldSeconds").nonZero ?? 3
        let pause = defaults.double(forKey: "sparringPauseSeconds").nonZero ?? 3
        driver = Task { [weak self] in
            try? await Task.sleep(for: .seconds(pause))
            let retryAfter = defaults.double(forKey: "sparringAutoRetrySeconds")
            var retried = false
            while let self, !Task.isCancelled {
                // `-sparringAutoRetrySeconds N`: taps Retry once, N seconds after the first failure that offers it.
                if case .failed(_, _, .some) = self.phase, retryAfter > 0, !retried {
                    retried = true
                    try? await Task.sleep(for: .seconds(retryAfter))
                    self.retry()
                    continue
                }
                if case .failed = self.phase { return }
                if case .done = self.phase { return }
                let ready: Bool = if case .ready = self.phase { true } else { false }
                if ready || self.isYourTurn {
                    await self.record()
                    try? await Task.sleep(for: .seconds(hold))
                    self.stop()
                } else {
                    try? await Task.sleep(for: .milliseconds(200))
                    if self.isYourTurn { try? await Task.sleep(for: .seconds(pause)) }
                }
            }
        }
    }
    #endif

    var isYourTurn: Bool {
        if case .replying(let shown) = phase { return shown.spoken && !shown.endsRound }
        return false
    }
}

private extension Double {
    var nonZero: Double? { self > 0 ? self : nil }
}

/// Plays the coach's MP3 through the watch speaker, or says the question with the watch's own voice.
/// Only the newest line reports that it finished; `stop()` silences both at once.
@MainActor
final class RoundSpeaker: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    private var player: AVAudioPlayer?
    private let synthesizer = AVSpeechSynthesizer()
    private var finished: (() -> Void)?
    private var utterance: AVSpeechUtterance?

    /// DEBUG `-sparringVolume 0.1` keeps simulator runs quiet; otherwise full volume.
    private var volume: Float {
        #if DEBUG
        if UserDefaults.standard.object(forKey: "sparringVolume") != nil { return max(0, min(1, UserDefaults.standard.float(forKey: "sparringVolume"))) }
        #endif
        return 1
    }

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Short spoken audio on the default route plays from the watch's own speaker (long-form audio would need headphones).
    private func activate() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, policy: .default)
        try? session.setActive(true)
    }

    func play(_ data: Data, finished: @escaping () -> Void) throws {
        stop()
        activate()
        let player = try AVAudioPlayer(data: data)
        player.delegate = self
        player.volume = volume
        guard player.play() else { throw SpeechFailure(status: 200, code: "unplayable") }
        self.player = player
        self.finished = finished
    }

    func say(_ text: String, language: VoiceLanguage, finished: @escaping () -> Void) {
        stop()
        activate()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language == .fr ? "fr-FR" : "en-US")
        utterance.volume = volume
        self.finished = finished
        self.utterance = utterance
        synthesizer.speak(utterance)
    }

    func stop() {
        finished = nil
        utterance = nil
        player?.stop(); player = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }

    private func done() {
        let call = finished
        finished = nil
        player = nil
        utterance = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        call?()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        Task { @MainActor in if let current = self.player, ObjectIdentifier(current) == id { self.done() } }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let id = ObjectIdentifier(player)
        Task { @MainActor in if let current = self.player, ObjectIdentifier(current) == id { self.done() } }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in if let current = self.utterance, ObjectIdentifier(current) == id { self.done() } }
    }
}
