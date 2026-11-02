**Measured habit counts: precision 0.788, recall 0.852 on 70 synthetic, self-labelled en/fr transcripts (flat word-list baseline 0.754 / 0.852); 0 false counts on 12 clean controls. Recompute with `npm run eval` or `GET /v1/eval`; method and limits in [eval/README.md](eval/README.md).**

# Comms Coach

Cross-device communication practice. Tap to capture a short answer on Apple Watch; Meta `muse-voice-transcribe-1.0` transcribes it, code measures speaking habits (fillers, hedges, restarts, pace), Muse Spark Open writes one observation, and the result becomes one shared record that Muse reads fresh in any chat, on any device, including scheduled practice suggestions. Goals, exercises and check-ins live in the same authenticated API.

Seeded fixtures are fictional. This is a hackathon prototype, not a validated coaching or speech-assessment product; see Evidence and limits.

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

All `/v1/` paths except `GET /v1/eval` require `Authorization: Bearer <key>`. Writes additionally require `Idempotency-Key`. An exact retry returns the original receipt; changed content with the same key returns 409. New keys cannot duplicate an exercise's check-in. Use a new assigned exercise for a new attempt. Updates require `expected_version`; stale versions return 409. JSON bodies are limited to 16 KiB. These are this service's limits, not Muse platform limits.

The authenticated identity comes only from the token. Clients cannot choose another user in the request. Record IDs and receipts are scoped by account. Tokens are stored hashed in SQLite; the bootstrap file holds the only local plaintext copy.

## What we'll tell you before you find it

- **One synthetic account.** The hosted service has a single account (`synthetic-operator`) and a single Bearer key. There is no sign-up or onboarding. This is a single-user prototype.
- **The watch carries that key.** The watch app reads the key from a Git-ignored `Secrets.xcconfig` at build time. A product would issue each device its own revocable token.
- **Some records are simulated.** The two seeded sessions (`session-before`, `session-after`) are fictional, and their pause values are made up. Exercise completions are self-reported. Only sessions with `source: capture` were measured from audio.
- **Nothing is pushed.** Muse reads the shared record when a chat or a scheduled Muse task calls the API. The backend never wakes Muse, the phone or the watch.
- **Two capture clients, at different stages.** The watch app records speech; our watch captures so far ran in the watchOS simulator using the Mac microphone. The Mac companion (`apps/mac`) reads one window's text when asked. Its tests and our end-to-end runs used a synthetic fixture image and a local server with stub models; two live calls to the hosted route used the fixture's redacted text. The API also accepts `phone` as a label, but there is no phone client.
- **The Mac companion can be seen in screen shares.** macOS offers no public way to hide a window from screen sharing or to know that sharing is on. Hide it with ⌃⌥H; it also hides itself while a known meeting app is in front.
- **Redaction on the Mac can miss things.** It replaces emails, phone numbers, long numbers, links, addresses and the names Apple's name recognition finds. A name it does not recognise, or text inside a picture, can get through. The server re-checks only pattern-shaped data, not names. Nothing but the redacted text leaves the Mac, and the text itself is not stored.
- **The counts come from a fixed lexicon.** On our [eval](eval/README.md) the counter is exact on ordinary disfluent speech. It counts content uses such as "what kind of report" or "du coup de fil" as habits. It misses habits we chose not to list, such as filler "like", "quoi" and "genre", and spellings such as "Umm". "Sorry, let me restart" counts as two restarts.
- **The eval corpus is ours.** We wrote and labelled all 70 transcripts ourselves. It is not real speech and nobody independent checked it.
- **Transcripts can be wrong.** Meta's transcription can drop or invent words (a repeat run of one clip dropped an "uh"). Speakers are not separated. Audio is not kept, so nobody can re-check a transcript against it.
- **No improvement score.** `measured_improvement` is always `null`. One session cannot show change, and we have no comparison method yet.
- **The observation is model-written.** Muse Spark Open words it from the transcript and the counts; code never takes numbers from it. If the model fails, the session is saved with `analysis.status: "unavailable"`.
- **One small container.** Hosting is one scale-to-zero Modal container, so the first request after idle is slow. It takes up to 4 requests at once: reads and ordinary writes are served while a capture or screen context waits on its models, but model calls run one at a time, so a second capture waits for the first. The only rate limit is 30 screen contexts per hour.

The limits, model names, eval numbers and test counts we state are listed in [FACTS.md](FACTS.md), and a test checks each one against the code.

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

Install the Modal SDK in your Python tool environment and authenticate with a profile named `meta-connector`. `python deploy/prepare-and-deploy.py` explicitly deploys the service and a persistent volume; review the published host in `deploy/modal_app.py` for your workspace. It uploads source and the dedicated token's digest, never the plaintext key or local database. The ASGI bridge closes/checkpoints SQLite and commits the volume before acknowledging writes. Keep one container; do not overlap deployments while requests are active. Active usage and persistent storage may incur charges.

Run adapter tests with `python -m unittest discover -s deploy -p 'test_*.py' -v`. To stop the hosted service, use `modal app stop synthetic-coaching-connector --profile meta-connector --env main`; stopping does not delete stored data. Hosted token revocation needs to affect the hosted database, not the local copy.
