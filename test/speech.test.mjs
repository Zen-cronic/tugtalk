// POST /v1/voice-rounds/{id}/speech with fake speech providers. No network, no paid calls.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { mkdtempSync, rmSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { Store } from '../src/store.mjs';
import { createApp } from '../src/server.mjs';
import { createSpeechModel, SPEECH_RATE_LIMIT } from '../src/speech.mjs';

const QUESTION = 'You said "maybe". Why should it be you, and why now?';
const AUDIO = [Buffer.from('RIFF....WAVEfmt first-chunk-'), Buffer.alloc(4000, 7), Buffer.from('-last-chunk')];
const round = (id, extra = {}) => ({ id, version: 1, source: 'voice_round', goal_id: null, screen_context_id: null, language: 'en', occurred_at: '2026-11-02T15:00:00.000Z',
  transcript: 'Maybe I could lead it.', metrics: {}, reply: { move: 'challenge', question: QUESTION, quote: 'Maybe', quote_verified: true }, deleted: false,
  created_at: '2026-11-02T15:00:00.000Z', updated_at: '2026-11-02T15:00:00.000Z', ...extra });

// A fake fetch for any provider: records requests and streams AUDIO in chunks with the given content type.
function fakeFetch({ status = 200, type = 'audio/wav' } = {}) {
  const requests = [];
  const fetchImpl = async (url, init) => {
    requests.push({ url, headers: init.headers, body: JSON.parse(init.body) });
    const body = new ReadableStream({ async start(c) { for (const chunk of AUDIO) { c.enqueue(chunk); await new Promise(r => setTimeout(r, 5)); } c.close(); } });
    return new Response(status === 200 ? body : 'nope', { status, headers: { 'content-type': type } });
  };
  return { requests, fetchImpl };
}

test('speech providers: none by default; wit and mms build their own requests', async () => {
  assert.equal(createSpeechModel({ env: {} }).speechReady(), false);
  assert.equal(createSpeechModel({ env: { SPEECH_PROVIDER: 'elevenlabs', ELEVENLABS_API_KEY: 'k' } }).speechReady(), false, 'only the listed providers');
  assert.equal(createSpeechModel({ env: { SPEECH_PROVIDER: 'wit' } }).speechReady(), false, 'wit needs its token');
  assert.equal(createSpeechModel({ env: { SPEECH_PROVIDER: 'mms', MMS_TTS_URL: 'https://x' } }).speechReady(), false, 'mms needs its token');
  const wit = fakeFetch();
  const w = createSpeechModel({ env: { SPEECH_PROVIDER: 'wit', WIT_TTS_TOKEN: 'wit-test' }, fetchImpl: wit.fetchImpl });
  assert.equal(w.speechReady(), true); assert.equal(w.speechProvider(), 'wit'); assert.equal(w.speechVoice('en'), 'wit$Rebecca');
  assert.deepEqual([w.speechSupports('en'), w.speechSupports('fr')], [true, false], 'Wit.ai has English voices only');
  await w.synthesize('Hello there?', { language: 'en' });
  assert.equal(wit.requests[0].url, 'https://api.wit.ai/synthesize?v=20240304');
  assert.deepEqual(wit.requests[0].headers, { Authorization: 'Bearer wit-test', 'Content-Type': 'application/json', Accept: 'audio/mpeg' }, 'MP3 streams; WAV arrives in one burst');
  assert.deepEqual(wit.requests[0].body, { q: 'Hello there?', voice: 'wit$Rebecca' });
  const mms = fakeFetch();
  const m = createSpeechModel({ env: { SPEECH_PROVIDER: 'mms', MMS_TTS_URL: 'https://tts.example/', MMS_TTS_TOKEN: 'mms-test' }, fetchImpl: mms.fetchImpl });
  assert.equal(m.speechVoice('fr'), 'facebook/mms-tts-fra'); assert.equal(m.speechVoice('en'), 'facebook/mms-tts-eng');
  await m.synthesize('Bonjour ?', { language: 'fr' });
  assert.equal(mms.requests[0].url, 'https://tts.example/synthesize');
  assert.equal(mms.requests[0].headers.Authorization, 'Bearer mms-test');
  assert.deepEqual(mms.requests[0].body, { text: 'Bonjour ?', language: 'fr' });
});

