// Speech prefetch: synthesis starts when a voice round's checked reply exists, and the speech route serves the
// audio from memory. Fake models and a fake speech provider; no network, no paid calls.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Store } from '../src/store.mjs';
import { createApp } from '../src/server.mjs';
import { createSpeechModel, createSpeechCache } from '../src/speech.mjs';

const ANSWER = 'So, um, I think we could maybe lead the launch.';
const QUESTION = 'You said "maybe". Why should it be you?';
const CHUNKS = [Buffer.from('ID3-first-'), Buffer.alloc(3000, 5), Buffer.from('-last')];

function wav(seconds = 2, rate = 24000) {
  const data = Buffer.alloc(Math.round(seconds * rate) * 2);
  for (let i = 0; i < data.length / 2; i++) data.writeInt16LE(Math.round(Math.sin(i / 9) * 2500), i * 2);
  const h = Buffer.alloc(44);
  h.write('RIFF', 0); h.writeUInt32LE(36 + data.length, 4); h.write('WAVE', 8); h.write('fmt ', 12); h.writeUInt32LE(16, 16);
  h.writeUInt16LE(1, 20); h.writeUInt16LE(1, 22); h.writeUInt32LE(rate, 24); h.writeUInt32LE(rate * 2, 28); h.writeUInt16LE(2, 32); h.writeUInt16LE(16, 34);
  h.write('data', 36); h.writeUInt32LE(data.length, 40);
  return Buffer.concat([h, data]);
}

// A speech provider whose stream is released chunk by chunk by the test (gate), so timing is deterministic.
function gatedProvider({ status = 200 } = {}) {
  const calls = [];
  let open = [];
  const release = () => { const o = open; open = []; o.forEach(r => r()); };
  const fetchImpl = async (url, init) => {
    calls.push(JSON.parse(init.body).q);
    if (status !== 200) return new Response('nope', { status });
    const body = new ReadableStream({ async start(c) {
      for (const chunk of CHUNKS) { await new Promise(r => open.push(r)); c.enqueue(chunk); }
      c.close();
    } });
    return new Response(body, { status: 200, headers: { 'content-type': 'audio/mpeg' } });
  };
  return { calls, fetchImpl, release };
}

