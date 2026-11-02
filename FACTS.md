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
| `analysis-budgets` | Observation token budgets | 4000, then 8000 on retry | `ANALYSIS_BUDGETS` |
| `contract-version` | API contract version | 0.4.0 | `/openapi.json` `info.version` and `/connector.md` |
| `languages` | Capture languages | en, fr | `LANGUAGES` |
| `devices` | Capture device labels the API accepts | watch, mac, phone, api | `DEVICES` |
| `lexicons` | Habit-count methods | lexicon-en-v1, lexicon-fr-v1 | `measure().method` |
| `audio-retained` | Uploaded audio is stored | no | HTTP capture with fake models: `audio_retained` is false and the audio bytes are not in the database file |
| `retry-no-rebill` | An exact retry calls the models again | no | HTTP: the same Idempotency-Key and audio twice calls each fake model once |
| `screen-text-max` | Largest redacted screen text accepted | 6000 characters, 12 KiB | HTTP: 6001 characters returns 400 |
| `screen-text-retained` | Screen text is stored | no | HTTP screen context with a fake model: `text_retained` is false and the text is not in the database file |
| `screen-rate-limit` | Screen contexts per hour, refused before any model call | 30 | `SCREEN_RATE_LIMIT`; the 31st returns 429 |
| `measured-improvement` | Improvement score we compute | none (null) | `measured_improvement` in the fresh overview |
| `unauthenticated` | `/v1/overview` without a token | 401 | HTTP |
| `eval-measure` | Habit-count precision / recall | 0.788 / 0.852 | `eval/results.json`, regenerated |
| `eval-baseline` | Flat word-list baseline precision / recall | 0.754 / 0.852 | `eval/results.json`, regenerated |
| `eval-corpus` | Eval corpus size | 70 items, 12 clean controls | `eval/results.json`, regenerated |
| `eval-controls` | False counts on clean controls | 0 | `eval/results.json`, regenerated |
| `node-tests` | Node test cases, as `npm test` reports them | 61 | `test(` and `t.test(` calls in test/*.test.mjs |
| `python-tests` | Python hosting-adapter tests | 5 | `def test_` in deploy/test_bridge.py |
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
