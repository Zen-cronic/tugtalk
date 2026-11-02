import AppKit
import Carbon.HIToolbox
import ScreenContextCore
import SwiftUI

/// What to point at: one line of a captured window, already chosen by code (`LineMatcher`).
struct PointingRequest {
    /// The line's box in global display points, origin at the main display's top left.
    let line: CGRect
    /// The captured window's bounds at capture time (same convention), to notice a move.
    let windowBounds: CGRect?
    let windowID: CGWindowID?
    let label: String
    /// The one sentence Tug says about it.
    let sentence: String
    let recordID: String

    /// Builds a request from a capture's lines and the card the coach wrote about them, or nil when no line
    /// is a clear match. Raw lines are only read here, on this Mac.
    static func make(lines: [TextLine], frame: CGRect?, windowID: CGWindowID?, windowBounds: CGRect?, card: ContextCard) -> PointingRequest? {
        guard let frame, let match = LineMatcher.bestLine(in: lines, summary: card.summary, observation: card.observation, nextStep: card.nextStep) else { return nil }
        let rect = ScreenMapping.globalTopLeftRect(normalized: lines[match.index].box, windowFrame: frame)
        return PointingRequest(line: rect, windowBounds: windowBounds ?? frame, windowID: windowID, label: match.label,
                               sentence: firstSentence(card.observation), recordID: card.recordID)
    }

    /// The card's observation up to its first full stop, at most 24 words.
    static func firstSentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var sentence = trimmed
        if let end = trimmed.firstIndex(where: { ".!?".contains($0) }) { sentence = String(trimmed[...end]) }
        let words = sentence.split(separator: " ")
        return words.count > 24 ? words.prefix(24).joined(separator: " ") + "." : sentence
    }
}

/// A transparent, click-through window over the captured window that rings one line and labels it.
/// Nothing is captured or sent for this; it draws boxes Vision already found on this Mac.
/// It goes away after a few seconds (about 1 s after Tug finishes the sentence), on Esc, when the
/// window moves or closes, or when the card is closed.
@MainActor
final class PointingController {
    private var panel: NSPanel?
    private var request: PointingRequest?
    private var shownAt = Date.distantPast
    private var spokenUntil: Date?
    private var watch: Timer?
    private var escape: EventHotKeyRef?
    private let model: CompanionModel
    private let speaker = AppleSpeaker()

    static let minimumSeconds: TimeInterval = 4
    static let maximumSeconds: TimeInterval = 12
    static let afterSpeech: TimeInterval = 1

    init(model: CompanionModel) { self.model = model }

    var isShowing: Bool { panel != nil }

    func show(_ request: PointingRequest, speak: Bool = true) {
        dismiss()
        guard let main = NSScreen.screens.first else { return }
        let ring = ScreenMapping.ringRect(around: ScreenMapping.appKitRect(fromGlobalTopLeft: request.line, mainDisplayHeight: main.frame.height))
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(ring) }) ?? main
        let ringRect = ScreenMapping.pixelAligned(ring, scale: screen.backingScaleFactor)
        // The label goes beside the end of the line when there is room on that display (it covers the
        // least text there), otherwise above the ring, otherwise below it.
        let labelSize = PointingView.labelSize(for: request.label)
        let room = screen.visibleFrame
        let label: CGRect
        let placement: PointingView.Placement
        if ringRect.maxX + 28 + labelSize.width < room.maxX - 8 {
            placement = .right
            label = CGRect(x: ringRect.maxX + 28, y: ringRect.midY - labelSize.height / 2, width: labelSize.width, height: labelSize.height)
        } else if ringRect.maxY + 22 + labelSize.height < room.maxY {
            placement = .above
            label = CGRect(x: max(room.minX + 8, ringRect.minX + 6), y: ringRect.maxY + 22, width: labelSize.width, height: labelSize.height)
        } else {
            placement = .below
            label = CGRect(x: max(room.minX + 8, ringRect.minX + 6), y: ringRect.minY - 22 - labelSize.height, width: labelSize.width, height: labelSize.height)
        }
        let frame = ringRect.union(label).insetBy(dx: -12, dy: -12).intersection(screen.frame)
        func local(_ r: CGRect) -> CGRect { CGRect(x: r.minX - frame.minX, y: frame.maxY - r.maxY, width: r.width, height: r.height) }
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isExcludedFromWindowsMenu = true
        panel.setAccessibilityElement(false)
        let view = NSHostingView(rootView: PointingView(ring: local(ringRect), labelRect: local(label), label: request.label, placement: placement))
        view.frame = NSRect(origin: .zero, size: frame.size)
        panel.contentView = view
        panel.orderFrontRegardless()
        self.panel = panel
        self.request = request
        shownAt = Date()
        spokenUntil = nil
        model.pointing = true
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: "\(request.label) on your window. \(request.sentence)", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        registerEscape()
        watch = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        if speak { say(request.sentence) }
    }

    private func say(_ sentence: String) {
        model.talking = true
        speaker.speak(SpokenLine(text: sentence, language: .en, roundID: nil), events: SpeechEvents(
            started: { _ in },
            finished: { [weak self] ended in self?.spokenUntil = ended; self?.model.talking = false },
            failed: { [weak self] _ in self?.spokenUntil = Date(); self?.model.talking = false }))
    }

    private func tick() {
        guard let request else { return }
        let now = Date()
        // Close with the card.
        if case .speaking(let card) = model.phase, card.recordID == request.recordID {} else { dismiss(); return }
        // The window moved, resized or closed: the ring would be in the wrong place.
        if let id = request.windowID, let old = request.windowBounds {
            guard let bounds = Self.bounds(of: id), !ScreenMapping.hasMoved(from: old, to: bounds) else { dismiss(); return }
        }
        let age = now.timeIntervalSince(shownAt)
        if age > Self.maximumSeconds { dismiss(); return }
        if age > Self.minimumSeconds, !model.talking, now.timeIntervalSince(spokenUntil ?? shownAt) > Self.afterSpeech { fadeOut() }
    }

    private func fadeOut() {
        guard let panel else { return }
        watch?.invalidate(); watch = nil
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup({ $0.duration = reduce ? 0.15 : 0.3; panel.animator().alphaValue = 0 }) { [weak self] in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    func dismiss() {
        watch?.invalidate(); watch = nil
        if let escape { UnregisterEventHotKey(escape); self.escape = nil }
        Hotkeys.setEscapeAction(nil)
        if model.talking { speaker.stop(); model.talking = false }
        panel?.orderOut(nil)
        panel = nil
        request = nil
        if model.pointing { model.pointing = false }
    }

    /// Esc, with no modifiers, only while the ring is showing. A Carbon hotkey: no Accessibility permission.
    private func registerEscape() {
        Hotkeys.setEscapeAction { [weak self] in self?.dismiss() }
        var ref: EventHotKeyRef?
        if RegisterEventHotKey(UInt32(kVK_Escape), 0, EventHotKeyID(signature: OSType(0x4343_4D43), id: Hotkeys.escapeID), GetApplicationEventTarget(), 0, &ref) == noErr {
            escape = ref
        }
    }

    /// A window's current bounds (global, top-left), or nil when it is gone. Bounds need no permission.
    static func bounds(of id: CGWindowID) -> CGRect? {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
              (info[kCGWindowIsOnscreen as String] as? Bool) == true,
              let dict = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: dict) else { return nil }
        return rect
    }
}

