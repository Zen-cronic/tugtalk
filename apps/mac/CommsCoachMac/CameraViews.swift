import AppKit
import Combine
import ScreenContextCore
import SwiftUI

// The camera's visible parts: Tug looking back while you hold ⌃⌥T, a small dot under the camera, one chip on the
// reply card, and the explainer shown before macOS asks for the camera. Every word here describes where the head
// pointed, never the person.

// Tug looks back

extension TugPose {
    /// While a hold has the camera on, Tug faces you when your head faces the camera, and its eyes drift off when
    /// you turn away. It mirrors the measurement and shows no feeling about it. With Reduce Motion the change is a cut.
    func lookingBack(_ look: CameraSession.Look?, phase: MascotPhase, now: Date, animated: Bool) -> TugPose {
        guard let look, case .voiceListening = phase else { return self }
        let blinking = eyeOpen < 0.2
        var facing = self
        facing.turn = 0; facing.lookX = 0; facing.lookY = 0
        facing.eyeOpen = 1.15; facing.browNear = 0.7; facing.browFar = 0.7; facing.smile = 0.35
        var away = self
        let t = now.timeIntervalSinceReferenceDate
        away.turn = -0.5
        away.lookX = -3.0 + (animated ? 0.5 * sin(t * 0.9) : 0)
        away.lookY = 2.0 + (animated ? 0.3 * sin(t * 0.6 + 1) : 0)
        away.eyeOpen = 1; away.browNear = 0.3; away.browFar = 0.3; away.smile = 0.3
        let k = animated ? min(1, max(0, now.timeIntervalSince(look.since) / 0.3)) : 1
        let eased = 1 - pow(1 - k, 3)
        var pose = look.facing ? TugPose.lerp(away, facing, eased) : TugPose.lerp(facing, away, eased)
        if blinking { pose.eyeOpen = eyeOpen }
        return pose
    }
}

// The dot under the camera

/// A small dot at the top centre of the screen, under the camera, shown only while a hold has the camera open:
/// filled when your head faces the camera, an open ring when it doesn't. It never takes clicks.
@MainActor
final class CameraCueController {
    private let panel: NSPanel
    private var watch: AnyCancellable?
    static let size = NSSize(width: 34, height: 20)

    init(session: CameraSession) {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.contentView = NSHostingView(rootView: CameraCueView(session: session))
        watch = session.$look.map { $0 != nil }.removeDuplicates().sink { [weak self] open in
            DispatchQueue.main.async { open ? self?.show() : self?.panel.orderOut(nil) }
        }
    }

    private func show() {
        // The camera is at the top centre of the built-in display; any other screen falls back to the menu-bar one.
        guard let screen = NSScreen.screens.first(where: { $0.localizedName.localizedCaseInsensitiveContains("built-in") }) ?? NSScreen.screens.first else { return }
        let top = max(screen.frame.maxY - screen.visibleFrame.maxY, screen.safeAreaInsets.top)
        panel.setFrameOrigin(NSPoint(x: screen.frame.midX - Self.size.width / 2, y: screen.frame.maxY - top - Self.size.height - 6))
        panel.orderFrontRegardless()
    }
}

struct CameraCueView: View {
    @ObservedObject var session: CameraSession
    @Environment(\.reduceMotionOn) private var reduceMotion

    var body: some View {
        let facing = session.look?.facing ?? false
        ZStack {
            Capsule().fill(Color(Tok.surface))
            Capsule().strokeBorder(Color(Tok.cardEdge).opacity(0.6), lineWidth: 1)
            ZStack {
                Circle().strokeBorder(Color(Tok.ink).opacity(0.55), lineWidth: 1.6).frame(width: 10, height: 10).opacity(facing ? 0 : 1)
                Circle().fill(Color(Tok.ink)).frame(width: 10, height: 10).opacity(facing ? 1 : 0)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: facing)
        }
        .frame(width: CameraCueController.size.width, height: CameraCueController.size.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(facing ? "Facing the camera" : "Not facing the camera")
    }
}

// The chip on the reply card

/// "62% faced the camera", then "Looked away 3 times": numbers code measured on this Mac. Neutral ink, not a habit colour.
struct CameraChip: View {
    let metrics: CameraMetrics

    var body: some View {
        HStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(metrics.faced_camera_pct)%").font(TypeFace.display(17, weight: 800))
                Text("faced the camera").font(TypeFace.body(13, weight: 650))
            }
            .foregroundStyle(Color(Tok.ink))
            .padding(.horizontal, 9).frame(height: 30)
            .thinEdge(radius: 8)
            .fixedSize()
            Text(metrics.lookedAwayLine).font(TypeFace.body(13, weight: 500)).foregroundStyle(Color(Tok.muted))
                .lineLimit(1).minimumScaleFactor(0.85).layoutPriority(-1)
        }
        .help([metrics.facedLine, metrics.looked_away_count > 0 ? String(format: "Longest look-away %.1f s", Double(metrics.longest_look_away_ms) / 1000) : nil,
               "Measured from head direction on this Mac, not from your eyes."].compactMap { $0 }.joined(separator: "\n"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Measured on this Mac: \(metrics.facedLine). \(metrics.lookedAwayLine).")
    }
}

// The explainer

/// Shown when "Use the Camera During Practice" is turned on. Continue shows the macOS prompt once; nothing opens the
/// camera until a hold. A denial points to System Settings.
@MainActor
enum CameraExplainer {
    enum Step { case ask, denied, on }
    private static var window: NSPanel?

    static func show(denied: Bool) { present(denied ? .denied : .ask) }

