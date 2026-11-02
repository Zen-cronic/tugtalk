# Practise on the watch: a spoken round on the wrist

After a capture, or from the goal screen, **Practise this answer** starts a spoken round on Apple Watch. You answer out loud, and Tug, playing the other person in the conversation, asks the follow-up question on the watch and says it through the watch speaker. You answer again. Each answer is saved to the same record the Mac and Muse read.

It uses the same two routes as the Mac, with no change on the server (`docs/voice.md`):

- `POST /v1/voice-rounds` with the answer as a WAV upload, and
- `POST /v1/voice-rounds/{round_id}/speech` for the spoken question.

## One round

1. **Your turn.** Tap **Record**, answer, and tap **Stop**. The red record light is on and the clock runs while the microphone is open. Tap is the watch's own pattern; holding a finger on the screen while talking is awkward on the wrist.
2. **Thinking.** The watch uploads the recording (mono 16-bit PCM WAV, 16 kHz) with:
   - its own `Idempotency-Key`;
   - the goal and language picked on the goal screen (`X-Goal-Id`, `X-Language`);
   - `X-Occurred-At` (when the recording started);
   - `X-Prompt-Ended-At` (when the previous question finished playing, if it played to the end).
   Meta transcribes the answer, code measures it, and Muse Spark Open picks the next move. Code checks the quote and the question before they come back.
3. **Speaking.** The question is the large text on screen. Below it is **You said**, your own words in the transcript face, shown only when code on the server found them word for word in the transcript (`quote_verified`). In English the watch fetches the Wit.ai voice (`wit$Rebecca`, MP3) and plays it with `AVAudioPlayer` on the default audio route, which is the watch speaker. The line under the question says which voice spoke.
4. **Your turn** again, with **Record**. Tapping **Answer now** while the question is still playing stops it. That answer is then sent without `X-Prompt-Ended-At`, because the question had no end.
5. **Round done** after the coach's `wrap_up` move or after the third answer, whichever comes first. The screen shows one number, the count of one habit in your last answer, with the same habit's count in your first answer beside it. Both counts come from the server's own measurements (`metrics` on each round). The habit is picked the way the Mac picks it: the one that dropped the most, or, when none dropped, the one used most in the last answer. With one answer there is no comparison, only that answer's count. The screen never says "improved". **Record again** starts a new round.

The Mac ends a round only on `wrap_up`. The watch also stops at three answers, because in the live runs in `docs/voice.md` the model chose `challenge` 12 times out of 12.

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

Tests: `cd apps/watch/SparringCore && swift test` (30 tests). They cover the turn count, the wrap-up, Retry reusing the same Idempotency-Key and headers, a 429 that offers no Retry, a speech failure that keeps the question and uses the watch voice, French skipping the speech request, the request headers, and the singular and plural labels.

## Try it in the simulator, without a microphone

```sh
STUB_SPEECH_MP3=question.mp3 PORT=4391 npm run stub       # prints token_file
cd apps/watch && xcodegen generate
xcodebuild -project CommsCoachWatch.xcodeproj -scheme CommsCoachWatch -destination 'platform=watchOS Simulator,name=Apple Watch SE 3 (40mm)' -derivedDataPath build/DerivedData build
xcrun simctl install booted build/DerivedData/Build/Products/Debug-watchsimulator/CommsCoachWatch.app
xcrun simctl launch booted com.kaungzinhein.commscoach.watch -devBaseURL http://127.0.0.1:4391 -devTokenFile <token_file> \
  -openSparring YES -sparringAutoplay YES -sparringFixtureWAV a1.wav,a2.wav,a3.wav -sparringVolume 0.1
```

Debug builds only:

- `-sparringFixtureWAV` plays WAV files in place of the microphone (answer n uses the n-th file), so no permission is asked.
- `-sparringAutoplay YES` taps Record and Stop by itself through a whole round.
- `-sparringLanguage fr` runs a French round.
- `-sparringAutoRetrySeconds N` taps Retry once after a failure.
- `-sparringScrollToEnd YES` shows the end of each screen.

Make the fixtures with `say -o a1.aiff "…"` and `afconvert -f WAVE -d LEI16@16000 -c 1 a1.aiff a1.wav`.

## Limits

- Tested in the watchOS simulator only, with the stub server and fixture audio. Playback through the watch speaker, the microphone and the audio session switch between recording and playback still need a check on a real watch.
- The voice-round route has no device label, so a watch round and a Mac round look the same in the record.
- The stub's transcript is fixed, so every stub answer measures the same, and the round's number in those runs is "the same as your first answer".
- The first audio waits for the whole MP3 before it plays (the Mac plays it as it streams).
