import AppKit
import Combine
import Foundation
import ScreenContextCore

/// What a saved capture looks like in the speech bubble.
struct ContextCard: Equatable {
    let recordID: String
    let version: Int
    let receiptID: String
    let appName: String
    let summary: String
    let observation: String
    let nextStep: String
    let replayed: Bool
    var modelLabel = "Muse Spark Open"
    var isPreview = false
    /// The language the card is written in, for saying its sentence out loud.
    var language: VoiceLanguage = .en
}

/// Who writes the card: the real model on the shared record, or a stub on a local test server.
enum ModelLabel {
    /// Nil is a code-only reply: no model wrote it.
    static func display(_ model: String?) -> String {
        guard let model else { return "Code only, no model" }
        return model == "meta-models/muse-spark-open-1026" ? "Muse Spark Open" : model
    }
    static var thinking: String {
        Connection.isLocalDevelopmentRequested ? "The local test server is writing the card" : "Muse Spark Open is reading the redacted text"
    }
    static var voiceThinking: String {
        Connection.isLocalDevelopmentRequested ? "The local test server is replying" : "Meta transcribes, Muse Spark Open replies"
    }
}

/// One voice reply in the speech bubble: the question it speaks, what it heard, and how long it took.
struct VoiceCard: Equatable {
    let roundID: String
    /// Empty until a live round is saved.
    var receiptID: String
    let question: String
    let move: VoiceReply.Move?
    let transcript: String
    /// Shown only when the coach checked it against the transcript.
    let quote: String?
    let metrics: VoiceMetrics?
    let latency: VoiceLatency?
    let replayed: Bool
    var modelLabel = "Muse Spark Open"
    /// From letting go of ⌃⌥T to the first spoken word, measured on this Mac.
    var releaseToVoice: TimeInterval?
    /// The question has played to the end (or was stopped).
    var finished = false
    /// Which voice said it: the coach server's voice, or Apple's voice on this Mac as a fallback.
    var voice: SpeechSource?
    var isPreview = false
    /// This answer's place in the spoken round, counted on this Mac since the last wrap-up.
    var round: Int?
    /// On a wrap-up: the one number the round is summed up with, from the code-measured metrics.
    var summary: RoundSummary?
    /// The source line a preview shows instead of a receipt.
    var sampleSource: String?
    /// The other person's need and the move gate for this answer (`counterpart`), when the coach sent them.
    var counterpart: VoiceCounterpart?
    /// "Need: a date, met on answer 2, unsure words 1 → 0", from `RoundNeed` on this Mac. Nil without a need.
    var needLine: String?
    /// No model wrote this question (`X-Reply-Mode: code`).
    var codeOnly: Bool { counterpart?.isCodeOnly == true }
    /// "Recording kept" when Keep my recordings is on and the server kept this answer's audio.
    var recordingNote: String?

    init(roundID: String, receiptID: String, question: String, move: VoiceReply.Move?, transcript: String, quote: String?,
         metrics: VoiceMetrics?, latency: VoiceLatency?, replayed: Bool, modelLabel: String = "Muse Spark Open", isPreview: Bool = false) {
        self.roundID = roundID; self.receiptID = receiptID; self.question = question; self.move = move; self.transcript = transcript
        self.quote = quote; self.metrics = metrics; self.latency = latency; self.replayed = replayed; self.modelLabel = modelLabel; self.isPreview = isPreview
    }

    /// A live round's reply, shown before it is saved; `receiptID` is filled in when it is.
    init(live: LiveReply) {
        self.init(roundID: live.round_id, receiptID: "", question: live.reply.question.trimmingCharacters(in: .whitespacesAndNewlines),
                  move: live.reply.kind, transcript: live.transcript, quote: live.reply.verifiedQuote, metrics: live.metrics,
                  latency: VoiceLatency(asr: live.latency_ms?.asr, model: live.latency_ms?.model, total: live.latency_ms?.release_to_reply),
                  replayed: false, modelLabel: ModelLabel.display(live.model))
        counterpart = live.counterpart
    }

