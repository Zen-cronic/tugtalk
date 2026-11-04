# TugTalk

Practise on your watch. Your assistant remembers.

Practise an answer out loud on Apple Watch or the Mac: an interview question, a stand-up update, a point in a meeting. Meta's speech-to-text writes down what you said. Code counts your fillers ("um"), unsure words ("I think", "maybe") and restarts. Muse Spark Open plays the other person: it asks a follow-up and assesses whether you covered the points you confirmed for this practice. Code checks every quote in the follow-up, and every piece of evidence in the assessment, against your own words before it is saved or spoken. The written observation and the Mac's screen card are model text, saved without that check. Muse, Meta's assistant, reads the same record through the API, so it remembers what you practised in any new chat.

**Landing:** https://tugtalk.live · **API:** https://kaungzinhein--synthetic-coaching-connector-web.us-east.modal.run · **Mac app:** download link added at release · **Demo video:** link added at submission

<!-- FOUNDER: one or two sentences in your own words -->

## What Meta's models decide, and what code checks

| Step | Meta model | What the model decides | What code checks | What breaks if Spark Open is off | Status |
|---|---|---|---|---|---|
| Assess the answer against your points | Muse Spark Open (`meta-models/muse-spark-open-1026`) on Baseten, one streamed call per answer | For each of the 1–3 points you confirmed: addressed, partial, not addressed or unclear, with the words that show it, and the next question | An "addressed" or "partial" needs a span that matches your transcript character for character. A duplicate, missing or extra point, or a span that does not match, becomes "unclear" ([`validateAssessment`](src/practice.mjs#L204-L214)). The round ends when every point is addressed, or after 4 answers ([`finishPractice`](src/practice.mjs#L185-L190)). Called from [`replyToAnswer`](src/voice.mjs#L313-L322) | The practice round cannot run. Code-only mode is refused ([`semantic_model_required`](src/practice.mjs#L142)), and without an assessment no point is ever marked addressed, so the round can only stop at the 4-answer cap, unconfirmed | live; matched our labels on 66% of points in a text-only test (below) |
| Play the other person | Muse Spark Open, streamed, low reasoning effort | One follow-up question, which may quote you | A quote is kept only if its words appear in your transcript as one unbroken run. Quoted words you never said are removed, and the question is cut to 25 words ([`verifyQuote`](src/voice.mjs#L68-L77), [`safeQuestion`](src/voice.mjs#L94-L116)) | The round fails. With no reply model configured, the voice route answers 503 `reply_unconfigured` ([`reply_unconfigured`](src/voice.mjs#L248-L249)); a failed or unusable reply answers 502 `reply_failed` ([`reply_failed`](src/voice.mjs#L421), live: [`reply_failed`](src/live-voice.mjs#L281)). A code-only reply mode exists for testing (`X-Reply-Mode: code`, [`codeOnlyReply`](src/counterpart.mjs#L90)), but the Mac sends it only in debug builds ([`replyMode`](apps/mac/CommsCoachMac/VoiceFlow.swift#L64-L69)), and practice rounds refuse it | live |
| Write the screen card (Mac) | Muse Spark Open | A summary, an observation and a next step from one window's redacted text | Re-scrubs pattern-shaped personal data in the input and the output, and caps lengths ([`scrub`](src/screen-context.mjs#L31-L36), [`cleanOutput`](src/screen-context.mjs#L79-L82)). The card's wording is not checked against the window text | No card: the request fails and nothing is saved ([`analysis_failed`](src/screen-context.mjs#L109-L110)) | live; our runs used a fixture window |
| Settle unclear word-list hits | Muse Spark Open, temperature 0 | For each unclear hit ("what kind of report"): a habit, or a normal use of the words, with a reason. Also whether each "like", "genre" or "quoi" is a filler | A label counts only if it names a proposed hit once and copies its text exactly ([`verifyLabels`](src/adjudicate.mjs#L95-L112)). It can only remove a word-list hit, never add one. Filler "like", "genre" and "quoi" are counted apart, in `adjudication.model_only`, and only when every one of their labels passes ([`modelOnlyBlock`](src/adjudicate.mjs#L118-L131)). Unsure words are not sent: they keep the word-list count ([`skipHedges`](src/adjudicate.mjs#L51-L55)) | The word-list count stands, and "like", "genre" and "quoi" are not counted | live since Nov 4; held-out result below |
| Write one observation | Muse Spark Open | One observation and one suggested exercise, in words | Sends it code's counts. Never takes a number from it ([`analyze`](src/capture.mjs#L218-L226)). Its wording, including any quote, is not checked against the transcript | The session is saved without it (`analysis.status: "unavailable"`) | live |
| Write it down from a file | `muse-voice-transcribe-1.0`, ENDPOINTING mode | The words, and when each stretch of speech starts and ends | Counts habits with fixed English and French word lists ([`measure`](src/capture.mjs#L88-L104), [`habitHits`](src/capture.mjs#L65)). Measures pauses and pace from the speech times ([`measurePauses`](src/pauses.mjs#L36)) | Not a Spark call | live |
| Write it down while you talk | `muse-voice-transcribe-1.0` over Meta's realtime socket (Mac, hold to talk) | The words as they arrive | If the socket fails, sends the same audio to the file endpoint ([`REALTIME_URL`](src/live-voice.mjs#L27), [`file_fallback`](src/live-voice.mjs#L270-L274)) | Not a Spark call | live |
| Speak the question | Wit.ai text-to-speech, a Meta voice, `wit$Rebecca` (Meta's Model API has no text-to-speech model) | The audio | Sends only the stored, checked question ([`handleSpeech`](src/speech.mjs#L146-L151)) | Not a Spark call. With no voice configured, the route returns 503 and the Mac uses an Apple voice | live, English only |
| Remember | Muse, as a client of our API, in chats and in scheduled tasks | When to read the record, and what to tell you | The API owns the record. Muse is told to re-read it before each goal-related turn, confirm a save only with a returned receipt, and reply in short, plain words ([`connectorDocument`](src/server.mjs#L138-L234)) | Not a Spark call. Muse still reads code's counts and any saved assessment | scheduled read observed Nov 1 |

Muse row evidence: [docs/muse-scheduled-read.md](docs/muse-scheduled-read.md).

Every Spark Open call goes to Baseten's OpenAI-compatible endpoint, by one of two paths: the streamed voice reply and assessment through [`sparkCall`](src/spark-stream.mjs#L62-L80), which uses [`SPARK_URL`](src/spark-stream.mjs#L12); and the observation, the screen card and the word-list labels through [`sparkJSON`](src/capture.mjs#L157-L164), which has its own copy of the same URL. The assessment of your answer is a model assessment. Code checks that its evidence is your own words, but a matching quote cannot prove the answer is true or good. See [docs/practice.md](docs/practice.md).

## What we found Meta's models can and can't do

- **Why a model assesses the answer, not keywords.** The keyword check we shipped first marks "My birthday is tomorrow." as answering "When will the customer get a fix?", and "We decided what to eat for lunch." as answering "Should we expand the pilot?" (cases in [`test/fixtures/practice-candidates.json`](test/fixtures/practice-candidates.json), predictions from `node scripts/eval-practice.mjs`). These are synthetic cases, labels not independently reviewed. They test the keyword check, not Spark; Spark's assessment is measured in the next point.
- **How often Spark's assessment matches ours.** On 40 answers we wrote and labelled ourselves (88 objectives, text only), the stored assessment matched our label on 66% of objectives (68% on a repeat run), and it marked 10% of not-fully-met objectives as addressed (4% on the repeat), never one we had labelled not addressed. Partly covered points are the weak class: 7 of 25 right on the first run, 9 of 25 on the repeat. The set, the metrics and the run plan were committed before the first model call. Nobody independent labelled the set, and the answers are not real speech. See [eval/SEMANTIC.md](eval/SEMANTIC.md).
- **Spark sorts filler "like", but drops real unsure words, so it now does one and not the other.** On a synthetic held-out set of 60 transcripts written and labelled by a separate agent, not real speech, Spark sorted filler "like", "genre" and "quoi" from normal uses with F1 0.940 and no false counts, against 0.677 for counting every occurrence; the word list alone doesn't count these words at all. But it removed 8 of the 23 real unsure words the word list found, so on unsure words its labels made the count worse than the word list alone (F1 0.652 against 0.708). Both pre-registered rules are now live (deployed Nov 4): model-only filler labels are on, and unsure words keep the word-list count. See [eval/README.md](eval/README.md#held-out-live-run-nov-4).
- **Speech times without word times.** ENDPOINTING mode returns the start and end of each stretch of speech. Code turns the gaps into pause metrics, so pauses are a floor: short pauses inside one stretch are not seen.
- **"uh" comes back as "ah".** On three synthetic `say` clips, the transcript kept "um" in 3 of 3 and wrote a spoken "uh" as "ah" in 3 of 3. The English word list now counts "ah" and "er" as "uh". We have not checked this on a human voice.

## Engineering guarantees

| Guarantee | Where | Test that proves it |
|---|---|---|
| An exact retry returns the original receipt. The same key with different content is refused with 409. Writes run under a write lock (`BEGIN IMMEDIATE`) and re-check the key inside it | [`replay`](src/store.mjs#L166-L174), [`mutate`](src/store.mjs#L191-L204) | [`exact retry replays receipt`](test/connector.test.mjs#L30-L37) |
| A retried recording or voice round returns its receipt before any paid model call | [`handleRecording`](src/server.mjs#L87-L98) | [`retries never re-bill`](test/capture.test.mjs#L80), [`an exact retry replays with no model call`](test/voice.test.mjs#L152), [`a retry with a saved key opens no Meta session`](test/live-voice.test.mjs#L350) |
| A practice answer reserves its round before any paid call. A second answer at the same time is refused before it spends anything | [`claimPractice`](src/practice.mjs#L129-L151) | [`concurrent answers and reused failed keys spend nothing`](test/practice.test.mjs#L69) |
| Versioned records: every update names `expected_version`, and a stale one gets 409 | [`version_conflict`](src/server.mjs#L328), [`version_conflict`](src/practice.mjs#L100) | [`rejects stale update`](test/connector.test.mjs#L45-L52), [`version conflicts`](test/practice.test.mjs#L124) |
| Audit log: each request's route, method, status, response hash and time, never tokens or headers | [`requests`](src/store.mjs#L26), [`audit`](src/store.mjs#L205-L207) | [`audit proves requests`](test/connector.test.mjs#L53-L54) |
| Tokens are stored only as SHA-256 hashes, with scopes, and can be revoked | [`tokens`](src/store.mjs#L23), [`addToken`](src/store.mjs#L30-L38) | read-only scope refused: [`reader-secret`](test/connector.test.mjs#L40); revoked token refused: [`store.revoke`](test/connector.test.mjs#L55) |
| Stale and disputed results are hidden. When a goal or source changes, or you dispute an assessment, the old assessment and reply are withheld from reads and from the dashboard | [`projectPractice`](src/practice.mjs#L64-L72), [`semanticSourceCurrent`](src/practice.mjs#L199-L203), [`context`](src/store.mjs#L63-L67) | [`stale goal/source blocks inference`](test/practice.test.mjs#L82), [`hide request and assessment evidence`](test/dashboard-practice-view.test.mjs#L10), [`hide all scenario and result content`](test/dashboard-exercises.test.mjs#L11) |
| Quote checks: follow-up quotes, assessment evidence and word-list labels must match your transcript. The observation and the screen card are not quote-checked | [`verifyQuote`](src/voice.mjs#L68-L77), [`validateAssessment`](src/practice.mjs#L204-L214), [`verifyLabels`](src/adjudicate.mjs#L95-L112) | [`verifyQuote`](test/voice.test.mjs#L24), [`a quote the speaker never said is dropped`](test/voice.test.mjs#L218); [`per-objective shape/evidence validation`](test/practice.test.mjs#L44), [`never close by keyword`](test/practice.test.mjs#L59); [`copies the quote exactly`](test/adjudicate.test.mjs#L31) |
| Persistence: SQLite on a Modal Volume. A write is answered only after the volume commits. Record fingerprints matched before and after each Nov 4, 2026 redeploy | [`volume`](deploy/modal_app.py#L8), [`volumes`](deploy/modal_app.py#L35); [`settle`](deploy/bridge.py#L222-L232) | [`test_commit_failure_never_reports_success`](deploy/test_bridge.py#L227), [`one process serves many requests`](test/worker.test.mjs#L14), reopened database: [`reopened`](test/connector.test.mjs#L58) |
| Every limit, model name and eval number in [FACTS.md](FACTS.md) is recomputed from the code | [FACTS.md](FACTS.md) | [`test/facts.test.mjs`](test/facts.test.mjs) |

## Real vs simulated

| State | What |
|---|---|
| **Live on the hosted API** | Meta speech-to-text (file and realtime), the Spark Open jobs above, the Wit.ai voice, goals, practice rounds, receipts and the audit log. One synthetic account with one key; there is no sign-up |
| **Mostly tested in the simulator** | The Apple Watch app. Most of our watch runs used the watchOS simulator with fixture audio or the Mac microphone, and a local stub server. On a real Apple Watch, one capture has succeeded: on Nov 4 at 13:08 EST, session `ab367ab1…`, measured and saved. The watch speaker and the watch voice round have not been checked on a real watch |
| **Tested with synthetic clips** | The Mac voice loop. Our recorded runs used macOS `say` clips, not a person's voice |
| **Off** | The SAM 3.1 hands check ([docs/replay.md](docs/replay.md)). The hosted route exists only when deployed with `REPLAY_ENABLED=1`, and it is off by default for each round |
| **Measured, then deployed (Nov 4)** | The pre-registered held-out run for word-list labelling (above). Both rule outcomes are live: model-only filler labels are on, and unsure words keep the word-list count |
| **Measured on text we wrote** | How often the assessment of your answer matches our label: 40 answers, 88 objectives, text only (above) |
| **Not yet measured** | The assessment on real people's spoken answers. "Faced the camera" on a real face. Any improvement over time: `measured_improvement` is always `null` |

The full list of limits is in [Limits in detail](#limits-in-detail).

## Built during the event (Oct 30 – Nov 4, 2026)

From this repository's commit dates (US Eastern time). The first commit is dated Oct 30.

- **Oct 30:** the authenticated goals, exercises and check-ins API with fresh overview reads, and Modal hosting.
- **Nov 1:** the recording route (Meta transcription, code-measured habits, a Muse Spark Open observation), the Apple Watch app, the landing page, the measurement eval, and the claims ledger.
- **Nov 1–2, overnight:** the Mac companion: the screen-context route, the on-device redaction core, the menu-bar app, capture, undo, polling and the Ask Muse hand-off.
- **Nov 2:** pause and speaking-time measurement from the transcription's speech segments, Muse Spark Open labelling of unclear word-list hits (checked by code) with its own eval arm, a hosting adapter that takes several requests at once and serves them all from one long-lived worker (warm health 2.9 s to 0.15 s, spoken reply first byte 6.1 s to under 1 s; see [docs/hosted-latency.json](docs/hosted-latency.json)), the watch's time-cap fix, a guard for malformed transcription replies, and claims checked against behaviour.
- **Nov 3:** confirmed practice requests: Spark assesses each spoken answer against the points you confirmed, and the round's state is saved across devices ([docs/practice.md](docs/practice.md)). Follow-up practice exercises built from a saved assessment ([docs/practice-exercises.md](docs/practice-exercises.md)). The private dashboard, with practice review and recording controls, served from one app with the landing ([docs/dashboard.md](docs/dashboard.md)).
- **Nov 4:** fixes to practice reservations and French replies; the dashboard's tab paths (`/app/goals`, `/app/conversations`, `/app/recordings`) and its Conversations tab; the TugTalk name; the contract 0.9.1 deploy; connector instructions that ask Muse for short, plain replies, with ids only on request; the pre-registered held-out labelling run, and its two rule outcomes deployed; and the pre-registered assessment eval.

## Run

Requires Node.js 24. No third-party runtime packages.

```sh
npm run setup
npm test
npm run eval   # recompute the measurement eval
npm start
```

Setup creates `.data/connector.sqlite` and a private `.data/owner-token.txt`. It refuses to overwrite an existing credential. Never commit either. Supply `PUBLIC_BASE_URL` when using an HTTPS preview URL; the server binds only `127.0.0.1:4318`. A reverse proxy/tunnel is required for remote access. Local serving requires the host to stay awake. The optional Modal adapter runs independently with persistent storage.

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
| POST | `/v1/practice-rounds` | Save a confirmed practice request: what you are asked, and 1–3 points your answer should cover. No model call. See `docs/practice.md`. |
| GET, PATCH | `/v1/practice-rounds/{id}` | Read a practice round, or revise, end or dispute it, with a version check |
| POST, GET, PATCH | `/v1/practice-exercises`, `/v1/practice-exercises/{id}` | A fictional follow-up scenario built from one saved assessment, confirmed by the person before it becomes a practice round. See `docs/practice-exercises.md`. |
| POST | `/v1/exercises` | Assign an exercise linked to a goal. With a `basis` (a habit count over the person's own measured sessions) it is a drill: the server recounts the basis and refuses a wrong one with 422 and the true count. One open drill per goal. See `docs/drills.md`. |
| POST | `/v1/check-ins` | Record one self-reported completion/skipped result for an assigned exercise. A watch capture that names a drill (`X-Exercise-Id`) writes the drill's check-in itself, with `evidence_type: measured`. |
| PATCH | `/v1/goals/{id}` | Revise a goal with optimistic version checking |
| PATCH | `/v1/sessions/{id}` | Correct or hide synthetic evidence with a reason and version check |
| GET | `/v1/eval` | Public, read-only. Recomputes the measurement eval over the bundled synthetic corpus (no user data). See `eval/README.md`. |
| POST | `/v1/recordings` | Capture devices (watch, Mac, phone) upload a mono 16-bit WAV (16/24 kHz, ≤180 s, ≤8 MiB). Meta `muse-voice-transcribe-1.0` transcribes it, code measures habits (en/fr word lists), Muse Spark Open words one observation, and a measured session is saved. See `docs/capture.md`. |
| POST | `/v1/screen-contexts` | The Mac companion sends the text of one window, redacted on the Mac (≤6,000 characters). Muse Spark Open writes a short context card; the text and pixels are not stored. See `docs/screen-context.md`. |
| PATCH | `/v1/screen-contexts/{id}` | Hide (undo) or restore a screen context, with a version check |
| POST | `/v1/voice-rounds/{id}/speech` | The round's checked question as audio, from a Meta voice (self-hosted MMS-TTS or Wit.ai, chosen by `SPEECH_PROVIDER`). 503 when none is configured, and the Mac uses an Apple voice. See `docs/voice.md`. |
| POST | `/v1/voice-rounds` | A device posts one spoken answer (WAV, as for recordings). Meta transcribes it, code measures it, Muse Spark Open plays the other person and returns one question, and code checks the reply's quote word for word against the transcript. In a confirmed practice round, the same call also assesses the answer against its points. The audio is not stored unless Keep my recordings is on. See `docs/voice.md` and `docs/practice.md`. |
| POST | `/v1/voice-rounds/end` | A device ended its practice round without a wrap-up (the watch's End round, the Mac's bubble closed), so the next answer from any device is answer 1. No model call; idempotent. See `docs/voice.md`. |
| GET, PATCH | `/v1/settings` | The person's settings: `keep_recordings` ("Keep my recordings"), off by default, versioned. Turning it off can also delete what is kept. See `docs/keep-recordings.md`. |
| GET, DELETE | `/v1/media`, `/v1/media/{id}` | Your kept recordings: list, download (`audio/wav`, owner only, 120 per hour), delete one or all. |
| POST | `/v1/sessions/{id}/remeasure` | Re-run the code metrics on a session's saved transcript as a new version, keeping the old; `retranscribe: true` re-transcribes the kept recording (paid, only when asked). |

All `/v1/` paths except `GET /v1/eval` require `Authorization: Bearer <key>`. Writes additionally require `Idempotency-Key`. An exact retry returns the original receipt; changed content with the same key returns 409. New keys cannot duplicate an exercise's check-in. Use a new assigned exercise for a new attempt. Updates require `expected_version`; stale versions return 409. JSON bodies are limited to 16 KiB. These are this service's limits, not Muse platform limits.

The authenticated identity comes only from the token. Clients cannot choose another user in the request. Record IDs and receipts are scoped by account. Tokens are stored hashed in SQLite; the bootstrap file holds the only local plaintext copy.

## Measurement details

**Measured habit counts: precision 0.788, recall 0.852 on 70 synthetic, self-labelled en/fr transcripts (flat word-list baseline 0.754 / 0.852); 0 false counts on 12 clean controls. Recompute with `npm run eval` or `GET /v1/eval`; method and limits in [eval/README.md](eval/README.md).**

**What transcription gives.** The counts depend on the transcript keeping fillers such as "uh" as words. In a repeat run of one clip, one run kept an "uh" and the other dropped it. On Nov 2, on three synthetic `say` clips, the transcript kept "um" in 3 of 3 and wrote a spoken "uh" as "ah" in 3 of 3. So since Nov 2 the English word list (`lexicon-en-v2`) counts "ah" and "er" as "uh"; the eval corpus has neither spelling, so its numbers did not change. ENDPOINTING mode also returns each speech segment with start and end times. Code turns the gaps between segments into `metrics.pauses`: pauses from 250 ms, the longest pause, pauses of 1 s or more, silence before the first segment, speaking time against clip time, and words per minute of speaking time.

**What Spark Open decides about word-list hits.** The word list counts every listed phrase, so normal uses such as "what kind of report", "I mean it" or "du coup de fil" count as habits. When a transcript has such unclear hits, one Spark call gets each hit with its exact text and six words either side, and labels it `habit` or `content`. Pure vocal fillers (um, uh, erm, euh, bah) are counted without asking, and a capture without unclear hits makes no call. Since Nov 4 the hosted app also sends every "like", "genre" and "quoi" in the same call, and no longer sends unsure words, which keep the word-list count (held-out result below).

**What code verifies.** A label counts only if it names a proposed candidate once, copies that candidate's text exactly as the transcript has it, says `habit` or `content`, and gives a reason. Anything else keeps the word-list count for that hit. So does a failed, truncated or refused call, after the same retry rule every Spark call follows. A content label can only remove a proposed hit. The model cannot add a hit or change a number. The session keeps both numbers: `adjudication.lexicon_count` and `adjudication.adjudicated_count`, with `adjudication.status` (`adjudicated`, `partial`, `fallback` or `no_candidates`) and each candidate's label, reason and rejection. `metrics` stays as it was, all code-measured.

**Results and limits.**

- **Held-out live run, Nov 4 (pre-registered).** Filler "like", "genre" and "quoi" (86 occurrences): Spark's labels scored precision 1.000, recall 0.886, F1 0.940, against 0.677 for counting every occurrence. Unsure words: recall 0.484 against the word list's 0.742. Under the pre-registered rules, rule 1 passes (count those fillers with Spark's labels) and rule 2 fires (stop asking Spark about unsure words). Both are live on the hosted app since the Nov 4 deploy (`ADJUDICATE_MODEL_ONLY=1`, `ADJUDICATE_HEDGES=0`): the filler labels are reported in `adjudication.model_only`, apart from the word-list counts, and unsure words keep the word-list count. See [eval/README.md](eval/README.md#held-out-live-run-nov-4).
- **First live run, Nov 2, on our own corpus.** One run, self-labelled corpus, 42 Spark calls at low reasoning effort: precision 0.953, recall 0.672, F1 0.788, against 0.788 / 0.852, F1 0.819 for the word list alone. The model removed all 12 content traps, but it labelled most unsure words as content ("Maybe", "probably", "Je pense"), so recall for unsure words fell from 0.889 to 0.333. Fillers (F1 0.889 against 0.800) and restarts (0.846 against 0.800) improved.
- The scripted labelling arm (code-checked scripted replies, not live model runs) scores 0.877 / 0.820. It tests what the check does with good and bad replies, and it did not predict the drop for unsure words.
- A wrong label that copies the text correctly passes the check. The eval counts these.
- A segment boundary is the transcriber's endpoint, not a word timing. A filled pause is speech, so pauses are a floor. Silence before the first segment includes the time between tapping record and starting to speak.
- Labelling adds one paid Spark call to each capture with unclear hits.
- The observation model still receives the word-list counts, not the labelled counts or the pauses. The watch shows the word-list filler count.

## Limits in detail

- **One synthetic account.** The hosted service has a single synthetic account and a single Bearer key. There is no sign-up or onboarding.
- **The watch carries that key.** The watch app reads the key from a Git-ignored `Secrets.xcconfig` at build time. A product would issue each device its own revocable token.
- **Some records are simulated.** The two seeded sessions (`session-before`, `session-after`, dated Oct 30 and 31) are fictional, and their pause values are made up. Exercise completions are self-reported. Only sessions with `source: capture` were measured from audio.
- **Your audio.** Audio is deleted after transcription unless you turn on Keep my recordings (off by default). Kept audio stays in your account and you can delete it any time. It is capped at 200 MB per account, never logged, and sent to a model only when you ask for a re-transcription.
- **Nothing is pushed.** Muse reads the shared record when a chat or a scheduled Muse task calls the API. The backend never wakes Muse, the phone or the watch.
- **Capture clients.** The watch app records speech; our watch captures ran in the watchOS simulator, apart from one real Apple Watch capture on Nov 4. The Mac companion (`apps/mac`) reads one window's text when asked; its tests and our end-to-end runs used a synthetic fixture image and a local server with stub models, and two live calls to the hosted route used the fixture's redacted text. The API also accepts `phone` as a label, but there is no phone client.
- **The Mac voice loop.** Hold ⌃⌥T, and the companion answers with a voice reply (`apps/mac/README.md`). Our runs used synthetic `say` clips. Spoken names are not redacted.
- **The watch voice round.** After a capture, Practise this answer lets you answer out loud on the wrist; the follow-up appears on the watch and is spoken, until code ends the round (at most four answers), saved to the same record (`docs/watch-sparring.md`). Our runs used fixture audio and a local stub server in the simulator.
- **"Faced the camera" is head direction, measured on the Mac, and off by default.** With **Use the Camera During Practice** on, Apple Vision reads head angles on the Mac while ⌃⌥T is held, and only four numbers join the voice round as `metrics.camera` ([docs/camera.md](docs/camera.md)). It does not track the eyes. Its counting is checked on synthetic head angles, not a real face.
- **The quote check covers quoted text only.** In a follow-up, only words inside quotation marks are checked against your transcript. An unquoted paraphrase is not checked. The observation and the screen card are not checked against your words at all.
- **Restarts are counted from words.** "Sorry" and "let me restart" count; a repeated phrase such as "with with" does not. "Sorry, let me restart" counts as two restarts.
- **The word lists are fixed.** They leave out filler "like", "quoi" and "genre", which only Spark's labels count (in `adjudication.model_only`, not in `metrics`), and spellings such as "Umm".
- **The eval corpus is ours.** We wrote and labelled all 70 transcripts ourselves. It is not real speech and nobody independent checked it.
- **Transcripts can be wrong.** Meta's transcription can drop or invent words. Speakers are not separated. Unless you turn on Keep my recordings, nobody can re-check a transcript against its audio.
- **The spoken voice.** The speech route can use Meta's MMS-TTS models (`facebook/mms-tts-eng`, `facebook/mms-tts-fra`), which are licensed CC-BY-NC-4.0 (non-commercial, attribution required), self-hosted, or Wit.ai's text-to-speech. The hosted service uses Wit.ai's Rebecca voice (English); French replies, and any reply whose audio is slow to start, use an Apple voice on the Mac.
- **The observation is model-written.** Muse Spark Open words it from the transcript and the counts; code never takes numbers from it.
- **The Mac companion can be seen in screen shares.** macOS offers no public way to hide a window from screen sharing. Hide it with ⌃⌥H; it also hides itself while a known meeting app is in front.
- **Redaction on the Mac can miss things.** It replaces emails, phone numbers, long numbers, links, addresses and the names Apple's name recognition finds. A name it does not recognise, or text inside a picture, can get through. The server re-checks only pattern-shaped data, not names. The Mac also sends the front app's name as macOS reports it, which is not redacted; never the window title or pixels.
- **One small container.** Hosting is one scale-to-zero Modal container. It stays up for 5 minutes after the last request; the first request after that waits for a cold start of about 3 s (`KEEP_WARM=1` keeps one running). It takes up to 4 requests at once, but requests that call a model run one at a time. The only rate limits are 30 recordings, 30 screen contexts and 60 voice rounds per hour. Each paid request has one 120 s time budget, 30 s under the hosting deadline.

The limits, model names and eval numbers we state are listed in [FACTS.md](FACTS.md), and a test checks each one against the code.

## Evidence

`npm test` exercises actual HTTP requests and SQLite persistence: authentication, read-only scope, per-user isolation, create/complete/correct flow, schema rejection, retries, duplicate check-ins, stale edits, soft-deleted evidence, request audit, and credential revocation. The test uses a disposable temporary database, separate from the live Muse test database.

`npm run audit` prints synthetic context, saved-write receipts and request metadata. Request records contain route, method, time, status and response hash, not tokens or request headers. Records/receipts preserve synthetic fixture text; do not put real personal data into this prototype.

- A session deletion is a reversible hiding flag, not erasure from storage or receipts.
- Beyond the WAV capture route used by capture devices, there are no arbitrary uploads, audio streaming, arbitrary URL fetching, or access to personal assistant memories.
- Local HTTP tests do not establish Muse tool reliability, cross-chat continuity, phone delivery, or background execution. Those need separate observed tests.
- Scaling past one container, comprehensive rate limiting and account onboarding are not implemented.

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
