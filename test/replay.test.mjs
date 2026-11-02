// The hands check (src/replay.mjs): SAM 3.1's saved box output, code's per-frame count, the fail-closed rules and the
// POST /v1/voice-rounds/{id}/replay route. Fake fetch and fake models only; no network, no paid calls.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, readdirSync, rmSync, existsSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Store } from '../src/store.mjs';
import { createApp } from '../src/server.mjs';
import * as media from '../src/media.mjs';
import { samSegment, samRequestBody, parseBoxes, overlaps, inHand, countFrames, secondsFrom, parseSegments, runReplay,
  latestReplay, checkSeconds, createReplayModel, SAM_URL, SAM_MODEL, REPLAY_METHOD, REPLAY_CONCEPTS, REPLAY_MAX_BYTES,
  REPLAY_RATE_LIMIT, REPLAY_WINDOW_MS } from '../src/replay.mjs';

const fixture = name => readFileSync(new URL(`./fixtures/sam/${name}`, import.meta.url));
const text = name => fixture(name).toString('utf8');
const CLIP = fixture('real_clip.mp4');
const TRUTH = JSON.parse(text('synthetic-truth.json'));
const inRanges = (ranges, i) => ranges.some(([a, b]) => i >= a && i < b);

// A streamed SAM response, as Meta sends it: created, one delta per matched frame, completed. Chunks are cut every
// `cut` bytes so the reader must join lines across chunks.
function samStream(outputText, { frames = 100, completed = true, store = false, extra = [], cut = 97, status = 200 } = {}) {
  const lines = outputText.split('\n').filter(Boolean);
  const events = [{ type: 'response.created', response: { id: 'resp_test', store } },
    ...lines.map(delta => ({ type: 'response.output_text.delta', delta: delta + '\n' })), ...extra,
    ...(completed ? [{ type: 'response.completed', response: { id: 'resp_test', store, status: 'completed', usage: { video_frames_processed: frames } } }] : [])];
  const body = Buffer.from(events.map(e => `event: ${e.type}\ndata: ${JSON.stringify(e)}\n\n`).join(''));
  return new Response(new ReadableStream({ start(c) { for (let i = 0; i < body.length; i += cut) c.enqueue(body.subarray(i, i + cut)); c.close(); } }),
    { status, headers: { 'content-type': 'text/event-stream' } });
}
const ENV = { MODEL_API_KEY: 'test-key-not-real' };
// The fake SAM: which saved output answers each prompt, for the real clip.
const REAL = { hand: text('real_hand.txt'), phone: text('real_phone.txt'), paper: '' };
const fakeSegment = (outputs = REAL, calls = []) => async (dataUrl, concept) => {
  calls.push({ concept, bytes: dataUrl.length });
  return { ok: true, text: outputs[concept], frames_processed: 100, ms: 5 };
};

test('box parser: per frame, masks and object ids ignored, synthetic output matches the frame-by-frame truth', () => {
  const hand = parseBoxes(text('hand.txt')), phone = parseBoxes(text('phone.txt')), paper = parseBoxes(text('paper.txt'));
  // Hands: the exact number of hands in every one of the 100 frames, though id 0 is the left hand on frames 0-19
  // and the right hand again from frame 70 (an id-based count would merge or split them).
  for (let i = 0; i < TRUTH.frames; i++) {
    const want = Number(inRanges(TRUTH.visible.left_hand, i)) + Number(inRanges(TRUTH.visible.right_hand, i));
    assert.equal(hand.get(i)?.length ?? 0, want, `frame ${i}`);
  }
  assert.ok(/<0f>0<\|box/.test(text('hand.txt')) && /<7\df>0<\|box/.test(text('hand.txt')), 'the fixture really reuses id 0');
  const framesWith = map => [...map.keys()].filter(f => map.get(f).length);
  const truthFrames = ranges => Array.from({ length: TRUTH.frames }, (_, i) => i).filter(i => inRanges(ranges, i));
  assert.deepEqual(framesWith(paper), truthFrames(TRUTH.visible.paper));
  // The phone slides in from the top edge and is found 2 frames late (0.2 s), as in the feasibility run.
  const missed = truthFrames(TRUTH.visible.phone).filter(i => !phone.has(i));
  assert.deepEqual(missed, [50, 51]);
  assert.equal(framesWith(phone).filter(i => !inRanges(TRUTH.visible.phone, i)).length, 0, 'no false phone frames');
  assert.ok(!text('hand.txt').includes('mask'), 'fixtures hold box tokens only');
});

