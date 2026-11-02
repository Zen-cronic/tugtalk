import AppKit
import Combine
import ScreenContextCore
import SwiftUI

/// Docked mode ("Show in Dock"): a Dock icon with a live tile, and a docked panel next to the Dock that
/// Tug travels into. The menu-bar accessory mode stays the default. The rules are in `DockState`.
@MainActor
final class DockController {
    private let model: CompanionModel
    private(set) var state: DockState
    private var panel: NSPanel?
    private var traveller: NSPanel?
    private var travelTask: Task<Void, Never>?
    private var observers: Set<AnyCancellable> = []
    private var tileView: NSHostingView<DockTileView>?

    /// Where the floating Tug is, so the trip starts and ends there.
    var floatingTugCenter: () -> CGPoint = { .zero }
    var onTalkDown: () -> Void = {}
    var onTalkUp: () -> Void = {}
    /// The panel's Talk hold ended without a release: close the microphone and send nothing.
    var onTalkCancel: () -> Void = {}
    /// Talk is held down in the panel.
    private var talkHeld = false
    var onReadWindow: () -> Void = {}

    init(model: CompanionModel) {
        self.model = model
        state = DockState(enabled: Settings.dockMode)
        model.$phase.receive(on: RunLoop.main).sink { [weak self] phase in self?.phaseChanged(phase) }.store(in: &observers)
        model.$presenting.receive(on: RunLoop.main).sink { [weak self] hidden in
            self?.state.hidden = hidden
            self?.refreshTile()
        }.store(in: &observers)
        apply(animated: false)
    }

    // Mode

    func setEnabled(_ on: Bool) {
        Settings.dockMode = on
        if !on { closePanel(animated: false) }
        state.setEnabled(on)
        apply(animated: false)
    }

    private func apply(animated: Bool) {
        if state.showsDockIcon {
            NSApp.setActivationPolicy(.regular)
            NSApp.applicationIconImage = DockIcon.image(size: 512)
            installTile()
        } else {
            NSApp.dockTile.contentView = nil
            tileView = nil
            NSApp.setActivationPolicy(.accessory)
        }
        model.dockedPanelOpen = state.panelOpen
        refreshTile()
    }

    // The tile

    private func installTile() {
        guard tileView == nil else { return }
        let size = NSApp.dockTile.size
        let view = NSHostingView(rootView: DockTileView(phase: model.phase, badge: state.badge, liveDot: state.showsLiveDot))
        view.frame = NSRect(origin: .zero, size: size)
        NSApp.dockTile.contentView = view
        tileView = view
    }

    private func refreshTile() {
        guard let tileView else { return }
        tileView.rootView = DockTileView(phase: model.phase, badge: state.badge, liveDot: state.showsLiveDot)
        tileView.needsDisplay = true
        NSApp.dockTile.display()
        tileView.setAccessibilityLabel(tileLabel)
    }

    private var tileLabel: String {
        var parts = ["\(MascotName): \(model.phase.pill().word)"]
        if let badge = state.badge { parts.append("\(badge) new in your record") }
        if state.showsLiveDot { parts.append("microphone open") }
        return parts.joined(separator: ", ")
    }

    private func phaseChanged(_ phase: MascotPhase) {
        state.recording = { if case .voiceListening = phase { return true } else { return false } }()
        if case .nudging(_, false) = phase { state.nudgeArrived() }
        // Cards that need the full floating window (errors, permission explainers, a window card) take
        // Tug back out of the panel. A spoken round stays in the panel.
        if state.panelOpen, phase.showsBubble, !phase.isVoiceTurn { closePanel(animated: true) }
        refreshTile()
    }

    // The docked panel

    /// The rule (open, or close if open; nothing outside docked mode) is `DockState.dockIconClicked`.
    func dockIconClicked() {
        let wasFloating = state.floatingTugVisible
        state.dockIconClicked()
        if state.panelOpen, panel == nil { presentPanel(wasFloating: wasFloating) }
        else if !state.panelOpen, panel != nil { closePanel(animated: true) }
    }

    func openPanel() {
        guard state.enabled, panel == nil else { return }
        let wasFloating = state.floatingTugVisible
        state.openPanel()
        presentPanel(wasFloating: wasFloating)
    }

