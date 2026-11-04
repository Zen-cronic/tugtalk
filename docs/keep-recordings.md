# Keep my recordings (contract 0.9.1)

Audio is deleted after transcription unless you turn on **Keep my recordings** (off by default). Kept audio stays in your account and you can delete it any time.

Why keep it: you can listen back and compare attempts, track progress across sessions, and re-measure old sessions when the counting improves (for example `lexicon-en-v2`, which counts "ah" and "er" as "uh").

## The setting

- `GET /v1/settings` returns `{ settings: { keep_recordings, label: "Keep my recordings", version, updated_at, kept: { recordings, bytes, cap_bytes } } }`. A new account reads `keep_recordings: false` at version 1.
- `PATCH /v1/settings` with `Idempotency-Key` and `{ "expected_version": <from a fresh read>, "keep_recordings": true | false }`. A stale version returns 409. An exact retry replays the receipt.
- **Turn off and delete kept recordings:** `{ "expected_version": n, "keep_recordings": false, "delete_kept_recordings": true }` turns it off and deletes every kept file in the same write. `delete_kept_recordings` with `keep_recordings: true` returns 400. Turning it off without that flag keeps what is already kept.
- The fresh overview (`GET /v1/overview`, and each goal's context) shows `settings: { keep_recordings, version, kept_recordings, kept_bytes }`, so Muse can say whether audio is kept. Muse reads it; it does not change it.

## What is kept

With the setting on, each `POST /v1/recordings` and `POST /v1/voice-rounds` saves the uploaded WAV, byte for byte, in the same write as its record:

- the file goes next to the database, at `media/<user>/<id>.wav` (on Modal: `/data/media/<user>/<id>.wav`, on the same volume), written to a temporary name, flushed and renamed;
- the record gets `media: { kept: true, kind: "audio", bytes, sha256, content_type: "audio/wav", kept_at, duration_ms }`, where `duration_ms` is the length read from the WAV header and `audio_retained: true`;
- the hosting adapter commits the volume before it answers, so the file and its record are acknowledged together;
- an exact retry (same `Idempotency-Key`, same audio) replays the receipt and writes nothing again;
- a voice round that fails (502) saves nothing, and keeps nothing.

The API accepts `kind: "video"` (`.mp4`) for a later clip feature; only audio is wired today.

**The cap** is 200 MB per account (`MEDIA_CAP_BYTES`, about 70 minutes of 24 kHz mono audio). When it is full the capture is still saved and measured, without its audio, with `media: { kept: false, reason: "full", message: "Your kept recordings are full (200 MB). Delete some to keep new ones." }`.

## Seeing, downloading and deleting

| Method | Path | Does |
|---|---|---|
| GET | `/v1/media` | Your kept recordings: `id`, `record_kind` (`sessions` or `voice-rounds`), `bytes`, `sha256`, `kept_at`, `occurred_at`, `duration_ms` (from the WAV header; for a file kept before it was stored, read from the stored file's header; `null` if unreadable). No audio. Plus `recordings`, `bytes`, `cap_bytes`. |
| GET | `/v1/media/{id}` | The audio, `audio/wav`, with `X-Media-Sha256`. Another account's id, or one that is not kept, is a 404. 120 downloads per hour. |
| DELETE | `/v1/media/{id}` | Deletes the file and the record's reference. The record gets a new version with `media: { kept: false, deleted_at }` and `audio_retained: false`. Needs `Idempotency-Key`. |
| DELETE | `/v1/media` | Deletes every kept recording, and anything else in your media folder. Needs `Idempotency-Key`. |

Every write needs write scope; a read-only key gets 403.

## Re-measure

`POST /v1/sessions/{id}/remeasure` with `Idempotency-Key` and `{ "expected_version": n }` re-runs the code metrics (today's lexicon and pause rules) on the saved transcript. It is free: no model call. The result is a new session version: `metrics` holds the new numbers, and every earlier measurement stays in `measurements`, oldest first, with its version and time. `remeasured` says when, from which version, which method, and whether anything changed. The observation and the adjudication are not rewritten; they still describe the first measurement.

`{ "expected_version": n, "retranscribe": true }` first sends the kept recording to Meta's transcription again. This is paid, so it runs only with the flag, and only for a session whose recording was kept (otherwise 409 `recording_not_kept`, before any call). The earlier transcript is kept with its metrics in `measurements`. At most 30 re-measures per hour, free or paid. Only captured sessions (`source: capture`) can be re-measured.

## What is never done

- Kept audio is never logged. A download's request-log row hashes a fixed label, not the audio.
- Kept audio is never sent to a model, except the re-transcription you ask for with `retranscribe: true`.
- With the setting off, nothing in `src/media.mjs` writes a byte, and records are exactly as before the setting existed.
