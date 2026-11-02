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
| `contract-version` | API contract version | 0.4.0 | `/openapi.json` `info.version`, `/connector.md` and the title of docs/capture.md |
| `languages` | Capture languages | en, fr | The `X-Language` check in `captureParams`: each listed value passes, others fail |
| `devices` | Capture device labels the API accepts | watch, mac, phone, api | The `X-Capture-Device` check in `captureParams`: each listed value passes, others fail |
| `lexicons` | Habit-count methods | lexicon-en-v1, lexicon-fr-v1 | `measure().method` |
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
| `node-tests` | Node test cases, as `npm test` reports them | 40 | A `node --test` run of the other test files (all must pass), plus this one |
| `python-tests` | Python hosting-adapter tests | 8 | `def test_` lines in deploy/test_bridge.py (counted, not run, by this check) |
| `hosting-concurrency` | Requests the hosted container takes at once | 4 at once; one model request at a time | `@modal.concurrent(max_inputs=…)` in deploy/modal_app.py, the bridge's model lock, and its concurrency test in deploy/test_bridge.py |
| `hosting` | Hosted service shape | 1 container, 512 MB, 180 s timeout | deploy/modal_app.py |
| `watch-target` | Watch app minimum OS | watchOS 11.0 | apps/watch/project.yml |
| `mac-target` | Mac companion minimum OS | macOS 14.0 | apps/mac/project.yml |