    private func presentPanel(wasFloating: Bool) {
        let start = floatingTugCenter()
        let view = NSHostingView(rootView: DockPanelView(model: model, onTalkDown: { [weak self] in self?.talkHeld = true; self?.onTalkDown() },
                                                         onTalkUp: { [weak self] in self?.talkReleased() },
                                                         onReadWindow: { [weak self] in self?.readWindow() },
                                                         onClose: { [weak self] in self?.closePanel(animated: true) }))
        let size = view.fittingSize
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main ?? NSScreen.screens[0]
        let edge = DockPlacement.edge(screen: screen.frame, visible: screen.visibleFrame)
        let origin = DockPlacement.panelOrigin(size: size, edge: edge, visible: screen.visibleFrame, pointer: NSEvent.mouseLocation)
        let panel = DockPanel(contentRect: NSRect(origin: origin, size: size))
        panel.contentView = view
        panel.onClose = { [weak self] in self?.closePanel(animated: true) }
        panel.onResignKey = { [weak self] in self?.cancelTalk() }
        self.panel = panel
        let end = CGPoint(x: origin.x + DockPanelView.tugCenter.x, y: origin.y + size.height - DockPanelView.tugCenter.y)
        model.dockedPanelOpen = true
        model.tugInPanel = false
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.16; panel.animator().alphaValue = 1 }
        travel(from: wasFloating ? start : nil, to: end) { [weak self] in self?.model.tugInPanel = true }
        refreshTile()
    }

    /// A release from the panel's Talk button. Ignored after the hold was cancelled, so it never sends.
    private func talkReleased() {
        guard talkHeld else { return }
        talkHeld = false
        onTalkUp()
    }

    /// The app lost focus, or the panel is closing, while Talk is held: the release will never come.
    func cancelTalk() {
        guard talkHeld else { return }
        talkHeld = false
        onTalkCancel()
    }

    func closePanel(animated: Bool) {
        cancelTalk()
        guard let panel else { return }
        let from = CGPoint(x: panel.frame.minX + DockPanelView.tugCenter.x, y: panel.frame.maxY - DockPanelView.tugCenter.y)
        self.panel = nil
        state.closePanel()
        model.tugInPanel = false
        panel.orderOut(nil)
        let to = floatingTugCenter()
        let finish = { [weak self] in
            guard let self else { return }
            self.model.dockedPanelOpen = false
            self.refreshTile()
        }
        if animated && !state.hidden { travel(from: from, to: to, completion: finish) } else { finish() }
    }

    private func readWindow() {
        closePanel(animated: true)
        onReadWindow()
    }

    // Travel: a short hop along an arc, about 0.4 s. With Reduce Motion there is no trip: Tug just appears.

    private func travel(from start: CGPoint?, to end: CGPoint, completion: @escaping () -> Void) {
        travelTask?.cancel(); traveller?.orderOut(nil); traveller = nil
        guard let start, !Motion.reduceInAppKit else { completion(); return }
        let side = MascotLayout.character
        let hop = NSPanel(contentRect: NSRect(x: start.x - side / 2, y: start.y - side / 2, width: side, height: side),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hop.level = .popUpMenu
        hop.isOpaque = false; hop.backgroundColor = .clear; hop.hasShadow = false; hop.ignoresMouseEvents = true
        hop.contentView = NSHostingView(rootView: TugView(phase: .nudging(PreviewSamples.nudge, opened: true), facesRight: end.x >= start.x)
            .frame(width: side, height: side))
        hop.orderFrontRegardless()
        traveller = hop
        let began = Date(), duration = 0.42
        let lift = max(60, abs(end.x - start.x) * 0.25)
        travelTask = Task { @MainActor [weak self] in
            while true {
                let k = min(1, Date().timeIntervalSince(began) / duration)
                let e = k < 0.5 ? 2 * k * k : 1 - pow(-2 * k + 2, 2) / 2
                let control = CGPoint(x: (start.x + end.x) / 2, y: max(start.y, end.y) + lift)
                let x = pow(1 - e, 2) * start.x + 2 * (1 - e) * e * control.x + e * e * end.x
                let y = pow(1 - e, 2) * start.y + 2 * (1 - e) * e * control.y + e * e * end.y
                hop.setFrameOrigin(NSPoint(x: x - side / 2, y: y - side / 2))
                if k >= 1 || Task.isCancelled { break }
                try? await Task.sleep(for: .milliseconds(16))
            }
            hop.orderOut(nil)
            guard !Task.isCancelled else { return }
            self?.traveller = nil
            completion()
        }
    }
}

extension MascotPhase {
    /// The hold-to-talk turn, which the docked panel can show itself.
    var isVoiceTurn: Bool {
        switch self {
        case .voiceListening, .voiceThinking, .voiceSpeaking: true
        default: false
        }
    }
}

/// The docked panel's window: a key panel (so its buttons work from the keyboard) that closes on Esc.
final class DockPanel: NSPanel {
    var onClose: () -> Void = {}
    /// The panel stopped taking the keyboard (another app or window came forward).
    var onResignKey: () -> Void = {}

