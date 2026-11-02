// Hands check: at the end of a spoken practice round, the Mac can send one silent clip of that round's answers
// (only when the person turned the check on for that round). Meta's SAM 3.1 finds boxes for three noun phrases,
// "hand", "phone" and "paper", one request each; code then counts, frame by frame, the frames where a phone or a
// paper box overlaps a hand box, and turns the counts into seconds. Only those seconds are kept.
//
// - The clip is sent inline (a data URL) with store: false, so Meta keeps no stored response, and no file is
//   uploaded. It stays in this process's memory: never written to disk, never kept as media, even with Keep my
//   recordings on (attachMedia is never called here).
// - Counts are per frame, never by object id: SAM reuses an id when an object leaves the frame and another enters.
// - It fails closed: any non-200, timeout, partial stream, missing response.completed, unreadable box or frame
//   index outside the clip means no numbers at all, never a partial count.
// - The route runs at round end only, never during a hold; behind the hosting adapter it does not take the model
//   lock, so it never delays the next hold's live round (deploy/bridge.py).
import { ApiError, digest } from './store.mjs';
import { createBudget } from './budget.mjs';

export const REPLAY_PATH = /^\/v1\/voice-rounds\/([A-Za-z0-9-]{1,64})\/replay$/;
export const REPLAY_PATH_PATTERN = '/v1/voice-rounds/%/replay';
export const REPLAY_METHOD = 'sam-3.1-boxes-v1';
export const SAM_MODEL = 'sam-3.1';
export const SAM_URL = 'https://api.meta.ai/v1/responses';
// One short noun phrase per request: SAM has no syntax for several concepts in one prompt.
export const REPLAY_CONCEPTS = ['hand', 'phone', 'paper'];
// The objects that can be "in hand", and the names their seconds are stored under.
export const IN_HAND = { phone: 'phone_in_hand', paper: 'paper_in_hand' };
export const REPLAY_FPS = 10;
export const REPLAY_MAX_FRAMES = 150; // 15 s at 10 frames a second
export const REPLAY_MAX_BYTES = 1024 * 1024; // matches VIDEO_LIMIT in deploy/bridge.py
export const REPLAY_MAX_SEGMENTS = 8;
export const REPLAY_TIMEOUT_MS = 30_000;
// The round's last answer must be this recent; the check belongs to the round that just ended.
export const REPLAY_WINDOW_MS = 15 * 60 * 1000;
export const REPLAY_RATE_LIMIT = { requests: 20, windowMs: 60 * 60 * 1000 };
// The least time worth starting the three calls with.
export const REPLAY_MIN_START_MS = 15_000;
export const REPLAY_UNAVAILABLE = 'Hands check unavailable';

// The hosted route exists only with REPLAY_ENABLED=1; it needs the same Meta key as transcription.
// segment(dataUrl, concept, { budget }) is one SAM request; it never throws.
export function createReplayModel({ env = process.env, fetchImpl = fetch } = {}) {
  return {
    replayEnabled: () => env.REPLAY_ENABLED === '1',
    replayReady: () => Boolean(env.MODEL_API_KEY),
    replaySegment: (dataUrl, concept, options = {}) => samSegment(dataUrl, concept, { env, fetchImpl, ...options })
  };
}

// The SAM request body for one concept. Exported so tests check exactly what leaves the server.
export function samRequestBody(dataUrl, concept) {
  return { model: SAM_MODEL,
    input: [{ type: 'message', role: 'user', content: [{ type: 'input_text', text: concept }, { type: 'input_video', video_url: dataUrl }] }],
    stream: true, store: false, metadata: { mask_encoding: 'one_bit' } };
}

// Server-sent events: the JSON payload of each "data:" line, until [DONE] or the end of the body.
async function* sseEvents(body) {
  const decoder = new TextDecoder();
  let buffer = '';
  for await (const chunk of body) {
    buffer += decoder.decode(chunk, { stream: true });
    let cut;
    while ((cut = buffer.search(/\r?\n/)) >= 0) {
      const line = buffer.slice(0, cut); buffer = buffer.slice(cut + (buffer[cut] === '\r' ? 2 : 1));
      if (!line.startsWith('data:')) continue;
      const data = line.slice(5).trim();
      if (data === '[DONE]') return;
      if (!data) continue;
      let event;
      try { event = JSON.parse(data); } catch { throw new Error('malformed event'); }
      yield event;
    }
  }
}

