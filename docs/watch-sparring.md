# Practise on the watch: a spoken round on the wrist

After a capture, or from the goal screen, **Practise this answer** starts a spoken round on Apple Watch. You answer out loud, and Tug, playing the other person in the conversation, asks the follow-up question on the watch and says it through the watch speaker. You answer again. Each answer is saved to the same record the Mac and Muse read.

It uses the same routes as the Mac (`docs/voice.md`):

- `POST /v1/voice-rounds` with the answer as a WAV upload,
- `POST /v1/voice-rounds/{round_id}/speech` for the spoken question, and
- `POST /v1/voice-rounds/end` when the round ends without a wrap-up (below).

## One round

1. **Your turn.** Tap **Record**, answer, and tap **Stop**. The red record light is on and the clock runs while the microphone is open. Tap is the watch's own pattern; holding a finger on the screen while talking is awkward on the wrist.
2. **Thinking.** The watch uploads the recording (mono 16-bit PCM WAV, 16 kHz) with:
   - its own `Idempotency-Key`;
   - the goal and language picked on the goal screen (`X-Goal-Id`, `X-Language`);
   - `X-Occurred-At` (when the recording started);
   - `X-Prompt-Ended-At` (when the previous question finished playing, if it played to the end);
   - `X-Screen-Context-Id`: the Mac's latest screen card, read from the overview the watch already loads. It is the selected goal's newest card, or else the account's newest card when no goal owns it (with no goal selected, the account's newest card, as the Mac sends its last card), and only if it is under an hour old; never another goal's card. With it, the round's first reply picks what the other person needs from the card, so the need set by what is on the Mac's screen reaches the wrist. Without one, the round runs without a need. If the card was hidden on the Mac after the overview was read (404), the same answer is sent again, with the same key, without it;
   - `X-Counterpart-Need`, when the round's first reply named what the other person needs (`counterpart.need`). The watch holds it for the round and drops it at the end, as the Mac does.
   Meta transcribes the answer, code measures it, and Muse Spark Open picks the next move. Code checks the quote and the question before they come back.
