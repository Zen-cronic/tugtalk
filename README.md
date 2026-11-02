# Comms Coach

For anyone practising how they answer out loud (an interview question, a stand-up update, a point in a meeting) who already asks Muse, Meta's assistant, for help on more than one device. When practice lives in its own app, the assistant never sees it, so each new chat starts from nothing and you explain again what you were working on. Comms Coach saves each practice to one record that Muse reads fresh in any chat, on any device.

<!-- FOUNDER: one or two sentences in your own words -->

Tap to capture a short answer on Apple Watch; Meta `muse-voice-transcribe-1.0` transcribes it, code measures speaking habits (fillers, hedges, restarts, pace), Muse Spark Open writes one observation, and the result joins the shared record, including scheduled practice suggestions. On the Mac, a hotkey sends the text of the window in front, redacted on the Mac, for a short context card in the same record. Goals, exercises and check-ins live in the same authenticated API.

Seeded fixtures are fictional. This is a hackathon prototype, not a validated coaching or speech-assessment product; see Evidence and limits.

## Built during the event (Oct 30 – Nov 4, 2026)

From this repository's commit dates (US Eastern time). The first commit is dated Oct 30.

- **Oct 30:** the authenticated goals, exercises and check-ins API with fresh overview reads, and Modal hosting.
- **Nov 1:** the recording route (Meta transcription, code-measured habits, a Muse Spark Open observation), the Apple Watch app, the landing page, the measurement eval, the claims ledger, and reuse hooks for a sister French-practice profile.
- **Nov 1–2, overnight:** the Mac companion: the screen-context route, the on-device redaction core, the menu-bar app, capture, undo, polling and the Ask Muse hand-off.
- **Nov 2:** pause and speaking-time measurement from the transcription's speech segments, Muse Spark Open labelling of ambiguous word-list hits (checked by code) with its own eval arm, a hosting adapter that takes several requests at once, the watch's time-cap fix, a guard for malformed transcription replies, and claims checked against behaviour.

**Measured habit counts: precision 0.788, recall 0.852 on 70 synthetic, self-labelled en/fr transcripts (flat word-list baseline 0.754 / 0.852); 0 false counts on 12 clean controls. Recompute with `npm run eval` or `GET /v1/eval`; method and limits in [eval/README.md](eval/README.md).**

## Run

Requires Node.js 24. No third-party runtime packages.

```sh
npm run setup
npm test
npm run eval   # recompute the measurement eval
npm start
```

Setup creates `.data/connector.sqlite` and a private `.data/operator-token.txt`. It refuses to overwrite an existing credential. Never commit either. Supply `PUBLIC_BASE_URL` when using an HTTPS preview URL; the server binds only `127.0.0.1:4318`. A reverse proxy/tunnel is required for remote access. Local serving requires the host to stay awake. The optional Modal adapter runs independently with persistent storage.

## Connect an assistant

1. Give it the HTTPS `/connector.md` and `/openapi.json` URLs.
2. Register the exact hostname and a Bearer API key through the assistant's secure credential flow. The key belongs only to the synthetic account. Do not paste it into chat.
3. Verify `GET /v1/context` before allowing writes. There should be two synthetic sessions and no goals or exercise completions initially.
4. Ask it to create a goal, assign an exercise, record a completion, correct evidence, and re-read current context. Inspect server receipts rather than trusting a conversational success claim.

## API contract

