import CoreGraphics
import Foundation

/// The docked mode's rules, kept free of AppKit so they are unit-tested: whether the app shows a Dock icon,
/// what its tile shows, and whether Tug floats or sits in the docked panel.
public struct DockState: Equatable, Sendable {
    /// "Show in Dock" is on.
    public private(set) var enabled: Bool
    public private(set) var panelOpen = false
    /// The microphone is open (⌃⌥T held).
    public var recording = false
    /// Changes Muse or the watch made to the shared record since the panel was last opened.
    public private(set) var unseenNudges = 0
    /// Presenting: Tug is hidden everywhere.
    public var hidden = false

    public init(enabled: Bool) { self.enabled = enabled }

    /// A Dock icon only in docked mode; the menu-bar accessory mode stays the default.
    public var showsDockIcon: Bool { enabled }

    /// The tile's count: nothing at zero, then 1 to 9, then "9+".
    public var badge: String? {
        guard enabled, unseenNudges > 0 else { return nil }
        return unseenNudges > 9 ? "9+" : String(unseenNudges)
    }

    /// The small live dot on the tile while the microphone is open.
    public var showsLiveDot: Bool { enabled && recording }

    /// Tug floats beside the work unless it has travelled into the open docked panel, or is hidden.
    public var floatingTugVisible: Bool { !hidden && !(enabled && panelOpen) }

    public mutating func setEnabled(_ on: Bool) {
        enabled = on
        if !on { panelOpen = false; unseenNudges = 0 }
    }

    /// A nudge counts only while nobody is looking at the panel.
    public mutating func nudgeArrived() {
        guard enabled, !panelOpen else { return }
        unseenNudges += 1
    }

    /// Opening the panel shows the record, so the count clears.
    public mutating func openPanel() {
        guard enabled else { return }
        panelOpen = true
        unseenNudges = 0
    }

    public mutating func closePanel() { panelOpen = false }

    /// The Dock icon was clicked: open the panel, or close it if it is open.
    public mutating func dockIconClicked() {
        if panelOpen { closePanel() } else { openPanel() }
    }
}

/// Where the docked panel goes: next to the Dock, near the icon that was clicked.
public enum DockPlacement {
    public enum Edge: Equatable, Sendable { case bottom, left, right, hidden }

    /// Which edge the Dock is on, from a display's frame and its visible frame (AppKit coordinates, y up).
    /// The menu bar trims only the top, so it never reads as a Dock. A hidden Dock trims nothing.
    public static func edge(screen: CGRect, visible: CGRect) -> Edge {
        if visible.minY - screen.minY > 2 { return .bottom }
        if visible.minX - screen.minX > 2 { return .left }
        if screen.maxX - visible.maxX > 2 { return .right }
        return .hidden
    }

    /// The panel's origin (bottom left, AppKit coordinates): against the Dock edge, centred on the pointer
    /// (which is over the Dock icon after a click), and kept inside the visible frame.
    public static func panelOrigin(size: CGSize, edge: Edge, visible: CGRect, pointer: CGPoint, gap: CGFloat = 8) -> CGPoint {
        func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(max(v, lo), max(lo, hi)) }
        switch edge {
        case .bottom, .hidden:
            return CGPoint(x: clamp(pointer.x - size.width / 2, visible.minX + gap, visible.maxX - size.width - gap), y: visible.minY + gap)
        case .left:
            return CGPoint(x: visible.minX + gap, y: clamp(pointer.y - size.height / 2, visible.minY + gap, visible.maxY - size.height - gap))
        case .right:
            return CGPoint(x: visible.maxX - size.width - gap, y: clamp(pointer.y - size.height / 2, visible.minY + gap, visible.maxY - size.height - gap))
        }
    }
}

/// The one big number on the docked panel's latest-round card: the round summary when the round is done,
/// otherwise the most-used habit in the latest answer. From code-measured metrics only.
public struct LatestRoundNumber: Equatable, Sendable {
    public let value: Int
    public let habit: RoundSummary.Habit
    /// "down from 2 in your first answer", or "in your last answer".
    public let caption: String
    /// The round ended with fewer than it started with: good news, never shown in an alarm colour.
    public var improved = false

    public static func make(summary: RoundSummary?, latest: VoiceMetrics?) -> LatestRoundNumber? {
        if let s = summary {
            return LatestRoundNumber(value: s.last, habit: s.habit,
                                     caption: s.dropped ? "down from \(s.first) in your first answer" : "in your last answer", improved: s.dropped)
        }
        guard let m = latest else { return nil }
        let counts: [(RoundSummary.Habit, Int?)] = [(.filler, m.filler_count), (.hedge, m.hedge_count), (.restart, m.restart_count)]
        guard let top = counts.compactMap({ h, n in n.map { (h, $0) } }).max(by: { $0.1 < $1.1 }) else { return nil }
        return LatestRoundNumber(value: top.1, habit: top.0, caption: "in your last answer")
    }
}