    init(_ receipt: VoiceRoundReceipt) {
        self.init(roundID: receipt.round_id, receiptID: receipt.receipt_id, question: receipt.reply.question.trimmingCharacters(in: .whitespacesAndNewlines),
                  move: receipt.reply.kind, transcript: receipt.transcript, quote: receipt.reply.verifiedQuote, metrics: receipt.metrics,
                  latency: receipt.latency_ms, replayed: receipt.replayed, modelLabel: ModelLabel.display(receipt.model))
        recordingNote = receipt.media?.note
        counterpart = receipt.counterpart
    }

    var endsRound: Bool { move == .wrap_up }

    /// Which voice spoke, or the fallback note with its reason.
    var voiceNote: String? {
        if case .remote = voice, Connection.isLocalDevelopmentRequested, !isPreview { return "Voice from the local test server" }
        return voice?.label
    }

    var moveTitle: String {
        switch move {
        case .follow_up: "Follow-up"
        case .challenge: "Challenge"
        case .wrap_up: "Wrap-up"
        case nil: "Reply"
        }
    }

    /// The start of what was heard, cut at a word.
    var transcriptSnippet: String {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > 140 else { return text }
        let cut = text.prefix(140)
        return (cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)) + "…"
    }

    /// "42 words, 132 per minute, 1 filler, 2 unsure words", from the code-computed metrics.
    var metricsLine: String? {
        guard let m = metrics else { return nil }
        func count(_ n: Int?, _ one: String, _ many: String) -> String? { n.map { "\($0) \($0 == 1 ? one : many)" } }
        let parts = [count(m.word_count, "word", "words"), m.words_per_minute.map { "\(Int($0.rounded())) per minute" },
                     count(m.filler_count, "filler", "fillers"), count(m.hedge_count, "unsure word", "unsure words"),
                     m.restart_count.flatMap { $0 > 0 ? count($0, "restart", "restarts") : nil },
                     m.onset_ms_approx.map { String(format: "started about %.1f s after the question", $0 / 1000) }]
        let line = parts.compactMap { $0 }.joined(separator: ", ")
        return line.isEmpty ? nil : line
    }

    /// "Voice reply 3.9 s after you let go, speech-to-text 2.1 s, model 1.7 s".
    var latencyLine: String? {
        func seconds(_ ms: Double?) -> String? { ms.map { String(format: "%.1f s", $0 / 1000) } }
        var parts: [String] = []
        if let mac = releaseToVoice { parts.append(String(format: "Voice reply %.1f s after you let go", mac)) }
        else if let total = seconds(latency?.total) { parts.append("Coach replied in \(total)") }
        if let asr = seconds(latency?.asr) { parts.append("speech-to-text \(asr)") }
        if let model = seconds(latency?.model) { parts.append("model \(model)") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// The short timing for the card footer: "reply 4.1 s after you let go".
    var shortLatency: String? {
        if let mac = releaseToVoice { return String(format: "reply %.1f\u{00A0}s after you let go", mac) }
        return latency?.total.map { String(format: "reply in %.1f\u{00A0}s", $0 / 1000) }
    }
}

/// What the companion shows when Muse or the watch changed the shared record.
struct NudgeCard: Equatable {
    let headline: String
    let detail: String
    let goalTitle: String
}

/// The companion's states (plan §3.2). Each has an icon and a text label, never colour alone.
enum MascotPhase: Equatable {
    case idle
    case listening(app: String)
    case thinking(since: Date)
    case speaking(ContextCard)
    case nudging(NudgeCard, opened: Bool)
    case blocked(String)
    case offline(String, retryable: Bool)
    case permission
    case notice(String)
    case hidden
    // Hold-to-talk (⌃⌥T).
    case voiceListening(since: Date)
    case voiceThinking(since: Date)
    case voiceSpeaking(VoiceCard)
    case voiceError(String, retryable: Bool)
    case micPermission(denied: Bool)

    /// A hold-to-talk state, which the voice flow owns.
    var isVoice: Bool {
        switch self {
        case .voiceListening, .voiceThinking, .voiceSpeaking, .voiceError, .micPermission: true
        default: false
        }
    }

    var name: String {
        switch self {
        case .idle: "idle"
        case .listening: "listening"
        case .thinking: "thinking"
        case .speaking: "speaking"
        case .nudging: "nudging"
        case .blocked: "blocked"
        case .offline: "offline"
        case .permission: "needs permission"
        case .notice: "notice"
        case .hidden: "hidden"
        case .voiceListening: "voice listening"
        case .voiceThinking: "voice thinking"
        case .voiceSpeaking: "voice speaking"
        case .voiceError: "voice error"
        case .micPermission: "needs microphone"
        }
    }

    var symbol: String {
        switch self {
        case .idle: "mic"
        case .listening: "text.viewfinder"
        case .thinking: "ellipsis"
        case .speaking: "checkmark"
        case .nudging: "bell.badge"
        case .blocked: "hand.raised"
        case .offline: "wifi.slash"
        case .permission: "lock.shield"
        case .notice: "arrow.uturn.backward.circle"
        case .hidden: "eye.slash"
        case .voiceListening: "mic.fill"
        case .voiceThinking: "ellipsis"
        case .voiceSpeaking(let card): card.finished ? (card.endsRound ? "checkmark" : "mic") : "speaker.wave.2.fill"
        case .voiceError: "exclamationmark.triangle"
        case .micPermission: "mic.slash"
        }
    }

    /// A state that reports something stopped: its card takes the graphite header.
    var isProblem: Bool {
        switch self {
        case .offline, .voiceError, .blocked: true
        default: false
        }
    }

    /// The plain-word status beside Tug, and an optional small detail (a timer, shown after 2 s).
    func pill(now: Date = Date()) -> (word: String, detail: String?) {
        // One timer format everywhere, m:ss, shown once a wait passes 2 s.
        func elapsed(_ since: Date) -> String? {
            let s = now.timeIntervalSince(since)
            return s >= 2 ? Self.clock(s) : nil
        }
        switch self {
        case .idle: return ("Hold ⌃⌥T and talk", nil)
        case .listening(let app): return ("Reading \(app)", nil)
        case .thinking(let since): return ("Thinking", elapsed(since))
        case .speaking(let card): return (card.replayed ? "Already saved" : "Card saved", nil)
        case .nudging: return ("New in your record", nil)
        case .blocked(let app): return ("I don't read \(app)", nil)
        case .offline: return ("Not saved", nil)
        case .permission: return ("Screen Recording needed", nil)
        case .notice(let text): return (text, nil)
        case .hidden: return ("Hidden while presenting", nil)
        case .voiceListening(let since): return ("Listening", Self.clock(now.timeIntervalSince(since)))
        case .voiceThinking(let since): return ("Thinking", elapsed(since))
        case .voiceSpeaking(let card):
            if !card.finished { return ("Speaking", nil) }
            return (card.endsRound ? "Round done" : "Hold ⌃⌥T to answer", nil)
        case .voiceError: return ("Not sent", nil)
        case .micPermission(let denied): return (denied ? "Microphone is off" : "Microphone needed", nil)
        }
    }

    /// The card's heading: six words or fewer.
    var heading: String {
        switch self {
        case .speaking(let card): card.replayed ? "Already saved" : "Card saved"
        case .nudging: "New in your record"
        case .offline: "Not saved"
        case .permission: "Allow Screen Recording"
        case .voiceSpeaking(let card): card.endsRound ? "Round done" : (card.move == .challenge ? "Challenge" : card.move == .follow_up ? "Follow-up" : "Reply")
        case .voiceError: "Not sent"
        case .micPermission(let denied): denied ? "Microphone is off" : "Allow the microphone"
        default: pill().word
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }

    /// Spoken by VoiceOver when the state changes.
    var announcement: String? {
        switch self {
        case .idle, .hidden: nil
        case .listening(let app): "Reading \(app), this window only."
        case .thinking: "\(ModelLabel.thinking)."
        case .speaking(let card): "Saved. Next step: \(card.nextStep)"
        case .nudging(let nudge, _): "\(nudge.headline). \(nudge.detail)"
        case .blocked(let app): "I don't read \(app)."
        case .offline(let reason, _): "Not saved. \(reason)"
        case .permission: "Screen Recording permission is needed to read a window."
        case .notice(let text): text
        // Kept short: anything VoiceOver says while the microphone is open is recorded too.
        case .voiceListening: "Listening."
        case .voiceThinking: "Sent. \(ModelLabel.voiceThinking)."
        // Silent while the question plays, so two voices never talk over each other.
        case .voiceSpeaking(let card): card.finished ? (card.endsRound ? "Round done." : "Hold Control-Option-T to answer.") : nil
        case .voiceError(let message, let retryable): "Not sent. \(message)\(retryable ? " Retry is available." : "")"
        case .micPermission(let denied): denied ? "Microphone access is off for \(appDisplayName)." : "Microphone permission is needed for voice replies."
        }
    }

    var showsBubble: Bool {
        switch self {
        case .speaking, .offline, .permission, .voiceSpeaking, .voiceError, .micPermission: true
        case .nudging(_, let opened): opened
        default: false
        }
    }
}

/// Fixed sample content for the "Preview States" menu. Never sent or saved. The voice samples use the
/// numbers of one recorded run (receipt 5aeff421), so every surface shows the same sample.
enum PreviewSamples {
    static let card = ContextCard(recordID: "preview", version: 1, receiptID: "preview", appName: "TextEdit",
                                  summary: "You're preparing to ask to own the Q1 launch in a 1:1.",
                                  observation: "For \"Answer clearly\", lead with the ask; right now it's buried at the end.",
                                  nextStep: "Say the ask in one sentence, out loud, twice.", replayed: false, isPreview: true)
    static let nudge = NudgeCard(headline: "New exercise in your record", detail: "State the ask in one sentence (2 min)", goalTitle: "Answer clearly")
    static let source = "Sample from receipt 5aeff421"

    private static func metrics(_ json: String) -> VoiceMetrics? { try? JSONDecoder().decode(VoiceMetrics.self, from: Data(json.utf8)) }
    static let sampleMetrics = metrics(#"{"word_count":40,"words_per_minute":166,"filler_count":2,"hedge_count":1,"restart_count":2}"#)

    static func voiceCard(finished: Bool = false) -> VoiceCard {
        let latency = try? JSONDecoder().decode(VoiceLatency.self, from: Data(#"{"asr":2100,"model":1700,"total":3900}"#.utf8))
        var card = VoiceCard(roundID: "preview", receiptID: "preview", question: "What's the one fact that backs that up?",
                             move: .challenge,
                             transcript: "Um, so I think the main point is basically that we should ship the smaller version first. Sorry, let me restart. The main point is ship the smaller version first because it lets us test with real users this week",
                             quote: "I think", metrics: sampleMetrics, latency: latency, replayed: false, isPreview: true)
        card.releaseToVoice = 4.1
        card.voice = .remote(provider: "wit")
        card.round = 1
        card.finished = finished
        card.sampleSource = source
        // `-previewRecordingKept YES`: the card as it looks with Keep my recordings on.
        if UserDefaults.standard.bool(forKey: "previewRecordingKept") { card.recordingNote = KeepRecordingsCopy.kept }
        return card
    }

    static let summaryCard: VoiceCard = {
        var card = VoiceCard(roundID: "preview", receiptID: "preview", question: "Good. That's clear and backed by a fact. Want to run it once more tomorrow?",
                             move: .wrap_up, transcript: "The main point is ship the smaller version first, because it lets us test with real users this week.",
                             quote: nil, metrics: metrics(#"{"word_count":21,"words_per_minute":150,"filler_count":0,"hedge_count":0,"restart_count":0}"#),
                             latency: nil, replayed: false, isPreview: true)
        card.round = 3
        card.finished = true
        card.summary = RoundSummary.make([sampleMetrics, card.metrics].compactMap { $0 })
        card.sampleSource = "Sample numbers"
        return card
    }()

    /// Name (as the menu and `-previewState` use it) and state.
    static let named: [(name: String, phase: MascotPhase)] = [
        ("idle", .idle), ("listening", .listening(app: "TextEdit")), ("thinking", .thinking(since: Date().addingTimeInterval(-4))),
        ("speaking", .speaking(card)), ("nudging", .nudging(nudge, opened: true)), ("nudge arriving", .nudging(nudge, opened: false)),
        ("blocked", .blocked("1Password")), ("offline", .offline("Can't reach the coach. Check the network.", retryable: true)), ("hidden", .hidden),
        ("needs permission", .permission),
        ("voice listening", .voiceListening(since: Date().addingTimeInterval(-4))), ("voice thinking", .voiceThinking(since: Date().addingTimeInterval(-2))),
        ("voice speaking", .voiceSpeaking(voiceCard())), ("voice follow-up", .voiceSpeaking(voiceCard(finished: true))),
        ("voice round summary", .voiceSpeaking(summaryCard)),
        ("voice error", .voiceError("The coach couldn't reply just now. Try again.", retryable: true)), ("needs microphone", .micPermission(denied: false)),
        ("microphone off", .micPermission(denied: true)),
    ]

    static var all: [MascotPhase] { named.map(\.phase) }
}

/// Shared state between the panel, the menu and the flows. Main-actor only.
@MainActor
final class CompanionModel: ObservableObject {
    @Published private(set) var phase: MascotPhase = .idle
    @Published var ghost = false
    @Published var presenting = false
    @Published var inMeetingApp = false
    @Published var demoMode = false
    @Published var bubbleLeading = true
    @Published var lastCard: ContextCard?
    /// Tug is saying a sentence out loud (about the line it points at).
    @Published var talking = false
    /// A ring is drawn on the captured window for the current card.
    @Published var pointing = false
    /// Docked mode: the docked panel is open, so the floating Tug is in it instead.
    @Published var dockedPanelOpen = false
    /// Tug has arrived in the docked panel (after its trip there).
    @Published var tugInPanel = false
    /// The latest spoken round's card, for the docked panel.
    @Published var latestVoiceCard: VoiceCard?
    /// Tug lives in the top bar, so the floating window stays hidden. Pointing still draws its ring.
    @Published var floatingSuppressed = false
    /// A global shortcut could not be registered (another copy of the app holds it), in plain words.
    @Published var hotkeyNotice: String?

    /// Set by the app delegate: the actions the view and menu trigger.
    var onCapture: () -> Void = {}
    var onUndo: () -> Void = {}
    var onAskMuse: () -> Void = {}
    var onRetry: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var onPermissionContinue: () -> Void = {}
    var onVoiceRetry: () -> Void = {}
    var onVoiceDismiss: () -> Void = {}
    var onMicContinue: () -> Void = {}
    var onOpenMicSettings: () -> Void = {}

    private var collapseTask: Task<Void, Never>?

    var isHidden: Bool { isPresenting || dockedPanelOpen || floatingSuppressed }
    /// Presenting (⌃⌥H) or a meeting app in front: nothing of ours may appear on screen, be said or be read.
    var isPresenting: Bool { presenting || inMeetingApp || phase == .hidden }

    func set(_ new: MascotPhase, collapseAfter seconds: Double? = nil) {
        collapseTask?.cancel()
        phase = new
        if case .speaking(let card) = new, !card.isPreview { lastCard = card }
        if case .voiceSpeaking(let card) = new { latestVoiceCard = card }
        if let message = new.announcement { announce(message) }
        if let seconds {
            collapseTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                self?.phase = .idle
            }
        }
    }

    func dismiss() {
        if phase.isVoice { onVoiceDismiss() }
        set(.idle)
    }

    /// Asks the panel to resize, for changes that do not alter the phase (hover).
    var onLayoutNeeded: () -> Void = {}
    func layoutNeeded() { DispatchQueue.main.async { self.onLayoutNeeded() } }

    /// Clicking the character: read a window when idle, open a waiting nudge, or close the bubble.
    func clicked() {
        switch phase {
        case .idle, .blocked, .notice: onCapture()
        case .nudging(let nudge, false): set(.nudging(nudge, opened: true), collapseAfter: 20)
        case .speaking, .nudging, .offline, .voiceSpeaking, .voiceError: dismiss()
        case .permission: onPermissionContinue()
        case .micPermission(let denied): denied ? onOpenMicSettings() : onMicContinue()
        default: break
        }
    }

    private func announce(_ message: String) {
        let element: Any = NSApp.windows.first(where: { $0.isVisible }) ?? NSApp as Any
        NSAccessibility.post(element: element, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}
