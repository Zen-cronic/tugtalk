# Practice dashboard

The shared application serves the public landing at `/` and the dashboard at `/app/`. The dashboard displays saved goals, capture and voice-round transcripts, code-counted speech metrics, model feedback, saved drills and retained audio. Its browser talks only to a same-origin Node gateway. The gateway holds one account's connector credential; the browser receives an opaque, eight-hour HttpOnly session cookie. No model calls are made by dashboard reads. In public read mode (below), visitors can read the same records without a code, and every change still needs a sign-in.

This is a single-account application, private unless public read mode is on. It does not sign into a personal Muse account or retrieve Muse chat history. Conversation import is not connected. Only drills actually saved through the connector are visible; unsaved chat suggestions are not records. Connector provenance alone does not prove which assistant wrote a drill.

## Local fictional preview

Requires Node 24, with no additional packages:

```sh
npm run dashboard:build
npm run dashboard:preview
```

Open `http://127.0.0.1:4321/` for the landing or `http://127.0.0.1:4321/app/` for the private preview. Each tab has its own address: `/app/goals`, `/app/conversations` and `/app/recordings` (`/app/` opens Goals). These three exact paths serve the same app shell and headers as `/app/`; any other `/app/` path must be a listed asset or returns 404. The generated access code is in `.data/dashboard-preview-code.txt`, mode 0600, and is never printed by the server. Read it locally and paste into the sign-in field. `.data/` is excluded from Git. The fixture API uses port 4320; change `DASHBOARD_PORT` and `DASHBOARD_FIXTURE_PORT` if needed. The preview explicitly labels fictional records and stores any setting changes only in memory. Restarting resets them. Its sample WAV is silence, not a person's recording.

For a local public read preview, start it with `DASHBOARD_PUBLIC_READ=1 npm run dashboard:preview`. `/app/` then opens straight to Goals without the access code.

## Public read mode

`DASHBOARD_PUBLIC_READ=1` lets visitors without a session read the dashboard. It is off by default in code and in the local preview; the hosted app sets it (see [dashboard-deployment.md](dashboard-deployment.md)).

- **Open to visitors, GET only:** `/app-api/session`, `/app-api/overview`, `/app-api/context`, `/app-api/goals/{id}`, `/app-api/practice-rounds/{id}`, `/app-api/settings`, `/app-api/media`, `/app-api/media/{id}` (kept-audio playback and download) and `/app-api/conversations`. Voice rounds, practice rounds and exercises arrive inside the overview and context reads. The gateway forwards each read with its server-side connector credential, exactly as for a signed-in session. The credential never reaches the browser.
- **Still gated:** every other method. `PATCH /app-api/settings`, `DELETE /app-api/media/{id}`, `POST /app-api/logout` and any other write return 401 without a session, or 403 when the Origin is wrong. A signed-in session still needs its CSRF token, and `DASHBOARD_ALLOW_RECORDING_CHANGES` still decides whether any write is allowed. The proxy allowlist, exact Host check, content security policy and size limits are unchanged.
- **Limits for visitors:** each client gets a number of API reads a minute (a page load makes about seven) and of audio files an hour, and all visitors together share a total of each. The four numbers are set at deploy time with `DASHBOARD_PUBLIC_READ_LIMIT`, `DASHBOARD_PUBLIC_READ_TOTAL`, `DASHBOARD_PUBLIC_MEDIA_LIMIT` and `DASHBOARD_PUBLIC_MEDIA_TOTAL` (see the table below). Keep the audio total below the account's own limit of 120 downloads an hour, so the owner keeps room. Past a limit the gateway answers 429 without calling the connector. A signed-in session is not counted. The client is found as for sign-in throttling.
- **In the app:** the dashboard opens straight to Goals with a "Public demo, read-only" label in the header. Settings and delete buttons are disabled. A "Sign in" link stays for the owner. `/app/goals`, `/app/conversations` and `/app/recordings` open directly.

Public read mode shows the configured account's real records, including transcripts and kept audio, to anyone with the address. Turn it on only for an account whose records are meant to be seen.

## Private server configuration

Build the assets, then run `npm run dashboard:start` in an environment configured privately with:

| Variable | Meaning |
|---|---|
| `DASHBOARD_ORIGIN` | Exact HTTPS browser origin, including nondefault port if any |
| `DASHBOARD_UPSTREAM` | Existing connector API origin; HTTPS unless loopback |
| `DASHBOARD_CONNECTOR_TOKEN` | Credential bound to the one account this instance serves; server-side only |
| `DASHBOARD_PASSWORD_FILE` | Protected file containing a separate random access code of at least 20 characters |
| `DASHBOARD_PASSWORD` | Alternative server environment value if a protected file is not used |
| `DASHBOARD_PORT` | Local listening port, default 4321 |
| `DASHBOARD_BIND` | Default 127.0.0.1; choose appropriate bind address only behind configured HTTPS ingress |
| `DASHBOARD_LOCAL_HTTP` | Set to `1` only for loopback HTTP testing; insecure nonloopback origins are refused |
| `DASHBOARD_ALLOW_RECORDING_CHANGES` | Defaults off. Set to `1` only when retention changes and individual audio deletion should be enabled |
| `DASHBOARD_PUBLIC_READ` | Defaults off. Set to `1` to let visitors read without the access code (see Public read mode) |
| `DASHBOARD_PUBLIC_READ_LIMIT` | Visitor API reads per client per minute in public read mode. Positive whole number; the code default is deliberately low |
| `DASHBOARD_PUBLIC_READ_TOTAL` | Visitor API reads per minute across all visitors. Not less than the per-client limit |
| `DASHBOARD_PUBLIC_MEDIA_LIMIT` | Visitor audio files per client per hour |
| `DASHBOARD_PUBLIC_MEDIA_TOTAL` | Visitor audio files per hour across all visitors; keep it below the connector's 120 downloads an hour |

An unset limit uses the code default; a value that is not a positive whole number, or a per-client limit above its total, stops the gateway at startup. The hosted values are set at deploy time and are not kept in the repository.

Generate access codes with a cryptographic random source, not a memorable password. Do not put either secret into command arguments, URLs, frontend build variables, screenshots or a committed file. Do not reuse the connector token as the access code. A read-only connector token provides an additional upstream boundary for read-only use.

The HTTPS ingress must preserve the configured Host and support its same-origin routes. A single process owns in-memory sessions and login throttling; restarting signs everyone out. Throttling counts failed codes only: a client that enters five wrong codes in a minute waits out that minute, while a correct code from any other client still signs in, and every wrong code waits a short delay that grows when many failures arrive. Behind the hosting proxy (`DASHBOARD_TRUST_PROXY=1`) the client is the left-most `X-Forwarded-For` entry; otherwise that header is ignored. This is not a multiuser identity system, and sharing its access code shares the configured account. Multiuser deployment needs per-user identity and connector binding, durable session controls and per-user revocation; adding replicas without that work is unsupported.

## Data and controls

- Goal association comes only from stored `goal_id`. Unlinked captures and voice rounds appear separately. Captures, voice rounds and saved drills use the existing API records. Device labels come only from recorded metadata; a voice round is not assumed to come from a Mac.
- The default displayed speech counts are the record's stored `metrics` counts. They are not an improvement score. AI observations and practice-partner replies are labelled separately.
- Refresh occurs on sign-in, browser focus, explicit refresh and successful recording changes. A failed refresh labels previously loaded results as older data. No local storage or service worker caches practice data.
- Audio playback/download goes through the same gateway: with a session, or for visitors in public read mode. No direct media URL or browser bearer is created.
- Turning retention off stops keeping new audio; it does not delete existing files. Each deletion needs a confirmation. Backend idempotency and settings version checks remain authoritative. On a conflict, refresh before reapplying.
- Conversation history is explicitly unavailable. No scraping or undocumented Muse endpoints are used.

The gateway allowlists reads for overview, context, focused goals, practice rounds, settings and media. Its only optional writes are recording settings and individual audio deletion. It rejects arbitrary upstream paths, cross-origin writes, missing CSRF tokens, unexpected body fields, oversized payloads and redirects. Upstream failures are sanitized. Responses use no-store and a restrictive content security policy. Request limits are 16 KB JSON, 4 MB ordinary upstream responses and 16 MB audio.

## Verification

```sh
npm run test:dashboard
npm test
npm run dashboard:build
```

Tests use a local temporary SQLite database or a fake upstream, never a personal account or model endpoint. Coverage includes unauthorized access, public read mode (every UI read open, every write refused, visitor limits, the flag off), CSRF/origin, login throttling, session expiry/logout, proxy allowlist, response sanitization, timeout, account ownership, fresh updates, settings conflicts, credential revocation and default read-only recording controls.

## Confirmed practice requests

With API contract 0.8.0, Goals also shows the current practice request and each objective's saved AI assessment. These assessments are model judgments, separately labelled from speech counts. Exact quoted spans can be checked against an answer, but neither a quote nor an “addressed” judgment proves truth, success or improvement. Capped and ended rounds never imply success.

The dashboard reads `practice_rounds` and `exercise_basis_status` from the fresh overview. It brackets the full context read with two overview reads whose `snapshot_revision` must match; a change retries once, then fails visibly rather than combining evidence from different revisions. Stale/disputed requests, unknown freshness, pending answer assessments and failed fresh reads do not expose earlier assessment evidence as current. Stale drill bases are excluded from the next-action count and marked for review in history. Voice practices preserve a recorded capture device; absent device metadata is not guessed.

The narrow authenticated `GET /app-api/practice-rounds/{id}` forwards to the existing API read route. The dashboard does not create, revise, end, dispute or recover practice rounds, and does not submit model calls. Use the existing confirmed-request flow in Muse for those actions. Existing backends without practice-round projections continue to display the original goals, transcripts and saved drills.

Separate read-only hosting is configured in [dashboard-deployment.md](dashboard-deployment.md).
