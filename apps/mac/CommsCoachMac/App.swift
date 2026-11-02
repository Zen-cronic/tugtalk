import AppKit
import Combine
import OSLog
import ScreenContextCore

/// Records what started each capture. Never the text, the image or the key.
let captureLog = Logger(subsystem: "com.kaungzinhein.commscoach.mac", category: "capture")

/// Menu-bar accessory app (LSUIElement): no Dock icon, one floating companion panel.
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    let model = CompanionModel()
    private var panel: PanelController!
    private var menu: StatusMenu!
    private let hotkeys = Hotkeys()
    private var previewTask: Task<Void, Never>?
    private var flow: CaptureFlow!
    private var voice: VoiceFlow!
    private var poller: Poller!
    private var pointing: PointingController!
    private var dock: DockController!
    private var notchBar: NotchBarController!
    /// The app that was in front before ours, so "Read This Window" in the docked panel reads that one.
    private var lastOtherApp: NSRunningApplication?
    private var phaseWatch: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        TypeFace.register()
        panel = PanelController(model: model)
        menu = StatusMenu(model: model)
        flow = CaptureFlow(model: model)
        voice = VoiceFlow(model: model)
        poller = Poller(model: model)
        pointing = PointingController(model: model)
        dock = DockController(model: model)
        notchBar = NotchBarController(model: model)
        applyHome(Settings.tugHome)
        wireActions()
        registerHotkeys()
        watchFrontmostApp()
        panel.show()
        handleLaunchArguments()
        poller.start()
    }

    private func wireActions() {
        model.onCapture = { [weak self] in self?.capture(trigger: "click") }
        model.onOpenSettings = { PermissionGate.openSettings() }
        model.onPermissionContinue = { [weak self] in
            PermissionGate.request()
            self?.model.dismiss()
        }
        model.onUndo = { [weak self] in self?.flow.undo() }
        model.onRetry = { [weak self] in self?.flow.retry() }
        model.onAskMuse = { [weak self] in
            guard let card = self?.model.lastCard else { return }
            AskMuse.open(for: card)
            self?.model.set(.notice("Question copied. Paste it into Muse."), collapseAfter: 4)
        }
        flow.afterSave = { [weak self] in self?.poller.pollSoon() }
        flow.onPoint = { [weak self] request in self?.pointing.show(request) }
        dock.floatingTugCenter = { [weak self] in self?.panel.tugCenter ?? .zero }
        pointing.avoid = { [weak self] rect in
            guard let self else { return true }
            return Settings.tugHome.showsTopBar ? self.notchBar.avoid(rect) : self.panel.moveAway(from: rect)
        }
        pointing.onDismiss = { [weak self] in self?.panel.restoreAnchor() }
        panel.onFrameChange = { [weak self] in self?.pointing.companionMoved() }
        dock.onTalkDown = { [weak self] in self?.previewTask?.cancel(); self?.voice.keyDown(source: "panel") }
        dock.onTalkUp = { [weak self] in self?.voice.keyUp(source: "panel") }
        dock.onTalkCancel = { [weak self] in self?.voice.cancelHold() }
        dock.onReadWindow = { [weak self] in self?.readLastOtherWindow() }
        menu.onTugHome = { [weak self] home in self?.setHome(home) }
        menu.onOpenTopBar = { [weak self] in self?.notchBar.open() }
        notchBar.onHome = { [weak self] home in self?.setHome(home) }
        notchBar.onTalkDown = { [weak self] in self?.previewTask?.cancel(); self?.voice.keyDown(source: "top bar") }
        notchBar.onTalkUp = { [weak self] in self?.voice.keyUp(source: "top bar") }
        notchBar.onTalkCancel = { [weak self] in self?.voice.cancelHold() }
        // The top bar never activates the app, so the window in front is still the one the person was using.
        notchBar.onReadWindow = { [weak self] in
            Task { try? await Task.sleep(for: .seconds(0.1)); self?.capture(trigger: "top bar") }
        }
        voice.afterSave = { [weak self] in self?.poller.pollSoon() }
        model.onVoiceRetry = { [weak self] in self?.voice.retry() }
        model.onVoiceDismiss = { [weak self] in self?.voice.dismissed() }
        model.onOpenMicSettings = { MicPermission.openSettings() }
        model.onMicContinue = { [weak self] in
            // The macOS prompt appears only here, after the explainer, and at most once.
            MicPermission.request { granted in
                guard let self else { return }
                if granted { self.model.set(.notice("Microphone on. Hold ⌃⌥T and talk."), collapseAfter: 4) } else { self.model.set(.micPermission(denied: true)) }
            }
        }
        menu.onCapture = { [weak self] in self?.capture(trigger: "menu") }
        menu.onUndo = { [weak self] in self?.flow.undo() }
        menu.onAskMuse = { [weak self] in self?.model.onAskMuse() }
        menu.onPreview = { [weak self] phase in self?.preview(phase) }
        #if DEBUG
        menu.onPreviewPointing = { [weak self] in self?.previewPointing() }
        menu.onGlyphSheet = { GlyphSheet.show() }
        #endif
        menu.onDemoMode = { [weak self] _ in self?.poller.pollSoon() }
        menu.onSelectGoal = { Settings.goalID = $0 }
        menu.goals = { [weak self] in self?.poller.goals ?? [] }
        menu.connectionStatus = { [weak self] in
            let source = Connection.isLocalDevelopmentRequested ? "Local test server" : "Shared record"
            return "\(source) · \(self?.poller.lastStatus ?? "")"
        }
        // A nudge that arrived during a capture shows once the companion is free again.
        phaseWatch = model.$phase.sink { [weak self] phase in
            if phase == .idle { DispatchQueue.main.async { self?.poller.showWaitingIfFree() } }
        }
    }

    /// A second copy of the companion (a test build, an older build) registers the same keys, and macOS then
    /// sends each press to only one of them, so presses can vanish from this copy without a trace.
    /// `-disableHotkeys YES` (Debug) registers none: test copies use it and drive the app with `-voiceScript`,
    /// which also implies it. A key that cannot be registered, or another copy running, is shown and logged.
    private func registerHotkeys() {
        let defaults = UserDefaults.standard
        #if DEBUG
        if defaults.bool(forKey: "disableHotkeys") || defaults.string(forKey: "voiceScript") != nil {
            hotkeyLog.notice("global hotkeys not registered (-disableHotkeys or -voiceScript)")
            // `-previewHotkeyConflict YES` shows the notice as if another copy held ⌃⌥T, without registering anything.
            if defaults.bool(forKey: "previewHotkeyConflict") { shortcutTaken(Hotkeys.talk) }
            return
        }
        #endif
        let others = NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && $0.executableURL?.lastPathComponent == "CommsCoachMac"
        }
        if !others.isEmpty {
            hotkeyLog.error("\(others.count, privacy: .public) other copy of the companion is running; ⌃⌥T presses may go to it instead")
            model.set(.notice("Another copy of Comms Coach is running. Quit it so ⌃⌥T works here."), collapseAfter: 10)
        }
        hotkeys.onRegistrationFailed = { [weak self] combo in self?.shortcutTaken(combo) }
        hotkeys.register(Hotkeys.capture) { [weak self] in self?.capture(trigger: "hotkey") }
        hotkeys.register(Hotkeys.hide) { [weak self] in self?.model.presenting.toggle() }
        hotkeys.register(Hotkeys.ghost) { [weak self] in self?.model.ghost.toggle() }
        hotkeys.register(Hotkeys.undo) { [weak self] in self?.model.onUndo() }
        hotkeys.register(Hotkeys.talk, onRelease: { [weak self] in self?.voice.keyUp() }) { [weak self] in
            self?.previewTask?.cancel()
            self?.voice.keyDown()
        }
    }

    /// Another copy holds a shortcut: say so, and keep the notice for the top bar, which then never offers the keys.
    private func shortcutTaken(_ combo: Hotkeys.Combo) {
        let notice = "Another copy of Comms Coach is using \(combo.label). Quit it to use the shortcut here."
        if combo.label == Hotkeys.talk.label || model.hotkeyNotice == nil { model.hotkeyNotice = notice }
        model.set(.notice(notice), collapseAfter: 10)
    }

    /// "Where Tug lives": the top bar, floating beside the work, or the Dock.
    private func setHome(_ home: TugHome) {
        guard home != Settings.tugHome || notchBar.enabled != home.showsTopBar else { return }
        Settings.tugHome = home
        dock.setEnabled(home.showsDockIcon)
        applyHome(home)
    }

    private func applyHome(_ home: TugHome) {
        notchBar.enabled = home.showsTopBar
        model.floatingSuppressed = !home.floatsTug
        model.layoutNeeded()
    }

    /// "Read This Window" in the docked panel: our panel is in front, so give the front back to the window the
    /// person was using, then read it. Never our own window: with no other app to return to, it says so instead.
    private func readLastOtherWindow() {
        guard let other = lastOtherApp, !other.isTerminated, other.bundleIdentifier != Bundle.main.bundleIdentifier, other.activate() else {
            captureLog.notice("read this window: no other app to read")
            model.set(.notice(CaptureError.ownWindow.localizedDescription), collapseAfter: 4)
            return
        }
        Task {
            try? await Task.sleep(for: .seconds(0.35))
            // The capture's own gate refuses our window too, if the switch did not happen.
            self.capture(trigger: "dock")
        }
    }

    /// Hides the companion while a known meeting app is in front. A heuristic: macOS offers no
    /// public way to know whether the screen is being shared.
    private func watchFrontmostApp() {
        // The app in front at launch counts as the last other app, so the docked panel can read it before any switch.
        if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier != Bundle.main.bundleIdentifier,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastOtherApp = front
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                if let self, let pid, self.lastOtherApp?.processIdentifier == pid { self.lastOtherApp = nil }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let running = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = running?.bundleIdentifier ?? ""
            let pid = running?.processIdentifier
            MainActor.assumeIsolated {
                guard let self else { return }
                if bundleID == Bundle.main.bundleIdentifier { return }
                self.lastOtherApp = pid.flatMap { NSRunningApplication(processIdentifier: $0) }
                self.model.inMeetingApp = Settings.autoHideInMeetings && Settings.meetingApps.contains(bundleID)
            }
        }
    }

    /// Clicking the Dock icon opens or closes the docked panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        dock.dockIconClicked()
        return false
    }

    func applicationDidResignActive(_ notification: Notification) {
        dock.cancelTalk()
        if dock.state.panelOpen { dock.closePanel(animated: true) }
    }

    func capture(trigger: String) {
        captureLog.notice("capture requested by \(trigger, privacy: .public)")
        previewTask?.cancel()
        flow.capture()
    }

    /// "Preview States": shows one state with sample content, or cycles them all. Nothing is sent.
    func preview(_ phase: MascotPhase?, interval: Double = 3) {
        previewTask?.cancel()
        model.presenting = false
        guard phase == nil else { show(phase!); return }
        previewTask = Task { [weak self] in
            for state in PreviewSamples.all {
                guard !Task.isCancelled else { return }
                self?.show(state)
                try? await Task.sleep(for: .seconds(interval))
            }
            self?.model.dismiss()
        }
    }

    #if DEBUG
    /// Rings the sample card's line on the fixture window. Reads the fixture on this Mac; sends nothing.
    func previewPointing() {
        previewTask?.cancel()
        model.presenting = false
        flow.previewPointing(card: PreviewSamples.card)
    }
    #endif

    private func show(_ phase: MascotPhase) {
        switch phase {
        case .thinking: model.set(.thinking(since: Date().addingTimeInterval(-4)))
        case .voiceListening: model.set(.voiceListening(since: Date().addingTimeInterval(-4)))
        case .voiceThinking: model.set(.voiceThinking(since: Date().addingTimeInterval(-2)))
        default: model.set(phase)
        }
    }

    /// `-previewState <name>` or `-previewCycle <seconds>`, for screenshots of each state.
    /// They show sample content only and send nothing.
    private func handleLaunchArguments() {
        let defaults = UserDefaults.standard
        // `-appearance dark|light` checks both looks without changing the system setting.
        switch defaults.string(forKey: "appearance") {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        if defaults.bool(forKey: "ghost") { model.ghost = true }
        if defaults.bool(forKey: "demoMode") { model.demoMode = true }
        if defaults.bool(forKey: "captureOnLaunch") {
            Task { try? await Task.sleep(for: .seconds(1.5)); capture(trigger: "launch argument") }
        }
        #if DEBUG
        if let script = defaults.string(forKey: "voiceScript") { voice.run(script: script) }
        #endif
        #if DEBUG
        if defaults.bool(forKey: "previewPointing") {
            Task { try? await Task.sleep(for: .seconds(1)); previewPointing() }
        }
        if defaults.bool(forKey: "glyphSheet") { GlyphSheet.show() }
        notchBar.handleDebugArguments()
        if defaults.bool(forKey: "dockPanel") { Task { try? await Task.sleep(for: .seconds(1.2)); dock.openPanel() } }
        if let dir = defaults.string(forKey: "dockTileSnapshots") { DockSnapshots.write(to: URL(fileURLWithPath: dir)) }
        #endif
        #if DEBUG
        if let name = defaults.string(forKey: "previewState"), let phase = PreviewSamples.named.first(where: { $0.name == name })?.phase {
            preview(phase)
        } else if defaults.double(forKey: "previewCycle") > 0 {
            let interval = defaults.double(forKey: "previewCycle")
            Task { try? await Task.sleep(for: .seconds(1)); preview(nil, interval: interval) }
        }
        #endif
    }
}
