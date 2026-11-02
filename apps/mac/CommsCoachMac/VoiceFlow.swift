import AppKit
import Combine
import OSLog
import ScreenContextCore

/// Records timings and status codes for each hold. Never audio, transcripts, questions or the key.
let voiceLog = Logger(subsystem: "com.kaungzinhein.commscoach.mac", category: "voice")

/// Hold ⌃⌥T to talk: the microphone opens on press and closes on release, the clip goes to
/// `POST /v1/voice-rounds`, and the whole reply is spoken once it has arrived. Pressing ⌃⌥T while
/// it speaks stops it at once and starts a new hold. `VoiceTurnMachine` decides; this performs.
@MainActor
final class VoiceFlow {
    private let model: CompanionModel
    private var machine = VoiceTurnMachine()
    /// The coach server's voice by default, Apple's voice on this Mac as the fallback.
    private let speech: SpeechRouter
    private let store = VoiceClipStore()
    private var recorder: MicRecorder?
    /// DEBUG `-voiceFixtureWAV <path>`: this file stands in for the microphone, so no permission is needed.
    private let fixture: URL?
    private var holdStarted: Date?
    /// The hold's start, sent as `X-Occurred-At`. Kept per key so a Retry sends the same value.
    private var occurredAt: (key: String, at: Date)?
    private var releasedAt: Date?
    private var bargeInAt: Date?
    private var card: VoiceCard?
    private var capTask: Task<Void, Never>?
    private var uploadTask: Task<Void, Never>?
    private var phaseWatch: AnyCancellable?
    /// The answers of the spoken round so far, counted on this Mac since the last wrap-up.
    private var roundAnswers = 0
    private var roundMetrics: [VoiceMetrics] = []

    var afterSave: () -> Void = {}

    init(model: CompanionModel) {
        self.model = model
        #if DEBUG
        fixture = UserDefaults.standard.string(forKey: "voiceFixtureWAV").map { URL(fileURLWithPath: $0) }
        #else
        fixture = nil
        #endif
        #if DEBUG
        // `-voiceSpeaker apple` skips the coach voice, for testing the fallback on purpose.
        let appleOnly = UserDefaults.standard.string(forKey: "voiceSpeaker") == "apple"
        #else
        let appleOnly = false
        #endif
        speech = SpeechRouter(remote: appleOnly ? nil : RemoteSpeaker(api: { Connection.api()?.api }), fallback: AppleSpeaker())
        let swept = store.sweep()
        if swept > 0 { voiceLog.notice("deleted \(swept, privacy: .public) recording(s) left from an earlier run") }
        // Another state took over the bubble (a screen capture, say): stop speaking and drop a kept clip.
        phaseWatch = model.$phase.sink { [weak self] phase in
            guard !phase.isVoice else { return }
            DispatchQueue.main.async { self?.leftVoice() }
        }
    }

    var usesFixture: Bool { fixture != nil }

    // Hotkey

    func keyDown() {
        let speaking: Bool = if case .speaking = machine.phase { true } else { false }
        // A screen capture in progress keeps the companion busy.
        if !speaking, case .listening = model.phase { return }
        if !speaking, case .thinking = model.phase { return }
        if fixture == nil {
            switch MicPermission.status {
            case .granted: break
            case .undetermined: if speaking { speech.stop(); _ = machine.dismiss() }; model.set(.micPermission(denied: false)); return
            case .denied: if speaking { speech.stop(); _ = machine.dismiss() }; model.set(.micPermission(denied: true)); return
            }
        }
        guard Connection.api() != nil else {
            model.set(.voiceError(Connection.unavailableReason, retryable: false))
            return
        }
        perform(machine.keyDown(at: Date()))
    }

    func keyUp() { perform(machine.keyUp(at: Date())) }

    func retry() { perform(machine.retry(at: Date())) }

    /// A hold that can no longer end with a release (the docked panel closed under Talk): nothing is sent.
    func cancelHold() {
        guard case .listening = machine.phase else { return }
        voiceLog.notice("hold cancelled before release; nothing sent")
        perform(machine.cancelHold())
        model.set(.notice("Not sent. Hold Talk until you finish."), collapseAfter: 3)
    }

    /// The bubble was closed, by its button or a click on the character.
    func dismissed() { perform(machine.dismiss()) }

    private func leftVoice() {
        switch machine.phase {
        case .speaking, .failed, .listening: perform(machine.dismiss())
        default: break
        }
    }

    // Effects

