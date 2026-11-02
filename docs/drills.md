# Drills set by Muse (contract 0.7.1)

Muse, the person's own assistant, can set the next drill for a goal. It has to give a reason in numbers, and the server checks that reason before saving anything. The watch then shows the drill, and the next capture records one measured result against it.

## 1. Muse sets a drill

Muse writes `POST /v1/exercises` with a `basis`:

```json
{
  "goal_id": "…",
  "title": "Answer without hedges",
  "instructions": "Give the decision in one sentence, then one reason.",
  "basis": { "habit": "hedge", "source_ids": ["<session id>", "<voice round id>"], "claimed_count": 3 },
  "due_at": "2026-11-03T15:00:00Z"
}
```

- `habit` is `filler`, `hedge` or `restart`.
- `source_ids` lists 1–10 ids of the person's own measured captures (`source: capture`) or voice rounds from the last 14 days. Fixture sessions, hidden sessions and ids from another account are refused (422 `basis_source_invalid`, with each refused id and why).
- `claimed_count` is the sum of `metrics.<habit>_count` over those ids.
- `due_at` is optional and at most 7 days ahead. There is no minimum lead time, so a drill can be due the same morning.

The server recounts the basis from the stored metrics inside the write (`checkBasis` in `src/drills.mjs`). If the sum differs, nothing is saved and the reply is:

```json
{ "error": "basis_mismatch", "message": "The basis claims 3 hedges; code counts 4 in the cited sources. …",
  "recomputed": { "habit": "hedge", "count": 4, "per_source": [{ "id": "…", "count": 3 }, { "id": "…", "count": 1 }] } }
```

Muse corrects `claimed_count` and retries with a new Idempotency-Key. A saved drill carries `basis` (with the per-source counts the server found) and `set_via: "connector"`.

**One open drill per goal.** An open drill is an exercise with a basis and no check-in. A second one on the same goal returns 409 `drill_open` with `open_exercise_id`. A check-in (completed or skipped) closes it.

**Who sets it.** Only the connector writes `POST /v1/exercises`: no file under `apps/` calls it (FACTS `drill-set-by`). That is why the watch can say "set by Muse". Muse writes only when the person asks: in chat, or in the instructions of a scheduled task the person created. A scheduled task may create at most one drill per goal and nothing else.

## 2. The watch shows it

On launch and when the goal changes, the watch reads `GET /v1/goals/{id}/context` and picks the newest exercise with a basis and no check-in. The setup card then shows **Today's drill · set by Muse** with the drill's title (or **Next drill** when it is due after today).

## 3. One capture records a measured result

While a drill is open, the watch sends its id as `X-Exercise-Id` with the next recording. Before any model call, the server checks that the exercise exists on this account and belongs to the capture's goal (404 or 400 otherwise, at no cost). After the capture is measured, in the same write as the session, the server writes one check-in:

```json
{ "status": "completed", "evidence_type": "measured",
  "measured": { "habit": "hedge", "capture_count": 0, "basis_count": 3, "basis_sources": 2, "basis_source_word": "sessions", "session_id": "…", "capture_device": "watch" },
  "feedback": "Measured by code: 0 hedges in this capture (session …). The drill's basis was 3 hedges in 2 sessions. One measured result, not a trend." }
```

The session record gets a `drill` block with the check-in id, and the watch shows **Drill: 0 hedges this capture · basis 3 in 2 sessions · measured by code**.

- It is recorded once per drill. A later capture that names the same drill saves normally and gets `drill: { status: "not_measured", reason: "already_recorded" }`.
- An exercise without a basis is never measured (`reason: "no_basis"`).
- The exercise id is part of the capture's idempotency fingerprint, so a retry must name the same drill, and an exact retry replays the same check-in without calling a model again.
- A measured check-in is not counted as a self-reported completion, and `measured_improvement` stays null.

## What this is not

One capture beside a basis is one measured result. It is not improvement and not a trend, and nothing here says so. The counts are word-list counts from an automatic transcript (`docs/capture.md`), the same number the watch shows.