    init(contentRect: NSRect) {
        // Non-activating, like the floating Tug: it appears over a full-screen app without switching Spaces,
        // and still takes keyboard focus for its buttons and Esc.
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Closed by the app when it stops being active (Tug travels back), not hidden in place.
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        setAccessibilityLabel("\(MascotName) docked panel")
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onClose() }
    override func resignKey() { super.resignKey(); onResignKey() }
}

/// Tug, larger, with its status, the latest spoken round, and four actions.
struct DockPanelView: View {
    @ObservedObject var model: CompanionModel
    var onTalkDown: () -> Void
    var onTalkUp: () -> Void
    var onReadWindow: () -> Void
    var onClose: () -> Void
    @State private var holding = false
    @Environment(\.reduceMotionOn) private var reduceMotion

    static let width: CGFloat = 360
    static let tugSide: CGFloat = 92
    /// Tug's centre from the panel's top left, for the trip in and out.
    static let tugCenter = CGPoint(x: 14 + tugSide / 2, y: 12 + tugSide / 2)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 14) {
                latestRound
                actions
            }
            .padding(16)
        }
        .frame(width: Self.width)
        .cartLabel()
        .padding(.bottom, 4)
    }

    private var status: (word: String, hint: String?) {
        let pill = model.phase.pill()
        switch model.phase {
        case .idle: return ("Ready", "Hold ⌃⌥T and talk")
        case .voiceSpeaking(let card) where card.finished && !card.endsRound: return ("Your turn", "Hold ⌃⌥T to answer")
        case .nudging(let nudge, _): return ("New in your record", nudge.detail)
        default: return (pill.word, pill.detail)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                if model.tugInPanel || reduceMotion {
                    TugView(phase: model.phase, talking: model.talking, facesRight: true)
                        .transition(.opacity.animation(Motion.fade))
                }
            }
            .frame(width: Self.tugSide, height: Self.tugSide)
            // On sunflower the string is ink in both looks.
            .environment(\.colorScheme, .light)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(MascotName), \(status.word)")
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if case .voiceListening = model.phase { RecordDot() }
                    Text(noWidow(status.word)).font(TypeFace.display(22, weight: 800)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                if let hint = status.hint {
                    if hint.contains("⌃⌥") { ShortcutLine(text: hint, font: TypeFace.body(14, weight: 600), ink: Tok.inkFixed) }
                    else { Text(hint).font(TypeFace.body(14, weight: 600)).fixedSize(horizontal: false, vertical: true) }
                }
            }
            .foregroundStyle(Color(Tok.inkFixed))
            .layoutPriority(1)
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).frame(width: 32, height: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(Color(Tok.inkFixed))
            .accessibilityLabel("Close")
        }
        .padding(.leading, 14).padding(.trailing, 10).padding(.vertical, 12)
        .background(Color(Tok.field))
        .overlay(alignment: .bottom) { Rectangle().fill(Color(Tok.cardEdge).opacity(0.5)).frame(height: 1) }
    }

    @ViewBuilder private var latestRound: some View {
        if let card = model.latestVoiceCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Latest round").font(TypeFace.body(12, weight: 600)).foregroundStyle(Color(Tok.muted))
                    Spacer()
                    if let round = card.round { Text("Round \(round)").font(TypeFace.body(12, weight: 600)).foregroundStyle(Color(Tok.muted)) }
                }
                if let quote = card.quote { QuoteTag(quote: quote) }
                if let number = LatestRoundNumber.make(summary: card.summary, latest: card.metrics) {
                    BigNumberTile(number: number)
                }
                SampleTag(isPreview: card.isPreview, text: card.summary == nil ? "Sample answer" : "Sample numbers")
            }
        } else {
            Instruction(label: "No spoken round yet", text: "Hold Talk below, or the talk keys, and answer out loud.")
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                talkButton
                Button("Read This Window", action: onReadWindow).buttonStyle(CartButtonStyle(primary: false, fill: true))
                    .accessibilityHint("Reads the window you were using, like Control-Option-Space.")
            }
            HStack(spacing: 8) {
                // Only when there is a card for Muse to open.
                if model.lastCard != nil {
                    Button("Ask Muse") { model.onAskMuse() }.buttonStyle(CartButtonStyle(primary: false))
                }
                Spacer()
                Button(model.presenting ? "Show Tug" : "Hide Tug") { model.presenting.toggle(); if model.presenting { onClose() } }
                    .buttonStyle(TextButtonStyle())
                    .accessibilityHint(model.presenting ? "Shows Tug again." : "Hides Tug, like Control-Option-H.")
            }
        }
    }

    /// Hold to talk, like holding ⌃⌥T: pressing opens the microphone, letting go sends the answer.
    private var talkButton: some View {
        HStack(spacing: 7) {
            if holding { RecordDot() } else { Image(systemName: "mic.fill").font(.system(size: 13, weight: .bold)) }
            Text(holding ? "Listening" : "Talk").font(TypeFace.body(14, weight: 650))
        }
        .foregroundStyle(Color(Tok.onAction))
        .padding(.horizontal, 16).frame(maxWidth: .infinity, minHeight: 32)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(Tok.action)))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in if !holding { holding = true; onTalkDown() } }
            .onEnded { _ in holding = false; onTalkUp() })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Talk")
        .accessibilityHint("Hold to talk, let go to send. Control-Option-T does the same.")
        .accessibilityAddTraits(.isButton)
    }
}

