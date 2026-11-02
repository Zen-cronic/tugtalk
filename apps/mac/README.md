# Mac companion

A small floating companion for macOS. When you press ⌃⌥Space or click it, it reads the front window, and only that window, on the Mac. It redacts names, emails, phone numbers, long numbers, links and addresses there too, and sends only the redacted text to `POST /v1/screen-contexts` (see [docs/screen-context.md](../../docs/screen-context.md)). Muse Spark Open writes a short context card into the same shared record that the watch writes to and that Muse reads.

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

- A menu-bar accessory with no Dock icon, plus one small floating character drawn in code.
- States: idle, listening (reading a window), thinking (Muse Spark Open), speaking (the card), nudging (Muse or the watch changed the record), blocked, offline, and hidden. Each shows an icon and a text label, not colour alone. **Preview States** in the menu shows each one with sample content; nothing is sent.
- Hotkeys: ⌃⌥Space read this window, ⌃⌥H hide (presenting), ⌃⌥G ghost mode (clicks pass through at 35% opacity), ⌃⌥Z undo the last card. They use Carbon hotkeys, which need no Accessibility permission. Every action is also in the menu.
- VoiceOver reads the character as one element and announces state changes. With Reduce Motion it does not bounce, breathe or blink. With Reduce Transparency the bubble is opaque.
- **The companion can appear in screen shares.** Hide it with ⌃⌥H. It also hides itself while Zoom, Teams, FaceTime or Webex is the front app, which is a guess, not detection.
- The character's name is one constant, `MascotName`, in `CommsCoachMac/Settings.swift`.

## Run it against a local test server (no permission, no key)

```sh
npm run stub    # prints the token file path; stub models, throwaway database, port 4319
# create a goal with curl (see docs/screen-context.md), then:
open apps/mac/build/DerivedData/Build/Products/Debug/CommsCoachMac.app --args \
  -devBaseURL http://127.0.0.1:4319 -devTokenFile <token file> \
  -fixtureImage "$PWD/apps/mac/Fixtures/meeting-prep.png" -goalID <goal id> -demoMode YES
```

`-devBaseURL` is refused for any host other than this machine, and the Keychain is not read in that mode. `-fixtureImage` reads the PNG instead of the screen, so no Screen Recording grant is needed. `-captureOnLaunch YES` runs one capture at start. In Demo mode the companion checks the record every 15 seconds, so an exercise created with curl shows as a nudge within that time.

## Run it against the shared record

1. Store the connector key in the login Keychain. The command prompts for it, so it never appears in shell history:
   `security add-generic-password -s com.zencronic.commscoach.mac -a connector -w`
   On first use macOS asks whether Comms Coach may read it; choose **Always Allow**. The signature is stable, so the answer survives rebuilds.
2. Open the app. In the menu, choose the goal under **Goal** (goals load after the first check) and the purpose under **Purpose**.
3. Press ⌃⌥Space with the window you want read in front. The first time, the companion explains Screen Recording; **Continue** shows the macOS prompt once, and **Open Settings** goes to Privacy & Security › Screen Recording. Turn on Comms Coach, then quit and reopen it.
4. The card shows the receipt. **Undo** hides it from the record. **Ask Muse** copies a question about the card and opens Muse; you paste and send it. The companion never types into Muse or any other app.

The Keychain key is sent only over HTTPS to the coach host built into the app (`CoachAPI.defaultBaseURL`); a changed `baseURL` setting for any other host or scheme is refused, and the bubble says so. A 429 (more than 30 cards in an hour) shows the limit without a Retry button, because the limit does not lift in seconds.

The companion reads nothing on a timer. It checks the shared record every 2 minutes (every 15 s in Demo mode) to notice exercises Muse added, goal changes and new watch captures.
