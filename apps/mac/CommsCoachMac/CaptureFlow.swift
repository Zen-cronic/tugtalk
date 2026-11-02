import AppKit
import Carbon.HIToolbox
import ScreenContextCore

/// One capture, start to finish: front window → on-device OCR and redaction → POST → card.
/// Runs only when the person presses the hotkey or clicks; there is no timer here.
@MainActor
final class CaptureFlow {
    private let model: CompanionModel
    private let pipeline: ScreenContextPipeline
    private let usesFixture: Bool
    private var busy = false
    /// The last unsent capture, kept in memory only, so Retry reuses its idempotency key.
    private var pending: (payload: ScreenContextPayload, key: String)?
    /// The capture's lines and window, kept in memory until the card arrives so Tug can ring one line.
    /// Never sent. Dropped once the card is shown, or replaced by the next capture.
    private var lines: (lines: [TextLine], frame: CGRect?, windowID: CGWindowID?, bounds: CGRect?, pid: pid_t?)?

    var afterSave: () -> Void = {}
    /// Ring a line of the captured window for this card.
    var onPoint: (PointingRequest) -> Void = { _ in }
    /// DEBUG `-fixtureWindow YES`: the fixture image shown in a window, so the ring has a window to sit on.
    private(set) var fixtureWindow: FixtureWindow?

    init(model: CompanionModel) {
        self.model = model
        // `-fixtureImage <png>` reads that file instead of the screen: no Screen Recording needed.
        if let path = UserDefaults.standard.string(forKey: "fixtureImage"), let image = try? ImageLoading.cgImage(at: URL(fileURLWithPath: path)) {
            var window: FixtureWindow?
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "fixtureWindow") { window = FixtureWindow(image: image) }
            #endif
            fixtureWindow = window
            pipeline = ScreenContextPipeline(gate: CaptureGate(denyList: Settings.denyList), capturer: FixtureCapture(image: image, window: window))
            usesFixture = true
        } else {
            pipeline = ScreenContextPipeline(gate: CaptureGate(denyList: Settings.denyList))
            usesFixture = false
        }
    }

    func capture() {
        guard !busy else { return }
        guard let api = Connection.api()?.api else {
            model.set(.offline(Connection.unavailableReason, retryable: false))
            return
        }
        let front = frontApp()
        if !usesFixture && !PermissionGate.granted {
            // The explainer first; the system prompt only after the person presses Continue.
            model.set(.permission)
            return
        }
        busy = true
        Task {
            defer { busy = false }
            let started = Date()
            model.set(.listening(app: front.name))
            let result: ScreenContextPipeline.Result
            do {
                result = try await pipeline.run(app: front, secureInput: IsSecureEventInputEnabled())
            } catch CaptureError.blocked(let name) {
                model.set(.blocked(name), collapseAfter: 2.5)
                return
            } catch CaptureError.permissionNeeded {
                model.set(.permission)
                return
            } catch {
                model.set(.offline((error as? LocalizedError)?.errorDescription ?? "The window could not be read.", retryable: false), collapseAfter: 8)
                return
            }
            let record = result.windowID.flatMap(PointingController.record(of:))
            lines = (result.lines, result.frame, result.windowID, record?.bounds, record?.pid)
            // Keep "listening" on screen long enough to be seen.
            let shown = Date().timeIntervalSince(started)
            if shown < 0.9 { try? await Task.sleep(for: .seconds(0.9 - shown)) }
            guard let payload = ScreenContextPayload.make(redacted: result.redacted, appName: front.name, goalID: Settings.goalID, purpose: Settings.purpose) else {
                lines = nil
                model.set(.offline(CaptureError.nothingRead.localizedDescription, retryable: false), collapseAfter: 6)
                return
            }
            await post(payload, key: CoachAPI.newIdempotencyKey(), api: api)
        }
    }

    func retry() {
        guard let pending, !busy, let api = Connection.api()?.api else { return }
        busy = true
        Task { defer { busy = false }; await post(pending.payload, key: pending.key, api: api) }
    }

    private func post(_ payload: ScreenContextPayload, key: String, api: CoachAPI) async {
        pending = (payload, key)
        model.set(.thinking(since: Date()))
        do {
            let receipt = try await api.postScreenContext(payload, idempotencyKey: key)
            pending = nil
            let r = receipt.record
            let card = ContextCard(recordID: r.id, version: r.version, receiptID: receipt.receipt_id, appName: r.app_name ?? payload.app_name ?? "this window",
                                   summary: r.analysis.summary, observation: r.analysis.observation, nextStep: r.analysis.next_step,
                                   replayed: receipt.replayed, modelLabel: ModelLabel.display(r.analysis.model))
            model.set(.speaking(card), collapseAfter: 20)
            point(at: card)
            afterSave()
        } catch let error as CoachError {
            model.set(.offline(error.localizedDescription, retryable: error.isRetryable))
        } catch {
            model.set(.offline("The card could not be saved.", retryable: true))
        }
    }

    /// Rings the line the card is about, when code finds one. Then the capture's lines are dropped.
    func point(at card: ContextCard) {
        defer { lines = nil }
        guard let lines, let request = PointingRequest.make(lines: lines.lines, frame: lines.frame, windowID: lines.windowID, windowBounds: lines.bounds, windowPID: lines.pid, card: card) else {
            captureLog.notice("no line to point at")
            return
        }
        captureLog.notice("pointing at one line")
        onPoint(request)
    }

    #if DEBUG
    /// Preview Pointing: reads the fixture window on this Mac and rings the line the sample card is about.
    /// Nothing is sent.
    func previewPointing(card: ContextCard) {
        guard let window = fixtureWindow else { model.set(.notice("Start with -fixtureImage and -fixtureWindow YES"), collapseAfter: 4); return }
        window.bringForward()
        Task {
            try? await Task.sleep(for: .seconds(0.4))
            guard let read = try? VisionTextReader().readLines(window.image) else { return }
            let record = PointingController.record(of: window.windowID)
            lines = (read, window.contentFrame, window.windowID, record?.bounds, record?.pid)
            model.set(.speaking(card), collapseAfter: 20)
            point(at: card)
        }
    }
    #endif

    func undo() {
        guard let card = model.lastCard, !card.isPreview, let api = Connection.api()?.api else { return }
        Task {
            do {
                _ = try await api.hideScreenContext(id: card.recordID, expectedVersion: card.version, idempotencyKey: "undo-\(card.recordID)-v\(card.version)")
                model.lastCard = nil
                model.set(.notice("Removed from your record"), collapseAfter: 3)
                afterSave()
            } catch {
                model.set(.offline("Undo failed: \((error as? LocalizedError)?.errorDescription ?? "try again")", retryable: false), collapseAfter: 8)
            }
        }
    }

    private func frontApp() -> FrontApp {
        let app = NSWorkspace.shared.frontmostApplication
        if usesFixture { return FrontApp(name: "TextEdit", bundleID: "com.apple.TextEdit", processID: 0) }
        return FrontApp(name: app?.localizedName ?? "this app", bundleID: app?.bundleIdentifier ?? "", processID: app?.processIdentifier ?? 0)
    }
}

