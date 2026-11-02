import CoreGraphics
import Foundation

/// Where Tug lives on the Mac: the top bar at the top centre of the screen, a floating window beside the work,
/// or the Dock. Kept free of AppKit so the rules are unit-tested.
public enum TugHome: String, CaseIterable, Equatable, Sendable {
    case topBar, floating, dock

    public static let standard: TugHome = .topBar

    public var title: String {
        switch self {
        case .topBar: "Top bar"
        case .floating: "Floating"
        case .dock: "Dock"
        }
    }

    /// The bar at the top centre of the screen.
    public var showsTopBar: Bool { self == .topBar }
    /// A Dock icon and the docked panel.
    public var showsDockIcon: Bool { self == .dock }
    /// The floating Tug beside the work. In the Dock it floats too, until it travels into the docked panel.
    public var floatsTug: Bool { self != .topBar }

    /// The stored choice; otherwise the older "Show in Dock" switch; otherwise the standard home.
    public static func resolve(stored: String?, legacyDockMode: Bool) -> TugHome {
        if let stored, let home = TugHome(rawValue: stored) { return home }
        return legacyDockMode ? .dock : standard
    }
}

/// Where the top bar sits. AppKit coordinates (y up) for screens and frames.
public enum NotchBarPlacement {
    /// The bar's frame on screen, and the camera housing inside it (window coordinates, y down from the top left).
    public struct Layout: Equatable, Sendable {
        public var frame: CGRect
        /// The camera housing in the window's own coordinates, or nil on a display without a notch.
        public var housing: CGRect?
        /// The height of the top band the bar's status row sits in: the notch's height, or the whole bar.
        public var band: CGFloat

        public init(frame: CGRect, housing: CGRect?, band: CGFloat) {
            self.frame = frame; self.housing = housing; self.band = band
        }
    }

    /// The camera housing on screen, from the safe area at the top and the two areas beside it. Nil without a notch.
    public static func housing(screen: CGRect, safeTop: CGFloat, auxLeft: CGRect?, auxRight: CGRect?) -> CGRect? {
        guard safeTop > 0, let left = auxLeft, let right = auxRight, right.minX - left.maxX > 1 else { return nil }
        return CGRect(x: left.maxX, y: screen.maxY - safeTop, width: right.minX - left.maxX, height: safeTop)
    }

    /// The collapsed bar. With a notch it wraps the housing: a wing on each side, flush with the top edge, plus a
    /// strip `below` it. Without one it hangs just under the menu bar, centred, at `plain` size.
    public static func collapsed(screen: CGRect, visible: CGRect, housing: CGRect?, wing: CGFloat, below: CGFloat, plain: CGSize) -> Layout {
        if let housing {
            let size = CGSize(width: housing.width + 2 * wing, height: housing.height + below)
            let x = clamp(housing.midX - size.width / 2, screen.minX, screen.maxX - size.width)
            let frame = CGRect(x: x, y: screen.maxY - size.height, width: size.width, height: size.height)
            return Layout(frame: frame, housing: local(housing, in: frame), band: housing.height)
        }
        // Under the menu bar (or at the top edge when the menu bar hides itself).
        let top = min(visible.maxY, screen.maxY)
        let x = clamp(screen.midX - plain.width / 2, screen.minX, screen.maxX - plain.width)
        return Layout(frame: CGRect(x: x, y: top - plain.height, width: plain.width, height: plain.height), housing: nil, band: plain.height)
    }

    /// The open panel: it grows down from the collapsed bar, keeps its top edge and its centre, is never narrower
    /// than the bar, and stays on the screen.
    public static func expanded(from bar: Layout, size: CGSize, screen: CGRect) -> Layout {
        let width = min(max(size.width, bar.frame.width), screen.width)
        let height = min(max(size.height, bar.frame.height), bar.frame.maxY - screen.minY)
        let x = clamp(bar.frame.midX - width / 2, screen.minX, screen.maxX - width)
        let frame = CGRect(x: x, y: bar.frame.maxY - height, width: width, height: height)
        // The housing stays where it is on screen.
        let housing = bar.housing.map { h in
            local(CGRect(x: bar.frame.minX + h.minX, y: bar.frame.maxY - h.maxY, width: h.width, height: h.height), in: frame)
        }
        return Layout(frame: frame, housing: housing, band: bar.band)
    }

