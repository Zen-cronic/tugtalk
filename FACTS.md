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
| `contract-version` | API contract version | 0.5.0 | `/openapi.json` `info.version`, `/connector.md` and the titles of docs/capture.md and docs/voice.md |
| `languages` | Capture languages | en, fr | The `X-Language` check in `captureParams`: each listed value passes, others fail |
| `devices` | Capture device labels the API accepts | watch, mac, phone, api | The `X-Capture-Device` check in `captureParams`: each listed value passes, others fail |
| `lexicons` | Habit-count methods | lexicon-en-v2, lexicon-fr-v1 | `measure().method` |
| `filler-forms` | Spellings counted as the filler "uh" (English) | ah, er | `measure()` on each spelling, and on "are", "her" and "aha", which do not count |
| `audio-retained` | Uploaded audio is stored | no | HTTP capture with fake models: `audio_retained` is false and the audio bytes are not in the database file |
| `retry-no-rebill` | An exact retry calls the models again | no | HTTP: the same Idempotency-Key and audio twice calls each fake model once |
| `screen-text-max` | Largest redacted screen text accepted | 6000 characters, 12 KiB | HTTP: 6001 characters returns 400 |
| `screen-text-retained` | Screen text is stored | no | HTTP screen context with a fake model: `text_retained` is false and the text is not in the database file |
| `screen-rate-limit` | Screen contexts per hour, refused before any model call | 30 | HTTP on a fresh account: 30 are saved, the 31st returns 429 without a model call |
| `seed-sessions` | Seeded sessions: fictional fixtures and their dates | 2, simulated, 2026-10-30 and 2026-10-31 | `Store.seed` on a new account: `source` synthetic_fixture, `measurement_status` simulated |
| `measured-improvement` | Improvement score we compute | none (null) | `measured_improvement` in the fresh overview |
| `unauthenticated` | `/v1/overview` without a token | 401 | HTTP |
| `eval-measure` | Habit-count precision / recall | 0.788 / 0.852 | `eval/results.json`, regenerated |
| `eval-baseline` | Flat word-list baseline precision / recall | 0.754 / 0.852 | `eval/results.json`, regenerated |
| `eval-corpus` | Eval corpus size | 70 items, 12 clean controls | `eval/results.json`, regenerated |
| `eval-controls` | False counts on clean controls | 0 | `eval/results.json`, regenerated |
| `node-tests` | Node test cases, as `npm test` reports them | 84 | A `node --test` run of the other test files (all must pass), plus this one |
| `python-tests` | Python hosting-adapter tests | 10 | `def test_` lines in deploy/test_bridge.py (counted, not run, by this check) |
| `hosting-concurrency` | Requests the hosted container takes at once | 4 at once; one model-calling request at a time | `@modal.concurrent(max_inputs=…)` in deploy/modal_app.py, the bridge's model lock, and its concurrency test in deploy/test_bridge.py |
| `hosting` | Hosted service shape | 1 container, 512 MB, 180 s timeout | deploy/modal_app.py |
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
| `voice-stored` | What a voice round stores | transcript, metrics and reply; not the audio | HTTP with fake models: the record's fields, `audio_retained` false, and the audio bytes are not in the database file |
| `voice-retry-no-rebill` | An exact voice-round retry calls a model again | no | HTTP: the same Idempotency-Key and audio twice calls each fake model once |
| `voice-rate-limit` | Voice rounds per hour, refused before any model call | 60 | HTTP on a fresh account: 60 are saved, the 61st returns 429 without a model call |
