# Mac companion

A small floating companion for macOS. Hold ⌃⌥T and talk, and it answers with a voice reply (see [Voice replies](#voice-replies-hold-t)). When you press ⌃⌥Space or click it, it reads the front window, and only that window, on the Mac. It redacts names, emails, phone numbers, long numbers, links and addresses there too, and sends only the redacted text to `POST /v1/screen-contexts` (see [docs/screen-context.md](../../docs/screen-context.md)). Muse Spark Open writes a short context card into the same shared record that the watch writes to and that Muse reads.

## Layout

| Path | What |
|---|---|
| `Package.swift`, `Sources/ScreenContextCore/` | On-device core: one-window capture, Vision OCR, redaction, payload, API client, nudge diff |
| `Sources/sc-capture/` | CLI that runs the core on an image file, with no permission needed |
| `Tests/ScreenContextCoreTests/` | `swift test` |
| `Fixtures/` | A synthetic meeting-prep note with planted personal data, and the script that renders it |
| `project.yml`, `CommsCoachMac/` | The menu-bar app and the companion character (XcodeGen) |

## Build and test

Requires Xcode 26 and XcodeGen.

```sh
cd apps/mac
swift test
swift run sc-capture --image Fixtures/meeting-prep.png --dry-run
xcodegen generate
xcodebuild -project CommsCoachMac.xcodeproj -scheme CommsCoachMac -configuration Debug -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/CommsCoachMac.app
```

The app signs with an Apple Development identity (team in `project.yml`); change `DEVELOPMENT_TEAM` to your own. A stable signature keeps the Screen Recording grant across rebuilds. There is no notarized build.

## The companion

- A menu-bar accessory with no Dock icon, plus Tug, a small tin-can telephone drawn in SwiftUI, with a plain-word status beside it ("Hold ⌃⌥T and talk", "Listening", "Thinking", "Speaking"). Its face and string act out each state; its string runs to whatever it is showing.
- States: idle, listening (reading a window), thinking (Muse Spark Open), speaking (the card), nudging (Muse or the watch changed the record), blocked, offline, and hidden. For voice: voice listening (the microphone is open), voice thinking, voice speaking (the reply card), voice error, and needs microphone. Each shows an icon and a text label, not colour alone. In Debug builds, **Preview States** in the menu shows each one with sample content; nothing is sent, and normal builds have no sample content.
- Hotkeys: hold ⌃⌥T to talk, ⌃⌥Space read this window, ⌃⌥H hide (presenting), ⌃⌥G ghost mode (clicks pass through at 35% opacity), ⌃⌥Z undo the last card. They use Carbon hotkeys, which need no Accessibility permission. Every action is also in the menu.
- VoiceOver reads the character as one element and announces state changes. With Reduce Motion every animation becomes a still per state and changes crossfade. Cards are always opaque.
- **The companion can appear in screen shares.** Hide it with ⌃⌥H. It also hides itself while Zoom, Teams, FaceTime or Webex is the front app, which is a guess, not detection.
- The character's name is one constant, `MascotName`, in `CommsCoachMac/Settings.swift`. Colours, fonts and motion are in `CommsCoachMac/Theme.swift`; the fonts (Anybody, Hanken Grotesk, Azeret Mono) are bundled under the SIL Open Font License.
- **Show in Dock** (menu toggle, or `-dockMode YES`). Docked mode adds a Dock icon, Tug on a sunflower tile, with an ink count of new changes to the shared record and the red record light while the microphone is open. Clicking the icon opens a panel next to the Dock, and Tug hops from its floating spot into it: its status, the latest spoken round (your quoted words and one number), and Talk (hold it like ⌃⌥T), Read This Window, Ask Muse (when there is a card to open) and Hide Tug. Esc or a click elsewhere closes it and Tug hops back. With Reduce Motion there is no hop. The menu-bar mode stays the default. Debug builds: `-dockPanel YES` opens it at launch; `-reduceMotion YES` shows the still poses.
- **Pointing.** After ⌃⌥Space, when the card is clearly about one line of the window, Tug rings that line on screen, adds a short label ("The ask is here") and says one sentence. Code picks the line by matching the card's words to the text Vision read on this Mac (`LineMatcher`); the model never chooses a position, and nothing extra is sent. The ring is a click-through window over the captured window: Tug sits on the window's title bar and lowers the label on its string, then the ring draws on. The window itself never moves. Before each draw, and every quarter second after, the window must be the same one, unmoved and uncovered (our own card moves aside first); otherwise there is no ring. It goes away after a few seconds, on Esc, or when the card closes. With no clear match there is no ring. Debug builds: `-fixtureImage <png> -fixtureWindow YES -previewPointing YES` shows it on the fixture; `-previewPointing YES` alone rings the sample card's line on the real front window (for filming, TextEdit with `Fixtures/meeting-prep.txt`), using a Screen Recording grant the app already has and never asking for one.

## Voice replies (hold ⌃⌥T)

1. Hold ⌃⌥T and answer out loud, for up to 60 seconds. A red record light shows beside Tug while the microphone is open.
2. Let go. The Mac converts the hold to a 24 kHz mono 16-bit WAV and sends it to `POST /v1/voice-rounds` on the coach host, with the Keychain key, the selected goal, the latest card's id and the reply language (**Voice Reply Language** in the menu). Meta `muse-voice-transcribe-1.0` transcribes it on the server, code measures the habits, and Muse Spark Open picks the next move: a follow-up, a challenge or a wrap-up.
3. The companion speaks the question once the whole reply has arrived. The card shows what it heard, the quote it pressed on (only when the server checked that quote against the transcript), the measured habits, and the time from letting go to the first spoken word.
4. Hold ⌃⌥T again to answer. Pressing it while the companion is still speaking stops the voice at once and starts a new hold. Every hold sends its start time (`X-Occurred-At`). When a question plays to the end, the next hold also sends that end time (`X-Prompt-Ended-At`), so the server can estimate how long you took to start; a question you cut off sends none.

A network failure or a 5xx is retried up to three times with the same idempotency key, so a retry never makes a second round. After that the card offers **Retry**, which sends the same recording with the same key. A 4xx is shown without a retry.

**The voice.** Meta's Model API has no text-to-speech model. The coach server voices each question with its configured speech provider (`POST /v1/voice-rounds/{round_id}/speech`), names that provider in `X-Speech-Provider`, and the Mac plays the WAV or MP3; the card says which voice spoke. The provider's key stays on the server, and the Mac calls no speech service itself. If the server has no voice set up (503 `speech_unconfigured`), cannot be reached, or sends no audio within 2 s, Apple's voice on this Mac says the question instead, and the card says "Fallback voice on this Mac". The Mac waits for the whole clip before playing it; it does not play while the audio is still arriving.

### Privacy

- **Push-to-talk only.** The microphone opens when ⌃⌥T goes down and closes when it comes up, or at 60 seconds. There is no wake word and no listening in the background, and barge-in is a key press too. Each hold uses a fresh audio engine that is released on key-up, so the macOS microphone indicator goes off.
- **The recording is deleted after it is sent.** It waits in a private temporary folder (`0700`, file `0600`) until the round is saved, the error card is closed, or a new hold starts. Any recording left by a quit is deleted at the next launch. The app never logs audio, transcripts or questions, only timings and status codes.
- **Where the audio goes.** Only to the coach host, which passes it to Meta's speech-to-text. Baseten serves Muse Spark Open with the transcript, not the audio, and keeps no data for synchronous Model API calls (zero data retention). We have not confirmed Meta's retention terms for speech-to-text input. The speech provider receives the question text, not your voice.
- **Spoken names are not redacted.** Window text is redacted on the Mac, but a recording cannot be: anything you say, names included, reaches the transcript. Leave out names you would not type.
- **The permission prompt appears once, and only when you ask.** The first hold shows an explainer. **Continue** shows the macOS prompt once; **Open Settings** goes to Privacy & Security › Microphone. The usage string is set in `project.yml`, because XcodeGen regenerates `Info.plist`.

### Filming tips

- Use the built-in or a wired microphone, not AirPods: opening the microphone switches AirPods to their low-quality call mode, and they can take a moment to switch back before the reply plays.
- Record system audio as well as the screen, or the reply will be silent in the recording.
- For the fallback voice, download an English Premium or Enhanced voice in System Settings › Accessibility › Spoken Content › System Voice › Manage Voices. The companion picks the best one installed.
- Grant the microphone before filming, and keep the companion away from Zoom, Teams or FaceTime in front: it hides itself there.

## Run it against a local test server (no permission, no key)

```sh
npm run stub    # prints the token file path; stub models, throwaway database, port 4319
# create a goal with curl (see docs/screen-context.md), then:
open apps/mac/build/DerivedData/Build/Products/Debug/CommsCoachMac.app --args \
  -devBaseURL http://127.0.0.1:4319 -devTokenFile <token file> \
  -fixtureImage "$PWD/apps/mac/Fixtures/meeting-prep.png" -goalID <goal id> -demoMode YES
```

For voice without a microphone (Debug builds only), add `-voiceFixtureWAV <path to any WAV>`. That file stands in for every hold, so no microphone permission is needed. `-voiceScript "down@2,up@5,down@12,up@14"` presses and releases ⌃⌥T at those seconds after launch (`retry@t` and `dismiss@t` press Retry and close), `-voiceSpeaker apple` skips the server voice, and `-voiceVolume 0.2` keeps runs quiet. A synthetic clip: `say -o /tmp/answer.aiff "Um, maybe I should lead the launch." && afconvert -f WAVE -d LEI16@24000 /tmp/answer.aiff /tmp/answer.wav`.

`-devBaseURL` is refused for any host other than this machine, and the Keychain is not read in that mode. `-fixtureImage` reads the PNG instead of the screen, so no Screen Recording grant is needed. `-captureOnLaunch YES` runs one capture at start. In Demo mode the companion checks the record every 15 seconds, so an exercise created with curl shows as a nudge within that time.

## Run it against the shared record

1. Store the connector key in the login Keychain. The command prompts for it, so it never appears in shell history:
   `security add-generic-password -s com.kaungzinhein.commscoach.mac -a connector -w`
   On first use macOS asks whether Comms Coach may read it; choose **Always Allow**. The signature is stable, so the answer survives rebuilds.
2. Open the app. In the menu, choose the goal under **Goal** (goals load after the first check) and the purpose under **Purpose**.
3. Press ⌃⌥Space with the window you want read in front. The first time, the companion explains Screen Recording; **Continue** shows the macOS prompt once, and **Open Settings** goes to Privacy & Security › Screen Recording. Turn on Comms Coach, then quit and reopen it.
4. The card shows the receipt. **Undo** hides it from the record. **Ask Muse** copies a question about the card and opens Muse; you paste and send it. The companion never types into Muse or any other app.

The Keychain key is sent only over HTTPS to the coach host built into the app (`CoachAPI.defaultBaseURL`); a changed `baseURL` setting for any other host or scheme is refused, and the bubble says so. A 429 (more than 30 cards in an hour) shows the limit without a Retry button, because the limit does not lift in seconds.

The companion reads nothing on a timer. It checks the shared record every 2 minutes (every 15 s in Demo mode) to notice exercises Muse added, goal changes and new watch captures.
