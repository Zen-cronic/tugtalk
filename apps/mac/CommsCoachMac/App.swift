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
    private var phaseWatch: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        TypeFace.register()
        panel = PanelController(model: model)
        menu = StatusMenu(model: model)
        flow = CaptureFlow(model: model)
        voice = VoiceFlow(model: model)
        poller = Poller(model: model)
        pointing = PointingController(model: model)
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

    private func registerHotkeys() {
        hotkeys.register(Hotkeys.capture) { [weak self] in self?.capture(trigger: "hotkey") }
        hotkeys.register(Hotkeys.hide) { [weak self] in self?.model.presenting.toggle() }
        hotkeys.register(Hotkeys.ghost) { [weak self] in self?.model.ghost.toggle() }
        hotkeys.register(Hotkeys.undo) { [weak self] in self?.model.onUndo() }
        hotkeys.register(Hotkeys.talk, onRelease: { [weak self] in self?.voice.keyUp() }) { [weak self] in
            self?.previewTask?.cancel()
            self?.voice.keyDown()
        }
    }

    /// Hides the companion while a known meeting app is in front. A heuristic: macOS offers no
    /// public way to know whether the screen is being shared.
    private func watchFrontmostApp() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier ?? ""
            MainActor.assumeIsolated {
                guard let self else { return }
                if bundleID == Bundle.main.bundleIdentifier { return }
                self.model.inMeetingApp = Settings.autoHideInMeetings && Settings.meetingApps.contains(bundleID)
            }
        }
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
        #endif
        if let name = defaults.string(forKey: "previewState"), let phase = PreviewSamples.named.first(where: { $0.name == name })?.phase {
            preview(phase)
        } else if defaults.double(forKey: "previewCycle") > 0 {
            let interval = defaults.double(forKey: "previewCycle")
            Task { try? await Task.sleep(for: .seconds(1)); preview(nil, interval: interval) }
        }
    }
}
