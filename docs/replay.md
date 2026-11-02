# Hands check (Mac, opt-in per round)

At the end of a spoken practice round, the Mac can show how long a phone or a paper was in your hand while you answered: `phone in hand 3 s · SAM 3.1 · counted by code`. Meta's SAM 3.1 finds the boxes; code counts the seconds. It is off by default and asked each round.

## Privacy

The camera is off unless you turn it on, and it opens only while you hold the talk key. With it on, Apple Vision reads your head angle on your Mac and only four numbers are sent; no camera image leaves your Mac.

One exception, off by default and asked each round: **Check what's in my hands** sends a silent clip of that round's answers (10 frames a second, at most 15 seconds) through our server to Meta's SAM 3.1, with `store: false`, so Meta keeps no stored response. We found no published retention period for the video input itself. Our server holds the clip in memory only, never on disk, and keeps only the seconds it counted. Keep my recordings never applies to it. Anything in frame is in the clip, including other people and screens behind you.

## Turning it on

- It needs **Use the Camera During Practice** (menu bar), because the clip is made from the frames the camera already reads for "faced the camera" ([docs/camera.md](camera.md)). There is no second camera session.
- On a reply card in the middle of a round, turn on **Check what's in my hands this round**. It starts with your next answer and covers the rest of that round.
- It turns itself off when the round ends, when you close the card without a wrap-up, or after a long silence. A round left without a wrap-up sends nothing, and its frames are deleted.

## What happens

1. During each hold, each frame the camera reads (about 10 a second) is also scaled into one silent MP4 on the Mac: H.264, the camera's shape inside 640×360 (480×360 for a 4:3 camera, so the bottom of the frame where hands are is not cropped), no audio track, index first (faststart). Holds follow each other in the clip; the pauses between answers are not in it. It stops at 150 frames (15 s).
2. When the round's wrap-up reply is saved, the Mac reads the clip into memory, deletes the file, and sends it once to `POST /v1/voice-rounds/{id}/replay`.
3. The server sends it inline (a base64 data URL, never the Files API) to `POST https://api.meta.ai/v1/responses` with `model: "sam-3.1"`, `stream: true`, `store: false` and `mask_encoding: one_bit`, **one request per noun phrase**: `hand`, `phone`, `paper`. The three run at once. SAM has no syntax for several concepts in one prompt.
4. Code reads only the boxes from each streamed answer (`<12f>0<|box;x1=…;y1=…;x2=…;y2=…|>`), frame by frame. A phone or paper is **in hand** on a frame where its box shares area with a hand box (touching edges do not count). Counting is per frame, never by object id: SAM reuses an id when one object leaves and another enters.
5. Frames become seconds (one frame is 0.1 s). The round gets a new version with `replay`; the clip is dropped. The wrap-up card shows one cell per second of answers, filled by the share of that second with something in hand, and the label.

**The next round.** The first answer of the next practice round (within 15 minutes) sends the counted seconds, in whole seconds, to the model playing the other person, so its first question can mention them. Code checks every number in that question against the counts: a number code did not count is never spoken; code's own line from the counts takes its place. Later answers of that round get no seconds.

The labels name counted objects and seconds only. Nothing here describes posture, confidence, attention or feelings, and the wrap-up card shows the strip instead of "faced the camera", never both.

Apple Vision could find hands on the Mac; phones and paper need SAM 3.1, so one SAM pass counts all three.

## `POST /v1/voice-rounds/{id}/replay`

Called by the Mac, never by Muse. The route exists only when the deployment sets `REPLAY_ENABLED=1`.

| | |
|---|---|
| Body | `Content-Type: video/mp4`, at most 1 MiB (the hosting adapter refuses more before buffering it, and needs a Bearer credential first) |
| Headers | `Idempotency-Key`; `X-Replay-Segments`: each answer's frames as `start-end`, end exclusive, in order, at most 8 and within 150 frames, for example `0-42,42-97` |
| The round | yours, not hidden, the round's wrap-up, created within the last 15 minutes, not checked yet (409 `not_round_end`, `round_expired` or `already_checked`) |
| Limit | 20 checks an hour, counted before any SAM call (429) |
| Fails closed | any non-200, a timeout (30 s per request), a stream without `response.completed`, a response not echoed as `store: false`, an unreadable box or a frame past the clip: 502 `replay_unavailable`, nothing saved. The card says "Hands check unavailable". |
| Retry | the same key and clip returns the saved check without calling SAM again |

The saved `replay` holds `method: "sam-3.1-boxes-v1"`, `fps`, `frames`, `seconds: { phone_in_hand, paper_in_hand }`, `per_second` (frames with each object in hand, and `in_hand` for either), `segments` (seconds per answer), the request times, `store: false` and `clip_retained: false`. No SAM response id is stored. The overview's `latest_voice_round.replay` carries the method, fps, frames and seconds.

Behind the hosting adapter the check gets the long deadline but **never the model lock**: the next hold's live round takes that lock at key-down, and a check still running must not delay it. The database is released during the SAM calls, so reads and other writes go on.

## Accuracy

- **Saved SAM output, done.** `test/replay.test.mjs` runs code's count on real SAM 3.1 answers saved on Nov 2 (box tokens only, `test/fixtures/sam`):
  - a synthetic clip (simple shapes, 100 frames, known truth for every frame): hands right on 100 of 100 frames, paper on 20 of 20, phone on 28 of 30 frames (it slides in from the top edge and is found 2 frames late, 0.2 s);
  - a clip made by panning one CC0 photo of a person texting: phone in hand 7.0 s against 7.0 s.
- **Real webcam footage, not yet measured.** Neither clip has motion blur, low light or real hands moving. The pass rule: on three 10 s webcam clips in three lighting setups, the counted phone-in-hand and paper-in-hand seconds must each be within 2 s of a hand count, with the three requests done in 15 s or less.

### The webcam check, step by step

```sh
# 1. Record a 10 s clip in QuickTime Player (File › New Movie Recording) for each lighting setup: desk lamp on, facing
#    the screen; overhead light only; a window behind or beside you. In each, glance at your phone for a few seconds and
#    hold a paper note. The clips stay on this Mac.
# 2. Count by hand, scrubbing each clip in QuickTime: the seconds a phone is in your hand, and the seconds a paper is.
# 3. Make the same clip the app would send (10 frames a second, 640×360, no audio):
cd apps/mac && swift run -c release replay-clip --video ~/Desktop/lamp.mov --out /tmp/lamp.mp4
# 4. Send it to SAM 3.1 (3 requests, MODEL_API_KEY in the environment) and score it. Exit 0 = pass.
cd ../.. && node scripts/replay-check.mjs --clip /tmp/lamp.mp4 --phone 3 --paper 2 --label lamp
```

## Cost

$0.0002 per frame per request, billed for at least 50 frames: 150 frames × 3 requests is $0.09 per check at most. 20 checks an hour at most.

## Testing without a camera (Debug builds)

- `-replayFixtureMP4 <clip.mp4>` sends that file at the end of the round instead of a clip from the camera, so the camera is never opened; `-replayArmed YES` turns the check on for every round. With `-voiceFixtureWAV`, `-voiceScript` and the local stub server, one scripted hold ends in a saved round with `replay`.
- The local stub server (`scripts/local-stub-server.mjs`) answers each SAM prompt with the saved output for `test/fixtures/sam/real_clip.mp4`, so any 100-frame clip counts phone in hand 7.0 s; `STUB_REPLAY_FAIL=1` makes the paper prompt fail, to show the unavailable state.
