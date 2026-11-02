import AppKit
import Combine
import Foundation

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
    var isPreview = false
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
    case hidden

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
        case .hidden: "hidden"
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
        case .hidden: "eye.slash"
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
        case .hidden: Palette.offline
        }
    }

    /// The one-line label beside the character.
    func label(now: Date = Date()) -> String {
        switch self {
        case .idle: "\(MascotName) · ⌃⌥Space reads this window"
        case .listening(let app): "Reading \(app) (this window only)"
        case .thinking(let since): "Muse Spark Open is reading the redacted text · \(max(0, Int(now.timeIntervalSince(since))))s"
        case .speaking(let card): card.isPreview ? "Preview · sample card, not saved" : (card.replayed ? "Already saved to your record" : "Saved to your record")
        case .nudging(let nudge, _): nudge.headline
        case .blocked(let app): "I don't read \(app)"
        case .offline(let reason, _): reason
        case .permission: "Screen Recording is needed to read a window"
        case .hidden: "Hidden while presenting"
        }
    }

    /// Spoken by VoiceOver when the state changes.
    var announcement: String? {
        switch self {
        case .idle, .hidden: nil
        case .listening(let app): "Reading \(app), this window only."
        case .thinking: "Muse Spark Open is reading the redacted text."
        case .speaking(let card): "Saved. Next step: \(card.nextStep)"
        case .nudging(let nudge, _): "\(nudge.headline). \(nudge.detail)"
        case .blocked(let app): "I don't read \(app)."
        case .offline(let reason, _): "Not saved. \(reason)"
        case .permission: "Screen Recording permission is needed to read a window."
        }
    }

    var showsBubble: Bool {
        switch self {
        case .speaking, .offline, .permission: true
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
    static let nudge = NudgeCard(headline: "Muse added an exercise", detail: "State the ask in one sentence (2 min)", goalTitle: "Answer clearly")

    static let all: [MascotPhase] = [
        .idle, .listening(app: "TextEdit"), .thinking(since: Date().addingTimeInterval(-4)), .speaking(card),
        .nudging(nudge, opened: true), .blocked("1Password"), .offline("Can't reach the coach. Check the network.", retryable: true), .hidden,
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

    func dismiss() { set(.idle) }

    /// Asks the panel to resize, for changes that do not alter the phase (hover).
    var onLayoutNeeded: () -> Void = {}
    func layoutNeeded() { DispatchQueue.main.async { self.onLayoutNeeded() } }

    /// Clicking the character: read a window when idle, open a waiting nudge, or close the bubble.
    func clicked() {
        switch phase {
        case .idle, .blocked: onCapture()
        case .nudging(let nudge, false): set(.nudging(nudge, opened: true), collapseAfter: 20)
        case .speaking, .nudging, .offline: dismiss()
        case .permission: onPermissionContinue()
        default: break
        }
    }

    private func announce(_ message: String) {
        let element: Any = NSApp.windows.first(where: { $0.isVisible }) ?? NSApp as Any
        NSAccessibility.post(element: element, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}