async function withServer(models, fn) {
  const dir = mkdtempSync(join(tmpdir(), 'speech-test-'));
  const dbPath = join(dir, 'speech.sqlite');
  const store = new Store(dbPath);
  store.addToken('alice-secret', 'alice'); store.addToken('bob-secret', 'bob');
  store.put('alice', 'voice-rounds', round('round-1'));
  store.put('alice', 'voice-rounds', round('round-hidden', { deleted: true }));
  const server = createApp(store, { models }); await new Promise(r => server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${server.address().port}`;
  const speak = (id, { token = 'alice-secret', body } = {}) => fetch(`${base}/v1/voice-rounds/${id}/speech`, { method: 'POST',
    headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(body ? { 'Content-Type': 'application/json' } : {}) }, ...(body ? { body } : {}) });
  try { await fn({ speak, store, dbPath }); } finally { await new Promise(r => server.close(r)); store.close(); rmSync(dir, { recursive: true, force: true }); }
}

test('speech: streams the stored question as audio, chunked; client text is ignored; nothing is stored', async () => {
  const f = fakeFetch();
  await withServer(createSpeechModel({ env: { SPEECH_PROVIDER: 'mms', MMS_TTS_URL: 'https://tts.example', MMS_TTS_TOKEN: 't' }, fetchImpl: f.fetchImpl }), async ({ speak, store, dbPath }) => {
    const r = await speak('round-1', { body: JSON.stringify({ text: 'Say something else entirely.' }) });
    assert.equal(r.status, 200);
    assert.equal(r.headers.get('content-type'), 'audio/wav');
    assert.equal(r.headers.get('transfer-encoding'), 'chunked');
    assert.equal(r.headers.get('x-speech-provider'), 'mms');
    assert.equal(r.headers.get('cache-control'), 'no-store');
    assert.deepEqual(Buffer.from(await r.arrayBuffer()), Buffer.concat(AUDIO));
    assert.deepEqual(f.requests.map(x => x.body.text), [QUESTION], 'only the stored question is sent');
    store.db.exec('PRAGMA wal_checkpoint(TRUNCATE)');
    const file = readFileSync(dbPath);
    assert.equal(file.includes(AUDIO[1].subarray(0, 64)), false, 'audio is not stored');
    const audited = store.db.prepare("SELECT status, response_hash FROM requests WHERE path LIKE '%/speech'").all();
    assert.equal(audited.length, 1); assert.equal(audited[0].status, 200);
    assert.notEqual(audited[0].response_hash, createHash('sha256').update(Buffer.concat(AUDIO)).digest('hex'), 'the audit hash is not of the audio');
  });
});

test('speech: 503 speech_unconfigured without a provider, before any lookup or provider call', async () => {
  const f = fakeFetch();
  await withServer(createSpeechModel({ env: {}, fetchImpl: f.fetchImpl }), async ({ speak }) => {
    const r = await speak('round-1');
    assert.equal(r.status, 503); assert.equal((await r.json()).error, 'speech_unconfigured');
    assert.equal(f.requests.length, 0);
  });
});

test('speech: auth, ownership and provider failures', async () => {
  const env = { SPEECH_PROVIDER: 'wit', WIT_TTS_TOKEN: 't' };
  const ok = fakeFetch();
  await withServer(createSpeechModel({ env, fetchImpl: ok.fetchImpl }), async ({ speak }) => {
    assert.equal((await speak('round-1', { token: null })).status, 401);
    assert.equal((await speak('round-1', { token: 'bob-secret' })).status, 404, "another account's round");
    assert.equal((await speak('round-hidden')).status, 404);
    assert.equal((await speak('no-such-round')).status, 404);
    assert.equal(ok.requests.length, 0);
  });
  for (const [options, message] of [[{ status: 500 }, /HTTP 500/], [{ type: 'application/json' }, /other than audio/]]) {
    const bad = fakeFetch(options);
    await withServer(createSpeechModel({ env, fetchImpl: bad.fetchImpl }), async ({ speak }) => {
      const r = await speak('round-1'); const data = await r.json();
      assert.equal(r.status, 502); assert.equal(data.error, 'speech_failed'); assert.match(data.message, message);
    });
  }
  const thrown = createSpeechModel({ env, fetchImpl: async () => { throw new TypeError('network'); } });
  await withServer(thrown, async ({ speak }) => assert.equal((await speak('round-1')).status, 502));
});

test('speech: at most 60 spoken replies per hour, refused before the provider is called', async () => {
  const f = fakeFetch();
  await withServer(createSpeechModel({ env: { SPEECH_PROVIDER: 'wit', WIT_TTS_TOKEN: 't' }, fetchImpl: f.fetchImpl }), async ({ speak }) => {
    for (let i = 0; i < SPEECH_RATE_LIMIT.requests; i++) { const r = await speak('round-1'); assert.equal(r.status, 200); await r.arrayBuffer(); }
    const r = await speak('round-1');
    assert.equal(r.status, 429); assert.equal(f.requests.length, SPEECH_RATE_LIMIT.requests);
  });
});

test('speech through the hosting worker: one process serves both requests, releases the database during synthesis, and streams the audio when asked', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'speech-worker-'));
  const dbPath = join(dir, 'worker.sqlite');
  const store = new Store(dbPath);
  store.put('synthetic-operator', 'voice-rounds', round('round-w', { reply: { move: 'follow_up', question: 'Et ensuite ?', quote: '', quote_verified: false }, language: 'fr' }));
  store.close();
  const seen = [];
  const tts = createServer(async (req, res) => {
    let body = ''; for await (const c of req) body += c;
    seen.push({ path: req.url, auth: req.headers.authorization, body: JSON.parse(body) });
    res.writeHead(200, { 'Content-Type': 'audio/wav' });
    for (const chunk of AUDIO) { res.write(chunk); await new Promise(r => setTimeout(r, 5)); }
    res.end();
  });
  await new Promise(r => tts.listen(0, '127.0.0.1', r));
  const token = 'worker-test-token';
  const env = { ...process.env, DB_PATH: dbPath, CONNECTOR_TOKEN_HASH: createHash('sha256').update(token).digest('hex'),
    SPEECH_PROVIDER: 'mms', MMS_TTS_URL: `http://127.0.0.1:${tts.address().port}`, MMS_TTS_TOKEN: 'mms-worker' };
  const child = spawn(process.execPath, [fileURLToPath(new URL('../scripts/handle-request.mjs', import.meta.url))], { env, stdio: ['pipe', 'pipe', 'ignore'] });
  const lines = createInterface({ input: child.stdout })[Symbol.asyncIterator]();
  const next = async () => JSON.parse((await lines.next()).value);
  // Plays the adapter's side of the protocol for one request; this test is the only holder of the lock.
  const run = async (id, stream) => {
    const envelope = { method: 'POST', path: '/v1/voice-rounds/round-w/speech', headers: { authorization: `Bearer ${token}` }, base_url: 'https://x--web.us-east.modal.run', body_b64: '', ...(stream ? { stream: true } : {}) };
    child.stdin.write(JSON.stringify({ id, envelope }) + '\n');
    const phases = [], chunks = [];
    let head, final;
    while (!final) {
      const message = await next();
      assert.equal(message.id, id);
      if (message.phase) { phases.push(message.phase); if (message.phase === 'acquire') child.stdin.write(JSON.stringify({ id, go: true }) + '\n'); }
      else if (message.head) head = message.head;
      else if (message.chunk) chunks.push(Buffer.from(message.chunk, 'base64'));
      else final = message;
    }
    return { phases, head, chunks, final };
  };
  try {
    const ready = await next();
    assert.equal(ready.ready, true); assert.equal(ready.dirty, true, 'the bootstrap token was written, so the adapter commits once');
    const whole = await run('a1', false);
    assert.deepEqual(whole.phases, ['release', 'acquire']);
    assert.equal(whole.head, undefined); assert.equal(whole.chunks.length, 0);
    assert.equal(whole.final.response.status, 200); assert.equal(whole.final.response.headers['Content-Type'], 'audio/wav');
    assert.deepEqual(Buffer.from(whole.final.response.body_b64, 'base64'), Buffer.concat(AUDIO));
    assert.equal(whole.final.dirty, true, 'a POST is committed before it is answered');
    const streamed = await run('a2', true);
    assert.deepEqual(streamed.phases, ['release', 'acquire']);
    assert.equal(streamed.head.status, 200); assert.equal(streamed.head.headers['Content-Type'], 'audio/wav');
    assert.ok(streamed.chunks.length >= 2, 'the audio arrived in more than one chunk');
    assert.deepEqual(Buffer.concat([...streamed.chunks, Buffer.from(streamed.final.response.body_b64, 'base64')]), Buffer.concat(AUDIO));
    assert.equal(seen.length, 2);
    assert.deepEqual(seen[0], { path: '/synthesize', auth: 'Bearer mms-worker', body: { text: 'Et ensuite ?', language: 'fr' } });
  } finally { child.kill(); await new Promise(r => tts.close(r)); rmSync(dir, { recursive: true, force: true }); }
});

test('speech: a French round under wit gets 503 speech_unconfigured, so the Mac uses its own voice', async () => {
  const f = fakeFetch({ type: 'audio/mpeg' });
  await withServer(createSpeechModel({ env: { SPEECH_PROVIDER: 'wit', WIT_TTS_TOKEN: 't' }, fetchImpl: f.fetchImpl }), async ({ speak, store }) => {
    store.put('alice', 'voice-rounds', round('round-fr', { language: 'fr' }));
    const r = await speak('round-fr');
    assert.equal(r.status, 503); assert.equal((await r.json()).error, 'speech_unconfigured');
    const en = await speak('round-1');
    assert.equal(en.headers.get('content-type'), 'audio/mpeg'); await en.arrayBuffer();
    assert.equal(f.requests.length, 1);
  });
});