    /// A screen rect in a window's own coordinates, y down from the window's top left.
    static func local(_ rect: CGRect, in frame: CGRect) -> CGRect {
        CGRect(x: rect.minX - frame.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(max(v, lo), max(lo, hi)) }
}

/// What the companion is doing, as the top bar needs it. The app maps its own states onto these.
public enum NotchBarInput: Equatable, Sendable {
    case idle
    case readingWindow
    case voiceListening(seconds: Int)
    case thinking
    /// A context card is shown; `talking` while Tug says its sentence.
    case contextCard(talking: Bool)
    /// A spoken reply: playing, then the person's turn, or the round's wrap-up.
    case voiceReply(finished: Bool, endsRound: Bool)
    case nudge(opened: Bool)
    case blocked
    case offline(retryable: Bool)
    case voiceError(retryable: Bool)
    case permission
    case notice
    case hidden
}

/// The top bar's status: one plain word beside Tug, and the mark on the other side of the notch. A word is at most
/// nine characters, the most that fits beside Tug in the wing left of a notch.
public struct NotchBarStatus: Equatable, Sendable {
    public enum Mark: Equatable, Sendable {
        /// The talk shortcut as keycaps; `cue` adds the "your turn" pulse to their edge.
        case keycaps(String, cue: Bool)
        /// The red record light, with the time held so far.
        case recordLight(String)
        case dots
        case wave
        /// An SF Symbol name, always beside a word.
        case symbol(String)
    }

    public let word: String
    public let mark: Mark
    /// The open panel shows a card for this state.
    public let showsCard: Bool
    /// How long a card that opened the panel by itself stays open with the pointer outside, in seconds. Nil: until
    /// the person acts on it (a permission step, a retry) or it closes.
    public let linger: Double?

    public static let talkShortcut = "⌃⌥T"

    public static func make(_ input: NotchBarInput) -> NotchBarStatus {
        let talk = Mark.keycaps(talkShortcut, cue: false)
        switch input {
        case .idle: return .init(word: "Ready", mark: talk, showsCard: false, linger: nil)
        case .readingWindow: return .init(word: "Reading", mark: .dots, showsCard: false, linger: nil)
        case .voiceListening(let s): return .init(word: "Listening", mark: .recordLight(clock(s)), showsCard: false, linger: nil)
        case .thinking: return .init(word: "Thinking", mark: .dots, showsCard: false, linger: nil)
        case .contextCard(let talking):
            return talking ? .init(word: "Speaking", mark: .wave, showsCard: true, linger: nil)
                           : .init(word: "Saved", mark: .symbol("checkmark"), showsCard: true, linger: 8)
        case .voiceReply(let finished, let endsRound):
            if !finished { return .init(word: "Speaking", mark: .wave, showsCard: true, linger: nil) }
            if endsRound { return .init(word: "Done", mark: talk, showsCard: true, linger: 8) }
            // The question has been asked: the panel folds a second later so the bar shows whose turn it is.
            return .init(word: "Your turn", mark: .keycaps(talkShortcut, cue: true), showsCard: true, linger: 1)
        case .nudge(let opened): return .init(word: "Updated", mark: .symbol("bell"), showsCard: opened, linger: 8)
        case .blocked: return .init(word: "Blocked", mark: .symbol("hand.raised"), showsCard: false, linger: nil)
        case .offline(let retryable): return .init(word: "Offline", mark: .symbol("wifi.slash"), showsCard: true, linger: retryable ? nil : 8)
        case .voiceError(let retryable): return .init(word: "Not sent", mark: .symbol("exclamationmark.triangle"), showsCard: true, linger: retryable ? nil : 8)
        case .permission: return .init(word: "Setup", mark: .symbol("lock"), showsCard: true, linger: nil)
        case .notice: return .init(word: "Ready", mark: talk, showsCard: true, linger: 4)
        case .hidden: return .init(word: "Hidden", mark: .symbol("eye.slash"), showsCard: false, linger: nil)
        }
    }

    static func clock(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }
}

/// When the top bar is open. The timing (a short hover delay, a pause after the pointer leaves, a card's linger)
/// belongs to the app; these are the rules it applies.
public struct NotchBarExpansion: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        /// The pointer rested on the bar.
        case hover
        /// A click, or the accessibility action: it also takes the keyboard.
        case click
        /// A card arrived (a voice reply, a saved card, a problem) and opened it by itself.
        case card
    }

    public private(set) var reason: Reason?
    public private(set) var pointerInside = false

    public init() {}

    public var expanded: Bool { reason != nil }

    public mutating func pointerEntered() { pointerInside = true }

    /// The pointer stayed on the bar for the hover delay.
    public mutating func hoverDwelled() {
        guard pointerInside, reason == nil else { return }
        reason = .hover
    }

    /// The pointer has been outside for the leave delay. A card that opened the panel by itself keeps it open
    /// until its own linger ends.
    public mutating func pointerLeft() {
        pointerInside = false
        if reason == .hover || reason == .click { reason = nil }
    }

    /// A click on the bar opens it; a second click closes it.
    public mutating func clicked() {
        reason = expanded ? nil : .click
    }

    /// Esc, the close button, or Hide.
    public mutating func close() { reason = nil }

    public mutating func cardShown() {
        if reason == nil { reason = .card }
    }

    /// The card's linger ended, or the card went away. With the pointer over the panel it stays open as a hover.
    public mutating func cardCleared() {
        guard reason == .card else { return }
        reason = pointerInside ? .hover : nil
    }

    /// The panel stopped taking the keyboard (the person clicked elsewhere).
    public mutating func resignedKey() {
        if reason == .click, !pointerInside { reason = nil }
    }
}
