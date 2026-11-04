# Capture pipeline (contract 0.9.1)

`POST /v1/recordings` turns one short recording from any device into measured session evidence that every other surface (Muse chats, scheduled Muse tasks, the app reader) reads through the same fresh overview. Context is never stored only on the capturing device.

## Request

- `Authorization: Bearer <key>` with write scope; `Idempotency-Key` (8–128 chars).
- `Content-Type: audio/wav`; body is mono 16-bit PCM WAV at 16 or 24 kHz, 0.5–180 s, ≤8 MiB.
- Optional headers: `X-Goal-Id` (owned goal), `X-Language` (`en` default, `fr`), `X-Capture-Device` (`watch`, `mac`, `phone`, `api`), `X-Occurred-At` (ISO 8601), `X-Exercise-Id` (an open drill: the capture then records one measured check-in against its basis; `docs/drills.md`).

## Pipeline

1. Authenticate, validate headers, read audio, and replay an exact retry (same key, same audio hash and headers) **before** any model call, so retries never re-bill. The same key with different content returns 409. Then the hourly limit: at most 30 recordings per account in the last hour (saved or model-failed); the 31st returns 429 before any model call. A replay is never refused.
2. Check the goal exists and the WAV header is supported; failures return 4xx without inference.
3. Meta Model API `POST /v1/asr/transcribe`, `muse-voice-transcribe-1.0`, `ENDPOINTING`, language bias from `X-Language`. A failure returns 502 and saves nothing.
4. Code computes `word_count`, `words_per_minute`, fillers, hedges, restarts and immediate repeats from a conservative per-language lexicon (`lexicon-en-v2`, `lexicon-fr-v1`). From the transcription's ENDPOINTING turns it adds `metrics.pauses` (`turn-gaps-v1`, `src/pauses.mjs`): gaps from 250 ms, the longest pause, pauses of 1 s or more, silence before the first and after the last turn, speaking time and words per speaking minute. Missing or impossible turn times give `status: "invalid_turns"` and no numbers.
5. Two Baseten `meta-models/muse-spark-open-1026` calls run side by side. Both are reasoning-model calls through one loop (`sparkJSON`): 4000 max tokens and, if the reply is unusable, one retry with 8000.
   - Observation: returns `{observation, suggested_exercise}`. Code never takes numbers from it. It asks for the reasoning effort in `ANALYSIS_EFFORT` (`low`, `medium`, `high` or `xhigh`; the hosted service sets `medium`). Unset, or any other value, sends no `reasoning_effort` and the provider default applies. An empty, malformed or failed reply saves the session with `analysis.status: "unavailable"`.
   - Adjudication (`src/adjudicate.mjs`), only when the transcript has ambiguous lexicon hits: the model labels each proposed hit `habit` or `content`. Code accepts a label only if it names a proposed candidate once and copies its quote exactly; otherwise, or on any failure, the lexicon count stands. The model can remove a proposed hit but never add one.
One time budget covers steps 3 and 5 (`src/budget.mjs`): 120 s per recording, 30 s under the hosting adapter's 150 s deadline. Behind the adapter it is also cut to what is left of the request's own deadline, so time spent waiting for another model request counts. Every provider call is cut off when the budget runs out, and a call that cannot start with enough time left (10 s for transcription, 15 s for a Spark call) is never sent. Transcription refused this way returns 503 `time_budget` and costs nothing. A Spark call refused this way is skipped, and the session saves without it: `analysis.status: "unavailable"`, or the lexicon count with `adjudication.status: "fallback"`. Both carry the reason. So a recording always answers before the adapter gives up, and a retry finds its receipt. Worst case before this budget: 60 s of transcription and two 50 s Spark attempts, 160 s; now it saves at 110 s (`test/budget.test.mjs`).
6. One receipt and a `sessions` record: `source: capture`, `measurement_status: measured`, `goal_id`, `language`, `capture_device`, `metrics`, `adjudication` (`lexicon_count`, `adjudicated_count`, `status`, per-candidate labels), `analysis`, `transcription`, `audio_retained: false`, `audio_sha256`.
7. Only if the person turned on **Keep my recordings** (off by default; `docs/keep-recordings.md`): the uploaded WAV is saved in the same write, under the account's media folder, and the record gets `media: { kept: true, kind: "audio", bytes, sha256, content_type, kept_at }` and `audio_retained: true`. An exact retry replays the receipt and writes nothing again. If the account's 200 MB is full, the session is still saved, with `media: { kept: false, reason: "full", message }`.

Fresh reads add per-goal `measured_sessions` and `latest_measurement`, plus `linked_sessions` in focused context. `measured_improvement` stays `null`: one session cannot show change, and no comparison method exists yet.

## Limits

- Automatic transcripts can drop or invent words (a repeat run of the same clip dropped one "uh").
- Speakers are not separated.
- Lexicon counts are not judgments. One restart event can match two phrases ("Sorry, let me restart" counts 2). Measured accuracy on a synthetic labelled corpus is in `eval/README.md`.
- Audio is deleted after transcription unless you turn on Keep my recordings (off by default). Kept audio stays in your account and you can delete it any time. Without it, a transcript cannot be checked against the audio later; with it, `POST /v1/sessions/{id}/remeasure` can re-measure the session (`docs/keep-recordings.md`).
- Pauses come from turn boundaries, not word timings: short pauses inside a turn are not seen, and silence before the first turn includes the time before the person started speaking.
- Adjudication cannot catch a wrong label that quotes its span correctly. On the eval corpus (live, one run on 2026-11-02, self-labelled corpus) it scored precision 0.953, recall 0.672 against 0.788 / 0.852 for the lexicon alone: the model labelled most hedges as content, so `adjudicated_count` undercounts hedges. See `eval/README.md`.
- On Modal, one container takes up to 4 requests at once. Every request runs on one long-lived Node worker that keeps the database open, and a lock serializes database access. A recording releases that lock during its model calls, so reads and ordinary writes are not queued behind inference. Requests that call a model run one at a time: a second capture, or a retry of one still running, waits, and the retry then returns the first receipt without new inference. Inside one capture, the observation and adjudication calls in step 5 still run side by side.
- A write is answered only after the volume commit succeeds. If the commit fails, the client gets 503, and the receipt stays in the container's database until a later commit succeeds; a retry with the same key replays it then. Only if the container stops before any commit succeeds is the receipt lost, and the retry runs inference again.