| Method | Path | Purpose |
|---|---|---|
| GET | `/health`, `/connector.md`, `/openapi.json` | Public health and integration documentation |
| GET | `/v1/overview` | Fresh all-goals overview with per-goal progress and retrieval metadata |
| GET | `/v1/goals/{id}/context` | Fresh context for one owned goal |
| GET | `/v1/context` | Current user-scoped goals, evidence, exercises, check-ins and progress |
| GET | `/v1/receipts` | Confirmed writes for that user |
| GET | `/v1/files/evidence.txt` | Current evidence as plain text |
| POST | `/v1/goals` | Create a goal |
| POST | `/v1/exercises` | Assign an exercise linked to a goal |
| POST | `/v1/check-ins` | Record one self-reported completion/skipped result for an assigned exercise |
| PATCH | `/v1/goals/{id}` | Revise a goal with optimistic version checking |
| PATCH | `/v1/sessions/{id}` | Correct or hide synthetic evidence with a reason and version check |
| GET | `/v1/eval` | Public, read-only. Recomputes the measurement eval over the bundled synthetic corpus (no user data). See `eval/README.md`. |
| POST | `/v1/recordings` | Capture devices (watch, Mac, phone) upload a mono 16-bit WAV (16/24 kHz, ≤180 s, ≤8 MiB). Meta `muse-voice-transcribe-1.0` transcribes it, code measures habits (en/fr lexicons), Muse Spark Open words one observation, and a measured session is saved. See `docs/capture.md`. |
| POST | `/v1/screen-contexts` | The Mac companion sends the text of one window, redacted on the Mac (≤6,000 characters). Muse Spark Open writes a short context card; the text and pixels are not stored. See `docs/screen-context.md`. |
| PATCH | `/v1/screen-contexts/{id}` | Hide (undo) or restore a screen context, with a version check |
| POST | `/v1/voice-rounds/{id}/speech` | The round's checked question as audio, from a Meta voice (self-hosted MMS-TTS or Wit.ai, chosen by `SPEECH_PROVIDER`). 503 when none is configured, and the Mac uses an Apple voice. See `docs/voice.md`. |
| POST | `/v1/voice-rounds` | The Mac posts one spoken answer (WAV, as for recordings). Meta transcribes it, code measures it, Muse Spark Open plays the other person and returns one move and one question, and code checks the reply's quote word for word against the transcript. The audio is not stored. See `docs/voice.md`. |

All `/v1/` paths except `GET /v1/eval` require `Authorization: Bearer <key>`. Writes additionally require `Idempotency-Key`. An exact retry returns the original receipt; changed content with the same key returns 409. New keys cannot duplicate an exercise's check-in. Use a new assigned exercise for a new attempt. Updates require `expected_version`; stale versions return 409. JSON bodies are limited to 16 KiB. These are this service's limits, not Muse platform limits.

The authenticated identity comes only from the token. Clients cannot choose another user in the request. Record IDs and receipts are scoped by account. Tokens are stored hashed in SQLite; the bootstrap file holds the only local plaintext copy.

## What we'll tell you before you find it

- **One synthetic account.** The hosted service has a single account (`synthetic-operator`) and a single Bearer key. There is no sign-up or onboarding. This is a single-user prototype.
- **The watch carries that key.** The watch app reads the key from a Git-ignored `Secrets.xcconfig` at build time. A product would issue each device its own revocable token.
- **Some records are simulated.** The two seeded sessions (`session-before`, `session-after`, dated Oct 30 and 31) are fictional, and their pause values are made up. Exercise completions are self-reported. Only sessions with `source: capture` were measured from audio.
- **Nothing is pushed.** Muse reads the shared record when a chat or a scheduled Muse task calls the API. The backend never wakes Muse, the phone or the watch.
- **Two capture clients, at different stages.** The watch app records speech; our watch captures so far ran in the watchOS simulator using the Mac microphone. The Mac companion (`apps/mac`) reads one window's text when asked. Its tests and our end-to-end runs used a synthetic fixture image and a local server with stub models; two live calls to the hosted route used the fixture's redacted text. The API also accepts `phone` as a label, but there is no phone client.
- **The Mac voice loop has not met a real microphone yet.** Hold ⌃⌥T, and the companion answers with a voice reply (`apps/mac/README.md`). Its tests and our runs so far used a synthetic `say` clip and a local stub server, not a live microphone or the hosted route. Spoken names are not redacted.
- **The Mac companion can be seen in screen shares.** macOS offers no public way to hide a window from screen sharing or to know that sharing is on. Hide it with ⌃⌥H; it also hides itself while a known meeting app is in front.
- **Redaction on the Mac can miss things.** It replaces emails, phone numbers, long numbers, links, addresses and the names Apple's name recognition finds. A name it does not recognise, or text inside a picture, can get through. The server re-checks only pattern-shaped data, not names. Nothing but the redacted text leaves the Mac, and the text itself is not stored.
- **The counts come from a fixed lexicon.** On our [eval](eval/README.md) the counter is exact on ordinary disfluent speech. It counts content uses such as "what kind of report" or "du coup de fil" as habits. It misses habits we chose not to list, such as filler "like", "quoi" and "genre", and spellings such as "Umm". "Sorry, let me restart" counts as two restarts.
- **The eval corpus is ours.** We wrote and labelled all 70 transcripts ourselves. It is not real speech and nobody independent checked it.
- **Transcripts can be wrong.** Meta's transcription can drop or invent words (a repeat run of one clip dropped an "uh"). Speakers are not separated. Audio is not kept, so nobody can re-check a transcript against it.
- **The spoken voice.** Meta's Model API has no text-to-speech model. The speech route can use Meta's MMS-TTS models (`facebook/mms-tts-eng`, `facebook/mms-tts-fra`), which are licensed CC-BY-NC-4.0 (non-commercial, attribution required), self-hosted, or Wit.ai's text-to-speech. Neither is live yet, so today the Mac speaks with an Apple voice.
- **No improvement score.** `measured_improvement` is always `null`. One session cannot show change, and we have no comparison method yet.
- **The observation is model-written.** Muse Spark Open words it from the transcript and the counts; code never takes numbers from it. If the model fails, the session is saved with `analysis.status: "unavailable"`.
- **One small container.** Hosting is one scale-to-zero Modal container. It stays up for 5 minutes after the last request; the first request after that waits for a cold start of about 4.5 s (deploy with `KEEP_WARM=1` to keep one running while filming). Every request runs on one long-lived Node worker. It takes up to 4 requests at once: reads and ordinary writes are served while a capture or screen context waits on its models, but requests that call a model run one at a time, so a second capture waits for the first. Inside one capture, the observation and the adjudication calls run side by side. The only rate limits are 30 screen contexts and 60 voice rounds per hour.

