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
    /// The window's owner at capture time: a reused window number must not get the ring.
    let windowPID: pid_t?
    let label: String
    /// The one sentence Tug says about it.
    let sentence: String
    let recordID: String

    /// Builds a request from a capture's lines and the card the coach wrote about them, or nil when no line
    /// is a clear match. Raw lines are only read here, on this Mac.
    static func make(lines: [TextLine], frame: CGRect?, windowID: CGWindowID?, windowBounds: CGRect?, windowPID: pid_t? = nil, card: ContextCard) -> PointingRequest? {
        guard let frame, let match = LineMatcher.bestLine(in: lines, summary: card.summary, observation: card.observation, nextStep: card.nextStep) else { return nil }
        let rect = ScreenMapping.globalTopLeftRect(normalized: lines[match.index].box, windowFrame: frame)
        return PointingRequest(line: rect, windowBounds: windowBounds ?? frame, windowID: windowID, windowPID: windowPID, label: match.label,
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

    /// Moves the floating card off the ring, if it covers it (AppKit rectangle). Set by the app.
    var avoid: (CGRect) -> Void = { _ in }

    init(model: CompanionModel) { self.model = model }

    var isShowing: Bool { panel != nil }

    func show(_ request: PointingRequest, speak: Bool = true) {
        dismiss()
        guard let main = NSScreen.screens.first else { return }
        let mainHeight = main.frame.height
        let ring = ScreenMapping.ringRect(around: ScreenMapping.appKitRect(fromGlobalTopLeft: request.line, mainDisplayHeight: mainHeight))
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(ring) }) ?? main
        let ringRect = ScreenMapping.pixelAligned(ring, scale: screen.backingScaleFactor)
        // Our own card must not sit on the line: move it aside first. Then check, fail-closed, that the
        // window is the one we read, unmoved, and that nothing else covers the line.
        avoid(ringRect.insetBy(dx: -12, dy: -12))
        ringGlobal = ScreenMapping.appKitRect(fromGlobalTopLeft: ringRect, mainDisplayHeight: mainHeight) // the same flip both ways
        let verdict = gate(request, ignoring: [])
        guard verdict == .clear else {
            captureLog.notice("no ring: \(String(describing: verdict), privacy: .public)")
            return
        }
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
        // Tug sits on the window's title bar and lowers the label on its string: decoration in this
        // overlay only. The real window is never moved.
        var perch: CGRect?
        if let bounds = request.windowBounds {
            let titleBar = ScreenMapping.appKitRect(fromGlobalTopLeft: CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: Self.titleBarHeight),
                                                    mainDisplayHeight: mainHeight)
            let side = PointingView.perchSide
            let spot = CGRect(x: label.midX - side / 2, y: titleBar.minY, width: side, height: side)
            // Clear of the window buttons, on the title bar, on screen, and above the label.
            let onBar = spot.minX > titleBar.minX + 80 && spot.maxX < titleBar.maxX - 8
            if onBar, screen.visibleFrame.contains(spot), spot.minY > label.maxY + 8 { perch = spot }
        }
        var frame = ringRect.union(label)
        if let perch { frame = frame.union(perch) }
        frame = frame.insetBy(dx: -12, dy: -12).intersection(screen.frame)
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
        let view = NSHostingView(rootView: PointingView(ring: local(ringRect), labelRect: local(label), perch: perch.map(local), label: request.label, placement: placement))
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

    /// The title bar's height for a standard window, in points.
    static let titleBarHeight: CGFloat = 28
    /// The ring in global top-left points, for the cover check.
    private var ringGlobal = CGRect.zero

    private func gate(_ request: PointingRequest, ignoring: Set<UInt32>) -> PointingGate.Verdict {
        guard let id = request.windowID, let bounds = request.windowBounds else { return .gone }
        let target = Self.record(of: id)
        return PointingGate.evaluate(target: target, expectedPID: request.windowPID ?? target?.pid ?? -1, expectedBounds: bounds,
                                     above: Self.windows(above: id), ring: ringGlobal, ignoring: ignoring)
    }

    private func tick() {
        guard let request else { return }
        let now = Date()
        // Close with the card.
        if case .speaking(let card) = model.phase, card.recordID == request.recordID {} else { dismiss(); return }
        // Checked again each time: the window moved, closed or was covered, so the ring would be wrong.
        let verdict = gate(request, ignoring: panel.map { [UInt32($0.windowNumber)] } ?? [])
        if verdict != .clear {
            captureLog.notice("ring removed: \(String(describing: verdict), privacy: .public)")
            fadeOut(); return
        }
        let age = now.timeIntervalSince(shownAt)
        if age > Self.maximumSeconds { dismiss(); return }
        if age > Self.minimumSeconds, !model.talking, now.timeIntervalSince(spokenUntil ?? shownAt) > Self.afterSpeech { fadeOut() }
    }

    private func fadeOut() {
        guard let panel else { return }
        watch?.invalidate(); watch = nil
        let reduce = Motion.reduceInAppKit
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

    /// One exact window record by number, or nil when it is gone or off screen. Owner, layer and bounds
    /// need no permission; titles are not read.
    static func record(of id: CGWindowID) -> PointingGate.WindowRecord? {
        var values: [UnsafeRawPointer?] = [UnsafeRawPointer(bitPattern: UInt(id))]
        guard let array = CFArrayCreate(nil, &values, 1, nil),
              let info = (CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]])?.first,
              (info[kCGWindowNumber as String] as? UInt32) == id,
              (info[kCGWindowIsOnscreen as String] as? Bool) == true else { return nil }
        return windowRecord(info)
    }

    /// The on-screen windows in front of a window, front to back.
    static func windows(above id: CGWindowID) -> [PointingGate.WindowRecord] {
        ((CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow], id) as? [[String: Any]]) ?? []).compactMap(windowRecord)
    }

    private static func windowRecord(_ info: [String: Any]) -> PointingGate.WindowRecord? {
        guard let number = info[kCGWindowNumber as String] as? UInt32,
              let dict = info[kCGWindowBounds as String] as? NSDictionary, let rect = CGRect(dictionaryRepresentation: dict) else { return nil }
        if let onscreen = info[kCGWindowIsOnscreen as String] as? Bool, !onscreen { return nil }
        return PointingGate.WindowRecord(id: number, pid: (info[kCGWindowOwnerPID as String] as? Int32) ?? -1, bounds: rect,
                                         layer: (info[kCGWindowLayer as String] as? Int) ?? 0, alpha: (info[kCGWindowAlpha as String] as? Double) ?? 1)
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

/// The ring and its label. Tug sits on the window's title bar and lowers the label on its string; then the
/// ring pops in around the line (drawn on, its stroke settling), and the label's string ties it to the ring.
/// No scale anywhere: the drop overshoots on position only. With Reduce Motion everything is a still that
/// crossfades in.
struct PointingView: View {
    enum Placement { case right, above, below }
    let ring: CGRect
    let labelRect: CGRect
    /// Where Tug sits on the title bar, in this view's coordinates, or nil when there is no room.
    let perch: CGRect?
    let label: String
    let placement: Placement
    @Environment(\.reduceMotionOn) private var reduceMotion
    @State private var drawn: CGFloat = 0
    @State private var ringWeight: CGFloat = 6
    @State private var ringShown = false
    @State private var dropped = false

    static let perchSide: CGFloat = 30
    /// For measuring only: the system bold face is a little wider than Hanken Grotesk 700, so the label always fits.
    static let labelFont = NSFont.systemFont(ofSize: 14, weight: .bold)

    /// The label's size: the small Tug, the words, the padding and the lip.
    static func labelSize(for text: String) -> CGSize {
        let width = (text as NSString).size(withAttributes: [.font: labelFont]).width
        return CGSize(width: ceil(6 + 22 + 7 + width * 1.04 + 12), height: 35)
    }

    /// Where the label starts: just under Tug on the title bar.
    private var labelStartY: CGFloat { perch.map { $0.maxY + 2 } ?? labelRect.minY - Motion.slotRise }
    private var labelY: CGFloat { dropped || reduceMotion ? labelRect.minY : labelStartY }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if let perch {
                HangingString(top: CGPoint(x: perch.midX, y: perch.maxY - 3), bottomY: labelY + 1)
                    .stroke(Color(Tok.inkFixed), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                TugCanvas(pose: Self.perchPose, facesRight: true)
                    .frame(width: perch.width, height: perch.height)
                    .offset(x: perch.minX, y: perch.minY)
            }
            let shape = RoundedRectangle(cornerRadius: min(ring.height / 2, 16), style: .continuous)
            Group {
                shape.trim(from: 0, to: drawn).stroke(Color(Tok.inkFixed), style: StrokeStyle(lineWidth: ringWeight, lineCap: .round))
                shape.trim(from: 0, to: drawn).stroke(Color(Tok.field), style: StrokeStyle(lineWidth: ringWeight * 0.53, lineCap: .round))
            }
            .frame(width: ring.width, height: ring.height).offset(x: ring.minX, y: ring.minY)
            .opacity(ringShown ? 1 : 0)
            leader.opacity(ringShown ? 1 : 0)
            labelView.offset(x: labelRect.minX, y: labelY).opacity(dropped || perch != nil ? 1 : 0)
        }
        .onAppear(perform: animateIn)
        .accessibilityHidden(true)
    }

    private func animateIn() {
        if reduceMotion {
            withAnimation(Motion.crossfade) { dropped = true; ringShown = true; drawn = 1; ringWeight = 6 }
            return
        }
        // The drop: about 0.45 s, overshooting on position only.
        withAnimation(.spring(duration: 0.45, bounce: 0.3)) { dropped = true }
        // The ring: in at once, drawn on over 0.3 s, its stroke settling from heavy to normal.
        withAnimation(.easeOut(duration: 0.06).delay(0.32)) { ringShown = true }
        withAnimation(.easeOut(duration: 0.3).delay(0.32)) { drawn = 1 }
        ringWeight = 9
        withAnimation(.spring(duration: 0.35, bounce: 0.2).delay(0.4)) { ringWeight = 6 }
    }

    /// Tug leaning back as it lowers the label, looking down at the line.
    static let perchPose: TugPose = {
        var p = TugPose(phase: .idle, t: 0, talking: false, animated: false)
        p.string = .none; p.lookY = 2.2; p.lean = -4; p.browNear = 0.8; p.browFar = 0.8; p.smile = 0.55
        return p
    }()

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

/// Tug's string hanging straight down to the label; its length animates with the drop.
struct HangingString: Shape {
    var top: CGPoint
    var bottomY: CGFloat
    var animatableData: CGFloat {
        get { bottomY }
        set { bottomY = newValue }
    }
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: top)
            p.addLine(to: CGPoint(x: top.x, y: max(top.y, bottomY)))
        }
    }
}
