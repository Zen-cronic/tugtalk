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

    var afterSave: () -> Void = {}

    init(model: CompanionModel) {
        self.model = model
        // `-fixtureImage <png>` reads that file instead of the screen: no Screen Recording needed.
        if let path = UserDefaults.standard.string(forKey: "fixtureImage"), let image = try? ImageLoading.cgImage(at: URL(fileURLWithPath: path)) {
            pipeline = ScreenContextPipeline(gate: CaptureGate(denyList: Settings.denyList), capturer: FixtureCapture(image: image))
            usesFixture = true
        } else {
            pipeline = ScreenContextPipeline(gate: CaptureGate(denyList: Settings.denyList))
            usesFixture = false
        }
    }

    func capture() {
        guard !busy else { return }
        guard let api = Connection.api()?.api else {
            model.set(.offline(Connection.isLocalDevelopmentRequested ? "The local test server settings are not usable." : CoachError.notConfigured.localizedDescription, retryable: false))
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
            // Keep "listening" on screen long enough to be seen.
            let shown = Date().timeIntervalSince(started)
            if shown < 0.9 { try? await Task.sleep(for: .seconds(0.9 - shown)) }
            guard let payload = ScreenContextPayload.make(redacted: result.redacted, appName: front.name, goalID: Settings.goalID, purpose: Settings.purpose) else {
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
            model.set(.speaking(ContextCard(recordID: r.id, version: r.version, receiptID: receipt.receipt_id, appName: r.app_name ?? payload.app_name ?? "this window",
                                            summary: r.analysis.summary, observation: r.analysis.observation, nextStep: r.analysis.next_step,
                                            replayed: receipt.replayed, modelLabel: ModelLabel.display(r.analysis.model))), collapseAfter: 20)
            afterSave()
        } catch let error as CoachError {
            model.set(.offline(error.localizedDescription, retryable: error.isRetryable))
        } catch {
            model.set(.offline("The card could not be saved.", retryable: true))
        }
    }

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
struct FixtureCapture: WindowCapturing {
    let image: CGImage
    func capture(_ app: FrontApp) async throws -> CapturedWindow { CapturedWindow(image: image, app: app) }
}