// One SAM 3.1 request: streamed, store: false, one noun phrase. Returns { ok: true, text, frames_processed, ms }
// with the concatenated output text, or { ok: false, reason }. Never throws, never logs the clip or the key.
export async function samSegment(dataUrl, concept, { env = process.env, fetchImpl = fetch, timeoutMs = REPLAY_TIMEOUT_MS, budget } = {}) {
  const started = performance.now();
  const fail = reason => ({ ok: false, reason, ms: Math.round(performance.now() - started) });
  if (!REPLAY_CONCEPTS.includes(concept)) return fail('unknown concept');
  if (!env.MODEL_API_KEY) return fail('not configured');
  const send = budget ? budget.fetch(fetchImpl, { step: 'replay' }) : fetchImpl;
  let response;
  try {
    response = await send(SAM_URL, { method: 'POST', signal: AbortSignal.timeout(timeoutMs),
      headers: { Authorization: `Bearer ${env.MODEL_API_KEY}`, 'Content-Type': 'application/json', Accept: 'text/event-stream' },
      body: JSON.stringify(samRequestBody(dataUrl, concept)) });
  } catch (error) {
    return fail(error?.name === 'TimeoutError' || error?.name === 'AbortError' ? 'timed out' : 'unreachable');
  }
  if (response.status !== 200 || !response.body) {
    try { await response.body?.cancel(); } catch {}
    return fail(`status ${response.status}`);
  }
  const deltas = [];
  let completed = null;
  try {
    for await (const event of sseEvents(response.body)) {
      if (event.type === 'response.output_text.delta' && typeof event.delta === 'string') deltas.push(event.delta);
      else if (event.type === 'response.completed') { completed = event.response ?? {}; break; }
      else if (event.type === 'response.failed' || event.type === 'response.incomplete' || event.type === 'error') return fail(event.type);
    }
  } catch (error) {
    return fail(error?.name === 'TimeoutError' || error?.name === 'AbortError' ? 'timed out' : 'stream broke');
  }
  if (!completed) return fail('partial stream');
  // The request said store: false; a response that says otherwise is not used.
  if (completed.store !== undefined && completed.store !== false) return fail('stored response');
  const frames = completed.usage?.video_frames_processed;
  // The response id is returned for a caller's own call log only; runReplay never saves it.
  return { ok: true, text: deltas.join(''), frames_processed: Number.isInteger(frames) ? frames : null, response_id: typeof completed.id === 'string' ? completed.id : null,
    ms: Math.round(performance.now() - started) };
}

// Boxes per frame from SAM's output text, masks ignored: "<12f>0<|box;x1=..;y1=..;x2=..;y2=..;w=..;h=..;c=..|>...".
// Returns Map(frame index -> [{x1, y1, x2, y2}]). Object ids are dropped on purpose. Throws on an unreadable box.
const FRAME = /<(\d+)f>/g;
const BOX = /<\|box;([^|]*)\|>/g;
export function parseBoxes(text) {
  const frames = new Map();
  const marks = [...String(text).matchAll(FRAME)];
  marks.forEach((mark, i) => {
    const frame = Number(mark[1]);
    const body = text.slice(mark.index + mark[0].length, i + 1 < marks.length ? marks[i + 1].index : text.length);
    const boxes = frames.get(frame) ?? [];
    for (const [, fields] of body.matchAll(BOX)) {
      const kv = Object.fromEntries(fields.split(';').map(p => p.split('=')));
      const box = { x1: Number(kv.x1), y1: Number(kv.y1), x2: Number(kv.x2), y2: Number(kv.y2) };
      if (!Object.values(box).every(Number.isFinite) || box.x2 < box.x1 || box.y2 < box.y1) throw new Error(`unreadable box in frame ${frame}`);
      boxes.push(box);
    }
    frames.set(frame, boxes);
  });
  return frames;
}

// "In hand": an object box and a hand box share some area in the same frame. Touching edges do not count.
export function overlaps(a, b) {
  return Math.min(a.x2, b.x2) > Math.max(a.x1, b.x1) && Math.min(a.y2, b.y2) > Math.max(a.y1, b.y1);
}
export function inHand(objectBoxes = [], handBoxes = []) {
  return objectBoxes.some(o => handBoxes.some(h => overlaps(o, h)));
}