The limits, model names, eval numbers and test counts we state are listed in [FACTS.md](FACTS.md), and a test checks each one against the code.

## How Meta's models measure

Two Meta models touch every capture. They work on words; code decides every number that is stored.

| Step | Model | What the model decides | What code does |
|---|---|---|---|
| Transcribe | `muse-voice-transcribe-1.0`, ENDPOINTING mode | The words, and the start and end of each speech segment ("turn") | Counts habits from the words with the en/fr lexicons. Measures pauses and speaking-time pace from the turn times. |
| Adjudicate | Muse Spark Open (`meta-models/muse-spark-open-1026`), temperature 0 | For each ambiguous word-list hit: habit or content, with a one-line reason | Proposes the hits and checks every label before it changes a count. Never lets a count grow. |
| Observe | Muse Spark Open | One observation and one exercise, in words | Sends it the lexicon counts and the transcript. Never takes a number from it. |

**What transcription gives.** The counts depend on the transcript keeping fillers such as "uh" as words. In a repeat run of one clip, one run kept an "uh" and the other dropped it. On Nov 2, on three synthetic `say` clips, the transcript kept "um" in 3 of 3 and wrote a spoken "uh" as "ah" in 3 of 3. So since Nov 2 the English lexicon (`lexicon-en-v2`) counts "ah" and "er" as "uh"; the eval corpus has neither spelling, so its numbers did not change. We have not checked this on a human voice. ENDPOINTING mode also returns each speech segment with start and end times. Code turns the gaps between segments into `metrics.pauses`: pauses from 250 ms, the longest pause, pauses of 1 s or more, silence before the first segment, speaking time against clip time, and words per minute of speaking time.

**What Spark Open decides.** The word list counts every listed phrase, so content uses such as "what kind of report", "I mean it" or "du coup de fil" count as habits. When a transcript has such ambiguous hits, one Spark call gets each hit with its exact text and six words either side, and labels it `habit` or `content`. Pure vocal fillers (um, uh, erm, euh, bah) are counted without asking, and a capture without ambiguous hits makes no call.

**What code verifies.** A label counts only if it names a proposed candidate once, copies that candidate's text exactly as the transcript has it, says `habit` or `content`, and gives a reason. Anything else keeps the word-list count for that hit. So does a failed, truncated or refused call, after the same retry rule every Spark call follows. A content label can only remove a proposed hit. The model cannot add a hit or change a number. The session keeps both numbers: `adjudication.lexicon_count` and `adjudication.adjudicated_count`, with `adjudication.status` (`adjudicated`, `partial`, `fallback` or `no_candidates`) and each candidate's label, reason and rejection. `metrics` stays as it was, all code-measured.

**Limits.**