3. **Speaking.** The question is the large text on screen. Below it is **You said**, your own words in the transcript face, shown only when code on the server found them word for word in the transcript (`quote_verified`). In English the watch fetches the Wit.ai voice (`wit$Rebecca`, MP3) and plays it with `AVAudioPlayer` on the default audio route, which is the watch speaker. The line under the question says which voice spoke.
4. **Your turn** again, with **Record**. Tapping **Answer now** while the question is still playing stops it. That answer is then sent without `X-Prompt-Ended-At`, because the question had no end.
5. **Round done** when the reply's move is `wrap_up`. Code decides that, not the model: the server's move gate (`src/counterpart.mjs`, [Who ends the round](voice.md#who-ends-the-round)) allows only `wrap_up` from the second answer once an answer has no unsure words (and meets the need, if there is one), and at the fourth answer whatever was measured. The watch stops at the fourth answer too, so a server without the gate still ends the round. The screen shows one number, the count of one habit in your last answer (for example "0 unsure words"), with the same habit's count in your first answer under it ("In your last answer, down from 2 in your first"), and says why the round ended. Both counts come from the server's own measurements (`metrics` on each round). The habit is picked the way the Mac picks it: the one that dropped the most, or, when none dropped, the one used most in the last answer. With one answer there is no comparison, only that answer's count. The screen never says "improved". **Record again** starts a new round.
6. **End round** before the wrap-up (or the watch's own fourth-answer stop on a server without the gate, or leaving the screen mid-round) also ends the round on the server: the watch sends `POST /v1/voice-rounds/end` with its own Idempotency-Key. The server counts a round's answers itself, across the Mac and the watch, so without it the next answer would be counted as the old round's next one (and could be cut to a wrap-up as answer 4). Until the server confirms it, the same end is sent again, with the same key, before the next round's first answer, and that answer waits for it. So **Record again** after End round is answer 1 of a new round, and the model chooses the need again.

## Voices

| Case | Voice |
|---|---|
| English | The coach's Wit.ai voice (MP3), through `POST …/speech` |
| French | The watch's own voice (`AVSpeechSynthesizer`, fr-FR). Wit.ai has no French voice, so the watch does not ask for one |
| The speech request fails (503 `speech_unconfigured`, 502, not audio, offline, or no audio within 6 s) | The watch's own voice, and the line says why ("Watch voice: the coach has no voice set up"). The question text stays on screen either way |

## States

| State | What the watch shows |
|---|---|
| Offline, or a 5xx | Each send is retried at most twice more, with the same key. Then "Lost connection." or "The coach couldn't reply just now.", "Your answer is saved on the watch.", and **Retry**, which resends the same file with the same Idempotency-Key and headers. If the server saved the round, it replays it with no new model call |
| 429 | "At most 60 voice rounds per hour. Try again later." No Retry: the limit does not lift in seconds |
| Not signed in | The connector key from `Secrets.xcconfig` is missing or refused (401): the same setup the watch's captures use |
| Microphone off | "Microphone access is off. Enable it in Settings." and **Try again** |
| A recording under 0.5 s | Not sent (the server's minimum); "That was too short to send." |
| Keep my recordings on | "Recording kept" under the question and on Round done, when the server's `media.kept` is true |

## Code

- `apps/watch/SparringCore`: a small Swift package with no UI or audio, linked by the watch target. It holds the round's turn machine (`SparringMachine`), the two requests (`RoundRequests`), the client with its retry rule (`RoundClient`), the failure wording (`RoundFailure`) and the round's number (`RoundSummary`). The Mac's shared package (`apps/mac/Sources/ScreenContextCore`) is macOS-only, because it links ScreenCaptureKit and Vision, so the few voice-round types are kept here in the same shape.
- `apps/watch/CommsCoachWatch/Sparring.swift`: performs what the machine decides (the microphone, the upload, the player and the speech synthesizer).
- `apps/watch/CommsCoachWatch/SparringView.swift`: the screens. Tug listens with its brows up and its string taut, closes its eyes while thinking, and moves its mouth while speaking. With Reduce Motion, Tug holds still and the mouth stays half open while it talks.

Tests: `cd apps/watch/SparringCore && swift test` (41 tests). They cover the turn count, the wrap-up from the move gate, the need carried to later answers, the round end sent after End round (and resent with its key until confirmed, never after a wrap-up), the screen card picked from the overview and dropped on a 404, Retry reusing the same Idempotency-Key and headers, a 429 that offers no Retry, a speech failure that keeps the question and uses the watch voice, French skipping the speech request, the request headers, and the singular and plural labels.

## Try it in the simulator, without a microphone

```sh
STUB_SPEECH_MP3=question.mp3 PORT=4391 npm run stub       # prints token_file
cd apps/watch && xcodegen generate
xcodebuild -project CommsCoachWatch.xcodeproj -scheme CommsCoachWatch -destination 'platform=watchOS Simulator,name=Apple Watch SE 3 (40mm)' -derivedDataPath build/DerivedData build
xcrun simctl install booted build/DerivedData/Build/Products/Debug-watchsimulator/CommsCoachWatch.app
xcrun simctl launch booted com.kaungzinhein.commscoach.watch.watchkitapp -devBaseURL http://127.0.0.1:4391 -devTokenFile <token_file> \
  -openSparring YES -sparringAutoplay YES -sparringFixtureWAV a1.wav,a2.wav,a3.wav -sparringVolume 0.1
```

Debug builds only:

- `-sparringFixtureWAV` plays WAV files in place of the microphone (answer n uses the n-th file), so no permission is asked.
- `-sparringAutoplay YES` taps Record and Stop by itself through a whole round.
- `-sparringLanguage fr` runs a French round.
- `-sparringAutoRetrySeconds N` taps Retry once after a failure.
- `-sparringScrollToEnd YES` shows the end of each screen.
- `-sparringScrollTo source` centres one part of each screen (here, Round done's source line).

Make the fixtures with `say -o a1.aiff "…"` and `afconvert -f WAVE -d LEI16@16000 -c 1 a1.aiff a1.wav`.

## Install on a watch Xcode can't see: TestFlight (internal testing)

The project has two targets, as in Xcode's Watch-only App template:

| Target | Bundle ID | What it is |
| --- | --- | --- |
| `CommsCoach` | `com.kaungzinhein.commscoach.watch` | The App Store wrapper: an iOS stub with no executable that carries the watch app under `Watch/`. The App Store Connect listing uses this ID. |
| `CommsCoachWatch` | `com.kaungzinhein.commscoach.watch.watchkitapp` | The watch app (`WKWatchOnly`), with the app icon. Embedded in the wrapper. |

Use the `CommsCoach` scheme to archive and upload, and the `CommsCoachWatch` scheme for simulator and watch runs. Archiving the watch app on its own makes an archive App Store Connect can't accept.

1. In App Store Connect, **Apps › + › New App**: platform iOS (watch-only apps are listed there), name "TugTalk", bundle ID `com.kaungzinhein.commscoach.watch`, any SKU.
2. Archive and upload. The upload uses Xcode's signed-in account to sign for distribution, and makes the App IDs and store profiles for both bundle IDs:
   ```sh
   cd apps/watch && xcodegen generate
   xcodebuild -project CommsCoachWatch.xcodeproj -scheme CommsCoach -configuration Release -destination 'generic/platform=iOS' -archivePath build/CommsCoachWatch.xcarchive archive -allowProvisioningUpdates
   xcodebuild -exportArchive -archivePath build/CommsCoachWatch.xcarchive -exportOptionsPlist ExportOptions-TestFlight.plist -exportPath build/export -allowProvisioningUpdates
   ```
   The destination is iOS because the wrapper is the archived target; Xcode builds the embedded watch app for watchOS. Raise `CURRENT_PROJECT_VERSION` in `project.yml` before each new upload (both targets share it). The build includes the synthetic test account's connector key from `Config/Secrets.xcconfig`, as every local build does.
3. In **TestFlight › Internal Testing**, add a group, add yourself, and add the build once it has finished processing.
4. On the iPhone paired with the watch, open TestFlight and install TugTalk. It installs on the watch.

## One live round (Nov 2, 15:56 EST)

One round of three answers in the watchOS simulator against the hosted service, before the move gate was deployed there and while the watch still stopped at three answers, with three `say` fixture clips in place of the microphone: 3 Meta transcriptions and 3 Spark Open replies, all HTTP 200, and 3 spoken questions, each played on the watch from the coach's MP3. Verbatim from the saved rounds:

| Answer | Transcript (Meta) | Fillers, unsure words, restarts (code) | Question (Spark Open, checked by code) | Quote |
|---|---|---|---|---|
| 1 | "Um, so I think the main point is, uh, we should maybe ship the smaller version first" | 2, 2, 0 | "You said 'I think' — can you pause and summarize my point before you answer?" | "I think" (verified) |
| 2 | "The main point is we ship ship the smaller version first because um it lets us test with real users" | 1, 0, 0 | "Good summary, but can you pause, then say it again more slowly without saying um?" | "um" (verified) |
| 3 | "The main point is we ship the smaller version first. It lets us test with real users this week" | 0, 0, 0 | "You said we ship the smaller version first, but that was very fast. Can you pause, then say it again much more slowly?" | "we ship the smaller version first" (verified) |

Round done showed **0 fillers in your last answer, down from 2 in your first answer**. All three moves were `challenge`; the round ended at the watch's three-answer stop of that build. Server time per round was 3.6–5.1 s. These are three synthetic clips in one round, not a measure of anyone's improvement.

## Limits

- Tested in the watchOS simulator only, with the stub server and fixture audio. Playback through the watch speaker, the microphone and the audio session switch between recording and playback still need a check on a real watch.
- The voice-round route has no device label, so a watch round and a Mac round look the same in the record.
- The stub's transcript is fixed, so every stub answer measures the same, and the round's number in those runs is "the same as your first answer".
- The transcription can double a word ("ship ship" above); it is shown as transcribed.
- The first audio waits for the whole MP3 before it plays (the Mac plays it as it streams).
