import AppKit
import ScreenContextCore

/// Reads the fresh overview on a slow cadence and points out changes made elsewhere: an exercise
/// Muse assigned, a revised goal, a new watch capture. The last revision is a local pointer only.
@MainActor
final class Poller {
    static let normalInterval: Double = 120
    static let demoInterval: Double = 15

    private let model: CompanionModel
    private var observed: ObservedState?
    private var loop: Task<Void, Never>?
    private var waiting: NudgeCard?
    private(set) var goals: [(id: String, title: String)] = []
    private(set) var lastStatus = ""

    init(model: CompanionModel) {
        self.model = model
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollSoon() }
        }
    }

    func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                let interval = (self?.model.demoMode ?? false) ? Self.demoInterval : Self.normalInterval
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// Restart the cadence now, for example after a capture, on wake, or when Demo mode changes.
    func pollSoon() { start() }

    func poll() async {
        guard let api = Connection.api()?.api else { lastStatus = "Not connected: no key in the Keychain"; return }
        do {
            let overview = try await api.overview()
            goals = overview.goals.map { ($0.id, $0.title) }
            let new = ObservedState(overview)
            let nudges = NudgeDiff.changes(from: observed, to: new)
            observed = new
            lastStatus = "Checked \(Date().formatted(date: .omitted, time: .shortened)) · revision \(overview.snapshot_revision.prefix(8))"
            if let first = nudges.first { await present(first, api: api) }
            showWaitingIfFree()
        } catch {
            lastStatus = "Last check failed: \((error as? LocalizedError)?.errorDescription ?? "unknown")"
        }
    }

    private func present(_ nudge: Nudge, api: CoachAPI) async {
        let card: NudgeCard
        switch nudge {
        case .exerciseAdded(let goalID, let goalTitle):
            let exercise = try? await api.goalContext(goalID).newestPending
            card = NudgeCard(headline: "New exercise in your record", detail: exercise?.title ?? "A new exercise is waiting.", goalTitle: goalTitle)
        case .goalRevised(_, let goalTitle):
            card = NudgeCard(headline: "Your goal was updated", detail: "\"\(goalTitle)\" has a new version in your record.", goalTitle: goalTitle)
        case .newCapture(_, let goalTitle, let device):
            card = NudgeCard(headline: "New \(device) capture", detail: "A practice from your \(device) was saved to this goal.", goalTitle: goalTitle)
        }
        waiting = card
    }

    /// A nudge never interrupts a capture in progress or a card being read; it waits its turn.
    func showWaitingIfFree() {
        guard let card = waiting else { return }
        switch model.phase {
        case .idle, .nudging, .notice:
            waiting = nil
            model.set(.nudging(card, opened: false))
        default:
            break
        }
    }
}