test('in hand means the boxes share area in the same frame; touching edges do not count', () => {
  const box = (x1, y1, x2, y2) => ({ x1, y1, x2, y2 });
  assert.equal(overlaps(box(0, 0, 10, 10), box(5, 5, 15, 15)), true);
  assert.equal(overlaps(box(0, 0, 10, 10), box(10, 0, 20, 10)), false, 'shared edge');
  assert.equal(overlaps(box(0, 0, 10, 10), box(0, 10, 10, 20)), false, 'shared edge');
  assert.equal(overlaps(box(0, 0, 100, 100), box(40, 40, 60, 60)), true, 'contained');
  assert.equal(overlaps(box(0, 0, 10, 10), box(11, 11, 20, 20)), false);
  assert.equal(inHand([], [box(0, 0, 10, 10)]), false);
  assert.equal(inHand([box(0, 0, 10, 10)], undefined), false, 'no hand in the frame');
  assert.equal(inHand([box(50, 50, 60, 60), box(0, 0, 10, 10)], [box(8, 8, 30, 30)]), true, 'any pair overlapping');
  // Per frame, from parsed maps: a phone with no hand in that frame is not in hand.
  const flags = countFrames({ hand: new Map([[0, [box(0, 0, 10, 10)]]]), phone: new Map([[0, [box(5, 5, 8, 8)]], [1, [box(5, 5, 8, 8)]]]), paper: new Map() }, 3);
  assert.deepEqual(flags.map(f => f.phone_in_hand), [true, false, false]);
  assert.equal(secondsFrom(28), 2.8);
  assert.equal(secondsFrom(0), 0);
});

test('the real-photo clip: phone in hand 7.0 s, paper 0 s, per second and per answer', async () => {
  const calls = [];
  const segments = parseSegments('0-40,40-70,70-100');
  const result = await runReplay(CLIP, { segments, segment: fakeSegment(REAL, calls) });
  assert.equal(result.status, 'measured');
  const r = result.replay;
  assert.deepEqual(r.seconds, { phone_in_hand: 7, paper_in_hand: 0 });
  assert.equal(r.method, REPLAY_METHOD); assert.equal(r.model, SAM_MODEL); assert.equal(r.fps, 10); assert.equal(r.frames, 100);
  assert.equal(r.store, false); assert.equal(r.clip_retained, false);
  assert.deepEqual(r.per_second.map(s => s.phone_in_hand), [10, 10, 10, 10, 0, 0, 0, 10, 10, 10]);
  assert.deepEqual(r.per_second.map(s => s.in_hand), [10, 10, 10, 10, 0, 0, 0, 10, 10, 10]);
  assert.ok(r.per_second.every(s => s.frames === 10));
  assert.deepEqual(r.segments.map(s => s.phone_in_hand), [4, 0, 3]);
  assert.deepEqual(calls.map(c => c.concept).sort(), [...REPLAY_CONCEPTS].sort(), 'one request per noun phrase');
  assert.ok(calls.every(c => c.bytes === `data:video/mp4;base64,${CLIP.toString('base64')}`.length), 'the whole clip, inline');
});

