# Claims ledger

Every number or name we state about this project, and where it comes from. `test/facts.test.mjs` recomputes each **Value** from the code, the running HTTP handler or the eval, and fails if any row here drifts. A row without a check fails the test too.

| ID | Claim | Value | Checked against |
|---|---|---|---|
| `audio-max-bytes` | Largest accepted audio upload | 8 MiB | `MAX_AUDIO_BYTES` (src/capture.mjs) and `AUDIO_LIMIT` (deploy/bridge.py) |
| `audio-max-seconds` | Longest accepted capture | 180 s | `MAX_AUDIO_MS`; a 181 s WAV is rejected |
| `audio-min-seconds` | Shortest accepted capture | 0.5 s | `inspectWav` accepts 0.5 s and rejects 0.4 s |
| `audio-format` | Accepted audio | mono 16-bit PCM WAV, 16 or 24 kHz | `inspectWav` accepts 16 and 24 kHz, rejects 44.1 kHz and stereo |
| `json-max-bytes` | Largest JSON request body | 16 KiB | HTTP: 16 KiB + 1 byte returns 413 |
| `idempotency-key` | Idempotency-Key length on writes | 8–128 characters | HTTP: 7 characters returns 400, 8 is accepted |
| `transcribe-model` | Speech-to-text model | muse-voice-transcribe-1.0 | `TRANSCRIBE_MODEL` and the request body sent to Meta (fake fetch) |
| `analysis-model` | Observation model | meta-models/muse-spark-open-1026 | `ANALYSIS_MODEL` and the request body sent to Baseten (fake fetch) |
| `analysis-budgets` | Observation token budgets | 4000, then 8000 on retry | `max_tokens` sent to Baseten (fake fetch) when the first reply runs out of tokens |
| `analysis-effort` | Reasoning effort the hosted service asks for | medium on the watch observation and the screen card; low on voice replies | `ANALYSIS_EFFORT` in deploy/modal_app.py, sent in both request bodies (fake fetch), and `VOICE_EFFORT` (src/voice.mjs); unset, the observation body is unchanged |
| `contract-version` | API contract version | 0.7.0 | `/openapi.json` `info.version`, `/connector.md` and the titles of docs/capture.md and docs/voice.md |
| `languages` | Capture languages | en, fr | The `X-Language` check in `captureParams`: each listed value passes, others fail |
| `devices` | Capture device labels the API accepts | watch, mac, phone, api | The `X-Capture-Device` check in `captureParams`: each listed value passes, others fail |
| `lexicons` | Habit-count methods | lexicon-en-v2, lexicon-fr-v1 | `measure().method` |
| `filler-forms` | Spellings counted as the filler "uh" (English) | ah, er | `measure()` on each spelling, and on "are", "her" and "aha", which do not count |
| `audio-retained` | Uploaded audio is stored with Keep my recordings off (the default) | no | HTTP capture with fake models: `audio_retained` is false and the audio bytes are not in the database file |
| `keep-recordings-default` | "Keep my recordings" on a new account | off | HTTP: `GET /v1/settings` on a fresh account returns `keep_recordings` false, and a capture then writes no media folder |
| `keep-recordings-kept` | What is kept with Keep my recordings on | the uploaded WAV, byte for byte, with its SHA-256 on the record | HTTP with fake models: the file under `media/`, `media.sha256`, and `GET /v1/media/{id}` (404 for another account) |
| `media-cap` | Kept audio per account | 200 MB | `MEDIA_CAP_BYTES` (src/media.mjs); test/keep-recordings.test.mjs fills a smaller cap and the capture is saved without its audio |
| `media-download-limit` | Kept-recording downloads per hour | 120 | `MEDIA_DOWNLOAD_LIMIT` (src/media.mjs); test/keep-recordings.test.mjs is refused on the 121st |
| `retry-no-rebill` | An exact retry calls the models again | no | HTTP: the same Idempotency-Key and audio twice calls each fake model once |
| `screen-text-max` | Largest redacted screen text accepted | 6000 characters, 12 KiB | HTTP: 6001 characters returns 400 |
| `screen-text-retained` | Screen text is stored | no | HTTP screen context with a fake model: `text_retained` is false and the text is not in the database file |
| `screen-rate-limit` | Screen contexts per hour, refused before any model call | 30 | HTTP on a fresh account: 30 are saved, the 31st returns 429 without a model call |
| `recording-rate-limit` | Recordings per hour, refused before any model call | 30 | HTTP on a fresh account: 30 are saved, the 31st returns 429 without a model call |
| `model-budget` | Time budget for one paid request (recording, voice round, screen context) | 120 s, 30 s under the 150 s deadline; a step needs 4–15 s left to start | `MODEL_BUDGET_MS`, `MIN_START_MS` (src/budget.mjs) against `MODEL_DEADLINE` and the `budget_ms` the adapter sends (deploy/bridge.py); worst case in test/budget.test.mjs |
| `seed-sessions` | Seeded sessions: fictional fixtures and their dates | 2, simulated, 2026-10-30 and 2026-10-31 | `Store.seed` on a new account: `source` synthetic_fixture, `measurement_status` simulated |
| `measured-improvement` | Improvement score we compute | none (null) | `measured_improvement` in the fresh overview |
| `unauthenticated` | `/v1/overview` without a token | 401 | HTTP |
| `eval-measure` | Habit-count precision / recall | 0.788 / 0.852 | `eval/results.json`, regenerated |
| `eval-baseline` | Flat word-list baseline precision / recall | 0.754 / 0.852 | `eval/results.json`, regenerated |
| `eval-corpus` | Eval corpus size | 70 items, 12 clean controls | `eval/results.json`, regenerated |
| `eval-controls` | False counts on clean controls | 0 | `eval/results.json`, regenerated |
| `node-tests` | Node test cases, as `npm test` reports them | 183 | A `node --test` run of the other test files (all must pass), plus this one |
| `python-tests` | Python hosting-adapter tests | 25 | `def test_` lines in deploy/test_bridge.py (counted, not run, by this check) |
| `hosting-concurrency` | Requests the hosted container takes at once | 4 at once; one model-calling request at a time | `@modal.concurrent(max_inputs=…)` in deploy/modal_app.py, the bridge's model lock, and its concurrency test in deploy/test_bridge.py |
| `hosting` | Hosted service shape | 1 container, 512 MB, 180 s timeout | deploy/modal_app.py |
| `hosting-worker` | How the hosting adapter runs requests | one long-lived Node process; writes commit before the answer, reads skip the commit; no volume reload | deploy/bridge.py and its tests in deploy/test_bridge.py |
| `keep-warm` | Containers kept running with no traffic | off by default, KEEP_WARM=1 keeps 1 container; idle containers stay up 300 s | deploy/modal_app.py |
| `watch-target` | Watch app minimum OS | watchOS 11.0 | apps/watch/project.yml |
| `mac-target` | Mac companion minimum OS | macOS 14.0 | apps/mac/project.yml |

