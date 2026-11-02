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
        /// The height of the top band the status row sits in: the menu bar's height.
        public var band: CGFloat

        public init(frame: CGRect, housing: CGRect?, band: CGFloat) {
            self.frame = frame; self.housing = housing; self.band = band
        }
    }

    /// Nothing of ours comes closer than this to the housing's edge.
    public static let notchGap: CGFloat = 8
    /// The menu bar's height when it hides itself and the display reports none.
    public static let standardMenuBar: CGFloat = 24

    /// The camera housing on screen, from the safe area at the top and the two areas beside it. Nil without a notch.
    public static func housing(screen: CGRect, safeTop: CGFloat, auxLeft: CGRect?, auxRight: CGRect?) -> CGRect? {
        guard safeTop > 0, let left = auxLeft, let right = auxRight, right.minX - left.maxX > 1 else { return nil }
        return CGRect(x: left.maxX, y: screen.maxY - safeTop, width: right.minX - left.maxX, height: safeTop)
    }

    /// The menu bar's height on a display: the gap above its visible frame, or the standard height when it hides.
    public static func menuBarHeight(screen: CGRect, visible: CGRect) -> CGFloat {
        let h = screen.maxY - visible.maxY
        return h >= 1 ? h : standardMenuBar
    }

    /// The width a wing needs for its content: `inset` at the outer edge, and `notchGap` (or `inset` without a notch)
    /// on the inner edge. Zero content means no wing.
    public static func wing(content: CGFloat, inset: CGFloat, notch: Bool) -> CGFloat {
        guard content > 0 else { return 0 }
        return inset + content + (notch ? notchGap : inset)
    }

    /// The collapsed bar: exactly the menu bar's height. With a notch it wraps the housing, flush with the top edge,
    /// with a wing of its own width on each side (a zero-width wing is left out). Without one it hangs just under the
    /// menu bar, centred, as wide as both wings.
    public static func collapsed(screen: CGRect, visible: CGRect, housing: CGRect?, left: CGFloat, right: CGFloat) -> Layout {
        if let housing {
            let width = left + housing.width + right
            let frame = CGRect(x: housing.minX - left, y: screen.maxY - housing.height, width: width, height: housing.height)
            return Layout(frame: frame, housing: local(housing, in: frame), band: housing.height)
        }
        let height = menuBarHeight(screen: screen, visible: visible)
        let top = min(visible.maxY, screen.maxY)
        let width = left + right
        let x = clamp(screen.midX - width / 2, screen.minX, screen.maxX - width)
        return Layout(frame: CGRect(x: x, y: top - height, width: width, height: height), housing: nil, band: height)
    }

    /// The open panel: it grows right and down from the bar's top left corner, where Tug is, so Tug never moves. It
    /// keeps the bar's top edge, is never narrower than the bar, and stays on the screen.
    public static func expanded(from bar: Layout, size: CGSize, screen: CGRect) -> Layout {
        let width = min(max(size.width, bar.frame.width), screen.width)
        let height = min(max(size.height, bar.frame.height), bar.frame.maxY - screen.minY)
        let x = clamp(bar.frame.minX, screen.minX, screen.maxX - width)
        let frame = CGRect(x: x, y: bar.frame.maxY - height, width: width, height: height)
        let housing = bar.housing.map { h in
            local(CGRect(x: bar.frame.minX + h.minX, y: bar.frame.maxY - h.maxY, width: h.width, height: h.height), in: frame)
        }
        return Layout(frame: frame, housing: housing, band: bar.band)
    }

    /// The right wing shows only while the menu bar has room for it: the leftmost status item on the right of the
    /// notch (screen x), if any, starts beyond the wing.
    public static func rightWingFits(statusItemsMinX: CGFloat?, housingMaxX: CGFloat, width: CGFloat) -> Bool {
        guard let x = statusItemsMinX else { return true }
        return housingMaxX + width <= x
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

/// The top bar's status: one plain word beside Tug, Tug's face, and at most one small mark past the notch. A word is
/// one word (the packet's "Your turn" is the one two-word cue), short enough to stay clear of the notch.
public struct NotchBarStatus: Equatable, Sendable {
    public enum Mark: Equatable, Sendable {
        /// No right wing.
        case none
        /// The red record light, with the time held so far.
        case recordLight(String)
        case dots
        case wave
        /// An SF Symbol name, always beside a word.
        case symbol(String)
    }

    /// Tug's face in the bar, so the state reads at a glance without the word.
    public enum Face: Equatable, Sendable {
        /// Breathing and blinking.
        case rest
        /// Brows up.
        case listening
        /// Eyes closed.
        case thinking
        /// Mouth open, moving.
        case speaking
        /// The string held up: over to you.
        case turn
        /// No motion: a stop or a problem.
        case still
    }

    public let word: String
    public let mark: Mark
    public let face: Face
    /// "Your turn": the bar turns ink with sunflower text, so it looks different at a glance.
    public let inverted: Bool
    /// The open panel shows a card for this state.
    public let showsCard: Bool
    /// A card that opens the panel by itself shows one or two lines, and its full form on hover.
    public let compact: Bool
    /// How long a card that opened the panel by itself stays open with the pointer outside, in seconds. Nil: until
    /// the person acts on it (a permission step, a retry) or it closes.
    public let linger: Double?

    init(_ word: String, _ mark: Mark, _ face: Face, inverted: Bool = false, card: Bool = false, compact: Bool = false, linger: Double? = nil) {
        self.word = word; self.mark = mark; self.face = face; self.inverted = inverted
        self.showsCard = card; self.compact = compact; self.linger = linger
    }

    public static func make(_ input: NotchBarInput) -> NotchBarStatus {
        switch input {
        case .idle: return .init("Ready", .none, .rest)
        case .readingWindow: return .init("Reading", .dots, .listening)
        case .voiceListening(let s): return .init("Listening", .recordLight(clock(s)), .listening)
        case .thinking: return .init("Thinking", .dots, .thinking)
        case .contextCard(let talking):
            return talking ? .init("Speaking", .wave, .speaking, card: true, compact: true)
                           : .init("Saved", .symbol("checkmark"), .rest, card: true, compact: true, linger: 8)
        case .voiceReply(let finished, let endsRound):
            if !finished { return .init("Speaking", .wave, .speaking, card: true, compact: true) }
            if endsRound { return .init("Done", .symbol("checkmark"), .rest, card: true, compact: true, linger: 8) }
            // The question has been asked: the panel folds a second later so the bar shows whose turn it is.
            return .init("Your turn", .none, .turn, inverted: true, card: true, compact: true, linger: 1)
        case .nudge(let opened): return .init("Updated", .symbol("bell"), .rest, card: opened, compact: true, linger: 8)
        case .blocked: return .init("Blocked", .symbol("hand.raised"), .still)
        case .offline(let retryable): return .init("Offline", .symbol("wifi.slash"), .still, card: true, linger: retryable ? nil : 8)
        case .voiceError(let retryable): return .init("Failed", .symbol("exclamationmark.triangle"), .still, card: true, linger: retryable ? nil : 8)
        case .permission: return .init("Setup", .symbol("lock"), .rest, card: true)
        case .notice: return .init("Ready", .none, .rest, card: true, compact: true, linger: 4)
        case .hidden: return .init("Hidden", .symbol("eye.slash"), .still)
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
