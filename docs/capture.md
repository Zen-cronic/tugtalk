# Capture pipeline (contract 0.4.0)

`POST /v1/recordings` turns one short recording from any device into measured session evidence that every other surface (Muse chats, scheduled Muse tasks, the app reader) reads through the same fresh overview. Context is never stored only on the capturing device.

## Request

- `Authorization: Bearer <key>` with write scope; `Idempotency-Key` (8–128 chars).
- `Content-Type: audio/wav`; body is mono 16-bit PCM WAV at 16 or 24 kHz, 0.5–180 s, ≤8 MiB.
- Optional headers: `X-Goal-Id` (owned goal), `X-Language` (`en` default, `fr`), `X-Capture-Device` (`watch`, `mac`, `phone`, `api`), `X-Occurred-At` (ISO 8601).

## Pipeline

1. Authenticate, validate headers, read audio, and replay an exact retry (same key, same audio hash and headers) **before** any model call, so retries never re-bill. The same key with different content returns 409.
2. Check the goal exists and the WAV header is supported; failures return 4xx without inference.
3. Meta Model API `POST /v1/asr/transcribe`, `muse-voice-transcribe-1.0`, `ENDPOINTING`, language bias from `X-Language`. A failure returns 502 and saves nothing.
4. Code computes `word_count`, `words_per_minute`, fillers, hedges, restarts and immediate repeats from a conservative per-language lexicon (`lexicon-en-v1`, `lexicon-fr-v1`).
5. Baseten `meta-models/muse-spark-open-1026` returns `{observation, suggested_exercise}`. It is a reasoning model, so it gets 4000 max tokens and, if it runs out before answering, one retry with 8000. Code never takes numbers from it. An empty, malformed or failed reply saves the session with `analysis.status: "unavailable"`.
6. One receipt and a `sessions` record: `source: capture`, `measurement_status: measured`, `goal_id`, `language`, `capture_device`, `metrics`, `analysis`, `transcription`, `audio_retained: false`, `audio_sha256`.

Fresh reads add per-goal `measured_sessions` and `latest_measurement`, plus `linked_sessions` in focused context. `measured_improvement` stays `null`: one session cannot show change, and no comparison method exists yet.

## Limits

- Automatic transcripts can drop or invent words (a repeat run of the same clip dropped one "uh").
- Speakers are not separated.
- Lexicon counts are not judgments. One restart event can match two phrases ("Sorry, let me restart" counts 2). Measured accuracy on a synthetic labelled corpus is in `eval/README.md`.
- Audio is not retained, so pronunciation cannot be re-checked.
- On Modal, one container takes up to 4 requests at once and serializes database access with a lock. A recording releases that lock during its model calls, so reads and ordinary writes are not queued behind inference. Model calls run one at a time: a second capture, or a retry of one still running, waits, and the retry then returns the first receipt without new inference.
- If the storage commit fails after inference, a retry re-runs inference because the receipt was not persisted.
