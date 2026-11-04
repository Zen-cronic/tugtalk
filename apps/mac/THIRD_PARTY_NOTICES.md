# Third-party notices

## Fonts

Bundled in `TugTalk/Fonts/`, each under the SIL Open Font License 1.1 (full text next to each file):

- Anybody, copyright 2020 The Anybody Project Authors (`OFL-anybody.txt`)
- Hanken Grotesk, copyright 2021 The Hanken Grotesk Project Authors (`OFL-hankengrotesk.txt`)
- Azeret Mono, copyright 2021 The Azeret Project Authors (`OFL-azeretmono.txt`)

The variable font files are unmodified copies from the Google Fonts repository, renamed only.

## clicky

Source: https://github.com/farzaa/clicky (commit a80fa80, MIT License).

Adapted, not copied verbatim:

- `TugTalk/MascotPanel.swift`: the borderless, non-activating floating `NSPanel` settings (from `CompanionResponseOverlay.swift`). Changed: `.floating` level instead of a full-screen overlay, sized to the character, and the character handles its own drag.
- `TugTalk/PermissionGate.swift`: the Screen Recording flow (from `WindowPositionManager.swift`): preflight without prompting, remember a confirmed grant because the preflight can report a false negative, show the system prompt once per launch, then open System Settings. Changed: the prompt only follows an in-app explainer.
- `Sources/ScreenContextCore/WindowCapture.swift`: the ScreenCaptureKit capture shape (from `CompanionScreenCaptureUtility.swift`). Changed: one window via `SCContentFilter(desktopIndependentWindow:)` instead of whole displays, and the image stays in memory as a `CGImage`.

Not used: its push-to-talk event tap, full-screen overlay, model and speech clients, and analytics.

```
MIT License

Copyright (c) 2026 Farza

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

The character is drawn in code in `TugTalk/MascotView.swift` and is original to this project. Icons are Apple SF Symbols, used inside the app's interface only.