## Measurement by Meta's models

| ID | Claim | Value | Checked against |
|---|---|---|---|
| `pause-source` | Where pause metrics come from | ENDPOINTING turn gaps, turn-gaps-v1 | The transcription request sent to Meta (fake fetch) and `measure()` on the turns it returns |
| `pause-thresholds` | Shortest gap counted as a pause, and as a long pause | 250 ms, 1000 ms | `measurePauses` probed with every gap from 0 to 2000 ms |
| `observation-inputs` | Numbers the observation model receives | word_count, words_per_minute, filler_count, hedge_count, restart_count | The request body sent to Baseten (fake fetch) |
| `adjudication-model` | Model that labels ambiguous hits | meta-models/muse-spark-open-1026, temperature 0 | The request body sent to Baseten (fake fetch) |
| `adjudication-calls` | Adjudication calls per capture | 1 with ambiguous hits, 2 if the reply is unusable, 0 without | `adjudicateCapture` with a counting fake fetch |
| `always-habit` | Hits counted without asking the model | um, uh, erm (en); euh, bah (fr) | `adjudicationCandidates` on every lexicon phrase |
| `adjudication-quote-check` | A label is accepted when its quote differs from the transcript | no | `verifyLabels` with a re-cased and a lengthened quote |
| `adjudication-never-adds` | Adjudication can raise a count | no | `buildAdjudication` with every label set to habit plus invented candidates, on every eval item |
| `eval-adjudicated-scripted` | Adjudicated precision / recall on scripted adjudication outputs, not live model runs | 0.877 / 0.82 | `eval/results.json`, regenerated |
| `eval-scripted-checks` | Scripted labels code rejected, and wrong labels it accepted | 8 of 51 rejected, 3 wrong accepted | `eval/results.json`, regenerated |
| `eval-live-calls` | Calls a live adjudication eval would make | 42, at most 84 with retries | `npm run eval -- --live` plan in `eval/results.json` |
| `eval-adjudicated-live` | Adjudicated precision / recall / F1; live, one run on 2026-11-02, self-labelled corpus | 0.953 / 0.672 / 0.788 | `eval/live-results.json` (its corpus SHA-256 matches `eval/corpus.json`) |
| `eval-live-vs-lexicon` | Lexicon-only F1 on the same run, and live hedge recall against the lexicon's | F1 0.819; hedge recall 0.333 against 0.889 | `eval/live-results.json` |
| `eval-live-attempts` | Live run: calls made, and first replies that needed a retry | 42 calls, 0 retries | `attempts` per item in `eval/live-results.json` |
| `eval-live-labels` | Live labels that passed code's check, and content labels on traps and on real habits | 51 of 51; 12 on traps, 11 on real habits | `eval/live-results.json` labels against the gold spans of `eval/corpus.json` |

