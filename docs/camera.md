# Faced the camera (Mac, optional)

While you hold ⌃⌥T to answer, the Mac can count how much of the answer your head faced the camera, and how often you looked away. The reply card shows "62% faced the camera, Looked away 3 times", and the same numbers go into the voice round as `metrics.camera`, so Muse on your phone can quote them from the shared record.

It follows your **head**, not your eyes. Your eyes can drop to your notes while your head stays still, so we say "faced the camera", never "eye contact", and nothing here describes how you felt or came across.

## Turning it on

- Menu bar › **Use the Camera During Practice**. It is off by default.
- The first time, an explainer says what is measured and that no picture leaves the Mac. **Continue** shows the macOS camera prompt once. If the camera was refused, the explainer opens Privacy & Security › Camera instead.
- Turning the menu item off stops it at once. Nothing else changes.

## What happens during a hold

1. Key down: the camera opens (the green camera light comes on). It uses the camera macOS prefers, which is the iPhone when Continuity Camera is in use, or else the built-in camera.
2. About 10 frames a second go to Apple Vision's face detector (`VNDetectFaceRectanglesRequest`, revision 3) for the largest face's head turn (yaw) and tilt (pitch). Each frame is dropped as soon as it is read. Only the two angles are kept, in memory.
3. While you talk, Tug looks back at you when your head faces the camera and its eyes drift off when you turn away. A small dot under the camera, at the top centre of the screen, is filled while you face it and an open ring while you don't. With Reduce Motion both change without animation.
4. Key up: the camera closes at once (the light goes off), and code turns the angles into four numbers. A live round (`WS /v1/voice-rounds/live`) sends them on its end message, `{"type":"end","camera":{…}}`; a file upload, including the fallback after a live round fails, sends them as the `X-Camera-Metrics` header.

The camera never opens while presenting (⌃⌥H) or while a meeting app is in front, and never outside a hold. If it is somehow still open 63 s after a hold started, it closes itself.

## The rule

| | Value | Why |
|---|---|---|
| Facing cone | head turn ≤ 20° and tilt ≤ 15° (`FacingRule.standard`) | Wide enough for the small head movements of talking to the lens; turning to a second screen (usually 30° or more) or tilting down to notes or a keyboard falls outside. Provisional until the hand-label check below. |
| No face in a frame | counts as not facing | The head turned fully away or left the frame. |
| Smoothing | each frame's label is the majority of the 5 frames around it (0.5 s) | One or two noisy or missed frames do not count as a look. |
| Look-away | a run of not-facing frames lasting 1.0 s or more (`CameraMeter.minLookAway`) | A glance under a second still lowers the percentage but is not counted. |
| Too little | fewer than 5 frames analysed | No numbers, no header. The camera takes about half a second to start, so a very short hold has none. |

`faced_camera_pct` is the share of analysed frames that face the camera after smoothing. `longest_look_away_ms` is the longest counted look-away, 0 when there was none; a look-away still running at release lasts until release.

## `X-Camera-Metrics`

Compact JSON, at most 512 bytes, exactly these four integer fields:

```json
{"faced_camera_pct":62,"frames":148,"longest_look_away_ms":4100,"looked_away_count":3}
```

| Field | Range |
|---|---|
| `faced_camera_pct` | 0–100 |
| `looked_away_count` | 0–1200, and not more than `frames` |
| `longest_look_away_ms` | 0–120000; 0 exactly when `looked_away_count` is 0 |
| `frames` | 1–1200 (a 60 s hold at 10 a second is 600) |

Anything else (another field, a missing field, a non-integer, a value out of range, or inconsistent values) is a 400 `invalid_value` before any model call, and nothing is saved. On a live round, numbers that fail the same check are dropped instead (a `camera_ignored` event says why), so the answer is still saved. The round stores the four numbers plus `method: "vision-face-pose-v1"` as `metrics.camera`; the overview's `latest_voice_round.metrics.camera` and `/v1/context` carry it. Rounds without the header have no `camera` field. The numbers are not part of the idempotency fingerprint: a retry with the same key and audio returns the round first saved. The reply model is not given them.

## Accuracy

- **Synthetic check, done.** `swift run camera-eval synthetic` runs the meter on 8 synthetic answers (notes below the screen, a second screen, quick glances, a head held near the cone's edge, leaving the frame, noisy detection), 20 noise seeds each, against the same rule on the noise-free angles. Result in [`eval/camera-synthetic.json`](../eval/camera-synthetic.json): the look-away count was right in 160 of 160 runs, and the share was at most 9 points off (a head held at 16°, just inside the 20° edge). This checks the counting, not Vision on a real face.
- **Real face, not yet measured.** The pass rule: on a 60 s hand-labelled clip the meter must be within 15 points of the hand labels. Until that passes, the feature stays behind its default-off menu item. Steps:

```sh
# 1. Record a 60 s clip in QuickTime Player (File › New Movie Recording), answering a question to the
#    camera and glancing at notes now and then. It stays on this Mac.
# 2. Head angles per frame from the clip, with the app's own Vision code (numbers only, no pictures):
cd apps/mac && swift run -c release camera-eval poses --video ~/Desktop/clip.mov --out /tmp/poses.json
# 3. Label the clip by hand, second by second, while scrubbing it in QuickTime:
node scripts/camera-label.mjs --seconds 60 --out /tmp/labels.json --clip "60 s check"
# 4. Score it. Exit 0 = within 15 points; --sweep lists the cones that agree best, to tune FacingRule.
swift run -c release camera-eval score --poses /tmp/poses.json --labels /tmp/labels.json --sweep
```

`poses` also prints Vision's time per frame. In a Debug build on a 640-pixel still, it was about 20 ms, so 10 frames a second costs roughly a fifth of one core while you hold the key; the app logs the same figure after each hold (category `camera`).

## Testing without a camera (Debug builds)

- `-cameraFixture <poses.json>` replays a list of `{t, yaw, pitch}` frames during each hold instead of opening the camera, so no permission is needed. With `-voiceFixtureWAV` and the local stub server, one scripted hold writes a real round with `metrics.camera`.
- `-cameraPreview facing|away|cycle` (with `-previewState "voice listening"`), `card` (with `-previewState "voice follow-up"`), and `explainer|denied|on` show each state with sample numbers; nothing is sent.
- `-disableHotkeys YES` keeps a test copy from taking ⌃⌥T from a copy already running.

## The hands check (a separate opt-in)

Everything above stays true for "faced the camera": its frames are dropped once read, and no camera image is stored or sent. One exception, off by default and asked each round: **Check what's in my hands** sends a silent clip of that round's answers (10 frames a second, at most 15 seconds) through our server to Meta's SAM 3.1, with `store: false`, so Meta keeps no stored response. Only the seconds it counted are kept. See [docs/replay.md](replay.md).
