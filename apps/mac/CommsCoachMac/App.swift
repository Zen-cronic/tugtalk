import AppKit
import ScreenContextCore

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = PanelController(model: model)
        menu = StatusMenu(model: model)
        wireActions()
        registerHotkeys()
        watchFrontmostApp()
        panel.show()
        handleLaunchArguments()
    }

    private func wireActions() {
        model.onCapture = { [weak self] in self?.capture() }
        model.onOpenSettings = { PermissionGate.openSettings() }
        model.onPermissionContinue = { [weak self] in
            PermissionGate.request()
            self?.model.dismiss()
        }
        menu.onCapture = { [weak self] in self?.capture() }
        menu.onPreview = { [weak self] phase in self?.preview(phase) }
    }

    private func registerHotkeys() {
        hotkeys.register(Hotkeys.capture) { [weak self] in self?.capture() }
        hotkeys.register(Hotkeys.hide) { [weak self] in self?.model.presenting.toggle() }
        hotkeys.register(Hotkeys.ghost) { [weak self] in self?.model.ghost.toggle() }
        hotkeys.register(Hotkeys.undo) { [weak self] in self?.model.onUndo() }
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

    func capture() {
        model.set(.offline("Capture is not connected in this build.", retryable: false), collapseAfter: 6)
    }

    /// "Preview States": shows one state with sample content, or cycles all eight. Nothing is sent.
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

    private func show(_ phase: MascotPhase) {
        if case .thinking = phase { model.set(.thinking(since: Date().addingTimeInterval(-4))) } else { model.set(phase) }
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
        if let name = defaults.string(forKey: "previewState"), let phase = PreviewSamples.all.first(where: { $0.name == name }) {
            preview(phase)
        } else if defaults.double(forKey: "previewCycle") > 0 {
            let interval = defaults.double(forKey: "previewCycle")
            Task { try? await Task.sleep(for: .seconds(1)); preview(nil, interval: interval) }
        }
    }
}
