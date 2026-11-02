import AppKit
import CoreGraphics

/// Screen Recording permission, asked for at most once per launch and only after the explainer.
/// Pattern adapted from clicky's WindowPositionManager (MIT); see THIRD_PARTY_NOTICES.md.
@MainActor
enum PermissionGate {
    private static let confirmedKey = "screenRecordingConfirmed"
    private static var promptedThisLaunch = false

    /// No prompt. Falls back to the last confirmed grant, because the preflight can report a false negative.
    static var granted: Bool {
        if CGPreflightScreenCaptureAccess() {
            UserDefaults.standard.set(true, forKey: confirmedKey)
            return true
        }
        return false
    }

    static var previouslyConfirmed: Bool { UserDefaults.standard.bool(forKey: confirmedKey) }

    /// After the person pressed Continue on the explainer: the system prompt once, then Settings.
    static func request() {
        if granted { return }
        if promptedThisLaunch || previouslyConfirmed {
            openSettings()
        } else {
            promptedThisLaunch = true
            _ = CGRequestScreenCaptureAccess()
        }
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
