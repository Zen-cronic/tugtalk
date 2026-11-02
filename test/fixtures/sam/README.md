# SAM 3.1 fixtures for the hands check

Saved from real `sam-3.1` responses (Nov 2, 2026), with the mask payloads removed: each `.txt` file is the
streamed output text, one line per frame that had a match, box tokens only. Frames with no match send no line.

| File | Clip | Prompt | Lines |
|---|---|---|---|
| `hand.txt` | synthetic | hand | 70 |
| `phone.txt` | synthetic | phone | 28 |
| `paper.txt` | synthetic | paper | 20 |
| `real_hand.txt` | `real_clip.mp4` | hand | 70 |
| `real_phone.txt` | `real_clip.mp4` | phone | 70 |

- **Synthetic clip:** 640×360, 10 fps, 100 frames of simple shapes on a plain background, rendered on a Mac. Only its
  frame-by-frame ground truth is kept here (`synthetic-truth.json`), not the clip.
- **`real_clip.mp4`:** 640×360, 10 fps, 100 frames, H.264, no audio. Built by panning and cropping one still photo:
  [*Woman texting on a smartphone*](https://commons.wikimedia.org/wiki/File:Woman_texting_on_a_smartphone.jpg) by
  Kristin Hardwick, **CC0 1.0** (public domain dedication) on Wikimedia Commons. Hands and phone are in frame on frames
  0–39 and 70–99; frames 40–69 are a close crop of the head and shoulders. It is a still photo moved by a camera
  path, so it has no motion blur, low light or real hand movement. It is not webcam footage.

The paper prompt was not run on `real_clip.mp4`; the tests treat it as a stream with no matches.
