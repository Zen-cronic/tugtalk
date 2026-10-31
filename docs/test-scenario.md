# Synthetic live test

Use only the Synthetic Coaching Modal Test connector. No personal memories, other connectors, real recordings or native Muse goals. The service starts with two fictional sessions and no goals/exercises/check-ins. For the deployed test, inspect the hosted database snapshot and correlate request IDs with Muse output; `npm run audit` only reads the local DB. Local test results are separate from live Muse results.

## 1. Authorize and read

After secure API-key entry, ask Muse to verify GET `/v1/context`. Expect two sessions (`session-before`, `session-after`), both version 1, zero goals and completions, and no measured improvement. Confirm an authenticated 200 in the hosted request log.

## 2. Goal and exercise

Prompt:

> Using only Synthetic Coaching Modal Test, read fresh context, create a goal titled “Pause before answering” with target “Listen to the full question, pause briefly, then answer,” and assign one exercise titled “One deliberate pause” with instructions “In a synthetic practice exchange, wait until the question ends, pause, then answer.” Do not mark it completed. Use the documented idempotency headers. Tell me the saved IDs/versions and receipt IDs, or explicitly say if a write failed. Do not create a native Muse goal or schedule.

Expect one goal, one assigned exercise, zero check-ins. Compare receipts, not just response prose.

## 3. Completion

Prompt:

> For this synthetic test, I report that I completed that assigned exercise once. Record a completed check-in with feedback “I tried one pause before answering.” This is a self-report, not a measured outcome. Read current context and tell me what has been saved and what remains unknown, with the write receipt. Do not infer that my communication improved.

Expect one check-in with `evidence_type=self_reported`, one self-reported completion, and `measured_improvement=null`.

## 4. Correction and goal revision

Prompt:

> Correct the synthetic evidence: session-after should say “Correction: the speaker interrupted before the question ended.” Its simulated pause is 80 ms, not 820. Reason: “Fixture attribution corrected.” Also revise my existing goal target to “Listen to the entire question before answering.” Use fresh expected_version values and distinct idempotency keys. Then read fresh context and explain how the correction changes the evidence, keeping self-reported completion separate from improvement. Show the saved versions and receipts.

Expect session-after version 2 / 80 ms; goal version 2. Improvement remains unestablished.

## 5. File retrieval

Prompt:

> Use the Synthetic Coaching Modal Test connector to GET /v1/files/evidence.txt. Report the current session-after text and version from the file, not this chat. Do not create files, upload anything, or use another service.

Expect server GET 200; current corrected text and version 2.

## 6. Fresh-chat continuity

Create a new Muse side chat without copying earlier results. Prompt:

> Using only Synthetic Coaching Modal Test, retrieve my current goal, assigned exercise, completion feedback and latest session evidence. What progress is supported and what is still unknown? Cite the retrieved IDs and versions. Do not rely on memories or earlier chat messages and do not write anything or create schedules.

Expect a fresh server GET and correct goal version 2, corrected session-after, one self-reported completion, no measured improvement claim.

## Scope of a pass

`node scripts/verify-live.mjs` checks persisted records and selected request receipts. It does not assess Muse's displayed response; inspect that separately. Record failed attempts, approvals, latency and manual interventions. One pass establishes feasibility only. Audio, scheduled authenticated access, clients-closed execution, phone notifications, and native Goals synchronization need additional tests.