## Voice rounds

| ID | Claim | Value | Checked against |
|---|---|---|---|
| `voice-model` | Voice reply model, reasoning effort, mode and token budget | meta-models/muse-spark-open-1026, low, streamed, 2000 max tokens | The request body sent to Baseten (fake fetch) |
| `voice-attempts` | Reply calls per round, and the cut-off for each | 1, a second only after an unusable reply; 8 s each | `createVoiceModel` with a counting fake fetch (an unusable reply, a 403) and `VOICE_TIMEOUT_MS` |
| `voice-quote-check` | A quote whose words are not in the transcript, word for word, is kept | no | HTTP with a fake model: `quote` is empty and `quote_verified` false |
| `voice-question-words` | Longest question returned to be spoken | 25 words | `safeQuestion` on a 40-word question |
| `voice-stored` | What a voice round stores with Keep my recordings off (the default) | transcript, metrics and reply; not the audio | HTTP with fake models: the record's fields, `audio_retained` false, and the audio bytes are not in the database file |
| `voice-retry-no-rebill` | An exact voice-round retry calls a model again | no | HTTP: the same Idempotency-Key and audio twice calls each fake model once |
| `voice-eval` | Offline voice-reply eval on scripted replies, not live model runs: quotes accepted and rejected, and replies that would speak unsaid words with and without the check | 7 of 16 accepted, 9 rejected; 10 without the check, 0 with it | `eval/voice-results.json`, regenerated |
| `voice-rate-limit` | Voice rounds per hour, refused before any model call | 60 | HTTP on a fresh account: 60 are saved, the 61st returns 429 without a model call |
| `speech-providers` | Speech providers `SPEECH_PROVIDER` can select, all Meta voices | mms, wit | `SPEECH_PROVIDERS` (src/speech.mjs); any other value is not ready |
| `speech-wit` | Wit.ai voice request: default voice, format, languages | wit$Rebecca, audio/mpeg, en only | The request sent to Wit.ai (fake fetch) and `speechSupports` |
| `speech-unconfigured` | Spoken reply with no provider configured | 503 speech_unconfigured, no provider call | HTTP with a counting fake fetch |
| `speech-text` | Text the speech route sends to the provider | the stored reply.question only | HTTP: a client body with other text is ignored (fake fetch) |
| `speech-stored` | Speech audio is stored | no | HTTP: the audio bytes are not in the database file |
| `speech-hosted` | How the spoken reply comes back | streamed locally and through the hosting adapter | HTTP `Transfer-Encoding: chunked` locally; scripts/handle-request.mjs passes each chunk on, and the adapter streams it (deploy/test_bridge.py) |
| `mms-licence` | Self-hosted Meta MMS-TTS models and their licence | facebook/mms-tts-eng, facebook/mms-tts-fra; CC-BY-NC-4.0 | `MODELS` and the licence line in deploy/mms_tts_app.py |
| `voice-live-latency` | Live voice rounds on a local server (no Modal hop), Nov 2: total server time p50 / p90 / max | 3546 / 4968 / 7616 ms over 12 rounds | `eval/voice-live-latency.json` (linear-interpolated percentiles) |
| `voice-live-steps` | Same run: transcription and reply p50 / max | ASR 1378 / 2506 ms; reply 2248 / 6368 ms | `eval/voice-live-latency.json` |
| `voice-live-quotes` | Same run: offered quotes that passed code's check | 11 of 11 (1 round offered none) | `eval/voice-live-latency.json` |
| `voice-wording` | What the latency lets us call the reply | voice reply, not real-time | Rule on `eval/voice-live-latency.json`: real-time needs at least 10 rounds, p50 ≤ 2000 ms and none over 3500 ms |
| `speech-wit-live` | One spoken reply through the speech route with wit, locally | first byte 340 ms, total 1589 ms, audio/mpeg | `speech_route_sample` in `eval/voice-live-latency.json` |
| `hosted-health` | Warm `GET /health` on the hosted service, Nov 2: median before and after the adapter change | 2906 ms before, 145 ms after (7 requests each) | docs/hosted-latency.json |
| `hosted-voice` | Hosted voice round: release to reply, and the time spent outside the API handler | 8800 ms before; 4751 and 3983 ms after (2 rounds); outside the handler 2855 ms before, 1277 and 945 ms after | docs/hosted-latency.json |
| `hosted-speech` | Hosted spoken reply (wit$Rebecca, audio/mpeg): time to the first audio byte | 6100 ms before; 920 and 706 ms after | docs/hosted-latency.json |
| `hosted-replay` | Hosted exact retry of a voice round: model calls, and time to the reply | none, 786 ms | docs/hosted-latency.json |
| `hosted-voice-before` | The live Mac turn the live route replaced (Nov 2, 14:08 EST, WAV upload): release to reply, and to the first spoken word | 10206 ms and 13689 ms | `voice_latency.before` in docs/hosted-latency.json |
| `hosted-live-voice` | Hosted live voice rounds (WS /v1/voice-rounds/live), Nov 2: release to reply text, and to the first audio byte, p50 / max | reply 2597 / 3233 ms; first audio byte 4175 / 4619 ms (5 rounds) | `voice_latency.live_rounds` in docs/hosted-latency.json |
| `hosted-live-transcript` | Same rounds: release to the final transcript, p50 / max, and how it was transcribed | 482 / 493 ms; Meta realtime in 5 of 5 | `voice_latency.live_rounds` in docs/hosted-latency.json |
| `hosted-live-steps` | Same rounds, measured on the server: reply model p50 / max, and the reply to its first audio (Wit), p50 / max | model 2203 / 2804 ms; reply to audio 1043 / 2679 ms | `voice_latency.live_rounds` in docs/hosted-latency.json |
| `hosted-speech-prefetch` | Hosted WAV round: the spoken reply requested after the receipt, first byte and server time | 284 ms, server 5.9 ms (made while the round was saved; no commit) | `voice_latency.wav_round` in docs/hosted-latency.json |

