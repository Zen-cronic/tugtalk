# Synthetic coaching connector

A small authenticated API for testing whether a personal assistant can maintain goals, assign exercises, record self-reported completions, and retrieve corrected evidence across conversations. All included data is fictional. This is an integration prototype, not a validated coaching or speech-analysis product.

## Run

Requires Node.js 24. No third-party runtime packages.

```sh
npm run setup
npm test
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
| POST | `/v1/recordings` | Capture devices (watch, Mac, phone) upload a mono 16-bit WAV (16/24 kHz, ≤180 s, ≤8 MiB). Meta `muse-voice-transcribe-1.0` transcribes it, code measures habits (en/fr lexicons), Muse Spark Open words one observation, and a measured session is saved. See `docs/capture.md`. |

All `/v1/` paths require `Authorization: Bearer <key>`. Writes additionally require `Idempotency-Key`. An exact retry returns the original receipt; changed content with the same key returns 409. New keys cannot duplicate an exercise's check-in. Use a new assigned exercise for a new attempt. Updates require `expected_version`; stale versions return 409. JSON bodies are limited to 16 KiB. These are this service's limits, not Muse platform limits.

The authenticated identity comes only from the token. Clients cannot choose another user in the request. Record IDs and receipts are scoped by account. Tokens are stored hashed in SQLite; the bootstrap file holds the only local plaintext copy.

## Evidence and limits

`npm test` exercises actual HTTP requests and SQLite persistence: authentication, read-only scope, per-user isolation, create/complete/correct flow, schema rejection, retries, duplicate check-ins, stale edits, soft-deleted evidence, request audit, and credential revocation. The test uses a disposable temporary database, separate from the live Muse test database.

`npm run audit` prints synthetic context, saved-write receipts and request metadata. Request records contain route, method, time, status and response hash, not tokens or request headers. Records/receipts preserve synthetic fixture text; do not put real personal data into this prototype.

- No speech analysis, genuine improvement measurement, or autonomous inference runs in the server.
- All metrics are simulated. Exercise completion is self-reported and never increments a measured-improvement score.
- A session deletion is a reversible hiding flag, not erasure from storage or receipts.
- The connector does not expose arbitrary uploads, audio streaming, arbitrary URL fetching, or access to personal assistant memories.
- Local HTTP tests do not establish Muse tool reliability, cross-chat continuity, phone delivery, or background execution. Those need separate observed tests.
- The optional Modal adapter uses one scale-to-zero container and a persistent volume. Production concurrency, comprehensive rate limiting and account onboarding are not implemented.

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