- A segment boundary is the transcriber's endpoint, not a word timing. Short pauses inside a segment are not seen, and a filled pause is speech, so pauses are a floor. Silence before the first segment includes the time between tapping record and starting to speak.
- A wrong label that copies the text correctly passes the check. The eval counts these.
- **Live adjudication is below the lexicon on our corpus.** Live, one run on 2026-11-02, self-labelled corpus, 42 Spark calls at low reasoning effort: precision 0.953, recall 0.672, F1 0.788, against 0.788 / 0.852, F1 0.819 for the lexicon alone. Precision rose and recall fell. The model removed all 12 content traps, but it labelled most hedges as content ("Maybe", "probably", "Je pense"), so hedge recall fell from 0.889 to 0.333. Fillers (F1 0.889 against 0.800) and restarts (0.846 against 0.800) improved.
- The scripted adjudication arm (code-checked scripted replies, not live model runs) scores 0.877 / 0.820. It tests what the check does with good and bad replies, and it did not predict the hedge drop. See [eval/README.md](eval/README.md).
- Which categories the model labels is unchanged after this run. Keeping hedges out would score higher on this corpus, but it would be tuned on the same transcripts.
- Adjudication adds one paid Spark call to each capture with ambiguous hits.
- The observation model still receives the lexicon counts, not the adjudicated counts or the pauses. The watch shows the lexicon filler count.

## Evidence and limits

`npm test` exercises actual HTTP requests and SQLite persistence: authentication, read-only scope, per-user isolation, create/complete/correct flow, schema rejection, retries, duplicate check-ins, stale edits, soft-deleted evidence, request audit, and credential revocation. The test uses a disposable temporary database, separate from the live Muse test database.

`npm run audit` prints synthetic context, saved-write receipts and request metadata. Request records contain route, method, time, status and response hash, not tokens or request headers. Records/receipts preserve synthetic fixture text; do not put real personal data into this prototype.

- Captured sessions (`POST /v1/recordings`) run Meta speech-to-text and Muse Spark Open on the server. Their metrics are code-measured lexicon counts from an automatic transcript: transcription errors, unseparated speakers and ambiguous words can skew them. Observations are model-written and stored separately from the numbers.
- Seeded fixture sessions are simulated. Exercise completion is self-reported. No measured-improvement score is computed; one session cannot show change.
- Uploaded audio is not retained; the transcript, metrics, observation and audio hash are.
- A session deletion is a reversible hiding flag, not erasure from storage or receipts.
- Beyond the WAV capture route used by capture devices, there are no arbitrary uploads, audio streaming, arbitrary URL fetching, or access to personal assistant memories.
- Local HTTP tests do not establish Muse tool reliability, cross-chat continuity, phone delivery, or background execution. Those need separate observed tests.
- The optional Modal adapter uses one scale-to-zero container and a persistent volume. Scaling past one container, comprehensive rate limiting and account onboarding are not implemented.

To revoke the local database's account token (this does not revoke a separately hosted copy):

```sh
node scripts/revoke.mjs
```

Also disconnect the custom connector in Muse. Disconnecting does not erase information Muse previously copied into its memory or conversations.


## Fresh reads

The app-side `createFreshReader` in `src/fresh-client.mjs` fetches each call anew, validates retrieval metadata, and throws on failures without returning a cached result. Both fresh routes use a single database read transaction and no-store responses. See [the retrieval contract](docs/fresh-retrieval.md). Historical chat messages do not update automatically.

## Modal adapter

Install the Modal SDK in your Python tool environment and authenticate with a profile named `meta-connector`. `python deploy/prepare-and-deploy.py` explicitly deploys the service and a persistent volume; review the published host in `deploy/modal_app.py` for your workspace. It uploads source and the dedicated token's digest, never the plaintext key or local database. The ASGI bridge runs every request on one long-lived Node worker, checkpoints SQLite and commits the volume before acknowledging writes; reads skip the commit, and the volume is never reloaded because this one container is its only writer. Keep one container; do not overlap deployments while requests are active, or a write made by the old container during the switch can be lost. `KEEP_WARM=1 python deploy/prepare-and-deploy.py` keeps one container running for filming (about $0.016 an hour at Modal's list price); redeploy without it afterwards. Active usage and persistent storage may incur charges.

Run adapter tests with `python -m unittest discover -s deploy -p 'test_*.py' -v`. To stop the hosted service, use `modal app stop synthetic-coaching-connector --profile meta-connector --env main`; stopping does not delete stored data. Hosted token revocation needs to affect the hosted database, not the local copy.