## The other person's need (voice rounds)

| ID | Claim | Value | Checked against |
|---|---|---|---|
| `counterpart-needs` | What the other person can need from you, and how code checks an answer for it | number, date, decision, owner, example; fixed English and French word patterns, counterpart-needs-v1 | `NEEDS`, `NEED_METHOD` and `needMet` (src/counterpart.mjs); HTTP: the need the model picks on answer 1 comes back in `counterpart` |
| `counterpart-move-gate` | Who ends a practice round | code: from answer 2, once the answer meets the need with no hedges (no hedges, when there is no need); at answer 4 at the latest | `allowedMoves` over every need state, hedge count and answer 1–6; HTTP: a model wrap-up on answer 1 is replaced (`gate.coerced`) |
| `counterpart-code-only` | Model calls in a code-only round (`X-Reply-Mode: code`) | 0 | HTTP with a counting fake model: the reply quotes the first hedge, `model` is null |
| `counterpart-need-stored` | The need is stored on the round | no; the round keeps gate (allowed, reason, hedges, coerced) | HTTP: the record's fields after a round with `X-Counterpart-Need` |
| `voice-practice-round` | Where a practice round starts | after the newest wrap-up in the last 15 minutes | HTTP: the answer after a wrap-up is answer 1, with no last question |
| `counterpart-eval` | Offline move-gate eval on scripted replies, not live model runs: replies outside the gate, and how many reach the speaker without and with it | 8 of 20; 8 without the gate, 0 with it | `eval/counterpart-results.json`, regenerated |

## Faced the camera (Mac, optional)

