// Scores the hands check on one clip against a hand count: the same three SAM 3.1 requests and the same count the
// route runs (src/replay.mjs), straight from this machine. Paid: 3 SAM requests per clip, about $0.0002 a frame each.
// Needs MODEL_API_KEY in the environment; the key is never printed. The clip is sent inline with store: false.
//   node scripts/replay-check.mjs --clip <clip.mp4> --phone <hand-counted s> --paper <hand-counted s> [--label <name>] [--log <file.jsonl>]
// Make the clip with the app's own writer first: cd apps/mac && swift run -c release replay-clip --video <in.mov> --out <clip.mp4>
// Pass rule: phone in hand and paper in hand each within 2 s of the hand count, and the three requests done in 15 s.
// --log appends one line per SAM request (time, model, response id, frames, estimated cost, purpose); never the clip.
import { readFileSync, appendFileSync } from 'node:fs';
import { createReplayModel, runReplay, parseSegments, REPLAY_MAX_FRAMES, REPLAY_MAX_BYTES } from '../src/replay.mjs';

export const PASS_SECONDS = 2;
export const PASS_WALL_MS = 15_000;
export const USD_PER_FRAME = 0.0002;
export const MIN_BILLED_FRAMES = 50;

// The number of video samples in an MP4, from its stsz box (the clip has one track).
export function mp4Frames(bytes) {
  const at = bytes.indexOf(Buffer.from('stsz'));
  if (at < 4) throw new Error('No stsz box: not an MP4 from replay-clip.');
  return bytes.readUInt32BE(at + 12);
}

export function score({ seconds, wallMs }, truth) {
  const error = { phone_in_hand: Math.round((seconds.phone_in_hand - truth.phone) * 10) / 10, paper_in_hand: Math.round((seconds.paper_in_hand - truth.paper) * 10) / 10 };
  const pass = Math.abs(error.phone_in_hand) <= PASS_SECONDS && Math.abs(error.paper_in_hand) <= PASS_SECONDS && wallMs <= PASS_WALL_MS;
  return { error, pass };
}

async function main(argv) {
  const arg = name => { const i = argv.indexOf(name); return i >= 0 ? argv[i + 1] : undefined; };
  const clipPath = arg('--clip'), phone = Number(arg('--phone')), paper = Number(arg('--paper')), label = arg('--label') ?? clipPath, log = arg('--log');
  if (!clipPath || !Number.isFinite(phone) || !Number.isFinite(paper)) {
    console.error('usage: node scripts/replay-check.mjs --clip <clip.mp4> --phone <s> --paper <s> [--label <name>] [--log <file.jsonl>]');
    process.exit(2);
  }
  if (!process.env.MODEL_API_KEY) { console.error('MODEL_API_KEY is not set.'); process.exit(2); }
  const clip = readFileSync(clipPath);
  if (clip.length > REPLAY_MAX_BYTES) { console.error(`The clip is ${clip.length} bytes; the route takes at most ${REPLAY_MAX_BYTES}.`); process.exit(2); }
  const frames = mp4Frames(clip);
  if (frames < 1 || frames > REPLAY_MAX_FRAMES) { console.error(`The clip has ${frames} frames; the route takes 1–${REPLAY_MAX_FRAMES}.`); process.exit(2); }
  const model = createReplayModel({ env: { ...process.env, REPLAY_ENABLED: '1' } });
  const calls = [];
  const segment = async (dataUrl, concept, options) => { const r = await model.replaySegment(dataUrl, concept, options); calls.push({ concept, ...r, text: undefined }); return r; };
  const result = await runReplay(clip, { segments: parseSegments(`0-${frames}`), segment });
  const t = new Date().toISOString();
  if (log) for (const c of calls) {
    const billed = Math.max(MIN_BILLED_FRAMES, c.frames_processed ?? frames);
    appendFileSync(log, JSON.stringify({ t, agent: 'C', bucket: 'U2', service: 'sam', model: 'sam-3.1', request_id: c.response_id ?? null, units: { frames: billed },
      est_usd: Math.round(billed * USD_PER_FRAME * 10000) / 10000, purpose: `webcam check ${label} ${c.concept}`, ok: c.ok }) + '\n');
  }
  const out = { label, frames, bytes: clip.length, hand_count: { phone_in_hand: phone, paper_in_hand: paper }, status: result.status,
    calls: calls.map(c => ({ concept: c.concept, ok: c.ok, ms: c.ms, frames_billed: c.frames_processed ?? null, ...(c.ok ? {} : { reason: c.reason }) })), wall_ms: result.wall_ms };
  if (result.status !== 'measured') { console.log(JSON.stringify({ ...out, reason: result.reason, pass: false }, null, 1)); process.exit(1); }
  const scored = score({ seconds: result.replay.seconds, wallMs: result.wall_ms }, { phone, paper });
  console.log(JSON.stringify({ ...out, seconds: result.replay.seconds, per_second: result.replay.per_second.map(s => s.in_hand), ...scored }, null, 1));
  process.exit(scored.pass ? 0 : 1);
}

if (import.meta.url === `file://${process.argv[1]}`) await main(process.argv.slice(2));