// Per frame: whether each object was in hand. byConcept holds parseBoxes() maps for hand, phone and paper.
export function countFrames(byConcept, frames) {
  const hands = byConcept.hand ?? new Map();
  return Array.from({ length: frames }, (_, i) => Object.fromEntries(Object.entries(IN_HAND)
    .map(([object, name]) => [name, inHand(byConcept[object]?.get(i), hands.get(i))])));
}

// Frames to seconds, to one decimal (one frame is 0.1 s at 10 frames a second).
export const secondsFrom = (count, fps = REPLAY_FPS) => Math.round((count / fps) * 10) / 10;

// X-Replay-Segments: each answer's frames in the clip, "start-end" with end exclusive, in order, for example "0-42,42-97".
export function parseSegments(header) {
  if (typeof header !== 'string' || !/^\d{1,3}-\d{1,3}(?:,\d{1,3}-\d{1,3}){0,7}$/.test(header))
    throw new ApiError(400, 'invalid_value', `X-Replay-Segments must list each answer's frames as start-end, for example 0-42,42-97 (at most ${REPLAY_MAX_SEGMENTS}).`);
  const segments = header.split(',').map(s => s.split('-').map(Number));
  let previous = 0;
  for (const [start, end] of segments) {
    if (start < previous || end <= start || end > REPLAY_MAX_FRAMES)
      throw new ApiError(400, 'invalid_value', `X-Replay-Segments must be in order, non-empty and within ${REPLAY_MAX_FRAMES} frames.`);
    previous = end;
  }
  return segments.map(([start, end]) => ({ start_frame: start, end_frame: end }));
}

const sum = (list, name) => list.reduce((n, f) => n + (f[name] ? 1 : 0), 0);

// The numbers code keeps, from the per-frame flags.
export function summarize(perFrame, segments, fps = REPLAY_FPS) {
  const frames = perFrame.length;
  const names = Object.values(IN_HAND);
  const per = slice => Object.fromEntries(names.map(n => [n, sum(slice, n)]));
  const seconds = Object.fromEntries(names.map(n => [n, secondsFrom(sum(perFrame, n), fps)]));
  const perSecond = [];
  // in_hand: frames in that second with a phone or a paper in hand (either), for the strip's cells.
  for (let s = 0; s * fps < frames; s++) {
    const slice = perFrame.slice(s * fps, (s + 1) * fps);
    perSecond.push({ frames: slice.length, ...per(slice), in_hand: slice.filter(f => names.some(n => f[n])).length });
  }
  return { seconds, per_second: perSecond,
    segments: segments.map((g, i) => ({ answer: i + 1, ...g, ...Object.fromEntries(names.map(n => [n, secondsFrom(sum(perFrame.slice(g.start_frame, g.end_frame), n), fps)])) })) };
}

// The three SAM calls, in parallel, then code's count. Returns { status: 'measured', replay } or
// { status: 'unavailable', reason }: no numbers unless every call finished and every box was read.
export async function runReplay(mp4, { segments, segment, budget, fps = REPLAY_FPS }) {
  const frames = segments.at(-1).end_frame;
  const dataUrl = `data:video/mp4;base64,${Buffer.from(mp4).toString('base64')}`;
  const started = performance.now();
  let results;
  try {
    results = await Promise.all(REPLAY_CONCEPTS.map(concept => Promise.resolve(segment(dataUrl, concept, { budget }))
      .catch(() => ({ ok: false, reason: 'failed' }))));
  } catch { results = [{ ok: false, reason: 'failed' }]; }
  const wallMs = Math.round(performance.now() - started);
  const failed = results.findIndex(r => !r?.ok);
  if (failed >= 0) return { status: 'unavailable', reason: `${REPLAY_CONCEPTS[failed] ?? 'a concept'}: ${results[failed]?.reason ?? 'failed'}`, wall_ms: wallMs };
  // SAM bills at least 50 frames, so it may report more frames than the clip has, never fewer.
  if (results.some(r => r.frames_processed !== null && r.frames_processed < frames)) return { status: 'unavailable', reason: 'SAM saw fewer frames than the clip has', wall_ms: wallMs };
  const byConcept = {};
  try {
    REPLAY_CONCEPTS.forEach((concept, i) => { byConcept[concept] = parseBoxes(results[i].text); });
  } catch (error) { return { status: 'unavailable', reason: error.message, wall_ms: wallMs }; }
  if (Object.values(byConcept).some(map => [...map.keys()].some(f => f >= frames))) return { status: 'unavailable', reason: 'a frame index is outside the clip', wall_ms: wallMs };
  const counted = summarize(countFrames(byConcept, frames), segments, fps);
  return { status: 'measured', wall_ms: wallMs,
    replay: { method: REPLAY_METHOD, model: SAM_MODEL, concepts: REPLAY_CONCEPTS, fps, frames, ...counted,
      sam_ms: Object.fromEntries(REPLAY_CONCEPTS.map((c, i) => [c, results[i].ms ?? null])), wall_ms: wallMs,
      store: false, clip_retained: false } };
}

