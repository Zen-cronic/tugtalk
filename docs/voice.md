# Voice rounds (contract 0.5.0)

A voice round is one spoken exchange of practice. The person holds a key on the Mac and answers out loud. On release, the Mac posts the clip to `POST /v1/voice-rounds`. Meta transcribes it and code measures it. Then Muse Spark Open, playing the other person in the conversation, picks the next move and asks one question, and the Mac speaks it. Code checks the reply before it is returned. The round joins the same record as watch captures and screen cards, so a Muse chat can read it.

Meta's Model API has no text-to-speech model. The spoken reply comes from `POST /v1/voice-rounds/{round_id}/speech` (below), with a Meta voice when one is configured, and otherwise from an on-device Apple voice on the Mac. The whole reply is spoken once it is ready, not word by word.

## Request

`POST /v1/voice-rounds`, routed through the same web host and hosting adapter as `POST /v1/recordings`.

- `Authorization: Bearer <key>` with write scope.
- `Idempotency-Key` (required, 8–128 letters, digits, `_` or `-`).
- `Content-Type: audio/wav`. The body is mono 16-bit PCM WAV at 16 or 24 kHz, 0.5–180 s, ≤8 MiB.
- Optional headers:
  - `X-Goal-Id`: an owned goal.
  - `X-Screen-Context-Id`: an owned, visible screen context. Only its model-written card summary reaches the model.
  - `X-Language`: `en` (default) or `fr`.
  - `X-Prompt-Ended-At`: ISO 8601 time when the mascot finished speaking its previous question.
  - `X-Occurred-At`: ISO 8601 time when the recording started (key down). This is the same header `POST /v1/recordings` takes. Onset needs it (see below).

An exact retry (same key, same audio and the same headers) returns the stored round and makes no model call. The same key with different audio or headers returns 409.

## What happens

1. Auth, headers, the goal, the screen context, the WAV header and the hourly limit are checked first. Any failure returns 4xx before a paid call. A deployment without the reply model returns 503 before transcription.
2. Meta Model API `POST /v1/asr/transcribe`, `muse-voice-transcribe-1.0`, `ENDPOINTING` mode: one file request per round.
3. Code measures the answer: the same `measure()` as captures (words, pace, fillers, hedges, restarts) plus `metrics.pauses` from the ENDPOINTING turns, and `onset_ms_approx`.
4. One Muse Spark Open call on Baseten, `meta-models/muse-spark-open-1026`, `reasoning_effort: "low"`, streamed, 2000 max tokens, cut off after 8 s. A second call runs only if the first reply is unusable (no JSON, wrong shape, empty, cut off by `max_tokens`), never after a timeout or a 4xx.
   - It gets the goal, the screen card's summary, the latest watch session's code-measured numbers, its own last question if a round ran in the last 15 minutes, the round number, and the answer with its measured numbers and the habit words code found.
   - It returns `{move, quote, question}`. `move` is `follow_up`, `challenge` or `wrap_up`.
5. Code checks the reply:
   - **The quote.** It is kept only if its words appear in the transcript as one unbroken run, in order (case and punctuation ignored). The kept quote is cut from the transcript itself, so it is exactly what the transcript says. Otherwise it becomes `""` and `quote_verified` is `false`.
   - **The question.** It is returned either way, but first code removes every quoted span in it that is not word for word in the transcript, and a "You said" left with nothing to introduce. It cuts the question to 25 words and re-scrubs emails, phone numbers and long numbers. If too little is left, a fixed question for the move replaces it. What code changed is stored in `reply_checks`.
6. One receipt and one `voice-rounds` record.

The round has one time budget (`src/budget.mjs`), as recordings do: 120 s, cut to what is left of the hosting adapter's deadline. Transcription starts only with 10 s left, and a reply attempt only with 4 s left; each attempt is cut off at 8 s or when the budget runs out. A reply with no time left is a 502 `reply_failed` like any failed reply. So the round always answers before the adapter gives up.

## Response 200

```json
{
  "round_id": "…", "receipt_id": "…", "replayed": false,
  "transcript": "So, um, I think I could maybe lead the launch.",
  "metrics": { "word_count": 10, "words_per_minute": 150, "filler_count": 1, "hedge_count": 2, "restart_count": 0,
               "pauses": { "status": "measured", "longest_pause_ms": null, "…": "…" }, "onset_ms_approx": 1300 },
  "reply": { "move": "challenge", "question": "You said \"maybe\". Why should it be you?", "quote": "maybe lead the launch", "quote_verified": true },
  "model": "meta-models/muse-spark-open-1026", "provider_request_id": "…",
  "latency_ms": { "asr": 2100, "model": 1700, "total": 3850 }
}
```

