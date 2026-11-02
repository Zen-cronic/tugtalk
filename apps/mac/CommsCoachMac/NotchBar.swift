import AppKit
import Combine
import ScreenContextCore
import SwiftUI

/// The top bar's window: borderless, non-activating, just above the menu bar, on every Space and over full-screen
/// apps. It takes the keyboard only when it is clicked open, and never activates the app.
final class NotchBarWindow: NSPanel {
    var onResignKey: () -> Void = {}

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 232, height: 30), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isExcludedFromWindowsMenu = true
        isMovable = false
        setAccessibilityLabel("\(MascotName) top bar")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    /// It sits in the menu bar's band on purpose; AppKit would otherwise push it below.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override func resignKey() { super.resignKey(); onResignKey() }
}

/// Owns the top bar: placement around the notch (or under the menu bar), opening and closing, and its actions.
/// The rules are in `NotchBarPlacement`, `NotchBarStatus` and `NotchBarExpansion`.
@MainActor
final class NotchBarController {
    private let model: CompanionModel
    let ui = NotchBarUI()
    private let window = NotchBarWindow()
    private var hosting: NSHostingView<NotchBarView>!
    private var expansion = NotchBarExpansion()
    private var observers: Set<AnyCancellable> = []
    private var dwellTask: Task<Void, Never>?
    private var leaveTask: Task<Void, Never>?
    private var lingerTask: Task<Void, Never>?
    private var shrinkTask: Task<Void, Never>?
    private var keyMonitor: Any?
    /// The card that opened the panel by itself, so a state that stays the same does not reopen it.
    private var cardKey: String?

    static let wing: CGFloat = 124
    static let below: CGFloat = 6
    static let plain = CGSize(width: 232, height: 30)
    static let hoverDelay = 0.25
    static let leaveDelay = 0.45

    var enabled = false { didSet { if enabled != oldValue { if !enabled { expansion.close() }; apply() } } }
    var onTalkDown: () -> Void = {}
    var onTalkUp: () -> Void = {}
    var onTalkCancel: () -> Void = {}
    var onReadWindow: () -> Void = {}
    var onHome: (TugHome) -> Void = { _ in }