    private func perform(_ effects: [VoiceTurnMachine.Effect]) {
        for effect in effects {
            switch effect {
            case .stopSpeaking:
                bargeInAt = Date()
                speech.stop()
                markCardFinished()
                voiceLog.notice("speech stopped in \(Self.ms(since: self.bargeInAt), privacy: .public) ms")
            case .startRecording(let key):
                startRecording(key)
            case .upload(let key, let promptEndedAt):
                upload(key, promptEndedAt: promptEndedAt)
            case .discard(let key):
                if let recorder { _ = recorder.stop(); self.recorder = nil }
                capTask?.cancel()
                store.remove(key)
            case .speak(let question):
                speak(question)
            case .tooShort:
                model.set(.notice("Hold ⌃⌥T while you talk, then let go."), collapseAfter: 3)
            }
        }
    }

    private func startRecording(_ key: String) {
        holdStarted = Date()
        occurredAt = (key, holdStarted!)
        if fixture == nil {
            let recorder = MicRecorder()
            do {
                try recorder.start()
                self.recorder = recorder
            } catch {
                _ = recorder.stop()
                _ = machine.dismiss()
                store.remove(key)
                voiceLog.error("the microphone did not start")
                model.set(.voiceError("The microphone could not start. Check the input in System Settings › Sound.", retryable: false))
                return
            }
        }
        voiceLog.notice("hold started\(self.fixture == nil ? "" : " (fixture WAV, microphone not used)", privacy: .public)")
        model.set(.voiceListening(since: holdStarted ?? Date()))
        capTask?.cancel()
        capTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(WAV.maxSeconds))
            guard !Task.isCancelled, let self else { return }
            voiceLog.notice("hold reached the 60 s cap")
            self.perform(self.machine.keyUp(at: Date(), capped: true))
        }
    }

    private func upload(_ key: String, promptEndedAt: Date?) {
        capTask?.cancel()
        let released = Date()
        releasedAt = released
        // The microphone closes at once, and "Thinking" shows before any encoding: the release must
        // feel instant (about 100 ms). The clip is prepared on the next turn of the run loop.
        let live = recorder?.stop()
        recorder = nil
        model.set(.voiceThinking(since: released))
        voiceLog.notice("thinking shown \(Self.ms(since: released), privacy: .public) ms after release")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            self?.send(key, promptEndedAt: promptEndedAt, live: live)
        }
    }

    private func send(_ key: String, promptEndedAt: Date?, live: [Int16]?) {
        guard case .thinking = machine.phase else { return }
        let wav: Data
        if store.exists(key), let kept = try? store.read(key) {
            wav = kept
        } else {
            let samples: [Int16]
            if let fixture {
                samples = (try? PCMResampler.convertFile(at: fixture)) ?? []
            } else {
                samples = live ?? []
            }
            let held = holdStarted.map { releasedAt!.timeIntervalSince($0) } ?? 0
            voiceLog.notice("hold released after \(String(format: "%.2f", held), privacy: .public) s; \(String(format: "%.2f", Double(samples.count) / Double(WAV.sampleRate)), privacy: .public) s of audio; microphone closed")
            guard samples.count >= WAV.sampleRate / 4 else {
                fail(key, message: "Nothing was recorded. Check the microphone input.", retryable: false)
                return
            }
            wav = WAV.encode(samples)
            do { try store.write(wav, for: key) } catch {
                fail(key, message: "The recording could not be prepared.", retryable: false)
                return
            }
        }
        guard let api = Connection.api()?.api else {
            fail(key, message: Connection.unavailableReason, retryable: false)
            return
        }
        let round = VoiceRoundRequest(wav: wav, idempotencyKey: key, goalID: Settings.goalID, screenContextID: model.lastCard?.recordID,
                                      language: Settings.voiceLanguage, promptEndedAt: promptEndedAt,
                                      occurredAt: occurredAt?.key == key ? occurredAt?.at : nil)
        voiceLog.notice("sending \(wav.count, privacy: .public) bytes; prompt end \(promptEndedAt == nil ? "not sent" : "sent", privacy: .public)")
        uploadTask = Task { [weak self] in
            do {
                let receipt = try await VoiceRoundUploader(api: api).send(round) { attempt in
                    if attempt > 1 { voiceLog.notice("retry \(attempt, privacy: .public) with the same idempotency key") }
                }
                self?.replied(receipt, key: key)
            } catch is CancellationError {
                return
            } catch let error as CoachError {
                self?.fail(key, message: Self.message(for: error), retryable: VoiceRoundUploader.isRetryable(error))
            } catch {
                self?.fail(key, message: "The reply could not be read.", retryable: true)
            }
        }
    }

    private func replied(_ receipt: VoiceRoundReceipt, key: String) {
        let ms = Self.ms(since: releasedAt)
        voiceLog.notice("reply in \(ms, privacy: .public) ms after release (server total \(receipt.latency_ms?.total.map { String(Int($0)) } ?? "n/a", privacy: .public) ms, replayed \(receipt.replayed, privacy: .public))")
        let effects = machine.replyReady(key: key, question: receipt.reply.question, endsRound: receipt.reply.kind == .wrap_up)
        guard !effects.isEmpty else { return }  // an older hold's reply
        var next = VoiceCard(receipt)
        roundAnswers += 1
        if let m = receipt.metrics { roundMetrics.append(m) }
        next.round = roundAnswers
        if next.endsRound {
            next.summary = RoundSummary.make(roundMetrics)
            roundAnswers = 0
            roundMetrics = []
        }
        card = next
        if case .failed = machine.phase {
            perform(effects)
            model.set(.voiceError("The reply had no question to speak.", retryable: false))
            return
        }
        perform(effects)
        afterSave()
    }

    private func fail(_ key: String, message: String, retryable: Bool) {
        if case .thinking = machine.phase {
            perform(machine.uploadFailed(key: key, retryable: retryable))
        } else {
            _ = machine.dismiss()
            store.remove(key)
        }
        voiceLog.notice("hold not sent (retryable \(retryable, privacy: .public))")
        model.set(.voiceError(message, retryable: retryable))
    }

    private func speak(_ question: String) {
        guard let card else { return }
        model.set(.voiceSpeaking(card))
        speech.speak(SpokenLine(text: question, language: Settings.voiceLanguage, roundID: card.roundID),
                     started: { [weak self] source in self?.speechStarted(source) },
                     finished: { [weak self] ended in self?.speechFinished(at: ended) })
    }

    private func speechStarted(_ source: SpeechSource) {
        guard var card, let releasedAt else { return }
        card.releaseToVoice = Date().timeIntervalSince(releasedAt)
        card.voice = source
        self.card = card
        voiceLog.notice("first word \(Self.ms(since: releasedAt), privacy: .public) ms after release (\(source.label, privacy: .public))")
        if case .voiceSpeaking = model.phase { model.set(.voiceSpeaking(card)) }
    }

    private func speechFinished(at ended: Date) {
        perform(machine.speechFinished(at: ended))
        voiceLog.notice("question played to the end")
        markCardFinished()
        if let card, case .voiceSpeaking = model.phase { model.set(.voiceSpeaking(card), collapseAfter: 30) }
    }

    private func markCardFinished() { card?.finished = true }

    static func message(for error: CoachError) -> String {
        switch error {
        case .server(401, _, _): "The coach refused the connector key."
        case .server(413, _, _): "That was too long. Keep an answer under a minute."
        case .server(400, _, let message): "The coach couldn't use that recording: \(message)"
        case .server(409, _, let message): message
        case .server(503, "reply_unconfigured", _): "Voice replies are not set up on this coach yet."
        case .server(let status, _, _) where status >= 500: "The coach couldn't reply just now. Try again."
        case .server(_, _, let message): message
        default: error.localizedDescription
        }
    }

    private static func ms(since date: Date?) -> Int { date.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1 }

    #if DEBUG
    /// `-voiceScript "down@1.5,up@4,down@9,up@11"`: presses and releases ⌃⌥T at those seconds after
    /// launch, for screenshots and barge-in checks with no keyboard. `retry@t` and `dismiss@t` press
    /// the error card's Retry and close buttons. Debug builds only.
    func run(script: String) {
        let steps = script.split(separator: ",").compactMap { step -> (String, Double)? in
            let parts = step.split(separator: "@")
            guard parts.count == 2, let at = Double(parts[1]) else { return nil }
            return (parts[0].trimmingCharacters(in: .whitespaces), at)
        }
        for (verb, at) in steps {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(at))
                guard let self else { return }
                voiceLog.notice("script: \(verb, privacy: .public)")
                switch verb {
                case "down": self.keyDown()
                case "up": self.keyUp()
                case "retry": self.model.onVoiceRetry()
                case "dismiss": self.model.dismiss()
                default: break
                }
            }
        }
    }
    #endif
}
