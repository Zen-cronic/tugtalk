import SwiftUI

/// A drill Muse set for a goal: an exercise with a basis the server recounted before saving it
/// (docs/drills.md). Only the connector writes exercises; this app never does.
struct DrillBasis: Decodable, Hashable {
    let habit: String
    let source_ids: [String]
    let claimed_count: Int
}

struct Drill: Decodable, Identifiable, Hashable {
    let id: String
    let goal_id: String
    let title: String
    let instructions: String
    let basis: DrillBasis?
    let set_via: String?
    let due_at: String?
    let updated_at: String?

    /// "Today's drill" unless it is due after today.
    var heading: String {
        guard let due = due_at.flatMap({ try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse($0) }),
              !Calendar.current.isDateInToday(due), due > Date() else { return "Today's drill" }
        return "Next drill"
    }
}

/// The `drill` block on a saved capture that named a drill with X-Exercise-Id.
struct DrillMeasured: Decodable {
    let habit: String
    let capture_count: Int
    let basis_count: Int
    let basis_sources: Int
    let basis_source_word: String?
}

struct DrillOutcome: Decodable {
    let exercise_id: String
    let status: String
    let reason: String?
    let measured: DrillMeasured?

    /// One capture beside the basis, in code-measured numbers. Never a trend, so it never says "improved".
    var line: String? {
        guard status == "measured", let m = measured else { return nil }
        let one = ["hedge": "unsure word"], many = ["filler": "fillers", "hedge": "unsure words", "restart": "restarts"]
        let habit = m.capture_count == 1 ? (one[m.habit] ?? m.habit) : (many[m.habit] ?? m.habit)
        let sources = m.basis_source_word ?? (m.basis_sources == 1 ? "session" : "sessions")
        return "Drill: \(m.capture_count) \(habit) now, \(m.basis_count) in \(m.basis_sources) earlier \(sources). Counted by code."
    }
}

private struct CheckInRef: Decodable { let exercise_id: String }
private struct GoalContext: Decodable { let exercises: [Drill]; let check_ins: [CheckInRef] }


extension CoachAPI {
    /// The goal's open drill: the newest exercise with a basis, set through the connector, and no check-in yet.
    func openDrill(goalID: String) async throws -> Drill? {
        var request = URLRequest(url: baseURL.appending(path: "v1/goals/\(goalID)/context"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 45
        let (data, response) = try await URLSession.shared.data(for: request)
        guard ((response as? HTTPURLResponse)?.statusCode ?? 0) == 200 else { return nil }
        let context = try JSONDecoder().decode(GoalContext.self, from: data)
        let done = Set(context.check_ins.map(\.exercise_id))
        return context.exercises
            .filter { $0.basis != nil && $0.set_via == "connector" && !done.contains($0.id) }
            .max { ($0.updated_at ?? "") < ($1.updated_at ?? "") }
    }
}

/// Under the setup card: the drill Muse set for this goal. The next recording is measured against it.
struct DrillLine: View {
    let drill: Drill

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            // "Today's drill · set by Muse" on one line where it fits; on a small watch, two lines, never cut off.
            ViewThatFits(in: .horizontal) {
                Text("\(drill.heading) · set by Muse").lineLimit(1)
                VStack(alignment: .leading, spacing: 0) { Text(drill.heading); Text("Set by Muse") }
            }
            .face(.text, 13, weight: 600, relativeTo: .caption)
            .foregroundStyle(Palette.mutedDark)
            Text(drill.title).face(.text, 15, weight: 700, relativeTo: .headline)
                .foregroundStyle(Palette.inkDark)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Palette.rack, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// On the result: this capture's count beside the drill's basis, both measured by code.
struct DrillResultLine: View {
    let outcome: DrillOutcome

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Capsule().fill(rule).frame(width: 3)
            Text(outcome.line ?? "").face(.text, 14, weight: 600, relativeTo: .footnote)
                .foregroundStyle(Palette.inkDark)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// The habit's own colour, as on the count chips above it.
    private var rule: Color {
        switch outcome.measured?.habit {
        case "filler": return Palette.filler
        case "restart": return Palette.restart
        default: return Palette.hedge
        }
    }
}
