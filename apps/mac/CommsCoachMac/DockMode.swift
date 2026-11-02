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

    func dockIconClicked() {
        guard state.enabled else { return }
        if state.panelOpen { closePanel(animated: true) } else { openPanel() }
    }

    func openPanel() {
        guard state.enabled, panel == nil else { return }
        let start = floatingTugCenter(), wasFloating = state.floatingTugVisible
        state.openPanel()
        let view = NSHostingView(rootView: DockPanelView(model: model, onTalkDown: { [weak self] in self?.onTalkDown() },
                                                         onTalkUp: { [weak self] in self?.onTalkUp() },
                                                         onReadWindow: { [weak self] in self?.readWindow() },
                                                         onClose: { [weak self] in self?.closePanel(animated: true) }))
        let size = view.fittingSize
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main ?? NSScreen.screens[0]
        let edge = DockPlacement.edge(screen: screen.frame, visible: screen.visibleFrame)
        let origin = DockPlacement.panelOrigin(size: size, edge: edge, visible: screen.visibleFrame, pointer: NSEvent.mouseLocation)
        let panel = DockPanel(contentRect: NSRect(origin: origin, size: size))
        panel.contentView = view
        panel.onClose = { [weak self] in self?.closePanel(animated: true) }
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

    func closePanel(animated: Bool) {
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
                Text(noWidow(status.word)).font(TypeFace.display(22, weight: 800)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if let hint = status.hint { Text(hint).font(TypeFace.body(14, weight: 600)).fixedSize(horizontal: false, vertical: true) }
            }
            .foregroundStyle(Color(Tok.inkFixed))
            Spacer(minLength: 4)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).frame(width: 32, height: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(Color(Tok.inkFixed))
            .accessibilityLabel("Close")
        }
        .padding(.leading, 14).padding(.trailing, 10).padding(.vertical, 12)
        .background(Color(Tok.field))
        .overlay(alignment: .bottom) { Rectangle().fill(Color(Tok.cardEdge)).frame(height: 1.5) }
    }

    @ViewBuilder private var latestRound: some View {
        if let card = model.latestVoiceCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Latest round").font(TypeFace.body(12, weight: 600)).foregroundStyle(Color(Tok.muted))
                    Spacer()
                    if let round = card.round { Text("Round \(round)").font(TypeFace.mono(11, weight: 600)).foregroundStyle(Color(Tok.muted)) }
                }
                if let quote = card.quote { QuoteTag(quote: quote) }
                if let number = LatestRoundNumber.make(summary: card.summary, latest: card.metrics) {
                    DockBigNumber(number: number)
                }
                SourceLine(card.sampleSource ?? "\(card.modelLabel) · receipt \(card.receiptID.prefix(8))")
            }
        } else {
            Instruction(label: "No spoken round yet", text: "Hold ⌃⌥T, or hold Talk below, and answer out loud.")
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
                Button("Ask Muse") { model.onAskMuse() }.buttonStyle(CartButtonStyle(primary: false, fill: true)).disabled(model.lastCard == nil)
                Button(model.presenting ? "Show" : "Hide") { model.presenting.toggle(); if model.presenting { onClose() } }
                    .buttonStyle(CartButtonStyle(primary: false, fill: true))
                    .accessibilityHint(model.presenting ? "Shows Tug again." : "Hides Tug, like Control-Option-H.")
            }
        }
    }

    /// Hold to talk, like holding ⌃⌥T: pressing opens the microphone, letting go sends the answer.
    private var talkButton: some View {
        HStack(spacing: 7) {
            if holding { RecordDot(color: Tok.onAction) } else { Image(systemName: "mic.fill").font(.system(size: 13, weight: .bold)) }
            Text(holding ? "Listening" : "Talk").font(TypeFace.body(14, weight: 650))
        }
        .foregroundStyle(Color(Tok.onAction))
        .padding(.horizontal, 16).frame(maxWidth: .infinity, minHeight: 34)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(Tok.action)))
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