/// The ring and its label. The ring is sunflower with an ink edge so it reads on light and dark windows;
/// the label is a white cart label tied to the ring by a short length of Tug's string.
struct PointingView: View {
    enum Placement { case right, above, below }
    let ring: CGRect
    let labelRect: CGRect
    let label: String
    let placement: Placement
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn: CGFloat = 0
    @State private var labelShown = false

    /// For measuring only: the system bold face is a little wider than Hanken Grotesk 700, so the label always fits.
    static let labelFont = NSFont.systemFont(ofSize: 14, weight: .bold)

    /// The label's size: the small Tug, the words, the padding and the lip.
    static func labelSize(for text: String) -> CGSize {
        let width = (text as NSString).size(withAttributes: [.font: labelFont]).width
        return CGSize(width: ceil(6 + 22 + 7 + width * 1.04 + 12), height: 35)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            let shape = RoundedRectangle(cornerRadius: min(ring.height / 2, 16), style: .continuous)
            Color.clear
            shape.trim(from: 0, to: drawn).stroke(Color(Tok.inkFixed), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .frame(width: ring.width, height: ring.height).offset(x: ring.minX, y: ring.minY)
            shape.trim(from: 0, to: drawn).stroke(Color(Tok.field), style: StrokeStyle(lineWidth: 3.2, lineCap: .round))
                .frame(width: ring.width, height: ring.height).offset(x: ring.minX, y: ring.minY)
            leader.opacity(labelShown ? 1 : 0)
            labelView
                .offset(x: labelRect.minX, y: labelRect.minY + (labelShown || reduceMotion ? 0 : Motion.slotRise))
                .opacity(labelShown ? 1 : 0)
        }
        .onAppear {
            if reduceMotion {
                withAnimation(Motion.crossfade) { drawn = 1; labelShown = true }
            } else {
                withAnimation(.easeOut(duration: 0.32)) { drawn = 1 }
                withAnimation(Motion.slot.delay(0.22)) { labelShown = true }
            }
        }
        .accessibilityHidden(true)
    }

    private var labelView: some View {
        HStack(spacing: 7) {
            // At this size Tug is the small one-colour drawing.
            Image(nsImage: TugGlyph.image(size: 22, color: Tok.inkFixed)).frame(width: 22, height: 22)
            Text(label).font(TypeFace.body(14, weight: 700)).foregroundStyle(Color(Tok.inkFixed)).lineLimit(1)
        }
        .padding(.leading, 6).padding(.trailing, 12).frame(height: 32)
        .cartLabel(radius: 10, lip: 3, fill: Tok.labelWhite, edge: Tok.inkFixed, lipColor: Tok.inkFixed)
        .environment(\.colorScheme, .light)
        .fixedSize()
    }

    /// A short length of Tug's string from the label to the ring.
    private var leader: some View {
        Path { p in
            switch placement {
            case .right:
                let a = CGPoint(x: labelRect.minX + 1, y: labelRect.minY + 16), b = CGPoint(x: ring.maxX + 2, y: ring.midY)
                p.move(to: a)
                p.addQuadCurve(to: b, control: CGPoint(x: (a.x + b.x) / 2, y: max(a.y, b.y) + 9))
            case .above, .below:
                let a = CGPoint(x: labelRect.minX + 22, y: placement == .above ? labelRect.maxY - 1 : labelRect.minY + 1)
                let b = CGPoint(x: a.x + 14, y: placement == .above ? ring.minY - 1 : ring.maxY + 1)
                p.move(to: a)
                p.addQuadCurve(to: b, control: CGPoint(x: a.x - 6, y: (a.y + b.y) / 2 + 4))
            }
        }
        .stroke(Color(Tok.inkFixed), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
    }
}
