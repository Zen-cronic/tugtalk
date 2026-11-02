// "Faced the camera" numbers for one voice round. The Mac measures them on the device from Apple Vision head angles
// while the talk key is held and sends only these four numbers, never a frame, as the X-Camera-Metrics header (a small
// JSON object). Code checks them strictly here; the round stores them as metrics.camera. Head direction is not gaze:
// they say "faced the camera", never eye contact.
import { ApiError } from './store.mjs';

export const CAMERA_METHOD = 'vision-face-pose-v1';
export const CAMERA_HEADER_MAX_BYTES = 512;
// Bounds the Mac clamps to as well (apps/mac/Sources/ScreenContextCore/CameraMeter.swift): a 60 s hold at 10 frames a
// second is 600 frames, so 1200 leaves room; the longest look-away cannot exceed a hold.
export const CAMERA_FIELDS = {
  faced_camera_pct: { min: 0, max: 100 },
  looked_away_count: { min: 0, max: 1200 },
  longest_look_away_ms: { min: 0, max: 120_000 },
  frames: { min: 1, max: 1200 }
};

const invalid = why => new ApiError(400, 'invalid_value', `X-Camera-Metrics ${why}`);

// value: the header string, or an already-parsed object (a live round's end message). Absent: null.
// Anything else that is not exactly the four integer fields, in bounds and consistent, is a 400; nothing is guessed.
export function parseCameraMetrics(value) {
  if (value === undefined || value === null) return null;
  let raw = value;
  if (typeof value === 'string') {
    if (Buffer.byteLength(value) > CAMERA_HEADER_MAX_BYTES) throw invalid(`must be at most ${CAMERA_HEADER_MAX_BYTES} bytes.`);
    try { raw = JSON.parse(value); } catch { throw invalid('must be a JSON object.'); }
  }
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) throw invalid('must be a JSON object.');
  const keys = Object.keys(raw), names = Object.keys(CAMERA_FIELDS);
  for (const k of keys) if (!Object.hasOwn(CAMERA_FIELDS, k)) throw invalid(`has an unsupported field: ${String(k).slice(0, 40)}.`);
  const out = {};
  for (const name of names) {
    const v = raw[name], { min, max } = CAMERA_FIELDS[name];
    if (!Number.isInteger(v)) throw invalid(`${name} must be an integer.`);
    if (v < min || v > max) throw invalid(`${name} must be from ${min} to ${max}.`);
    out[name] = v;
  }
  if (out.looked_away_count > out.frames) throw invalid('looked_away_count cannot exceed frames.');
  if ((out.looked_away_count === 0) !== (out.longest_look_away_ms === 0)) throw invalid('longest_look_away_ms must be 0 exactly when looked_away_count is 0.');
  return { ...out, method: CAMERA_METHOD };
}
