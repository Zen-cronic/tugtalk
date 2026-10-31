# Fresh goal context

Contract 0.2.0. Deployed to the existing Modal preview October 30, 2026.

1. Every goal-related turn reads `GET /v1/overview` for the authenticated account.
2. Bind a focused conversation to an explicit owned `goal_id`, then read `GET /v1/goals/{id}/context`. Do not choose a goal based on whichever other chat was last active.
3. Write only requested changes, with a distinct idempotency key and fresh expected_version for patches.
4. Read the overview and focused context again after writes or conflicts. If retrieval fails, say current state is unavailable; do not present chat history as current.

Both routes compute from one committed SQLite read transaction. Overview progress is grouped by goal; focused exercises/check-ins are filtered by goal and user. Shared evidence remains account-wide and explicitly unassigned. All responses use no-store, as_of, snapshot_revision and request_id; the revision hashes content and may remain unchanged across successful fresh reads.

`src/fresh-client.mjs` is the app-side stateless reader: `createFreshReader({baseUrl, token}).overview()` or `.goal(goalId)`. Use it server-side with the appropriate user's credential. It requests no-store, validates request metadata and a 30-second freshness tolerance, and throws on failures without retaining a cached result. No UI has been added.

The live two-chat test passed: A's completion/target update and B's skipped/target update stayed separate; an existing overview conversation retrieved the changed state without receiving it in the prompt. Nine Node tests and two adapter tests pass.

An idle Muse message does not update automatically. Muse's compliance with retrieval instructions is observed, not enforced by our backend. Chat binding is currently an agent convention; all goal reads require the same user's authenticated scope, but that scope is not restricted to one chat's goal.
