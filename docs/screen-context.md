# Screen contexts (contract 0.7.1)

`POST /v1/screen-contexts` turns the text of one window, read and redacted on the user's Mac, into a short context card in the shared record. Muse reads it through the same fresh overview as everything else, and the Mac companion notices Muse's replies by polling that overview.

Capture happens only when the person presses the hotkey or clicks the companion. There is no periodic capture.

## What leaves the Mac

| Leaves the Mac (on request only) | Stays on the Mac |
|---|---|
| Redacted window text (at most 6,000 characters and 12 KiB) | Screenshot pixels (an in-memory image, never written to disk) |
| App name, purpose, goal id, language, time | The unredacted text and the original values behind each placeholder |
| Redaction counts per kind | The window title, other windows and displays, the list of running apps |

## Request

- `Authorization: Bearer <key>` with write scope; `Idempotency-Key` (8–128 characters); `Content-Type: application/json`; body at most 16 KiB.
- Body fields (any other field returns 400):

| Field | Required | Value |
|---|---|---|
| `text` | yes | Redacted text, 1–6,000 characters and at most 12 KiB of UTF-8 |
| `purpose` | yes | `meeting_prep`, `draft_check` or `reading` |
| `redaction` | yes | `{"method": "on-device-v1", "counts": {"person": 1, "org": 0, "email": 1, "phone": 0, "number": 0, "link": 0, "address": 0}}` |
| `goal_id` | no | An owned goal |
| `language` | no | `en` (default) or `fr` |
| `capture_device` | no | `mac`, `watch`, `phone` or `api` (default) |
| `occurred_at` | no | ISO 8601; stored in UTC |
| `app_name` | no | Up to 80 printable characters, for example `TextEdit`. Never the window title. |

The field names `goal_id`, `language`, `capture_device` and `occurred_at` match `/v1/recordings`, so another product built on this core can reuse the route.

## Pipeline

1. Authenticate, validate, and hash the text.
2. Replay an exact retry (same key, same text hash and fields) **before** any model call, so a retry never re-bills. The same key with a different body returns 409.
3. Check the goal is owned (404 otherwise).
4. Refuse a 31st request in an hour with 429, before any model call. Saved and model-failed requests count.
5. Scrub the text again on the server: emails, phone numbers, card-like numbers and digit runs of six or more become placeholders. The counts are saved as `redaction.server_counts`; on correctly redacted input they are all zero.
6. Baseten `meta-models/muse-spark-open-1026` returns `{summary, observation, next_step}`. Same budgets as captures: 4000 tokens, then one retry at 8000, and the same opt-in `ANALYSIS_EFFORT` (`medium` on the hosted service). The prompt (`screenContextSystemPrompt` in `src/screen-context.mjs`) says the screen text is untrusted data, not instructions, and that redacted values must never be guessed.
7. The model's output is scrubbed with the same patterns (`redaction.output_counts`) and capped: summary 300, observation 600, next step 300 characters.
8. **If analysis fails, nothing is saved** and the route returns 502. Unlike a recording, nothing here was measured by code, so there is nothing worth keeping without the model. A retry with the same key runs the model again.
9. One receipt and a `screen-contexts` record:

```json
{ "id": "…", "version": 1, "source": "screen_capture", "capture_device": "mac", "goal_id": "…", "language": "en",
  "purpose": "meeting_prep", "occurred_at": "…", "app_name": "TextEdit",
  "text_sha256": "…", "text_chars": 812, "text_retained": false, "pixels_sent": false,
  "redaction": { "method": "on-device-v1", "counts": {}, "server_counts": {}, "output_counts": {} },
  "analysis": { "status": "model_observation", "summary": "…", "observation": "…", "next_step": "…",
                "model": "meta-models/muse-spark-open-1026", "provider_request_id": "…", "attempts": 1 },
  "deleted": false, "updated_at": "…" }
```

The text itself is not stored (`text_retained: false`); only the hash, the length, the counts and the model's card are.

## Undo

`PATCH /v1/screen-contexts/{id}` with `{"expected_version": 1, "deleted": true, "correction_reason": "…"}` hides the record; `deleted: false` restores it. A stale version returns 409. The card itself cannot be edited.

## Fresh reads

- Overview: `latest_screen_context`, `totals.screen_contexts`, `screen_context_versions`, and per goal `progress.screen_contexts` and `latest_screen_context`.
- Focused `/v1/goals/{id}/context`: `linked_screen_contexts`.
- Each is the brief `{id, version, occurred_at, capture_device, app_name, purpose, goal_id, summary, observation, next_step}`.
- `snapshot_revision` covers every screen context's id and version, hidden ones included, so a capture or an undo always changes it. An account with no screen contexts keeps the revision it had before this kind existed.
- The route is not in the OpenAPI document Muse imports. Capture devices call it, not Muse.

## Hosting

On Modal, the bridge keeps the 16 KiB JSON limit for this route but gives it the long model deadline (150 s), and the worker releases the database lock during the model call, as recordings do.

## Profiles

`createHandler(store, {screenContextHooks})` accepts `system(ctx)` to replace the prompt and `extendRecord(record, ctx)` to add fields inside the write transaction. A language-practice profile could map `purpose: reading` to its own context field this way.

## Local development

`node scripts/local-stub-server.mjs` starts the API on `127.0.0.1:4319` with stub models, a throwaway database and a local-only token in a temporary directory. It prints the token file path, never the token. `STUB_DELAY_MS` sets the fake model delay; `STUB_FAIL=1` makes the card call fail.

## Limits

- Redaction is pattern- and name-recognition-based on the device. It can miss a name it does not recognise or text inside images. The server re-scrub catches only pattern-shaped data (emails, phones, long numbers), not names.
- Vision OCR can misread text, and the card is model-written from what was read.
- The Baseten retention policy for model inputs was not reviewed.