// An MP4 starts with an ftyp box. Anything else is refused before any paid call.
export const looksLikeMp4 = bytes => bytes.length >= 12 && bytes.subarray(4, 8).toString('latin1') === 'ftyp';

async function videoOf(req) {
  const type = (req.headers['content-type'] ?? '').split(';')[0].trim();
  if (type !== 'video/mp4') throw new ApiError(415, 'content_type', 'Use video/mp4.');
  let bytes = 0; const chunks = [];
  for await (const chunk of req) {
    bytes += chunk.length;
    if (bytes > REPLAY_MAX_BYTES) throw new ApiError(413, 'too_large', 'Maximum replay clip is 1 MiB.');
    chunks.push(chunk);
  }
  return Buffer.concat(chunks);
}

const NO_PHASES = { async release() {}, async acquire() {} };

// The round a replay belongs to: owned, not hidden, the round's last answer (a wrap-up), recent, not yet checked.
function checkRound(store, user, roundId, now = Date.now()) {
  const round = store.get(user, 'voice-rounds', roundId);
  if (round.deleted) throw new ApiError(404, 'not_found', 'Record not found.');
  if (round.reply?.move !== 'wrap_up') throw new ApiError(409, 'not_round_end', 'A hands check runs only at the end of a round (a wrap-up reply).');
  if (now - Date.parse(round.created_at) > REPLAY_WINDOW_MS) throw new ApiError(409, 'round_expired', 'A hands check must be sent within 15 minutes of the round.');
  if (round.replay) throw new ApiError(409, 'already_checked', 'This round already has a hands check.');
  return round;
}

// POST /v1/voice-rounds/{id}/replay. Headers: Content-Type video/mp4, Idempotency-Key, X-Replay-Segments.
// Returns { round_id, receipt_id, replayed, record_version, replay }.
export async function handleReplay(store, models, user, roundId, req, key, requestId, phases = NO_PHASES, budget = createBudget()) {
  const path = `/v1/voice-rounds/${roundId}/replay`;
  const segments = parseSegments(req.headers['x-replay-segments']);
  const video = await videoOf(req);
  const fingerprintBody = { round_id: roundId, video_sha256: digest(video), segments };
  const respond = receipt => ({ round_id: receipt.record.id, receipt_id: receipt.receipt_id, replayed: receipt.replayed, record_version: receipt.record_version, replay: receipt.record.replay });
  // An exact retry returns the saved check without calling SAM again.
  const previous = store.replay(user, 'POST', path, fingerprintBody, key);
  if (previous) return respond(previous);
  if (store.recentRequestsMatching(user, 'POST', REPLAY_PATH_PATTERN, [200, 502], REPLAY_RATE_LIMIT.windowMs) >= REPLAY_RATE_LIMIT.requests)
    throw new ApiError(429, 'rate_limited', `At most ${REPLAY_RATE_LIMIT.requests} hands checks per hour.`);
  checkRound(store, user, roundId);
  if (typeof models.replaySegment !== 'function' || (models.replayReady && !models.replayReady()))
    throw new ApiError(503, 'replay_unconfigured', 'The hands check is not configured on this deployment.');
  if (!looksLikeMp4(video)) throw new ApiError(415, 'content_type', 'The clip is not an MP4 file.');
  if (!budget.allows(REPLAY_MIN_START_MS)) throw new ApiError(503, 'time_budget', 'Not enough time left for the hands check; retry with the same Idempotency-Key.');
  let result;
  // The SAM calls take seconds; the database is released meanwhile, and everything is re-checked inside the write.
  await phases.release();
  try {
    result = await runReplay(video, { segments, segment: models.replaySegment, budget });
  } finally {
    await phases.acquire();
  }
  // Nothing is saved without numbers; the clip is dropped either way.
  if (result.status !== 'measured') throw new ApiError(502, 'replay_unavailable', `${REPLAY_UNAVAILABLE}: ${result.reason}.`);
  return respond(store.mutate(user, 'POST', path, fingerprintBody, key, () => {
    const round = checkRound(store, user, roundId);
    const timestamp = new Date().toISOString();
    const record = { ...round, replay: { ...result.replay, checked_at: timestamp }, version: round.version + 1, updated_at: timestamp };
    store.put(user, 'voice-rounds', record);
    return record;
  }));
}