test('samSegment sends one noun phrase, inline, streamed, store false, and reads the stream across chunk cuts', async () => {
  let sent;
  const fetchImpl = async (url, init) => { sent = { url, init, body: JSON.parse(init.body) }; return samStream(text('real_phone.txt')); };
  const dataUrl = `data:video/mp4;base64,${CLIP.toString('base64')}`;
  const r = await samSegment(dataUrl, 'phone', { env: ENV, fetchImpl });
  assert.equal(r.ok, true); assert.equal(r.frames_processed, 100);
  assert.equal(parseBoxes(r.text).size, 70);
  assert.equal(sent.url, SAM_URL);
  assert.equal(sent.init.headers.Authorization, 'Bearer test-key-not-real');
  assert.deepEqual(sent.body, samRequestBody(dataUrl, 'phone'));
  assert.equal(sent.body.store, false); assert.equal(sent.body.stream, true); assert.equal(sent.body.model, 'sam-3.1');
  assert.deepEqual(sent.body.input[0].content, [{ type: 'input_text', text: 'phone' }, { type: 'input_video', video_url: dataUrl }]);
  assert.ok(!('file_id' in sent.body.input[0].content[1]), 'no Files API upload');
  assert.equal((await samSegment(dataUrl, 'hand, phone', { env: ENV, fetchImpl })).ok, false, 'never several concepts in one prompt');
  assert.equal((await samSegment(dataUrl, 'phone', { env: {}, fetchImpl })).reason, 'not configured');
});

test('samSegment fails closed: non-200, partial stream, failed or stored response, malformed event, timeout', async () => {
  const url = 'data:video/mp4;base64,AAAA', phone = text('real_phone.txt');
  const run = fetchImpl => samSegment(url, 'phone', { env: ENV, fetchImpl, timeoutMs: 80 });
  assert.equal((await run(async () => samStream(phone, { status: 429 }))).reason, 'status 429');
  assert.equal((await run(async () => samStream(phone, { completed: false }))).reason, 'partial stream');
  assert.equal((await run(async () => samStream(phone, { extra: [{ type: 'response.failed', response: {} }] }))).reason, 'response.failed');
  assert.equal((await run(async () => samStream(phone, { store: true }))).reason, 'stored response');
  assert.equal((await run(async () => new Response('data: {not json\n\n', { status: 200 }))).reason, 'stream broke');
  // A stream that stops sending is cut off by the timeout.
  const stalled = async (u, init) => new Response(new ReadableStream({ start(c) {
    c.enqueue(new TextEncoder().encode('data: {"type":"response.created"}\n\n'));
    init.signal.addEventListener('abort', () => c.error(init.signal.reason)); } }), { status: 200 });
  const t0 = performance.now();
  assert.equal((await run(stalled)).reason, 'timed out');
  assert.ok(performance.now() - t0 < 2000);
  const hanging = (u, init) => new Promise((_, reject) => init.signal.addEventListener('abort', () => reject(init.signal.reason)));
  assert.equal((await run(hanging)).reason, 'timed out');
  assert.equal((await run(async () => { throw new TypeError('fetch failed'); })).reason, 'unreachable');
});

test('runReplay keeps no numbers unless all three calls finished and every box was read', async () => {
  const segments = parseSegments('0-100');
  const one = (concept, value) => async (u, c) => c === concept ? value : { ok: true, text: REAL[c], frames_processed: 100 };
  for (const [why, segment] of [
    ['a failed call', one('paper', { ok: false, reason: 'status 500' })],
    ['a thrown call', async (u, c) => { if (c === 'hand') throw new Error('boom'); return { ok: true, text: '', frames_processed: 100 }; }],
    ['an unreadable box', one('hand', { ok: true, text: '<3f>0<|box;x1=a;y1=2;x2=3;y2=4|>', frames_processed: 100 })],
    ['a frame past the clip', one('phone', { ok: true, text: '<120f>0<|box;x1=1;y1=2;x2=3;y2=4|>', frames_processed: 100 })],
    ['fewer frames than the clip', one('hand', { ok: true, text: REAL.hand, frames_processed: 60 })]]) {
    const r = await runReplay(CLIP, { segments, segment });
    assert.equal(r.status, 'unavailable', why);
    assert.equal(r.replay, undefined, why);
  }
  // A short clip may be billed as 50 frames; more frames reported than sent is fine.
  const short = await runReplay(CLIP, { segments: parseSegments('0-30'), segment: async () => ({ ok: true, text: '', frames_processed: 50 }) });
  assert.equal(short.status, 'measured'); assert.deepEqual(short.replay.seconds, { phone_in_hand: 0, paper_in_hand: 0 });
});

