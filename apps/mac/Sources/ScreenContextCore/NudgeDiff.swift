import Foundation

/// The parts of the overview the companion compares between polls. Kept in memory only.
public struct ObservedState: Sendable, Equatable {
    public struct Goal: Sendable, Equatable {
        public let title: String
        public let version: Int
        public let pending: Int
        public let latestMeasurementID: String?
        public let latestMeasurementDevice: String?
    }
    public let revision: String
    public let goals: [String: Goal]

    public init(revision: String, goals: [String: Goal]) { self.revision = revision; self.goals = goals }

    public init(_ overview: Overview) {
        revision = overview.snapshot_revision
        goals = Dictionary(uniqueKeysWithValues: overview.goals.map {
            ($0.id, Goal(title: $0.title, version: $0.version, pending: $0.progress.pending_exercises,
                         latestMeasurementID: $0.latest_measurement?.id, latestMeasurementDevice: $0.latest_measurement?.capture_device))
        })
    }
}

/// A change made somewhere else (Muse, the watch) that the companion should point out.
public enum Nudge: Sendable, Equatable {
    case exerciseAdded(goalID: String, goalTitle: String)
    case goalRevised(goalID: String, goalTitle: String)
    case newCapture(goalID: String, goalTitle: String, device: String)

    public var goalID: String {
        switch self {
        case .exerciseAdded(let id, _), .goalRevised(let id, _), .newCapture(let id, _, _): return id
        }
    }
}

public enum NudgeDiff {
    /// Compares two polls. The same revision means nothing changed. The companion's own Mac
    /// captures change the revision too, but never produce a nudge.
    public static func changes(from old: ObservedState?, to new: ObservedState) -> [Nudge] {
        guard let old, old.revision != new.revision else { return [] }
        var nudges: [Nudge] = []
        for (id, goal) in new.goals.sorted(by: { $0.key < $1.key }) {
            guard let before = old.goals[id] else { continue }
            if goal.pending > before.pending { nudges.append(.exerciseAdded(goalID: id, goalTitle: goal.title)) }
            else if goal.version > before.version { nudges.append(.goalRevised(goalID: id, goalTitle: goal.title)) }
            else if let latest = goal.latestMeasurementID, latest != before.latestMeasurementID, goal.latestMeasurementDevice != "mac" {
                nudges.append(.newCapture(goalID: id, goalTitle: goal.title, device: goal.latestMeasurementDevice ?? "device"))
            }
        }
        // An exercise is the most useful thing to point at, then a revised goal, then a capture.
        return nudges.sorted { rank($0) < rank($1) }
    }

    private static func rank(_ nudge: Nudge) -> Int {
        switch nudge { case .exerciseAdded: 0; case .goalRevised: 1; case .newCapture: 2 }
    }
}