async function withServer(speech, fn) {
  const dir = mkdtempSync(join(tmpdir(), 'prefetch-test-'));
  const store = new Store(join(dir, 'p.sqlite'));
  store.addToken('alice-secret', 'alice'); store.addToken('bob-secret', 'bob');
  const order = [];
  const models = {
    async transcribe() { return { transcript: ANSWER, turns: [{ turn_id: 0, start_ms: 300, end_ms: 1800 }], audio_duration_ms: 2000, model: 'muse-voice-transcribe-1.0', provider_session_id: 's' }; },
    async voiceReply() { return { status: 'model_reply', reply: { move: 'challenge', quote: 'maybe lead the launch', question: QUESTION }, model: 'meta-models/muse-spark-open-1026', provider_request_id: 'r', attempts: 1 }; },
    ...speech,
    prefetchSpeech(...args) { order.push(['prefetch', store.list(args[1], 'voice-rounds').length]); return speech.prefetchSpeech(...args); }
  };
  const server = createApp(store, { models }); await new Promise(r => server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${server.address().port}`;
  const round = async () => (await fetch(base + '/v1/voice-rounds', { method: 'POST', headers: { Authorization: 'Bearer alice-secret', 'Content-Type': 'audio/wav', 'Idempotency-Key': `k-${Math.random().toString(36).slice(2, 12)}` }, body: wav() })).json();
  const speak = (id, token = 'alice-secret') => fetch(`${base}/v1/voice-rounds/${id}/speech`, { method: 'POST', headers: { Authorization: `Bearer ${token}` } });
  try { await fn({ round, speak, store, order }); } finally { await new Promise(r => server.close(r)); store.close(); rmSync(dir, { recursive: true, force: true }); }
}

test('prefetch: synthesis starts before the round is saved, and the speech route serves it from memory with one provider call', async () => {
  const p = gatedProvider();
  const speech = createSpeechModel({ env: { SPEECH_PROVIDER: 'wit', WIT_TTS_TOKEN: 't' }, fetchImpl: p.fetchImpl, cache: createSpeechCache() });
  await withServer(speech, async ({ round, speak, order }) => {
    const data = await round();
    assert.deepEqual(order, [['prefetch', 0]], 'started before the round was written');
    assert.deepEqual(p.calls, [QUESTION], 'the checked question, once');
    p.release(); // the first chunk arrives before anyone asks for it
    await new Promise(r => setTimeout(r, 10));
    const r = await speak(data.round_id);
    assert.equal(r.status, 200); assert.equal(r.headers.get('content-type'), 'audio/mpeg'); assert.equal(r.headers.get('x-speech-provider'), 'wit');
    const reader = r.body.getReader();
    const first = await reader.read();
    assert.deepEqual(Buffer.from(first.value), CHUNKS[0], 'what was already made goes out at once');
    const rest = [];
    const pump = (async () => { for (;;) { const x = await reader.read(); if (x.done) return; rest.push(Buffer.from(x.value)); } })();
    p.release(); await new Promise(r => setTimeout(r, 5)); p.release();
    await pump;
    assert.deepEqual(Buffer.concat([Buffer.from(first.value), ...rest]), Buffer.concat(CHUNKS));
    // A second request (a replay of the card) is served from memory too: still one provider call.
    const again = await speak(data.round_id);
    assert.deepEqual(Buffer.from(await again.arrayBuffer()), Buffer.concat(CHUNKS));
    assert.equal(p.calls.length, 1);
    assert.equal((await speak(data.round_id, 'bob-secret')).status, 404, "another account never gets this round's audio");
  });
});

test('prefetch: a failed prefetch gets one fresh call from the speech route; no provider means no prefetch', async () => {
  const bad = gatedProvider({ status: 500 });
  let calls = 0;
  const fetchImpl = async (url, init) => { calls++; return calls === 1 ? bad.fetchImpl(url, init) : new Response(Buffer.concat(CHUNKS), { status: 200, headers: { 'content-type': 'audio/mpeg' } }); };
  const speech = createSpeechModel({ env: { SPEECH_PROVIDER: 'wit', WIT_TTS_TOKEN: 't' }, fetchImpl, cache: createSpeechCache() });
  await withServer(speech, async ({ round, speak }) => {
    const data = await round();
    const r = await speak(data.round_id);
    assert.equal(r.status, 200);
    assert.deepEqual(Buffer.from(await r.arrayBuffer()), Buffer.concat(CHUNKS));
    assert.equal(calls, 2);
  });
  const none = createSpeechModel({ env: {}, cache: createSpeechCache() });
  assert.equal(none.prefetchSpeech('r1', 'alice', QUESTION, 'en'), null);
  const wit = createSpeechModel({ env: { SPEECH_PROVIDER: 'wit', WIT_TTS_TOKEN: 't' }, fetchImpl: async () => { throw new Error('unused'); }, cache: createSpeechCache() });
  assert.equal(wit.prefetchSpeech('r2', 'alice', 'Et alors ?', 'fr'), null, 'no French Wit voice: the Mac speaks it');
});

test('speech cache: kept per account, expires, and holds a bounded number of rounds', async () => {
  const cache = createSpeechCache({ ttlMs: 30, entries: 2 });
  cache.put('a', { user: 'alice', at: Date.now() }); cache.put('b', { user: 'alice', at: Date.now() }); cache.put('c', { user: 'alice', at: Date.now() });
  assert.equal(cache.get('a', 'alice'), null, 'the oldest round goes first');
  assert.ok(cache.get('c', 'alice')); assert.equal(cache.get('c', 'bob'), null);
  await new Promise(r => setTimeout(r, 40));
  assert.equal(cache.get('c', 'alice'), null, 'expired');
});
