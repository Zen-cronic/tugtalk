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