/// Stands in for the screen during local testing: returns a fixed image as the "window".
struct FixtureCapture: WindowCapturing, @unchecked Sendable {
    let image: CGImage
    var window: FixtureWindow?
    func capture(_ app: FrontApp) async throws -> CapturedWindow {
        guard let window else { return CapturedWindow(image: image, app: app) }
        let (frame, id) = await MainActor.run { (window.contentFrame, window.windowID) }
        return CapturedWindow(image: image, app: app, frame: frame, windowID: id)
    }
}

/// DEBUG: the fixture image in an ordinary titled window, at its natural point size (pixels / 2),
/// so pointing can be checked and filmed without Screen Recording.
@MainActor
final class FixtureWindow {
    let image: CGImage
    private let window: NSWindow

    init(image: CGImage) {
        self.image = image
        let size = NSSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        window = NSWindow(contentRect: NSRect(x: screen.minX + 80, y: screen.maxY - size.height - 80, width: size.width, height: size.height),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "meeting-prep.png"
        window.isReleasedWhenClosed = false
        let view = NSImageView(frame: NSRect(origin: .zero, size: size))
        view.image = NSImage(cgImage: image, size: size)
        view.imageScaling = .scaleAxesIndependently
        window.contentView = view
        window.orderFrontRegardless()
        // `-fixtureMoveAfter <seconds>` moves the window once, to check that a ring on it goes away.
        let moveAfter = UserDefaults.standard.double(forKey: "fixtureMoveAfter")
        if moveAfter > 0 {
            Task { [window] in
                try? await Task.sleep(for: .seconds(moveAfter))
                window.setFrameOrigin(NSPoint(x: window.frame.minX + 60, y: window.frame.minY))
            }
        }
    }

    func bringForward() { window.orderFrontRegardless() }

    var windowID: CGWindowID { CGWindowID(window.windowNumber) }

    /// Where the image is on screen, in global points with the origin at the main display's top left.
    var contentFrame: CGRect {
        let rect = window.convertToScreen(window.contentLayoutRect)
        let mainHeight = NSScreen.screens.first?.frame.height ?? rect.maxY
        return CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}
