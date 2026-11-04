import AppKit
import Combine
import ScreenContextCore
import SwiftUI

// The camera's visible parts: Tug looking back while you hold ⌃⌥T, a small dot in the top bar, one chip on the
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

// The dot in the top bar

/// Beside the record light in the top bar while a hold has the camera open: a small eye, its own shape so it never
/// reads as a second record dot. Open with a filled pupil when your head faces the camera; dimmed and closed to a line
/// when it doesn't. Nothing shows while the camera is off. It never takes clicks.
struct CameraDot: View {
    @ObservedObject var session: CameraSession = .shared
    var ink: NSColor = Tok.inkFixed
    @Environment(\.reduceMotionOn) private var reduceMotion

    static let side: CGFloat = 15

    var body: some View {
        if let look = session.look {
            ZStack {
                EyeOutline().stroke(Color(ink), style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
                    .opacity(look.facing ? 1 : 0)
                Circle().fill(Color(ink)).frame(width: 4.6, height: 4.6).opacity(look.facing ? 1 : 0)
                Capsule().fill(Color(ink)).frame(width: Self.side - 2, height: 1.4).opacity(look.facing ? 0 : 0.55)
            }
            .frame(width: Self.side, height: 10)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: look.facing)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(look.facing ? "Facing the camera" : "Not facing the camera")
        }
    }
}

/// An almond eye outline.
struct EyeOutline: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.midY), control: CGPoint(x: r.midX, y: r.minY - r.height * 0.45))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.midY), control: CGPoint(x: r.midX, y: r.maxY + r.height * 0.45))
        p.closeSubpath()
        return p
    }
}

// The chip on the reply card

/// "62% faced the camera", then "Looked away 3 times": numbers code measured on this Mac. Neutral ink, not a habit colour.
struct CameraChip: View {
    let metrics: CameraMetrics

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            // The same chip grammar as the habit counts: Hanken Grotesk, the number in bold. Neutral, not a habit colour.
            EvidenceChipText(number: "\(metrics.faced_camera_pct)%", unit: "faced the camera")
                .foregroundStyle(Color(Tok.ink))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .thinEdge(radius: 6)
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
                    CoachText("Turn on TugTalk in Privacy & Security › Camera, then choose Use the Camera During Practice again.")
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
        case .denied: "Camera is off for TugTalk"
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