    init(model: CompanionModel) {
        self.model = model
        hosting = NSHostingView(rootView: NotchBarView(model: model, ui: ui))
        hosting.sizingOptions = []
        window.contentView = hosting
        window.onResignKey = { [weak self] in
            guard let self else { return }
            self.cancelTalk()
            self.expansion.resignedKey()
            self.apply()
        }
        ui.onPointer = { [weak self] inside in self?.pointer(inside: inside) }
        ui.onBarClick = { [weak self] in self?.barClicked() }
        ui.onClose = { [weak self] in self?.close() }
        ui.onTalkDown = { [weak self] in self?.onTalkDown() }
        ui.onTalkUp = { [weak self] in self?.talkReleased() }
        ui.onReadWindow = { [weak self] in
            self?.close()
            self?.onReadWindow()
        }
        ui.onHide = { [weak self] in
            self?.close()
            self?.model.presenting = true
        }
        ui.onHome = { [weak self] home in self?.onHome(home) }

        model.$phase.combineLatest(model.$talking).receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.phaseChanged() }.store(in: &observers)
        model.$presenting.combineLatest(model.$inMeetingApp).receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.apply() }.store(in: &observers)
        model.$latestVoiceCard.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] card in if card != nil { self?.ui.latest = .round } }.store(in: &observers)
        model.$lastCard.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] card in if card != nil { self?.ui.latest = .card } }.store(in: &observers)
        ui.$bodyHeight.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.layoutWindow() }.store(in: &observers)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.layoutWindow() }.store(in: &observers)
    }

    // State

    private var status: NotchBarStatus { NotchBarStatus.make(model.phase.barInput(talking: model.talking)) }

    private func phaseChanged() {
        let status = self.status
        if status.showsCard {
            let key = cardIdentity
            if key != cardKey {
                cardKey = key
                expansion.cardShown()
                linger(status.linger)
            }
        } else if cardKey != nil {
            cardKey = nil
            lingerTask?.cancel()
            expansion.cardCleared()
        }
        if case .voiceListening = model.phase {} else { ui.holdingTalk = false }
        apply()
    }

    /// Changes when a different card arrives, or a spoken reply finishes playing.
    private var cardIdentity: String {
        if case .voiceSpeaking(let card) = model.phase { return "voice-\(card.roundID)-\(card.finished)" }
        if case .notice(let text) = model.phase { return "notice-\(text)" }
        return model.phase.name
    }

    private var isPreviewCard: Bool {
        switch model.phase {
        case .voiceSpeaking(let card): card.isPreview
        case .speaking(let card): card.isPreview
        default: false
        }
    }

    /// A card that opened the panel by itself folds after its linger, unless it waits for an action. Sample cards
    /// in Debug previews stay, as they do in the floating window.
    private func linger(_ seconds: Double?) {
        lingerTask?.cancel()
        guard let seconds, !isPreviewCard else { return }
        lingerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.expansion.cardCleared()
            self.apply()
        }
    }

    // Pointer, click and keyboard

    private func pointer(inside: Bool) {
        if inside {
            leaveTask?.cancel()
            expansion.pointerEntered()
            dwellTask?.cancel()
            dwellTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.hoverDelay))
                guard !Task.isCancelled, let self else { return }
                self.expansion.hoverDwelled()
                self.apply()
            }
        } else {
            dwellTask?.cancel()
            leaveTask?.cancel()
            leaveTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.leaveDelay))
                guard !Task.isCancelled, let self, !self.ui.holdingTalk else { return }
                self.expansion.pointerLeft()
                self.apply()
            }
        }
    }

    private func barClicked() {
        expansion.clicked()
        apply()
        if expansion.expanded { takeKeyboard() }
    }

    /// Also the accessibility press and the menu's "Open Top Bar": the panel takes the keyboard, so Tab and Esc work.
    func open() {
        guard enabled else { return }
        if !expansion.expanded { expansion.clicked() }
        apply()
        takeKeyboard()
    }

    func close() {
        expansion.close()
        apply()
    }

    private func takeKeyboard() {
        window.makeKey()
        guard keyMonitor == nil else { return }
        // Esc, only while this window has the keyboard. A local monitor: no key is ever taken from another app.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, event.window === self.window else { return event }
            self.close()
            return nil
        }
    }

    /// Gives the keyboard back to the app the person was using.
    private func releaseKeyboard() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        guard window.isKeyWindow else { return }
        window.orderOut(nil)
        window.orderFrontRegardless()
    }

    private func talkReleased() {
        guard ui.holdingTalk else { return }
        ui.holdingTalk = false
        onTalkUp()
    }

    func cancelTalk() {
        guard ui.holdingTalk else { return }
        ui.holdingTalk = false
        onTalkCancel()
    }

    // Showing and sizing

    private var shown: Bool { enabled && !model.isPresenting }

    private func apply() {
        guard shown else {
            cancelTalk()
            releaseKeyboard()
            shrinkTask?.cancel()
            ui.expanded = false
            ui.mounted = false
            window.orderOut(nil)
            return
        }
        let want = expansion.expanded
        if want && !ui.expanded { grow() } else if !want && ui.expanded { shrink() } else { layoutWindow() }
        if !window.isVisible { window.orderFrontRegardless() }
    }

    private var reduceMotion: Bool { Motion.reduceInAppKit }

    private func grow() {
        shrinkTask?.cancel()
        ui.mounted = true
        // Let the body lay out once at its open width, so the window is sized for it before the spring starts.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.expansion.expanded, self.shown else { return }
            self.layoutWindow(open: true)
            self.ui.expanded = true
        }
    }

    private func shrink() {
        cancelTalk()
        releaseKeyboard()
        ui.expanded = false
        shrinkTask?.cancel()
        shrinkTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.reduceMotion == true ? 0 : 0.45))
            guard !Task.isCancelled, let self, !self.expansion.expanded else { return }
            self.ui.mounted = false
            self.layoutWindow(open: false)
        }
    }

    /// The display with the menu bar.
    private var screen: NSScreen? { NSScreen.screens.first }

    private var barLayout: NotchBarPlacement.Layout? {
        guard let screen else { return nil }
        var housing = NotchBarPlacement.housing(screen: screen.frame, safeTop: screen.safeAreaInsets.top,
                                                auxLeft: screen.auxiliaryTopLeftArea, auxRight: screen.auxiliaryTopRightArea)
        #if DEBUG
        // `-notchBarNoNotch YES` places the bar as on a Mac without a notch, for checking that layout here.
        if UserDefaults.standard.bool(forKey: "notchBarNoNotch") { housing = nil }
        #endif
        return NotchBarPlacement.collapsed(screen: screen.frame, visible: screen.visibleFrame, housing: housing,
                                           wing: Self.wing, below: Self.below, plain: Self.plain)
    }

    private func layoutWindow(open: Bool? = nil) {
        guard let screen, let bar = barLayout else { return }
        let isOpen = open ?? (ui.mounted)
        ui.housingWidth = bar.housing?.width
        ui.band = bar.band
        ui.below = bar.housing == nil ? 0 : Self.below
        ui.barSize = bar.frame.size
        let frame: CGRect
        if isOpen {
            let size = CGSize(width: NotchBarUI.openWidth, height: ui.openHeight + NotchBarUI.slack)
            frame = NotchBarPlacement.expanded(from: bar, size: size, screen: screen.frame).frame
        } else {
            frame = bar.frame
        }
        if window.frame != frame { window.setFrame(frame, display: true) }
        report(bar: bar)
    }

    /// The bar's frame on screen, for keeping a pointing ring clear of it.
    var frameOnScreen: CGRect { window.isVisible ? window.frame : .zero }

    /// A ring is about to be drawn at `rect`: fold the panel if it would cover the line. True when the bar is clear.
    func avoid(_ rect: CGRect) -> Bool {
        guard shown else { return true }
        if expansion.expanded, window.frame.intersects(rect) {
            expansion.close()
            apply()
        }
        return !(barLayout?.frame.intersects(rect) ?? false)
    }

    // Debug

    #if DEBUG
    /// `-notchBarReport <path>`: writes the window number and frames, for screenshots of the bar window alone.
    private func report(bar: NotchBarPlacement.Layout) {
        guard let path = UserDefaults.standard.string(forKey: "notchBarReport") else { return }
        let f = window.frame
        let h = bar.housing
        let text = """
        {"window": \(window.windowNumber), "frame": [\(f.minX), \(f.minY), \(f.width), \(f.height)], \
        "bar": [\(bar.frame.width), \(bar.frame.height)], "housing": \(h.map { "[\($0.minX), \($0.minY), \($0.width), \($0.height)]" } ?? "null"), \
        "expanded": \(ui.expanded)}
        """
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// `-notchBarOpen YES` opens the panel at launch (as a hover, without the keyboard); `-notchBarSample round|card`
    /// fills the latest card with sample content. Nothing is sent.
    func handleDebugArguments() {
        let defaults = UserDefaults.standard
        switch defaults.string(forKey: "notchBarSample") {
        case "round":
            model.latestVoiceCard = PreviewSamples.voiceCard(finished: true)
            ui.latest = .round
        case "card":
            model.lastCard = PreviewSamples.card
            ui.latest = .card
        default: break
        }
        if defaults.bool(forKey: "notchBarOpen") {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(0.8))
                guard let self else { return }
                self.expansion.pointerEntered()
                self.expansion.hoverDwelled()
                self.apply()
            }
        }
    }
    #else
    private func report(bar: NotchBarPlacement.Layout) {}
    #endif
}
