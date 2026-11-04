# Confirmed practice requests (contract 0.8.0)

A practice round keeps a request, its objectives and the current conversation on the server, scoped to one goal. Spark interprets each spoken answer against that confirmed request. Its assessment is a **model judgment**, not a code-measured success, proof of truth or evidence of improvement. Code validates ownership, versions, evidence spans and transitions; code cannot establish semantic correctness from a matching quote.

## Create and read

Authenticate with the existing Bearer token. Every write needs a unique `Idempotency-Key`; reuse only for the exact same request. `POST /v1/practice-rounds` accepts:

```json
{
  "goal_id": "an-owned-goal-id",
  "expected_goal_version": 1,
  "request_text": "When can you deliver, and what does it depend on?",
  "objectives": [
    {"id": "delivery", "text": "Explain the delivery commitment and dependency."}
  ],
  "confirmed": true,
  "sources": []
}
```

Confirm the wording with the person before creating/revising. `confirmed:true` records the caller's acceptance; it does not prove independent human review. Request text is limited to 2000 characters, objectives to 1–3 with unique IDs and 240-character descriptions, source references to 5. Each optional `{kind,id,version}` source is a visible session or screen context belonging to the same goal at that exact version. No model is called to create a request. Do not retain full screenshots or window text here; submit only the confirmed request.

Read `GET /v1/practice-rounds/{id}` or the `practice_rounds` field of fresh overview/focused goal context. Reads never call a model. Snapshot revisions include round state and source freshness. A GET from another account returns 404.

## Answer from a device

Existing WAV `/v1/voice-rounds` and live voice calls can send `X-Practice-Round-Id` + `X-Practice-Round-Version` (live fields `practice_round_id` + `practice_round_version`) together with the goal ID. Installed clients that only send the goal automatically select its sole persisted-open round; if none is open, the latest lifecycle mutation is authoritative. A closed/stale/disputed round returns 409 with a fetch/revise instruction. A goal with no semantic history retains its existing sparring behavior. Ordinary `/v1/recordings` remains count-only. Unlinked audio never acquires an implicit goal.

One existing Spark reply call returns the follow-up and an assessment per confirmed objective. Outcomes are `addressed`, `partial`, `not_addressed`, `unclear`. Addressed/partial require exact nonempty answer spans using UTF-16 offsets, end-exclusive. Duplicate/extra IDs, missing objectives and invalid evidence abstain. Malformed or unavailable assessment while still open uses: “I couldn't assess that answer. Please try again or revise the practice request.”

At the fourth unanswered attempt the unavailable line explicitly says the round is over and asks the person to revise the request, rather than soliciting a fifth answer. Addressed rounds use a fixed “My assessment...” closure; capped rounds explicitly say the request was not confirmed as addressed.

A relevant refusal or conditional commitment may address the request. Irrelevant dates/numbers do not establish a useful answer. A valid quote still does not establish relevance, truth or feasibility. No numeric confidence is exposed. Model-produced follow-up relevance is not certified by quote checks.

The additive `practice` response contains round/request versions, answer number, lifecycle state and labelled assessment. Compatibility `counterpart` carries null `need` and null `need_met`, with answer 1 on the first answer to reset an old Mac's lexical tally. `model_assessed_addressed` is never `measured_close`. Existing clients can speak the response but do not display the full semantic assessment; Muse/API is needed to inspect and revise a request. Old watch 409 handling may offer retries, which remain free of repeated inference. Empty legacy `/voice-rounds/end` does not end a semantic round.

## Lifecycle and concurrent devices

Persisted states: `open`, `addressed`, `capped`, `ended`, `disputed`. `stale` is a projection when dependencies change. All objectives addressed closes as `addressed`; otherwise four answers close as `capped`, which never means success.

`PATCH /v1/practice-rounds/{id}` needs `expected_version` and `action`:

- `revise`: new confirmed brief fields, current `expected_goal_version`; increments request_version, clears current assessment/answer dependencies, resets count, reopens.
- `end`: ends without success; leaves request_version unchanged.
- `dispute`: makes assessment unusable; leaves request_version unchanged.
- `recover`: only after a pending attempt is older than five minutes; fails that attempt, increments reservation epoch and releases its lock. Use a fresh answer key afterward.

Each mutation increments round version and records an event. Create/revise enforce one persisted-open round per goal even if it is stale. Other goals remain independent. End/revise/dispute refuse while an answer is pending.

An answer reserves the round before any paid ASR/model call. The reservation and attempt key are persisted; a concurrent answer fails before inference. A failed or recovered key is consumed permanently, preventing uncertain retries from spending twice. Recovery changes the epoch/nonce: a late original result cannot apply. A successful exact replay returns its historical receipt before current-round selection, even after closure/revision. Re-read current state before using historical evidence. Changed audio/parameters under the same key returns 409.

On the volume-backed host, `persist` checkpoints/closes SQLite and asks the adapter to commit while retaining its lock. The worker waits for `go` before reopening and starting inference. Semantic live replies/speech use a second commit acknowledgement after saving. Commit failure emits no semantic reply/speech and no success. Legacy routes retain their existing streaming behavior.

## Invalidating evidence

Goal/source version changes or hidden/deleted sources make the current request stale. Earlier answer revisions also invalidate the assessment. New answers refuse until confirmed revise; revisions clear current answer dependencies while retaining historical records. Source-derived request/assessment text is withheld from current stale projections. Results finishing after a source change cannot apply.

Count-drill citations to stale/disputed/superseded semantic answers are rejected. New count bases store source versions; existing count bases still check visibility and count consistency. A stale basis is shown in `exercise_basis_status` and cannot create a new measured completion. This change does not add semantic exercise assignment.

## Evaluation status

Deterministic tests use mocked model outputs and prove state/validation behavior only. No new live provider evaluation is included. The 24 synthetic candidates and 4 separate calibration examples in `test/fixtures/practice-candidates.json` carry `human_review_pending`, not verified labels. Run `node scripts/eval-practice.mjs` for the lexical and topic/negation heuristic predictions. Neither is a semantic ground truth.

`node scripts/eval-practice.mjs --prepare with_brief` prepares offline requests; `without_brief` and `without_history` remove the named context. This command makes no network call. Human review must freeze an independent label set before recorded responses can be scored with `--score <reviewed-corpus.json> <responses.json>`. Response records require case ID, condition, model, provider request ID and assessment. Report missing responses, abstention, false success and false rejection with denominators separately. Review follow-up usefulness separately. Do not claim model reliability, cross-device usability or learning gain from mocked tests.

The topic/negation baseline is a limited heuristic, especially on useful refusals and uncertainty. It is not a strong semantic baseline. Recorded scoring is binary addressed-versus-other with abstention and ambiguous labels reported separately; it does not establish four-class agreement or satisfy a four-class accuracy gate.