/// The latest round's one number on the docked panel, in its habit's colour.
struct DockBigNumber: View {
    let number: LatestRoundNumber
    var body: some View {
        let (fill, lip): (NSColor, NSColor) = switch number.habit {
        case .filler: (Tok.filler, Tok.fillerEdge)
        case .hedge: (Tok.hedge, Tok.hedgeEdge)
        case .restart: (Tok.restart, Tok.restartEdge)
        }
        HStack(spacing: 14) {
            Text("\(number.value)").font(TypeFace.display(50, weight: 850))
            VStack(alignment: .leading, spacing: 2) {
                Text(number.value == 1 ? number.habit.rawValue : number.habit.rawValue + "s").font(TypeFace.display(18, weight: 800))
                Text(number.caption).font(TypeFace.body(13, weight: 550))
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color(Tok.inkFixed))
        .padding(.horizontal, 14).padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cartLabel(radius: 12, lip: 4, fill: fill, edge: lip, lipColor: lip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(RoundSummary.count(number.value, number.habit)) \(number.caption)")
    }
}

/// The Dock tile: the can-and-string mark on a sunflower tile, Tug in its current state, an ink count
/// for new changes to the record, and a small live dot while the microphone is open.
struct DockTileView: View {
    let phase: MascotPhase
    let badge: String?
    let liveDot: Bool

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                DockIconArt(phase: phase).frame(width: s, height: s)
                if let badge {
                    Text(badge).font(TypeFace.body(s * 0.2, weight: 800)).foregroundStyle(Color(Tok.labelWhite))
                        .padding(.horizontal, s * 0.07).frame(minWidth: s * 0.3, minHeight: s * 0.3)
                        .background(Capsule().fill(Color(Tok.inkFixed)))
                        .overlay(Capsule().strokeBorder(Color(Tok.labelWhite), lineWidth: s * 0.025))
                        .position(x: s * 0.82, y: s * 0.17)
                }
                if liveDot {
                    ZStack {
                        Circle().fill(Color(Tok.labelWhite)).frame(width: s * 0.22, height: s * 0.22)
                        Circle().fill(Color(Tok.inkFixed)).frame(width: s * 0.13, height: s * 0.13)
                    }
                    .position(x: s * 0.18, y: s * 0.17)
                }
            }
        }
        .environment(\.colorScheme, .light)
    }
}

/// The icon art: a rounded sunflower tile with an ink edge, and Tug with its string running off the tile.
struct DockIconArt: View {
    let phase: MascotPhase
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let inset = s * 0.1
            let shape = RoundedRectangle(cornerRadius: s * 0.2, style: .continuous)
            ZStack {
                shape.fill(Color(Tok.inkFixed)).frame(width: s - inset * 2, height: s - inset * 2).offset(y: s * 0.02)
                shape.fill(Color(Tok.field)).frame(width: s - inset * 2, height: s - inset * 2)
                    .overlay(shape.strokeBorder(Color(Tok.inkFixed), lineWidth: max(1, s * 0.018)))
                TugCanvas(pose: TugPose(phase: phase, t: 0.35, talking: false, animated: false), facesRight: true)
                    .frame(width: s * 0.66, height: s * 0.66)
                    .offset(x: s * 0.02, y: s * 0.01)
            }
            .frame(width: s, height: s)
        }
    }
}

/// The static app icon (app switcher, Finder), rendered from the same art.
@MainActor
enum DockIcon {
    static func image(size: CGFloat) -> NSImage {
        let renderer = ImageRenderer(content: DockIconArt(phase: .idle).frame(width: size, height: size).environment(\.colorScheme, .light))
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
            let renderer = ImageRenderer(content: DockIconArt(phase: .idle).frame(width: size, height: size))
            renderer.scale = 2
            if let tiff = renderer.nsImage?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appending(path: "dock-icon-\(Int(size))pt.png"))
            }
        }
    }
}
#endif