| ID | Claim | Value | Checked against |
|---|---|---|---|
| `camera-header` | What the Mac sends about the camera for one answer (`X-Camera-Metrics`, stored as `metrics.camera`) | 4 integers (faced_camera_pct, looked_away_count, longest_look_away_ms, frames); any other field is refused | `CAMERA_FIELDS` (src/camera-metrics.mjs); HTTP: the Mac's header is stored, and one with an extra field returns 400 |
| `camera-cone` | When a camera frame counts as "faced the camera", and the shortest counted look-away | head turn ≤ 20° and tilt ≤ 15°; look-aways counted from 1.0 s | `FacingRule` and `minLookAway` in apps/mac/Sources/ScreenContextCore/CameraMeter.swift, and the rule in `eval/camera-synthetic.json` |
| `camera-synthetic` | Offline meter check on synthetic head angles with noise and missed frames, not a real face | 8 scenarios × 20 seeds: look-away count right in 160 of 160; worst share error 9 points | `eval/camera-synthetic.json` (`swift run camera-eval synthetic`) |

## Drills set by Muse

| ID | Claim | Value | Checked against |
|---|---|---|---|
| `drill-basis-check` | A drill is saved when its basis claims the wrong count | no: 422 basis_mismatch, with the count code measured | HTTP: `POST /v1/exercises` with claimed_count one above the stored metrics; the body carries `recomputed.count` (src/drills.mjs `checkBasis`) |
| `drill-basis-sources` | What a basis may cite | 1–10 measured captures or voice rounds from the last 14 days; fixtures and hidden sessions refused; habits filler, hedge, restart | `BASIS_MAX_SOURCES`, `BASIS_WINDOW_DAYS` and `DRILL_HABITS` (src/drills.mjs); test/drills.test.mjs refuses each other kind of id |
| `drill-one-open` | Open drills (a basis, no check-in) per goal | 1 | HTTP: a second drill on the same goal returns 409 drill_open |
| `drill-measured-checkin` | What a capture that names a drill (`X-Exercise-Id`) records | one check-in per drill, evidence_type measured: the capture's hedge count beside the basis count | HTTP with fake models: two captures name the drill, one check-in is written, and its feedback says one measured result, not a trend |
| `drill-due` | When a drill may be due | optional; at most 7 days ahead, no minimum lead time | `DUE_MAX_DAYS` and `checkDueAt` (src/drills.mjs) |
| `drill-set-by` | Who writes exercises, so "set by Muse" can be checked | the assistant, through the connector; 0 app source files call POST /v1/exercises | A read of every source file under apps/ for `v1/exercises` |

## Hands check (Mac, opt-in per round)

| ID | Claim | Value | Checked against |
|---|---|---|---|
| `replay-method` | How the hands check counts | sam-3.1-boxes-v1: 3 requests (hand, phone, paper); in hand = a phone or paper box sharing area with a hand box in the same frame, counted per frame | `REPLAY_METHOD`, `REPLAY_CONCEPTS` and `overlaps` (src/replay.mjs) on sample boxes, including touching edges |
| `replay-store-false` | What our server sends Meta for one check, and what it keeps | the clip inline (data URL) with store false and no file upload; only the seconds are kept, never the clip, even with Keep my recordings on | `samRequestBody` (src/replay.mjs); test/replay.test.mjs saves a check with Keep my recordings on and finds no clip file, no clip bytes and no new media |
| `replay-clip` | The clip the Mac sends | 10 frames a second, at most 150 frames (15 s), at most 1 MiB, no audio | `REPLAY_FPS`, `REPLAY_MAX_FRAMES`, `REPLAY_MAX_BYTES` (src/replay.mjs), `VIDEO_LIMIT` (deploy/bridge.py) and `ReplayClip` (apps/mac/Sources/ScreenContextCore/ReplayClip.swift) |
| `replay-no-lock` | Whether a hands check can delay the next hold | never takes the model lock; a live hold started during a check waits at most 0.2 s for it (adapter test) | the replay route in deploy/bridge.py and its lock test in deploy/test_bridge.py |
| `replay-saved-output` | Code's count on saved SAM 3.1 answers (not webcam footage) | synthetic clip: hands right on 100 of 100 frames, paper on 20 of 20, phone on 28 of 30; CC0 photo clip: phone in hand 7 s of 7 s | `test/fixtures/sam` and `synthetic-truth.json`, recounted by `parseBoxes` and `runReplay` |
