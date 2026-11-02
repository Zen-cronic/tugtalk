import AppKit
import Combine
import OSLog
import ScreenContextCore

/// Records timings and status codes for each hold. Never audio, transcripts, questions or the key.
let voiceLog = Logger(subsystem: "com.kaungzinhein.commscoach.mac", category: "voice")

/// Hold ⌃⌥T to talk: the microphone opens on press and closes on release. While it is held the samples stream to the
/// coach over the live socket (`WS /v1/voice-rounds/live`), so the transcript is ready on release; the reply comes back
/// on the same socket with its audio, which plays as it arrives. If the live round fails before a reply, the same clip
/// goes to `POST /v1/voice-rounds` with the same key (which replays a live round that was saved). Pressing ⌃⌥T while it
/// speaks stops it at once and starts a new hold. `VoiceTurnMachine` decides; this performs.
@MainActor
final class VoiceFlow {
    private let model: CompanionModel
    private var machine = VoiceTurnMachine()
    /// The coach server's voice with Apple's voice as the fallback, or Apple's voice only (`Settings.replyVoice`,
    /// read for each reply). `speech` is the one speaking now.
    private let serverVoice: SpeechRouter
    private let macVoice: SpeechRouter
    private var speech: SpeechRouter
    /// The live round of the current hold, its key, and what it has reported.
    private var live: LiveVoiceSession?
    private var liveKey: String?
    private var liveRound: VoiceRoundRequest?
    private var liveTask: Task<Void, Never>?
    private var liveReplied = false
    private var liveFallback: Task<Void, Never>?
    private var fixtureFeed: Task<Void, Never>?
    /// A live reply's audio, by round, for the speaker to play as it arrives.
    private var liveAudio: [String: LiveAudio] = [:]
    private var liveRoundID: String?
    private let appleOnly: Bool
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
    /// The answers of the spoken round so far, counted on this Mac since the last wrap-up or reset.
    private var tally = RoundTally()

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
        self.appleOnly = appleOnly
        let volume: @MainActor () -> Float = {
            #if DEBUG
            if UserDefaults.standard.object(forKey: "voiceVolume") != nil { return max(0, min(1, UserDefaults.standard.float(forKey: "voiceVolume"))) }
            #endif
            return 1
        }
        let apple = AppleSpeaker()
        let remote = StreamingSpeaker(volume: volume) { line in
            guard let roundID = line.roundID else { throw CoachError.notConfigured }
            if let audio = await MainActor.run(body: { LiveAudio.lookup?(roundID) }) { return try await audio.stream() }
            guard let api = await MainActor.run(body: { Connection.api()?.api }) else { throw CoachError.notConfigured }
            return try await api.streamSpeech(roundID: roundID)
        }
        remote.onStarted = { after, provider in
            voiceLog.notice("coach voice (\(provider ?? "unnamed", privacy: .public)) playing \(Int(after * 1000), privacy: .public) ms after the request")
        }
        serverVoice = SpeechRouter(remote: appleOnly ? nil : remote, fallback: apple)
        macVoice = SpeechRouter(remote: nil, fallback: apple, localReason: "your voice setting")
        speech = serverVoice
        let swept = store.sweep()
        if swept > 0 { voiceLog.notice("deleted \(swept, privacy: .public) recording(s) left from an earlier run") }
        // Another state took over the bubble (a screen capture, say): stop speaking and drop a kept clip.
        phaseWatch = model.$phase.sink { [weak self] phase in
            guard !phase.isVoice else { return }
            DispatchQueue.main.async { self?.leftVoice() }
        }
        // The server voice's source looks a round's live audio up here first.
        LiveAudio.lookup = { [weak self] id in self?.liveAudio[id] }
    }

    private func stopSpeech() {
        serverVoice.stop()
        macVoice.stop()
    }

    var usesFixture: Bool { fixture != nil }

    // Hotkey

    /// `source` says where the press came from (the hotkey, the docked panel's Talk button, or a script), so the
    /// log tells a press that never arrived from one that was refused. Every refusal is logged with both states.
    func keyDown(source: String = "hotkey") {
        let speaking: Bool = if case .speaking = machine.phase { true } else { false }
        let states = "machine \(machine.phase.name), companion \(model.phase.name)"
        voiceLog.notice("talk pressed (\(source, privacy: .public)): \(states, privacy: .public)")
        // A screen capture in progress keeps the companion busy.
        if !speaking, case .listening = model.phase { voiceLog.notice("press refused: a window is being read"); return }
        if !speaking, case .thinking = model.phase { voiceLog.notice("press refused: a window card is on its way"); return }
        if fixture == nil {
            switch MicPermission.status {
            case .granted: break
            case .undetermined:
                voiceLog.notice("press refused: microphone permission not asked yet")
                if speaking { stopSpeech(); _ = machine.dismiss() }; model.set(.micPermission(denied: false)); return
            case .denied:
                voiceLog.notice("press refused: microphone permission denied")
                if speaking { stopSpeech(); _ = machine.dismiss() }; model.set(.micPermission(denied: true)); return
            }
        }
        guard Connection.api() != nil else {
            voiceLog.notice("press refused: no connection to the coach")
            model.set(.voiceError(Connection.unavailableReason, retryable: false))
            return
        }
        let effects = machine.keyDown(at: Date())
        if effects.isEmpty { voiceLog.notice("press ignored by the voice turn: \(states, privacy: .public)") }
        perform(effects)
    }

    func keyUp(source: String = "hotkey") {
        let effects = machine.keyUp(at: Date())
        voiceLog.notice("talk released (\(source, privacy: .public)): machine now \(self.machine.phase.name, privacy: .public)\(effects.isEmpty ? ", nothing to send" : "", privacy: .public)")
        perform(effects)
    }

    func retry() { perform(machine.retry(at: Date())) }

    /// A hold that can no longer end with a release (the docked panel closed under Talk): nothing is sent.
    func cancelHold() {
        guard case .listening = machine.phase else { return }
        voiceLog.notice("hold cancelled before release; nothing sent")
        perform(machine.cancelHold())
        model.set(.notice("Not sent. Hold Talk until you finish."), collapseAfter: 3)
    }

    /// The bubble was closed, by its button or a click on the character. The round ends with it.
    func dismissed() {
        tally.reset()
        perform(machine.dismiss())
    }

    /// Another state took the bubble (a screen capture, a nudge): the round ends. A reply card that only
    /// collapsed to idle keeps the round, and a long silence ends it by itself (`RoundTally.idleGap`).
    private func leftVoice() {
        if model.phase != .idle { tally.reset() }
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
                stopSpeech()
                // The spoken round's socket: its audio stops; the round itself is still saved.
                if liveReplied { closeLive() }
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
                // A hold dropped before release is dropped on the server too; after a reply, only its audio stops.
                if liveKey == key, !liveReplied { closeLive() }
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
        let session = openLive(key)
        if fixture == nil {
            let recorder = MicRecorder()
            if let session { recorder.onSamples = { session.send($0) } }
            do {
                try recorder.start()
                self.recorder = recorder
            } catch {
                closeLive()
                _ = recorder.stop()
                _ = machine.dismiss()
                store.remove(key)
                voiceLog.error("the microphone did not start")
                model.set(.voiceError("The microphone could not start. Check the input in System Settings › Sound.", retryable: false))
                return
            }
        }
        if let session, let fixture { feedFixture(fixture, to: session) }
        voiceLog.notice("hold started\(self.fixture == nil ? "" : " (fixture WAV, microphone not used)", privacy: .public)\(session == nil ? "" : "; streaming live", privacy: .public)")
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
        let recorded = recorder?.stop()
        recorder = nil
        model.set(.voiceThinking(since: released))
        voiceLog.notice("thinking shown \(Self.ms(since: released), privacy: .public) ms after release")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            self?.send(key, promptEndedAt: promptEndedAt, recorded: recorded)
        }
    }

    private func send(_ key: String, promptEndedAt: Date?, recorded: [Int16]?) {
        guard case .thinking = machine.phase, machine.currentKey == key else { return }
        let wav: Data
        if store.exists(key), let kept = try? store.read(key) {
            wav = kept
        } else {
            let samples: [Int16]
            if let fixture {
                samples = (try? PCMResampler.convertFile(at: fixture)) ?? []
            } else {
                samples = recorded ?? []
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
        if liveKey == key, let live {
            finishFixtureFeed(to: live)
            live.end()
            voiceLog.notice("live round ended at release (\(live.samplesSent, privacy: .public) samples streamed)")
            // No reply in time: the same clip goes by upload, with the same key.
            liveFallback = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                self?.fallbackToUpload(key, reason: "no reply within 10 s")
            }
            return
        }
        post(key, wav: wav, promptEndedAt: promptEndedAt)
    }

    /// `POST /v1/voice-rounds` with the clip. A live round's own parameters are reused, so the request matches it.
    private func post(_ key: String, wav: Data, promptEndedAt: Date?) {
        guard let api = Connection.api()?.api else {
            fail(key, message: Connection.unavailableReason, retryable: false)
            return
        }
        var round = VoiceRoundRequest(wav: wav, idempotencyKey: key, goalID: Settings.goalID, screenContextID: model.lastCard?.recordID,
                                      language: Settings.voiceLanguage, promptEndedAt: promptEndedAt,
                                      occurredAt: occurredAt?.key == key ? occurredAt?.at : nil)
        if let started = liveRound, started.idempotencyKey == key { round = started; round.wav = wav }
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
                self?.fail(key, message: error.plainMessage(for: .voiceReply), retryable: VoiceRoundUploader.isRetryable(error))
            } catch {
                self?.fail(key, message: "The reply could not be read.", retryable: true)
            }
        }
    }

    private func replied(_ receipt: VoiceRoundReceipt, key: String) {
        let ms = Self.ms(since: releasedAt)
        voiceLog.notice("reply in \(ms, privacy: .public) ms after release (server total \(receipt.latency_ms?.total.map { String(Int($0)) } ?? "n/a", privacy: .public) ms, replayed \(receipt.replayed, privacy: .public))")
        show(VoiceCard(receipt), key: key, question: receipt.reply.question, endsRound: receipt.reply.kind == .wrap_up, metrics: receipt.metrics)
        afterSave()
    }

    private func show(_ shown: VoiceCard, key: String, question: String, endsRound: Bool, metrics: VoiceMetrics?) {
        let effects = machine.replyReady(key: key, question: question, endsRound: endsRound)
        guard !effects.isEmpty else {
            voiceLog.notice("an earlier hold's reply arrived after a newer press; not shown")
            return
        }
        var next = shown
        let counted = tally.record(metrics, endsRound: next.endsRound, at: Date())
        next.round = counted.round
        next.summary = counted.summary
        card = next
        if case .failed = machine.phase {
            tally.reset()
            perform(effects)
            model.set(.voiceError("The reply had no question to speak.", retryable: false))
            return
        }
        perform(effects)
    }

    // Live rounds

    /// Opens the hold's live socket, or nil when live rounds are off or there is no connection (the clip is then
    /// uploaded on release, as before).
    private func openLive(_ key: String) -> LiveVoiceSession? {
        closeLive()
        guard Settings.liveVoice, let api = Connection.api()?.api else { return nil }
        let prompt: Date? = if case .listening(_, _, let ended) = machine.phase { ended } else { nil }
        let round = VoiceRoundRequest(wav: Data(), idempotencyKey: key, goalID: Settings.goalID, screenContextID: model.lastCard?.recordID,
                                      language: Settings.voiceLanguage, promptEndedAt: prompt, occurredAt: occurredAt?.key == key ? occurredAt?.at : nil)
        let session = LiveVoiceSession(socket: api.liveSocket(), start: LiveStart(round, speech: Settings.replyVoice == .rebecca && !appleOnly))
        live = session; liveKey = key; liveRound = round; liveReplied = false; liveRoundID = nil
        liveTask = Task { [weak self] in
            for await event in session.events { self?.liveEvent(event, key: key) }
        }
        return session
    }

    private func closeLive() {
        live?.close(); live = nil; liveKey = nil
        liveTask?.cancel(); liveTask = nil
        liveFallback?.cancel(); liveFallback = nil
        fixtureFeed?.cancel(); fixtureFeed = nil
        fixtureSamples = nil
        for audio in liveAudio.values { audio.fail(CancellationError()) }
        liveAudio = [:]
    }

    private func liveEvent(_ event: LiveVoiceEvent, key: String) {
        guard liveKey == key else { return }
        switch event {
        case .ready(let mode):
            voiceLog.notice("live round ready \(Self.ms(since: self.holdStarted), privacy: .public) ms after the hold started (\(mode, privacy: .public) transcription)")
        case .partial:
            break
        case .transcript(_, let mode):
            voiceLog.notice("transcript \(Self.ms(since: self.releasedAt), privacy: .public) ms after release (\(mode, privacy: .public))")
        case .reply(let reply):
            liveReplied = true
            liveFallback?.cancel()
            liveRoundID = reply.round_id
            if Settings.replyVoice == .rebecca && !appleOnly { liveAudio[reply.round_id] = LiveAudio() }
            voiceLog.notice("reply in \(Self.ms(since: self.releasedAt), privacy: .public) ms after release (live; server \(reply.latency_ms?.release_to_reply.map { String(Int($0)) } ?? "n/a", privacy: .public) ms, transcription \(reply.transcription ?? "n/a", privacy: .public))")
            show(VoiceCard(live: reply), key: key, question: reply.reply.question, endsRound: reply.reply.kind == .wrap_up, metrics: reply.metrics)
        case .speechStart(let type, let provider):
            if let id = liveRoundID { liveAudio[id]?.start(contentType: type, provider: provider) }
        case .audio(let data):
            if let id = liveRoundID { liveAudio[id]?.yield(data) }
        case .speechEnd:
            if let id = liveRoundID { liveAudio[id]?.finish() }
        case .speechUnavailable(let why):
            if let id = liveRoundID { liveAudio[id]?.fail(CoachError.server(503, "speech_unconfigured", why)) }
        case .saved(let receipt):
            voiceLog.notice("saved \(Self.ms(since: self.releasedAt), privacy: .public) ms after release")
            if var shown = card, shown.roundID == receipt.round_id {
                shown.receiptID = receipt.receipt_id
                card = shown
                if case .voiceSpeaking(let visible) = model.phase, visible.roundID == shown.roundID {
                    var updated = visible; updated.receiptID = receipt.receipt_id; model.set(.voiceSpeaking(updated))
                }
            }
            afterSave()
        case .error(let error):
            if liveReplied {
                voiceLog.error("live round was not saved (\(error.localizedDescription, privacy: .public))")
                return
            }
            if VoiceRoundUploader.isRetryable(error) { fallbackToUpload(key, reason: "server error") }
            else { closeLive(); fail(key, message: error.plainMessage(for: .voiceReply), retryable: false) }
        case .closed(let code):
            if !liveReplied {
                // Closed while held: the release has not happened yet, so the clip is uploaded on release instead.
                if case .listening = machine.phase { voiceLog.notice("live socket closed during the hold (\(code ?? -1, privacy: .public)); the clip will be uploaded"); live = nil; liveKey = nil; return }
                fallbackToUpload(key, reason: "socket closed (\(code ?? -1))")
            } else if let id = liveRoundID {
                liveAudio[id]?.finish()
            }
        }
    }

    /// The live round failed before its reply: the clip kept on this Mac goes by upload with the same key, which
    /// replays the live round if the server saved it.
    private func fallbackToUpload(_ key: String, reason: String) {
        guard liveKey == key, !liveReplied, case .thinking = machine.phase, machine.currentKey == key else { return }
        voiceLog.notice("live round failed before a reply (\(reason, privacy: .public)); uploading the clip instead")
        let prompt = liveRound?.promptEndedAt
        let started = liveRound
        closeLive()
        liveRound = started
        guard let wav = try? store.read(key) else {
            fail(key, message: "The recording could not be prepared.", retryable: false)
            return
        }
        post(key, wav: wav, promptEndedAt: prompt)
    }

    /// DEBUG fixture holds: the file's samples go out in real time while held, and the rest at release, so the live
    /// round carries exactly the clip a fallback upload would send.
    private var fixtureSamples: (samples: [Int16], sent: Int)?

    private func feedFixture(_ url: URL, to session: LiveVoiceSession) {
        guard let samples = try? PCMResampler.convertFile(at: url) else { return }
        fixtureSamples = (samples, 0)
        let step = WAV.sampleRate * 85 / 1000
        fixtureFeed = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, var feed = self.fixtureSamples, feed.sent < feed.samples.count else { return }
                let end = min(feed.sent + step, feed.samples.count)
                session.send(feed.samples[feed.sent..<end])
                feed.sent = end
                self.fixtureSamples = feed
                try? await Task.sleep(for: .milliseconds(85))
            }
        }
    }

    private func finishFixtureFeed(to session: LiveVoiceSession) {
        fixtureFeed?.cancel(); fixtureFeed = nil
        guard let feed = fixtureSamples else { return }
        if feed.sent < feed.samples.count { session.send(feed.samples[feed.sent...]) }
        fixtureSamples = nil
    }

    private func fail(_ key: String, message: String, retryable: Bool) {
        // A hold that was replaced by a newer press: its failure must not cover the new hold.
        if let current = machine.currentKey, current != key {
            voiceLog.notice("an earlier hold failed after a newer press; ignored")
            return
        }
        if liveKey == key { closeLive() }
        tally.reset()
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
        // The voice setting is read for each reply: "This Mac" never calls the coach's speech route.
        speech = Settings.replyVoice == .thisMac ? macVoice : serverVoice
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
        // "Your turn" shows only once the turn is idle, so the press it asks for is always taken.
        guard case .speaking = machine.phase else {
            voiceLog.notice("a finished question arrived after the turn moved on (machine \(self.machine.phase.name, privacy: .public)); ignored")
            return
        }
        perform(machine.speechFinished(at: ended))
        voiceLog.notice("question played to the end; machine \(self.machine.phase.name, privacy: .public)")
        markCardFinished()
        if let card, case .voiceSpeaking = model.phase { model.set(.voiceSpeaking(card), collapseAfter: 30) }
    }

    private func markCardFinished() { card?.finished = true }

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
                case "down": self.keyDown(source: "script")
                case "up": self.keyUp(source: "script")
                case "retry": self.model.onVoiceRetry()
                case "dismiss": self.model.dismiss()
                default: break
                }
            }
        }
    }
    #endif
}