test('X-Replay-Segments: in order, non-empty, at most 8 and within 150 frames', () => {
  assert.deepEqual(parseSegments('0-42,42-97'), [{ start_frame: 0, end_frame: 42 }, { start_frame: 42, end_frame: 97 }]);
  for (const bad of [undefined, '', '0-0', '5-3', '0-151', '0-10,5-20', '0-1,1-2,2-3,3-4,4-5,5-6,6-7,7-8,8-9', '0-10;10-20', '-1-4'])
    assert.throws(() => parseSegments(bad), { status: 400 }, String(bad));
});

test('checkSeconds: a number the model writes must be a measured second, or code writes the line', () => {
  const replay = { seconds: { phone_in_hand: 2.8, paper_in_hand: 0 } };
  assert.deepEqual(checkSeconds('You had your phone in hand for about 3 seconds last time. Tell me without it.', replay),
    { question: 'You had your phone in hand for about 3 seconds last time. Tell me without it.', replaced: false, reason: null });
  assert.equal(checkSeconds('About three seconds on your phone. Again, without it?', replay).replaced, false);
  const wrong = checkSeconds('You held your phone for 5 seconds. Again?', replay);
  assert.equal(wrong.replaced, true); assert.equal(wrong.reason, 'number_not_measured');
  assert.equal(wrong.question, 'Last round, your phone was in your hand for 3 s. Try this answer without it.');
  assert.equal(checkSeconds('Seven seconds of phone. Again?', replay).replaced, true);
  assert.equal(checkSeconds('Tell me again, without your phone.', replay).replaced, false, 'no number, nothing to check');
  assert.equal(checkSeconds('Vous aviez votre téléphone en main 3 secondes.', replay, 'fr').replaced, false);
  assert.match(checkSeconds('Vous aviez votre téléphone 9 secondes.', replay, 'fr').question, /pendant 3 s\./);
  assert.deepEqual(checkSeconds('Phone for 4 s.', { seconds: { phone_in_hand: 0, paper_in_hand: 0 } }), { question: null, replaced: true, reason: 'nothing_counted' });
  assert.match(checkSeconds('', { seconds: { phone_in_hand: 0, paper_in_hand: 2 } }).question, /held a paper for 2 s/);
});

test('createReplayModel: off unless REPLAY_ENABLED=1, needs the Meta key', () => {
  assert.equal(createReplayModel({ env: {} }).replayEnabled(), false);
  assert.equal(createReplayModel({ env: { REPLAY_ENABLED: 'yes' } }).replayEnabled(), false);
  assert.equal(createReplayModel({ env: { REPLAY_ENABLED: '1' } }).replayEnabled(), true);
  assert.equal(createReplayModel({ env: { REPLAY_ENABLED: '1' } }).replayReady(), false);
  assert.equal(createReplayModel({ env: { MODEL_API_KEY: 'x' } }).replayReady(), true);
});

// HTTP

function wav(seconds = 2, rate = 24000) {
  const samples = Math.round(seconds * rate), data = Buffer.alloc(samples * 2);
  for (let i = 0; i < samples; i++) data.writeInt16LE(Math.round(Math.sin(i / 9) * 2500 + (i % 17) * 7), i * 2);
  const h = Buffer.alloc(44);
  h.write('RIFF', 0); h.writeUInt32LE(36 + data.length, 4); h.write('WAVE', 8); h.write('fmt ', 12); h.writeUInt32LE(16, 16);
  h.writeUInt16LE(1, 20); h.writeUInt16LE(1, 22); h.writeUInt32LE(rate, 24); h.writeUInt32LE(rate * 2, 28); h.writeUInt16LE(2, 32); h.writeUInt16LE(16, 34);
  h.write('data', 36); h.writeUInt32LE(data.length, 40);
  return Buffer.concat([h, data]);
}

