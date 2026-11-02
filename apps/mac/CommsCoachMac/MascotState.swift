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
}

/// Who writes the card: the real model on the shared record, or a stub on a local test server.
enum ModelLabel {
    static func display(_ model: String) -> String {
        model == "meta-models/muse-spark-open-1026" ? "Muse Spark Open" : model
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
    let receiptID: String
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

    init(roundID: String, receiptID: String, question: String, move: VoiceReply.Move?, transcript: String, quote: String?,
         metrics: VoiceMetrics?, latency: VoiceLatency?, replayed: Bool, modelLabel: String = "Muse Spark Open", isPreview: Bool = false) {
        self.roundID = roundID; self.receiptID = receiptID; self.question = question; self.move = move; self.transcript = transcript
        self.quote = quote; self.metrics = metrics; self.latency = latency; self.replayed = replayed; self.modelLabel = modelLabel; self.isPreview = isPreview
    }

    init(_ receipt: VoiceRoundReceipt) {
        self.init(roundID: receipt.round_id, receiptID: receipt.receipt_id, question: receipt.reply.question.trimmingCharacters(in: .whitespacesAndNewlines),
                  move: receipt.reply.kind, transcript: receipt.transcript, quote: receipt.reply.verifiedQuote, metrics: receipt.metrics,
                  latency: receipt.latency_ms, replayed: receipt.replayed, modelLabel: ModelLabel.display(receipt.model))
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

    /// "42 words · 132 per minute · 1 filler · 2 hedges", from the code-computed metrics.
    var metricsLine: String? {
        guard let m = metrics else { return nil }
        func count(_ n: Int?, _ one: String, _ many: String) -> String? { n.map { "\($0) \($0 == 1 ? one : many)" } }
        let parts = [count(m.word_count, "word", "words"), m.words_per_minute.map { "\(Int($0.rounded())) per minute" },
                     count(m.filler_count, "filler", "fillers"), count(m.hedge_count, "hedge", "hedges"),
                     m.restart_count.flatMap { $0 > 0 ? count($0, "restart", "restarts") : nil },
                     m.onset_ms_approx.map { String(format: "started about %.1f s after the question", $0 / 1000) }]
        let line = parts.compactMap { $0 }.joined(separator: " · ")
        return line.isEmpty ? nil : line
    }

    /// "Voice reply 3.9 s after you let go · speech-to-text 2.1 s · model 1.7 s".
    var latencyLine: String? {
        func seconds(_ ms: Double?) -> String? { ms.map { String(format: "%.1f s", $0 / 1000) } }
        var parts: [String] = []
        if let mac = releaseToVoice { parts.append(String(format: "Voice reply %.1f s after you let go", mac)) }
        else if let total = seconds(latency?.total) { parts.append("Coach replied in \(total)") }
        if let asr = seconds(latency?.asr) { parts.append("speech-to-text \(asr)") }
        if let model = seconds(latency?.model) { parts.append("model \(model)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
        case .idle: "text.bubble"
        case .listening: "record.circle"
        case .thinking: "sparkles"
        case .speaking: "checkmark.seal"
        case .nudging: "bell.badge"
        case .blocked: "hand.raised"
        case .offline: "wifi.slash"
        case .permission: "lock.shield"
        case .notice: "arrow.uturn.backward.circle"
        case .hidden: "eye.slash"
        case .voiceListening: "mic.fill"
        case .voiceThinking: "sparkles"
        case .voiceSpeaking: "speaker.wave.2.fill"
        case .voiceError: "exclamationmark.bubble"
        case .micPermission: "mic.slash"
        }
    }

    var accent: NSColor {
        switch self {
        case .idle: NSColor.secondaryLabelColor
        case .listening: Palette.capture
        case .thinking: Palette.model
        case .speaking: Palette.record
        case .nudging: Palette.record
        case .blocked: Palette.warn
        case .offline: Palette.offline
        case .permission: Palette.warn
        case .notice: Palette.record
        case .hidden: Palette.offline
        case .voiceListening: Palette.capture
        case .voiceThinking: Palette.model
        case .voiceSpeaking: Palette.model
        case .voiceError: Palette.warn
        case .micPermission: Palette.warn
        }
    }

    /// The one-line label beside the character.
    func label(now: Date = Date()) -> String {
        switch self {
        case .idle: "\(MascotName) · ⌃⌥Space reads this window · hold ⌃⌥T to talk"
        case .listening(let app): "Reading \(app) (this window only)"
        case .thinking(let since): "\(ModelLabel.thinking) · \(max(0, Int(now.timeIntervalSince(since))))s"
        case .speaking(let card): card.isPreview ? "Preview · sample card, not saved" : (card.replayed ? "Already saved to your record" : "Saved to your record")
        case .nudging(let nudge, _): nudge.headline
        case .blocked(let app): "I don't read \(app)"
        case .offline(let reason, _): reason
        case .permission: "Screen Recording is needed to read a window"
        case .notice(let text): text
        case .hidden: "Hidden while presenting"
        case .voiceListening(let since):
            "Listening · let go of ⌃⌥T to send · \(Self.clock(now.timeIntervalSince(since))) of 1:00"
        case .voiceThinking(let since): "\(ModelLabel.voiceThinking) · \(max(0, Int(now.timeIntervalSince(since))))s"
        case .voiceSpeaking(let card):
            card.isPreview ? "Preview · sample voice reply, not sent"
                : !card.finished ? "Voice reply · ⌃⌥T cuts in"
                : card.endsRound ? "Round done · hold ⌃⌥T to start again" : "Voice reply · hold ⌃⌥T to answer"
        case .voiceError(let message, _): message
        case .micPermission(let denied): denied ? "Microphone access is off" : "The microphone is needed to hear you"
        }
    }

    private static func clock(_ seconds: TimeInterval) -> String {
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

/// Fixed sample content for the "Preview states" menu. Clearly labelled; never sent or saved.
enum PreviewSamples {
    static let card = ContextCard(recordID: "preview", version: 1, receiptID: "preview", appName: "TextEdit",
                                  summary: "You're preparing to ask to own the Q1 launch in a 1:1.",
                                  observation: "For \"Answer clearly\", lead with the ask; right now it's buried at the end.",
                                  nextStep: "Say the ask in one sentence, out loud, twice.", replayed: false, isPreview: true)
    static let nudge = NudgeCard(headline: "New exercise in your record", detail: "State the ask in one sentence (2 min)", goalTitle: "Answer clearly")
    static let voiceCard: VoiceCard = {
        let metrics = try? JSONDecoder().decode(VoiceMetrics.self, from: Data(#"{"word_count":38,"words_per_minute":141,"filler_count":2,"hedge_count":2,"restart_count":0}"#.utf8))
        let latency = try? JSONDecoder().decode(VoiceLatency.self, from: Data(#"{"asr":2100,"model":1700,"total":3900}"#.utf8))
        var card = VoiceCard(roundID: "preview", receiptID: "preview", question: "You said you'd maybe lead it. What would you own on day one?",
                             move: .challenge, transcript: "Um, I think I'm ready to lead the Q1 launch, maybe, because I ran the beta and the team knows me.",
                             quote: "maybe", metrics: metrics, latency: latency, replayed: false, isPreview: true)
        card.releaseToVoice = 4.1
        card.voice = .remote(provider: "wit")
        return card
    }()

    static let all: [MascotPhase] = [
        .idle, .listening(app: "TextEdit"), .thinking(since: Date().addingTimeInterval(-4)), .speaking(card),
        .nudging(nudge, opened: true), .blocked("1Password"), .offline("Can't reach the coach. Check the network.", retryable: true), .hidden,
        .permission,
        .voiceListening(since: Date().addingTimeInterval(-4)), .voiceThinking(since: Date().addingTimeInterval(-2)), .voiceSpeaking(voiceCard),
        .voiceError("The coach couldn't reply (503).", retryable: true), .micPermission(denied: false),
    ]
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

    var isHidden: Bool { presenting || inMeetingApp || phase == .hidden }

    func set(_ new: MascotPhase, collapseAfter seconds: Double? = nil) {
        collapseTask?.cancel()
        phase = new
        if case .speaking(let card) = new, !card.isPreview { lastCard = card }
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