- `metrics.pauses` is the full pause block of `src/pauses.mjs` (`turn-gaps-v1`).
- `onset_ms_approx` is the time from `X-Prompt-Ended-At` to the first speech the transcriber found: (`X-Occurred-At` − `X-Prompt-Ended-At`) + the start of the first turn. It is `null` unless both headers are sent and turns were measured, and `null` if negative (the person spoke before the question ended) or over 120 s. It is approximate: both times come from the device clock, and the first turn's start is the transcriber's endpoint, not an acoustic onset, so it can be off by a few hundred milliseconds.
- `latency_ms` is measured on the server: `asr` and `model` are the two provider calls, `total` runs from the request's arrival at the API handler to the saved receipt. On the hosted service, the hosting adapter's queueing and worker start come before `total` starts. A replay returns the original round's numbers.

## Spoken reply: `POST /v1/voice-rounds/{round_id}/speech`

- `Authorization: Bearer <key>` with write scope. No body is read; any body is ignored.
- It speaks the round's stored `reply.question` and nothing else, so only text this server produced and checked is ever synthesized.
- 200 returns the audio (`audio/mpeg` from wit, `audio/wav` from mms), with `X-Speech-Provider` and `X-Speech-Voice` headers. The local server streams it chunked as the provider sends it, and so does the hosting adapter on Modal: the worker passes each chunk on as it arrives, and the adapter sends it to the client before the rest is made.
- 503 `speech_unconfigured` when no provider is set up: the Mac then speaks the question with an Apple voice. 404 for an unknown, hidden or other account's round, 429 over 60 spoken replies per hour, 502 `speech_failed` if the provider fails or returns something other than audio.
- The audio is not stored or logged. The request log records the route and status, with a hash of a fixed label, not of the audio.

`SPEECH_PROVIDER` picks one of two Meta voices:

| Value | Voice | Needs | Status |
|---|---|---|---|
| `mms` | Meta MMS-TTS, `facebook/mms-tts-eng` and `facebook/mms-tts-fra`, self-hosted on Modal as its own app (`deploy/mms_tts_app.py`, CPU). **Licence CC-BY-NC-4.0: non-commercial use, with attribution.** | `MMS_TTS_URL`, `MMS_TTS_TOKEN` (a shared secret only the backend holds) | Code and tests ready; not deployed |
| `wit` | Wit.ai text-to-speech, the service behind Meta's Voice SDK. English voices only (30, in en_US, en_CA and en_GB); a French round gets 503 and the Apple voice | `WIT_TTS_TOKEN`, optional `WIT_TTS_VOICE` (default `wit$Rebecca`) | Checked live on Nov 2 (5 calls): `POST /synthesize?v=20240304`, Bearer, `{q, voice}`. It asks for MP3, which streams (first byte 0.39 s for a 10 s clip); WAV came back in one burst after 2.8–3.6 s |

## Errors

The usual JSON error shape, `{error, message, request_id}`:

| Status | `error` | When |
|---|---|---|
| 400 | `idempotency_required`, `invalid_value`, `unsupported_audio`, `audio_too_long` | A missing key, a bad header, or audio that is not mono 16-bit PCM WAV of 0.5–180 s |
| 401 | `unauthorized` | No or wrong Bearer key |
| 403 | `forbidden` | A read-only key |
| 404 | `not_found` | `X-Goal-Id` or `X-Screen-Context-Id` not found, not owned, or (screen context) hidden |
| 409 | `idempotency_conflict` | The key was used for a different request |
| 413 | `too_large` | Body over 8 MiB |
| 415 | `content_type` | Not `audio/wav` |
| 429 | `rate_limited` | Over 60 rounds in the last hour |
| 502 | `transcription_failed`, `transcription_empty`, `reply_failed` | A provider failed; nothing is saved, and a retry with the same key runs the round again |
| 503 | `transcription_unconfigured`, `reply_unconfigured`, `speech_unconfigured`, `time_budget`, `storage_or_worker_unavailable` | Not configured, not enough time left to start (nothing sent), or the hosting adapter could not run the request in time; retry with the same key |

## What is stored, and what is not