// The newest hands check on a round created since `since` (ISO), for the next round's first reply (prepareVoiceRound,
// src/voice.mjs, passes the wrap-up that ended the last round, so only that round's check is found).
export function latestReplay(store, user, since) {
  const rounds = store.list(user, 'voice-rounds').filter(r => !r.deleted && r.replay && (!since || r.created_at >= since))
    .sort((a, b) => b.created_at.localeCompare(a.created_at) || b.id.localeCompare(a.id));
  const r = rounds[0];
  return r ? { round_id: r.id, created_at: r.created_at, method: r.replay.method, seconds: r.replay.seconds } : null;
}

// Spoken numerals the next reply may use for seconds, so "three seconds" is checked like "3 s".
const NUMBER_WORDS = {
  en: ['zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'ten', 'eleven', 'twelve', 'thirteen', 'fourteen', 'fifteen'],
  fr: ['zéro', 'un', 'deux', 'trois', 'quatre', 'cinq', 'six', 'sept', 'huit', 'neuf', 'dix', 'onze', 'douze', 'treize', 'quatorze', 'quinze']
};
const CODE_LINE = {
  en: { phone_in_hand: s => `Last round, your phone was in your hand for ${s} s. Try this answer without it.`,
    paper_in_hand: s => `Last round, you held a paper for ${s} s. Try this answer without it.` },
  fr: { phone_in_hand: s => `Au dernier tour, votre téléphone était dans votre main pendant ${s} s. Essayez cette réponse sans lui.`,
    paper_in_hand: s => `Au dernier tour, vous teniez une feuille pendant ${s} s. Essayez cette réponse sans elle.` }
};

// Code's check of a model-written line that mentions the last hands check: every number in it must be one of the
// measured seconds, rounded to a whole second. Otherwise the line is replaced by one code writes from the numbers.
// Returns { question, replaced, reason }; question is null when nothing was counted (the caller keeps its own line).
export function checkSeconds(question, replay, language = 'en') {
  const lang = Object.hasOwn(NUMBER_WORDS, language) ? language : 'en';
  const seconds = replay?.seconds ?? {};
  const counted = Object.entries(IN_HAND).map(([, name]) => [name, Math.round(seconds[name] ?? 0)]).filter(([, s]) => s > 0);
  const allowed = new Set(counted.map(([, s]) => s));
  const text = String(question ?? '');
  const digits = [...text.matchAll(/\d+(?:[.,]\d+)?/g)].map(m => Number(m[0].replace(',', '.')));
  const words = [...text.toLowerCase().matchAll(/\p{L}+/gu)].map(m => NUMBER_WORDS[lang].indexOf(m[0])).filter(n => n >= 0
    && !(lang === 'en' && n === 1) && !(lang === 'fr' && n === 1)); // "one"/"un" are also ordinary words
  const numbers = [...digits, ...words];
  if (numbers.length && numbers.every(n => allowed.has(n))) return { question: text, replaced: false, reason: null };
  if (!numbers.length && text.trim()) return { question: text, replaced: false, reason: null };
  if (!counted.length) return { question: null, replaced: true, reason: 'nothing_counted' };
  const [name, s] = counted.sort((a, b) => b[1] - a[1])[0];
  return { question: CODE_LINE[lang][name](s), replaced: true, reason: numbers.length ? 'number_not_measured' : 'empty' };
}