/// One live reply's audio, from the socket to the speaker: it waits for the head (its type and voice), then hands over
/// the bytes as they arrive. Fails if the coach says it has no voice, so the Mac's voice speaks instead.
@MainActor
final class LiveAudio {
    static var lookup: (@MainActor (String) -> LiveAudio?)?
    private var head: (type: String, provider: String?)?
    private var failure: Error?
    private var waiters: [CheckedContinuation<SpeechStream, Error>] = []
    private let chunks: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation

    init() { (chunks, continuation) = AsyncThrowingStream.makeStream(of: Data.self) }

    private var speechStream: SpeechStream? { head.map { SpeechStream(contentType: $0.type, provider: $0.provider, chunks: chunks) } }

    func start(contentType: String, provider: String?) {
        guard head == nil, failure == nil else { return }
        head = (contentType, provider)
        let stream = speechStream!
        waiters.forEach { $0.resume(returning: stream) }; waiters = []
    }

    func yield(_ data: Data) { continuation.yield(data) }
    func finish() { continuation.finish() }

    func fail(_ error: Error) {
        guard failure == nil else { return }
        failure = error
        continuation.finish(throwing: error)
        waiters.forEach { $0.resume(throwing: error) }; waiters = []
    }

    func stream() async throws -> SpeechStream {
        if let stream = speechStream { return stream }
        if let failure { throw failure }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }
}