/// The Dock tile: Tug on a sunflower tile in its current state, an ink count for new changes to the
/// record, and the red record light while the microphone is open (top right; the count moves left of it).
struct DockTileView: View {
    let phase: MascotPhase
    let badge: String?
    let liveDot: Bool

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                DockIconArt(phase: phase, size: s).frame(width: s, height: s)
                if liveDot {
                    ZStack {
                        Circle().fill(Color(Tok.labelWhite)).frame(width: s * 0.24, height: s * 0.24)
                        Circle().fill(Color(Tok.record)).frame(width: s * 0.17, height: s * 0.17)
                    }
                    .position(x: s * 0.84, y: s * 0.16)
                    .accessibilityLabel("Recording")
                }
                if let badge {
                    Text(badge).font(TypeFace.body(s * 0.18, weight: 800)).foregroundStyle(Color(Tok.labelWhite))
                        .padding(.horizontal, s * 0.06).frame(minWidth: s * 0.27, minHeight: s * 0.27)
                        .background(Capsule().fill(Color(Tok.inkFixed)))
                        .overlay(Capsule().strokeBorder(Color(Tok.labelWhite), lineWidth: s * 0.02))
                        .position(x: liveDot ? s * 0.6 : s * 0.84, y: s * 0.16)
                }
            }
        }
        .environment(\.colorScheme, .light)
    }
}

/// The icon art: a sunflower tile on the standard icon grid (no outline, no offset shadow), with the can
/// centred and its string kept inside the tile. At 32 pt and below it uses the small one-colour Tug.
struct DockIconArt: View {
    let phase: MascotPhase
    var size: CGFloat = 128

    var body: some View {
        let tile = size * 0.8125            // the macOS icon grid: an 832 tile on a 1024 canvas
        let shape = RoundedRectangle(cornerRadius: tile * 0.225, style: .continuous)
        ZStack {
            shape.fill(Color(Tok.field)).frame(width: tile, height: tile)
            if size <= 32 {
                Image(nsImage: TugGlyph.image(size: tile * 0.72, color: Tok.inkFixed)).frame(width: tile * 0.72, height: tile * 0.72)
            } else {
                // The drawing's can is centred in its square, and its string ends inside it.
                TugCanvas(pose: TugPose(phase: phase, t: 0.35, talking: false, animated: false), facesRight: true)
                    .frame(width: tile * 0.82, height: tile * 0.82)
            }
        }
        .frame(width: size, height: size)
    }
}

/// The static app icon (app switcher, Finder), rendered from the same art.
@MainActor
enum DockIcon {
    static func image(size: CGFloat) -> NSImage {
        let renderer = ImageRenderer(content: DockIconArt(phase: .idle, size: size).environment(\.colorScheme, .light))
        renderer.scale = 1
        return renderer.nsImage ?? NSImage(size: NSSize(width: size, height: size))
    }
}

#if DEBUG
/// DEBUG `-dockTileSnapshots <dir>`: renders the Dock tile's states to PNG files (128 pt at 2x), with the
/// same view the Dock shows, for checking them by eye.
@MainActor
enum DockSnapshots {
    static func write(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cases: [(String, MascotPhase, String?, Bool)] = [
            ("dock-tile-idle", .idle, nil, false),
            ("dock-tile-badge", .idle, "2", false),
            ("dock-tile-badge-9plus", .nudging(PreviewSamples.nudge, opened: false), "9+", false),
            ("dock-tile-recording", .voiceListening(since: Date()), nil, true),
            ("dock-tile-thinking", .voiceThinking(since: Date()), nil, false),
            ("dock-tile-offline", .offline("Offline", retryable: false), nil, false),
        ]
        for (name, phase, badge, dot) in cases {
            let renderer = ImageRenderer(content: DockTileView(phase: phase, badge: badge, liveDot: dot).frame(width: 128, height: 128))
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: dir.appending(path: "\(name).png"))
        }
        // The small sizes the Dock and Finder use.
        for size in [16.0, 32.0, 64.0] {
            let renderer = ImageRenderer(content: DockIconArt(phase: .idle, size: size))
            renderer.scale = 2
            if let tiff = renderer.nsImage?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appending(path: "dock-icon-\(Int(size))pt.png"))
            }
        }
    }
}
#endif
