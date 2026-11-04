# Fictional follow-up practice (contract 0.9.1)

A practice exercise proposes a different fictional scenario from one saved objective assessment. The person confirms the scenario before it becomes an active [practice round](practice.md). An assessed answer is a fallible model interpretation, not a measured completion, communication improvement or demonstrated learning transfer.

This resource is separate from habit-count `exercises.basis`. It never creates a generic measured check-in. No additional provider call is made to propose or activate it; the existing voice pipeline assesses the later answer.

## Read a real basis

Fetch fresh overview, the focused goal context, then `GET /v1/practice-rounds/{id}`. Use the returned opaque identifiers and versions:

- `goal_id` and the current goal's version.
- Source round `id`, `version` and `request_version`.
- Its last `answer_sources` entry: `id` is `voice_id`, `version` is `voice_version`.
- One ID from `objectives`, matched to the current `assessment.objectives` entry.

The source must be current, terminal (`addressed`, `capped` or `ended`), not disputed, without a pending turn, and belong to this account and goal. It must be ordinary practice, not an exercise-created round; exercise chains are not supported in this version. `address_gap` requires `partial` or `not_addressed`; `transfer` requires `addressed`. Unclear/unavailable results do not establish a gap. The server reads the actual stored assessment rather than trusting a supplied score or outcome.

## Propose, then confirm

`POST /v1/practice-exercises`, with authentication and a new `Idempotency-Key`:

```json
{
  "goal_id": "copy-from-current-goal",
  "expected_goal_version": 1,
  "title": "Explain a conditional commitment",
  "request_text": "Fictional rehearsal: a customer requests Tuesday delivery, but an external approval is pending. Explain what you can commit to.",
  "scenario_type": "fictional_practice",
  "purpose": "address_gap",
  "basis": {
    "round_id": "copy-from-source-round",
    "round_version": 4,
    "request_version": 1,
    "voice_id": "copy-from-last-answer-source",
    "voice_version": 1,
    "objective_id": "copy-from-confirmed-objective"
  }
}
```

Replace all example IDs and versions with fresh returned values. Titles are limited to 160 characters, requests to 2000. The server copies one confirmed objective unchanged. It rejects an exact normalized copy of the source request; this is not proof that a new scenario is useful or meaningfully different. Do not invent real customer/work facts: scenarios are explicitly fictional. If the objective is too specific to reuse, revise it with the person first.

Creation returns a receipt and a `proposed` exercise. Only one proposed/active practice exercise is allowed per goal. Another goal is independent. `created_via:connector` identifies the API route, not proof that personal Muse authored it. A real Muse interaction must be observed before making that claim.

Show the scenario and copied objective. Once the person confirms that exact content, `PATCH /v1/practice-exercises/{id}`:

```json
{
  "expected_version": 1,
  "action": "activate",
  "confirmed": true,
  "content_version": 1,
  "expected_goal_version": 1
}
```

Activation revalidates the basis and atomically creates a single linked round. It refuses if another round on that goal is open. The saved exercise's `activation.round_id` identifies the new round; re-fetch it and fresh context. Exact retries return the original exercise/round pair. Only proposed/current exercises can activate; terminal exercises cannot restart. Skip and propose a new exercise for another scenario.

The connector instructions prohibit scheduled creation/activation and require an explicit user request and scenario confirmation. The server cannot independently inspect a caller's conversation or scheduling origin: `confirmed:true` records the caller's acceptance, as for ordinary practice. Never claim this field proves independent human review.

## Answer and retrieve

Read the scenario in Muse or current web context, then record against the matching goal. Existing goal-only voice clients attach to the active server round. **On the installed watch, end an old local round and start fresh first.** Do not claim its existing UI displays/selects these scenarios or supports arbitrary mid-round migration. Old Mac compatibility uses `counterpart.answer=1` as a reset sentinel; `practice.answer` is the authoritative ordinal.

`GET /v1/practice-exercises/{id}` and `practice_exercises` in fresh overview/focused context expose:

- Immutable `content_version`, goal, title, fictional request, copied `objective` and validated `basis`.
- `activation` with round/request/content versions; `latest_attempt` with exact voice/round/request references.
- `state`, `persisted_state`, `superseded`, and `freshness:{status,reasons}`.
- `result`, when present, with `evidence_type:model_assessment`, exact references and A's full assessment object.

States are `proposed`, `active`, `assessed_addressed`, `attempted`, `skipped`, `disputed`; `stale` is a projection. A matching addressed answer atomically records `assessed_addressed`. An open answer keeps the exercise active. A four-answer cap or explicit end records attempted, never success. Without an answer, ending produces no result. Exercise updates share the answer's receipt transaction and durable commit before semantic live output.

The snapshot revision covers these projections, including changes to source/target freshness. Source corrections/deletion, target answer correction/deletion, changed request revisions, disputes or supersession hide current scenario/objective/result content. Saved receipts remain historical. No model runs on reads. Freshness checks separate original basis from target result to avoid recursive dependency loops.

## Skip, dispute or revise

`PATCH` actions `skip` and `dispute` require `expected_version`. If the original target remains linked, also provide its fresh `expected_target_round_version`. Pending answers refuse lifecycle changes.

Skip is allowed from proposed/active. It ends only the exact linked target and records skipped; an intentional stop does not pretend the source changed. Dispute is allowed from proposed, active, assessed_addressed or attempted. It suppresses the exercise result and its linked A judgment even after a terminal assessment. Skipped/disputed exercises cannot reactivate.

If the person revises the target A request, that transaction detaches the exercise and marks it superseded. Dismissing/disputing the old exercise can no longer mutate the revised ordinary round. Exercise dependency checks use immutable content and original basis, not lifecycle version, so activation/completion do not invalidate themselves. A skipped linked target is valid historical ended practice; disputed/superseded judgments remain unusable.

All writes use account-global idempotency keys and optimistic versions. Reuse a key only for an exact retry. A key reserved for an answer cannot be repurposed for an exercise operation.

## Evidence boundary

Offline integration tests use actual records/routes and stubbed inference. They verify atomic activation, state transitions, retries, independent goals, source/target invalidation, terminal dispute, detached-round safety, count-drill separation and commit-before-live-output. They do not establish live Muse authorship, scenario usefulness, model accuracy, learning gain or physical-device continuity. The native package harness still applies only under its documented fresh-round precondition. Live provider calls and deployment remain separate actions.