function models({ enabled = true, move = 'wrap_up', segment } = {}) {
  const calls = { segment: [], voiceReply: 0, phases: [] };
  return { calls, models: {
    async transcribe() { return { transcript: 'Um, I think we ship the smaller version first.', turns: [{ turn_id: 0, start_ms: 300, end_ms: 2600 }], audio_duration_ms: 3000, model: 'muse-voice-transcribe-1.0', provider_session_id: 'asr-1' }; },
    async voiceReply() { calls.voiceReply++; return { status: 'model_reply', reply: { move: calls.move ?? move, quote: '', question: 'Thanks. What is the one thing to remember?' }, model: 'meta-models/muse-spark-open-1026', provider_request_id: 'req', attempts: 1 }; },
    replayEnabled: () => enabled, replayReady: () => true,
    replaySegment: segment ?? (async (dataUrl, concept) => { calls.segment.push(concept); calls.phases.push(`segment-${concept}`); return { ok: true, text: REAL[concept], frames_processed: 100 }; })
  } };
}

async function withServer(fake, fn, phases) {
  const dir = mkdtempSync(join(tmpdir(), 'replay-test-'));
  const store = new Store(join(dir, 'replay.sqlite'));
  store.addToken('alice-secret', 'alice'); store.seed('alice');
  store.addToken('bob-secret', 'bob');
  const server = createApp(store, { models: fake.models, ...(phases ? { phases } : {}) });
  await new Promise(r => server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${server.address().port}`;
  try { await fn({ base, store, dir }); }
  finally { await new Promise(r => server.close(r)); store.close(); rmSync(dir, { recursive: true, force: true }); }
}

let seq = 0;
async function round(base, token = 'alice-secret') {
  const r = await fetch(base + '/v1/voice-rounds', { method: 'POST', body: wav(),
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'audio/wav', 'Idempotency-Key': `replay-round-${++seq}` } });
  assert.equal(r.status, 200);
  return (await r.json()).round_id;
}
function send(base, id, { body = CLIP, key = `replay-key-${++seq}`, segments = '0-40,40-70,70-100', type = 'video/mp4', token = 'alice-secret' } = {}) {
  const headers = { 'Content-Type': type };
  if (token) headers.Authorization = `Bearer ${token}`;
  if (key) headers['Idempotency-Key'] = key;
  if (segments) headers['X-Replay-Segments'] = segments;
  return fetch(`${base}/v1/voice-rounds/${id}/replay`, { method: 'POST', body, headers });
}

test('route: off by default (404), and every refusal comes before any SAM call', async () => {
  const off = models({ enabled: false });
  await withServer(off, async ({ base }) => {
    const id = await round(base);
    assert.equal((await send(base, id)).status, 404);
    assert.equal(off.calls.segment.length, 0);
  });
  const on = models();
  await withServer(on, async ({ base, store }) => {
    const id = await round(base);
    assert.equal((await send(base, id, { token: null })).status, 401);
    assert.equal((await send(base, id, { key: null })).status, 400);
    assert.equal((await send(base, id, { segments: null })).status, 400);
    assert.equal((await send(base, id, { segments: '0-200' })).status, 400);
    assert.equal((await send(base, id, { type: 'application/json' })).status, 415);
    assert.equal((await send(base, id, { body: Buffer.alloc(REPLAY_MAX_BYTES + 1) })).status, 413);
    assert.equal((await send(base, id, { body: Buffer.from('not a video at all') })).status, 415);
    assert.equal((await send(base, 'no-such-round')).status, 404);
    assert.equal((await send(base, id, { token: 'bob-secret' })).status, 404, "another person's round");
    on.calls.move = 'follow_up';
    const middle = await round(base);
    const r = await send(base, middle);
    assert.equal(r.status, 409); assert.equal((await r.json()).error, 'not_round_end');
    on.calls.move = undefined;
    const old = store.get('alice', 'voice-rounds', id);
    store.put('alice', 'voice-rounds', { ...old, created_at: new Date(Date.now() - REPLAY_WINDOW_MS - 1000).toISOString() });
    const late = await send(base, id);
    assert.equal(late.status, 409); assert.equal((await late.json()).error, 'round_expired');
    store.put('alice', 'voice-rounds', { ...old, deleted: true });
    assert.equal((await send(base, id)).status, 404, 'a hidden round');
    assert.equal(on.calls.segment.length, 0, 'no SAM call for any refused request');
  });
});

test('route: saves only the seconds on the round, once; a retry replays it; the overview carries them', async () => {
  const fake = models();
  const order = [];
  const phases = { async release() { order.push('release'); }, async acquire() { order.push('acquire'); } };
  await withServer(fake, async ({ base, store }) => {
    const id = await round(base);
    order.length = 0;
    const key = 'replay-once-1';
    const first = await send(base, id, { key });
    assert.equal(first.status, 200);
    const body = await first.json();
    assert.equal(body.round_id, id); assert.equal(body.record_version, 2); assert.equal(body.replayed, false);
    assert.deepEqual(body.replay.seconds, { phone_in_hand: 7, paper_in_hand: 0 });
    assert.equal(body.replay.store, false); assert.equal(body.replay.clip_retained, false);
    assert.deepEqual(order, ['release', 'acquire'], 'the database is released during the SAM calls');
    assert.equal(fake.calls.segment.length, 3);
    const again = await (await send(base, id, { key })).json();
    assert.equal(again.replayed, true); assert.equal(again.receipt_id, body.receipt_id);
    assert.equal(fake.calls.segment.length, 3, 'an exact retry does not call SAM again');
    const second = await send(base, id);
    assert.equal(second.status, 409); assert.equal((await second.json()).error, 'already_checked');
    const saved = store.get('alice', 'voice-rounds', id);
    assert.equal(saved.version, 2); assert.equal(saved.transcript, 'Um, I think we ship the smaller version first.');
    assert.equal(JSON.stringify(saved).includes('resp_'), false, 'no SAM response ids are stored');
    const overview = await (await fetch(base + '/v1/overview', { headers: { Authorization: 'Bearer alice-secret' } })).json();
    assert.deepEqual(overview.latest_voice_round.replay, { method: REPLAY_METHOD, fps: 10, frames: 100, seconds: { phone_in_hand: 7, paper_in_hand: 0 } });
    assert.deepEqual(latestReplay(store, 'alice', new Date(Date.now() - 60_000).toISOString()).seconds, { phone_in_hand: 7, paper_in_hand: 0 });
    assert.equal(latestReplay(store, 'alice', new Date(Date.now() + 60_000).toISOString()), null);
  }, phases);
});

test('route: a clip of exactly 1 MiB is accepted; one byte more is refused (413)', async () => {
  const fake = models();
  await withServer(fake, async ({ base }) => {
    const limit = Buffer.alloc(REPLAY_MAX_BYTES); CLIP.copy(limit, 0, 0, 64);
    const over = Buffer.alloc(REPLAY_MAX_BYTES + 1); CLIP.copy(over, 0, 0, 64);
    const id = await round(base);
    assert.equal((await send(base, id, { body: over })).status, 413);
    assert.equal((await send(base, id, { body: limit })).status, 200);
  });
});

test('route: SAM failing saves nothing and says the check is unavailable (502)', async () => {
  const fake = models({ segment: async (u, c) => c === 'paper' ? { ok: false, reason: 'timed out' } : { ok: true, text: REAL[c], frames_processed: 100 } });
  await withServer(fake, async ({ base, store }) => {
    const id = await round(base);
    const r = await send(base, id);
    assert.equal(r.status, 502);
    const body = await r.json();
    assert.equal(body.error, 'replay_unavailable'); assert.match(body.message, /^Hands check unavailable: paper: timed out\.$/);
    assert.equal(store.get('alice', 'voice-rounds', id).replay, undefined);
    assert.equal(store.get('alice', 'voice-rounds', id).version, 1);
  });
});

test('route: never keeps the clip, even with Keep my recordings on (no attachMedia, no file, no bytes in the database)', async () => {
  const fake = models();
  const calls = [];
  // attachMedia is an ES module export, so it cannot be spied on; instead check every place it would write.
  assert.ok(typeof media.attachMedia === 'function');
  await withServer(fake, async ({ base, store, dir }) => {
    const auth = { Authorization: 'Bearer alice-secret', 'Content-Type': 'application/json' };
    const settings = await (await fetch(base + '/v1/settings', { headers: auth })).json();
    const on = await fetch(base + '/v1/settings', { method: 'PATCH', headers: { ...auth, 'Idempotency-Key': 'keep-on-replay' },
      body: JSON.stringify({ expected_version: settings.settings.version, keep_recordings: true }) });
    assert.equal(on.status, 200);
    const id = await round(base);
    const kept = store.get('alice', 'voice-rounds', id).media;
    assert.equal(kept?.kept, true, 'the answer audio is kept, as Keep my recordings says');
    assert.equal((await send(base, id)).status, 200);
    const saved = store.get('alice', 'voice-rounds', id);
    assert.deepEqual(saved.media, kept, 'the round keeps its audio media only; no video was attached');
    const files = [];
    const walk = d => { for (const f of readdirSync(d)) { const p = join(d, f); if (statSync(p).isDirectory()) walk(p); else files.push(p); } };
    walk(dir);
    assert.equal(files.filter(f => f.endsWith('.mp4')).length, 0, 'no clip file anywhere next to the database');
    const db = Buffer.concat(files.filter(f => /replay\.sqlite/.test(f)).map(f => readFileSync(f)));
    assert.equal(db.includes(CLIP.subarray(2000, 2064)), false, 'no clip bytes in the database');
    assert.equal(db.includes(Buffer.from(CLIP.subarray(2000, 2064).toString('base64').slice(4, 60))), false, 'nor the clip as base64');
    const settingsAfter = await (await fetch(base + '/v1/settings', { headers: auth })).json();
    assert.equal(settingsAfter.settings.kept.recordings, 1, 'only the answer audio is counted as kept');
    calls.push('done');
  });
  assert.deepEqual(calls, ['done']);
  assert.doesNotMatch(readFileSync(new URL('../src/replay.mjs', import.meta.url), 'utf8').replace(/^\s*\/\/.*$/gm, ''), /attachMedia|writeFile|createWriteStream|\/v1\/files/,
    'src/replay.mjs has no path that writes the clip anywhere');
});

test('route: at most 20 hands checks an hour, counted before any SAM call', async () => {
  const fake = models();
  await withServer(fake, async ({ base, store }) => {
    const id = await round(base);
    const template = store.get('alice', 'voice-rounds', id);
    for (let i = 0; i < REPLAY_RATE_LIMIT.requests; i++) {
      const rid = `rate-round-${i}`;
      store.put('alice', 'voice-rounds', { ...template, id: rid });
      assert.equal((await send(base, rid)).status, 200, `check ${i + 1}`);
    }
    const before = fake.calls.segment.length;
    const r = await send(base, id);
    assert.equal(r.status, 429);
    assert.equal(fake.calls.segment.length, before);
  });
});

test('fixtures: the clip is CC0 with its credit, and the synthetic truth matches its description', () => {
  const readme = text('README.md');
  assert.match(readme, /Kristin Hardwick/); assert.match(readme, /CC0 1\.0/);
  assert.equal(CLIP.subarray(4, 8).toString('latin1'), 'ftyp');
  assert.ok(CLIP.length < REPLAY_MAX_BYTES);
  assert.equal(TRUTH.frames, 100); assert.equal(TRUTH.fps, 10);
  assert.ok(existsSync(new URL('./fixtures/sam/real_phone.txt', import.meta.url)));
});