- **Stored** in the `voice-rounds` record: the transcript, the metrics, the checked reply, `reply_checks`, `goal_id`, `screen_context_id`, `language`, `occurred_at`, `prompt_ended_at`, provider ids, attempts, and `latency_ms`. `audio_retained` is `false`.
- **Not stored:** the audio, or any hash of it in the record. The receipt keeps a digest of the request for retry matching, as every write does.
- **Not logged:** the hosting adapter discards the worker's stderr, and the API logs only error names.
- **The audio goes to Meta only,** for transcription. Spark Open on Baseten receives text: the transcript, the numbers, the goal, and the screen card summary. Baseten documents zero data retention for synchronous Model API calls. We have not checked Meta's retention for transcription requests.
- **Spoken names are not redacted.** Whatever the person says is in the transcript and is stored and sent to Baseten as said. Screen text is redacted on the Mac before it leaves it, but speech is not.
- The fresh overview shows `latest_voice_round` without the transcript; `GET /v1/context` lists rounds with it. Muse reads both like other evidence.

## Latency

Live, one run on 2026-11-02 (`eval/voice-live-latency.json`): 12 headless rounds of one practice conversation against a local server with the real providers, synthetic `say` clips of 2.8–6.0 s, from Toronto. 24 provider calls (12 Meta transcriptions, 12 Spark Open replies), all HTTP 200, no retries.

| Step | p50 | p90 | max |
|---|---|---|---|
| Meta file transcription (`asr`) | 1378 ms | 2191 ms | 2506 ms |
| Spark Open reply, low effort (`model`) | 2248 ms | 3026 ms | 6368 ms |
| Server total, request to saved round (`total`) | 3546 ms | 4968 ms | 7616 ms |
| Client, WAV sent to reply parsed | 3561 ms | 4983 ms | 7632 ms |

- p90 and the percentiles are linear-interpolated over 12 rounds; the 6.4 s reply was one outlier.
- 11 of 11 offered quotes passed code's check; one round offered no quote.
- One spoken reply through the speech route with `wit` (`wit$Rebecca`, MP3): first byte 340 ms, total 1589 ms, locally.
- What it does not include: the Modal hop. The hosted service runs each request in a new Node worker; on Nov 2 a warm `GET /health` took 6.7 s, so a hosted round will be slower until that is fixed. Meta's realtime transcription would save about 2 s of the `asr` step; it is not wired in.
- What we saw in the replies: every one of the 12 moves was `challenge`, including round 12, although the prompt asks for `wrap_up` by about round 4. The model presses well on what was said, but code does not yet end a round.
- The file transcription repeated words in 5 of 12 clips that were not in the audio ("two weeks two weeks", "you you know", "cut the cut the"). A repeated single word shows up in `immediate_repeats`; neither kind counts as a restart.

Copy rule: the mascot's replies are called "voice replies", not "real-time", unless at least 10 live turns have a median of 2.0 s or less and none over 3.5 s, measured from release to reply.

## Offline eval of the reply check

`npm run eval:voice` runs code's check over 20 scripted replies in `eval/voice-replies.json` (scripted voice replies, not live model runs; we wrote them knowing how the check works) and compares the result with `eval/voice-results.json`.

- Code accepted 7 of the 16 offered quotes and rejected 9 (paraphrased, reordered, cut mid-word, a changed number, invented, over 30 words, and one quote that skipped a word the transcriber had doubled).
- The baseline trusts the model and speaks its quote and question as written. On these replies, 10 would have put words in the person's mouth that they never said. After the check, 0 do.
- 3 replies were unusable (prose, an unknown move, an empty question) and would get the one retry.

It measures the checking code, not the model: how often Spark Open picks a fair quote, or presses on the right weakness, needs live rounds.

## Try it without a microphone

```sh
npm run stub    # prints token_file; stub models, throwaway database, port 4319
node scripts/voice-client.mjs --token-file <token_file> --say "So, um, I think I could maybe lead the launch." --onset-ms 900 --repeat
```

`--say` renders the text with macOS `say` and `afconvert` (24 kHz mono 16-bit). `--repeat` sends the same request twice to show the replay. `--realtime` holds for the clip's length before sending. `--speech FILE` then fetches the spoken reply, saves it to FILE and prints the time to its first byte. With `STUB_BAD_QUOTE=1` the stub model returns a quote the speaker never said, so you can watch code drop it. `npm run stub -- --live-models` uses the real Meta and Baseten clients instead (paid) with the same throwaway database.

## Limits

- File transcription only. Meta's realtime transcription socket works for our key, but it is not wired in; it would save about 2 s per turn.
- One reply call per round at low effort. If it fails, the round returns 502 and the person answers again; there is no code-written fallback reply.
- The model cannot hear the audio. It works from the transcript and the measured numbers.
- The quote check is on words, not meaning: a correct quote can still be pressed on unfairly.
- The file transcription sometimes doubles a word ("of of"); a quote can include the doubled word because it is in the transcript.
- On the hosted service, requests that call a model run one at a time, so a voice round waits for a capture or screen card already running.
