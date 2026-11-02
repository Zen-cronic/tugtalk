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
    /// The open panel's left edge on screen, fixed while it is open so Tug's corner never moves.
    private var openOriginX: CGFloat?

    static let hoverDelay = 0.25
    static let leaveDelay = 0.45

    var enabled = false { didSet { if enabled != oldValue { if !enabled { expansion.close() }; apply() } } }
    var onTalkDown: () -> Void = {}
    var onTalkUp: () -> Void = {}
    var onTalkCancel: () -> Void = {}
    var onReadWindow: () -> Void = {}
    var onHome: (TugHome) -> Void = { _ in }
    /// The left edge of this app's own menu-bar item, from the status menu.
    var ownStatusItemMinX: () -> CGFloat? = { nil }

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
                self.ui.dwelled = true
                self.apply()
            }
        } else {
            dwellTask?.cancel()
            leaveTask?.cancel()
            leaveTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.leaveDelay))
                guard !Task.isCancelled, let self, !self.ui.holdingTalk else { return }
                self.expansion.pointerLeft()
                self.ui.dwelled = false
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
        ui.openedByCard = expansion.reason == .card
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
        ui.settingsOpen = false
        ui.dwelled = false
        shrinkTask?.cancel()
        shrinkTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.reduceMotion == true ? 0 : 0.45))
            guard !Task.isCancelled, let self, !self.expansion.expanded else { return }
            self.ui.mounted = false
            self.openOriginX = nil
            self.layoutWindow(open: false)
        }
    }

    /// The display with the menu bar.
    private var screen: NSScreen? { NSScreen.screens.first }

    private var housing: CGRect? {
        guard let screen else { return nil }
        #if DEBUG
        // `-notchBarNoNotch YES` places the bar as on a Mac without a notch, for checking that layout here.
        if UserDefaults.standard.bool(forKey: "notchBarNoNotch") { return nil }
        #endif
        return NotchBarPlacement.housing(screen: screen.frame, safeTop: screen.safeAreaInsets.top,
                                         auxLeft: screen.auxiliaryTopLeftArea, auxRight: screen.auxiliaryTopRightArea)
    }

    /// The bar's mark for now: the state's own, or the warning when another copy holds the talk keys.
    private var mark: NotchBarStatus.Mark {
        let status = self.status
        if model.hotkeyNotice != nil, status.mark == .none, !status.wordChip { return .symbol("exclamationmark.circle") }
        return status.mark
    }

    /// The wings shrink to their content: Tug and the word on the left, one small mark on the right. The left one
    /// always ends 8 pt short of the housing; the right one hides when the menu bar has no room for it.
    private func wings(housing: CGRect?) -> (left: CGFloat, right: CGFloat) {
        let notch = housing != nil
        let glyph: CGFloat = notch ? 18 : 16
        let word = glyph + 6 + BarType.width(status.word) + (status.wordChip ? 2 * NotchBarUI.chipPad : 0)
        let markWidth = BarType.markWidth(mark)
        var right = markWidth == 0 ? 0 : (notch ? NotchBarPlacement.notchGap : 8) + markWidth + NotchBarUI.inset
        if let housing, right > 0, !NotchBarPlacement.rightWingFits(statusItemsMinX: statusItemsMinX(right: housing.midX),
                                                                   housingMaxX: housing.maxX, width: right) {
            right = 0
        }
        // The record light never goes: with no room on the right, it moves beside the word.
        let content = right == 0 && markWidth > 0 && { if case .recordLight = mark { return true } else { return false } }()
            ? word + 6 + RecordLight.side : word
        // With a notch the left wing ends at the housing, 8 pt clear; without one it runs into the right wing.
        let left = notch || right == 0 ? NotchBarPlacement.wing(content: content, inset: NotchBarUI.inset, notch: notch)
                                       : NotchBarUI.inset + content
        return (left, right)
    }

    private var barLayout: NotchBarPlacement.Layout? {
        guard let screen else { return nil }
        let housing = self.housing
        let (left, right) = wings(housing: housing)
        return NotchBarPlacement.collapsed(screen: screen.frame, visible: screen.visibleFrame, housing: housing, left: left, right: right)
    }

    /// The left edge of the leftmost menu-bar status item to the right of `x`, on the display with the menu bar: this
    /// app's own item (added last, so usually the leftmost), or any status window the system lists. Window bounds
    /// only (no names), which needs no permission.
    private func statusItemsMinX(right x: CGFloat) -> CGFloat? {
        #if DEBUG
        // `-notchBarCrowded YES|NO`: as if status items reached the notch, or as if the menu bar had room.
        if let crowded = UserDefaults.standard.object(forKey: "notchBarCrowded") as? String {
            return ["YES", "1", "true"].contains(crowded) ? x : nil
        }
        #endif
        let own = ownStatusItemMinX().map { max($0, x) }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return own }
        let level = Int(CGWindowLevelForKey(.statusWindow))
        var found: CGFloat?
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == level,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict), bounds.minY < 2, bounds.minX > x else { continue }
            found = min(found ?? bounds.minX, bounds.minX)
        }
        return [found, own].compactMap { $0 }.min()
    }

    private func layoutWindow(open: Bool? = nil) {
        guard let screen, let bar = barLayout else { return }
        let isOpen = open ?? (ui.mounted)
        ui.housingWidth = bar.housing?.width
        ui.band = bar.band
        let (left, right) = wings(housing: housing)
        ui.leftWing = left
        ui.rightWing = right
        ui.barSize = bar.frame.size
        let frame: CGRect
        if isOpen {
            let size = CGSize(width: NotchBarUI.openWidth, height: ui.openHeight + NotchBarUI.slack)
            var open = NotchBarPlacement.expanded(from: bar, size: size, screen: screen.frame)
            // Keep Tug's corner where it was when the panel opened, even if the word changes while it is open.
            if let x = openOriginX { open.frame.origin.x = x } else { openOriginX = open.frame.minX }
            ui.openHousingX = housing.map { $0.minX - open.frame.minX } ?? 0
            frame = open.frame
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
        "expanded": \(ui.expanded), "left": \(ui.leftWing), "right": \(ui.rightWing), "word": "\(status.word)", \
        "wordWidth": \(BarType.width(status.word)), "ownItemMinX": \(ownStatusItemMinX().map { "\($0)" } ?? "null"), "statusItemsMinX": \(h.flatMap { statusItemsMinX(right: bar.frame.minX + $0.midX) }.map { "\($0)" } ?? "null")}
        """
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// `-notchBarOpen YES` opens the panel at launch (as a hover, without the keyboard), `-notchBarSettings YES` with
    /// its settings view; `-notchBarSample round|card` fills the latest card with sample content. Nothing is sent.
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
        // `-notchBarFold YES`: folds a card that opened the panel, as its linger would, so the bar alone shows.
        if defaults.bool(forKey: "notchBarFold") {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard let self else { return }
                self.expansion.cardCleared()
                self.apply()
            }
        }
        if defaults.bool(forKey: "notchBarOpen") || defaults.bool(forKey: "notchBarSettings") {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(0.8))
                guard let self else { return }
                self.expansion.pointerEntered()
                self.expansion.hoverDwelled()
                self.ui.dwelled = true
                self.ui.settingsOpen = defaults.bool(forKey: "notchBarSettings")
                self.apply()
            }
        }
    }
    #else
    private func report(bar: NotchBarPlacement.Layout) {}
    #endif
}
