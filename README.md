# TugTalk

Practise out loud. Your assistant remembers.

Communication practice for interviews, meetings, sales pitches and public speaking, based on how you actually talk.

**Landing:** https://tugtalk.live, **API:** https://kaungzinhein--synthetic-coaching-connector-web.us-east.modal.run, **Mac app:** download link added at release, **Demo video:** link added at submission

> "What matters is how you speak and how you want to improve on it." Kaung Zin Hein, who built TugTalk

**The problem: your assistant forgets how you practise.** Practice apps keep what you said to themselves, so every new chat starts from nothing. TugTalk keeps one record that every device shares. Practise on your watch, your Mac or the web, and Muse, the assistant you already use on your phone and laptop, reads that record in any chat. Your next drill comes from how you actually spoke, and you can practise it on any device.

## What it does

- **Practise on your wrist or your Mac.** Record an answer on Apple Watch, or hold ⌃⌥T on the Mac. Meta's speech-to-text writes down what you said, and the app counts your fillers ("um"), unsure words ("I think", "maybe") and restarts.
- **Get a follow-up question.** Muse Spark Open plays the other person: it asks one follow-up question and checks whether you covered the points you set. The app keeps a quote only if you said it word for word.
- **Your assistant remembers.** Every practice lands in one record. Muse, Meta's assistant, reads it through a custom connector, so any new chat on your phone or laptop knows what you practised, and it can save your next drill.
- **See it all in one place.** The web dashboard at [tugtalk.live/app](https://tugtalk.live/app/) shows the same goals, sessions, conversations and recordings.

## Meta models used

| Model | What it does here |
|---|---|
| `muse-voice-transcribe-1.0` (Meta Model API) | Writes down each answer, from a file or live while you talk on the Mac |
| Muse Spark Open (`meta-models/muse-spark-open-1026`), served on Baseten | Asks the follow-up question, checks each point, and writes a short note |
| Muse, Meta's assistant | Reads and updates your practice record through the TugTalk connector |
| Wit.ai voice | Speaks the follow-up question out loud |

Models suggest; the app checks. How each check works is in [docs/technical.md](docs/technical.md).

## Built during the event (Oct 30 – Nov 4, 2026)

From this repository's commit dates (US Eastern time). The first commit is dated Oct 30.

- **Oct 30:** the authenticated goals, exercises and check-ins API with fresh overview reads, and Modal hosting.
- **Nov 1:** the recording route (Meta transcription, code-measured habits, a Muse Spark Open observation), the Apple Watch app, the landing page, the measurement eval, and the claims ledger.
- **Nov 1–2, overnight:** the Mac companion: the screen-context route, the on-device redaction core, the menu-bar app, capture, undo, polling and the Ask Muse hand-off.
- **Nov 2:** pause and speaking-time measurement from the transcription's speech segments, Muse Spark Open labelling of unclear word-list hits (checked by code) with its own eval arm, a hosting adapter that takes several requests at once and serves them all from one long-lived worker (warm health 2.9 s to 0.15 s, spoken reply first byte 6.1 s to under 1 s; see [docs/hosted-latency.json](docs/hosted-latency.json)), the watch's time-cap fix, a guard for malformed transcription replies, and claims checked against behaviour.
- **Nov 3:** confirmed practice requests: Spark assesses each spoken answer against the points you confirmed, and the round's state is saved across devices ([docs/practice.md](docs/practice.md)). Follow-up practice exercises built from a saved assessment ([docs/practice-exercises.md](docs/practice-exercises.md)). The private dashboard, with practice review and recording controls, served from one app with the landing ([docs/dashboard.md](docs/dashboard.md)).
- **Nov 4:** fixes to practice reservations and French replies; the dashboard's tab paths (`/app/goals`, `/app/conversations`, `/app/recordings`) and its Conversations tab; the dashboard opened read-only to visitors, with no access code ([docs/dashboard.md](docs/dashboard.md#public-read-mode)); the TugTalk name; the contract 0.9.1 deploy; connector instructions that ask Muse for short, plain replies, with ids only on request; the pre-registered held-out labelling run, and its two rule outcomes deployed; and the pre-registered assessment eval.

## Run

Requires Node.js 24. No third-party runtime packages.

```sh
npm run setup
npm test
npm run eval   # recompute the measurement eval
npm start
```

Setup creates `.data/connector.sqlite` and a private `.data/owner-token.txt`. It refuses to overwrite an existing credential. Never commit either. Supply `PUBLIC_BASE_URL` when using an HTTPS preview URL; the server binds only `127.0.0.1:4318`. A reverse proxy/tunnel is required for remote access. Local serving requires the host to stay awake. The optional Modal adapter runs independently with persistent storage.

## Limits

- One account: the developer's own practice plus sample recordings read by a computer voice.
- On 40 practice answers we wrote and labelled ourselves, Spark's assessment matched ours on about 2 in 3 points. It has not been measured on other people's spoken answers.
- One answer describes that answer. TugTalk never claims you have improved.

## More detail

- [Technical details](docs/technical.md): which model decides what, what the app checks, the API, measurements, guarantees and the full list of limits.
- Other docs in [docs/](docs/), and the [Mac app](apps/mac/README.md).