    static func present(_ step: Step) {
        let view = CameraExplainerView(step: step, onContinue: allow, onSettings: { CameraPermission.openSettings(); close() }, onClose: close)
        let panel = window ?? makeWindow()
        panel.contentView = NSHostingView(rootView: view)
        panel.setContentSize(panel.contentView!.fittingSize)
        if window == nil { panel.center() }
        window = panel
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        cameraLog.notice("camera explainer shown (\(String(describing: step), privacy: .public)), window \(panel.windowNumber, privacy: .public)")
    }

    private static func allow() {
        CameraPermission.request { granted in
            if granted {
                CameraSettings.enabled = true
                cameraLog.notice("camera for practice turned on")
                present(.on)
            } else {
                present(.denied)
            }
        }
    }

    static func close() { window?.orderOut(nil); window = nil }

    private static func makeWindow() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 300), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.title = "Use the Camera During Practice"
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        return panel
    }
}

struct CameraExplainerView: View {
    let step: CameraExplainer.Step
    var onContinue: () -> Void
    var onSettings: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                // A still Tug: the explainer is a one-off window, so it does not act or breathe.
                TugCanvas(pose: TugPose(phase: step == .on ? .idle : .permission, t: TugView.stillT, talking: false, animated: false)).frame(width: 50, height: 50)
                Text(heading).font(TypeFace.display(17, weight: 800)).foregroundStyle(Color(Tok.ink)).lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.top, 24).padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(Tok.setupBand))
            .overlay(alignment: .bottom) { Rectangle().fill(Color(Tok.cardEdge).opacity(0.5)).frame(height: 1) }
            VStack(alignment: .leading, spacing: 12) {
                switch step {
                case .ask:
                    CoachText("While you hold ⌃⌥T, the camera checks which way your head points. It runs on this Mac and turns off when you let go.")
                    Fact(symbol: "tray.and.arrow.down", text: "Saved with your answer: how much of it you faced the camera, and how often you looked away.")
                    Fact(symbol: "photo.badge.checkmark", text: "No picture is saved or sent.")
                    Text("It follows your head, not your eyes.").font(TypeFace.body(13, weight: 500)).foregroundStyle(Color(Tok.muted))
                    HStack(spacing: 8) {
                        Button("Continue", action: onContinue).buttonStyle(CartButtonStyle()).keyboardShortcut(.defaultAction)
                        Button("Not Now", action: onClose).buttonStyle(CartButtonStyle(primary: false)).keyboardShortcut(.cancelAction)
                        Spacer()
                    }
                case .denied:
                    CoachText("Turn on Comms Coach in Privacy & Security › Camera, then choose Use the Camera During Practice again.")
                    HStack(spacing: 8) {
                        Button("Open System Settings", action: onSettings).buttonStyle(CartButtonStyle()).keyboardShortcut(.defaultAction)
                        Button("Close", action: onClose).buttonStyle(CartButtonStyle(primary: false)).keyboardShortcut(.cancelAction)
                        Spacer()
                    }
                case .on:
                    CoachText("Hold ⌃⌥T and answer. The reply card shows how much of the answer you faced the camera.")
                    HStack { Button("Done", action: onClose).buttonStyle(CartButtonStyle()).keyboardShortcut(.defaultAction); Spacer() }
                }
            }
            .padding(16)
        }
        .frame(width: 380)
        .background(Color(Tok.surface))
    }

    private var heading: String {
        switch step {
        case .ask: "Use the camera during practice?"
        case .denied: "Camera is off for Comms Coach"
        case .on: "Camera on for practice"
        }
    }

    private struct Fact: View {
        let symbol: String
        let text: String
        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).frame(width: 16)
                Text(text).font(TypeFace.body(14, weight: 550)).fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Color(Tok.ink))
        }
    }
}

// DEBUG previews

#if DEBUG
/// `-cameraPreview facing|away|card|explainer|denied|on`, for screenshots. Sample numbers only; no camera, nothing sent.
/// facing and away go with `-previewState "voice listening"`; card goes with `-previewState "voice speaking"`.
@MainActor
enum CameraPreview {
    /// The synthetic "reads notes below the screen every 8 s" answer (eval/camera-synthetic.json): sample numbers.
    nonisolated static let sample = CameraMetrics(faced_camera_pct: 75, looked_away_count: 4, longest_look_away_ms: 2000, frames: 320)
    nonisolated static var mode: String? { UserDefaults.standard.string(forKey: "cameraPreview") }

    nonisolated static func metrics(for card: VoiceCard) -> CameraMetrics? {
        card.isPreview && mode == "card" ? sample : nil
    }

    static func runLaunchPreview(_ session: CameraSession) {
        guard let mode else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            switch mode {
            case "facing": session.preview(facing: true)
            case "away": session.preview(facing: false)
            case "explainer": CameraExplainer.present(.ask)
            case "denied": CameraExplainer.present(.denied)
            case "on": CameraExplainer.present(.on)
            case "cycle":
                // Facing for 2 s, away for 2 s, and again: Tug's eyes meet yours, then drift.
                for facing in [true, false, true, false, true] {
                    session.preview(facing: facing)
                    try? await Task.sleep(for: .seconds(2))
                }
            default: break
            }
        }
    }
}
#endif

extension VoiceCard {
    /// The camera numbers for this answer, when the camera was on (and the sample in a DEBUG card preview).
    var camera: CameraMetrics? {
        #if DEBUG
        if let sample = CameraPreview.metrics(for: self) { return sample }
        #endif
        return metrics?.camera
    }
}
