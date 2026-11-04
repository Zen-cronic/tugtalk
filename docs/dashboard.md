# Private practice dashboard

The dashboard displays saved goals, capture and voice-round transcripts, code-counted speech metrics, model feedback, saved drills and retained audio. Its browser talks only to a separate same-origin Node gateway. The gateway holds one account's connector credential; the browser receives an opaque, eight-hour HttpOnly session cookie. No model calls are made by dashboard reads.

This is a private, single-account application. It does not sign into a personal Muse account or retrieve Muse chat history. Conversation import is not connected. Only drills actually saved through the connector are visible; unsaved chat suggestions are not records. Connector provenance alone does not prove which assistant wrote a drill.

## Local fictional preview

Requires Node 24, with no additional packages:

```sh
npm run dashboard:build
npm run dashboard:preview
```

Open `http://127.0.0.1:4321/app/`. The generated access code is in `.data/dashboard-preview-code.txt`, mode 0600, and is never printed by the server. Read it locally and paste into the sign-in field. `.data/` is excluded from Git. The fixture API uses port 4320; change `DASHBOARD_PORT` and `DASHBOARD_FIXTURE_PORT` if needed. The preview explicitly labels fictional records and stores any setting changes only in memory. Restarting resets them. Its sample WAV is silence, not a person's recording.

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

Generate access codes with a cryptographic random source, not a memorable password. Do not put either secret into command arguments, URLs, frontend build variables, screenshots or a committed file. Do not reuse the connector token as the access code. A read-only connector token provides an additional upstream boundary for read-only use.

The HTTPS ingress must preserve the configured Host and support its same-origin routes. A single process owns in-memory sessions and login throttling; restarting signs everyone out. This is not a multiuser identity system, and sharing its access code shares the configured account. Multiuser deployment needs per-user identity and connector binding, durable session controls and per-user revocation; adding replicas without that work is unsupported.

## Data and controls

- Goal association comes only from stored `goal_id`. Unlinked captures and voice rounds appear separately. Watch captures, Mac voice rounds and saved drills use the existing API records.
- The default displayed speech counts are the record's stored `metrics` counts. They are not an improvement score. AI observations and practice-partner replies are labelled separately.
- Refresh occurs on sign-in, browser focus, explicit refresh and successful recording changes. A failed refresh labels previously loaded results as older data. No local storage or service worker caches practice data.
- Audio playback/download is authenticated through the same gateway. No public media URL or browser bearer is created.
- Turning retention off stops keeping new audio; it does not delete existing files. Each deletion needs a confirmation. Backend idempotency and settings version checks remain authoritative. On a conflict, refresh before reapplying.
- Conversation history is explicitly unavailable. No scraping or undocumented Muse endpoints are used.

The gateway allowlists reads for overview, context, focused goals, settings and media. Its only optional writes are recording settings and individual audio deletion. It rejects arbitrary upstream paths, cross-origin writes, missing CSRF tokens, unexpected body fields, oversized payloads and redirects. Upstream failures are sanitized. Responses use no-store and a restrictive content security policy. Request limits are 16 KB JSON, 4 MB ordinary upstream responses and 16 MB audio.

## Verification

```sh
npm run test:dashboard
npm test
npm run dashboard:build
```

Tests use a local temporary SQLite database or a fake upstream, never a personal account or model endpoint. Coverage includes unauthorized access, CSRF/origin, login throttling, session expiry/logout, proxy allowlist, response sanitization, timeout, account ownership, fresh updates, settings conflicts, credential revocation and default read-only recording controls.
