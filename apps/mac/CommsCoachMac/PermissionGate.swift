import AppKit
import AVFoundation
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

/// Microphone permission for hold-to-talk. Never asked for on its own: only after the person
/// presses Continue on the explainer, at most once per launch. macOS itself never asks twice.
@MainActor
enum MicPermission {
    enum Status { case granted, undetermined, denied }
    private static var promptedThisLaunch = false

    /// No prompt.
    static var status: Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .undetermined
        default: .denied
        }
    }

    /// After Continue: the system prompt once if macOS has never asked, otherwise System Settings.
    static func request(_ done: @escaping @MainActor (Bool) -> Void) {
        guard status == .undetermined, !promptedThisLaunch else {
            if status == .granted { done(true) } else { openSettings() }
            return
        }
        promptedThisLaunch = true
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { MainActor.assumeIsolated { done(granted) } }
        }
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}
