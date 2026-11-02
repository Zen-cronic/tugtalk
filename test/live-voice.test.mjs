// Live voice rounds (src/live-voice.mjs) with a fake Meta realtime socket and fake models. No network, no paid calls.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Store } from '../src/store.mjs';
import { createLiveRound, createRealtimeModel, liveStart, wavFromPcm, LIVE_PATH } from '../src/live-voice.mjs';
import { handleVoiceRound, voiceParams, VOICE_ROUNDS_PATH, VOICE_RATE_LIMIT } from '../src/voice.mjs';
import { createSpeechModel, createSpeechCache } from '../src/speech.mjs';
import { inspectWav } from '../src/capture.mjs';

const ANSWER = 'So, um, I think we could maybe lead the launch.';
const QUESTION = 'You said "maybe". Why should it be you?';
const tick = (ms = 0) => new Promise(r => setTimeout(r, ms));

// One fake socket per `new`: records what is sent; the test plays Meta's side.
function fakeMeta() {
  const sockets = [];
  class FakeSocket {
    constructor(url) { this.url = url; this.sent = []; this.closed = null; sockets.push(this); queueMicrotask(() => this.onopen?.()); }
    send(data) { this.sent.push(typeof data === 'string' ? JSON.parse(data) : Buffer.from(data)); if (typeof data === 'string' && JSON.parse(data).type === 'endStream') this.onEnd?.(); }
    close(code = 1000) { if (this.closed === null) { this.closed = code; } }
    // Meta's side
    say(message) { this.onmessage?.({ data: JSON.stringify(message) }); }
    ack() { this.say({ sessionId: 'meta-session-1' }); }
    drop(code) { this.onclose?.({ code }); }
    get audio() { return Buffer.concat(this.sent.filter(Buffer.isBuffer)); }
    get handshake() { return this.sent[0]; }
  }
  return { sockets, FakeSocket };
}

function pcm(ms, seed = 1) {
  const b = Buffer.alloc(ms * 48);
  for (let i = 0; i < b.length / 2; i++) b.writeInt16LE(Math.round(Math.sin((i + seed) / 7) * 2000), i * 2);
  return b;
}

function setup({ realtime = true, speech = true, ttsChunks = [Buffer.from('mp3-a'), Buffer.from('mp3-b')] } = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'live-test-'));
  const store = new Store(join(dir, 'live.sqlite'));
  store.addToken('alice-secret', 'alice'); store.addToken('reader-secret', 'alice', ['read']); store.seed('alice');
  const meta = fakeMeta();
  const calls = { transcribe: [], voiceReply: 0, tts: 0 };
  const tts = createSpeechModel({ env: speech ? { SPEECH_PROVIDER: 'wit', WIT_TTS_TOKEN: 't' } : {}, cache: createSpeechCache(),
    fetchImpl: async () => { calls.tts++; return new Response(new ReadableStream({ start(c) { ttsChunks.forEach(x => c.enqueue(x)); c.close(); } }), { headers: { 'content-type': 'audio/mpeg' } }); } });
  const models = {
    ...(realtime ? createRealtimeModel({ env: { MODEL_API_KEY: 'meta-key' }, WebSocketImpl: meta.FakeSocket }) : {}),
    ...tts,
    async transcribe(audio) { calls.transcribe.push(audio); return { transcript: ANSWER, turns: [{ turn_id: 0, start_ms: 300, end_ms: 1800, transcript: ANSWER }], audio_duration_ms: 2000, model: 'muse-voice-transcribe-1.0', provider_session_id: 'file-1' }; },
    voiceReady: () => true,
    async voiceReply() { calls.voiceReply++; return { status: 'model_reply', reply: { move: 'challenge', quote: 'maybe lead the launch', question: QUESTION }, model: 'meta-models/muse-spark-open-1026', provider_request_id: 'r1', attempts: 1 }; }
  };
  const log = [];
  const phases = { async release() { log.push('release'); }, async acquire() { log.push('acquire'); } };
  const events = [], audio = [];
  const open = (start, token = 'Bearer alice-secret') => createLiveRound({ store, models, token, start, phases,
    emit: e => { events.push(e); log.push(`event:${e.type}`); }, emitAudio: b => { audio.push(Buffer.from(b)); log.push('audio'); } });
  return { store, meta, calls, models, log, events, audio, open, cleanup: () => { store.close(); rmSync(dir, { recursive: true, force: true }); } };
}

const START = { type: 'start', idempotency_key: 'live-key-0001', language: 'en', occurred_at: '2026-11-02T19:00:00.000Z', prompt_ended_at: '2026-11-02T18:59:59.000Z' };

// Plays Meta's side of an ENDPOINTING session for one turn, answering endStream with the final events.
function metaAnswers(socket) {
  socket.ack();
  socket.say({ type: 'speechStart', turnId: 0, audioProcessedMs: 300 });
  socket.say({ type: 'transcript', transcript: 'So, um, I think', final: false, audioProcessedMs: 900 });
  socket.onEnd = () => queueMicrotask(() => {
    socket.say({ type: 'speechEnd', turnId: 0, audioProcessedMs: 1800 });
    socket.say({ type: 'speechComplete', turnId: 0, transcript: ANSWER, audioProcessedMs: 1900 });
    socket.say({ type: 'transcript', transcript: '', final: true, audioProcessedMs: 2000 });
    socket.drop(1000);
  });
}

test('live: the connector key and every pre-paid check come before Meta is called', async () => {
  const s = setup();
  try {
    for (const [token, start, status] of [['Bearer wrong', START, 401], ['Bearer reader-secret', START, 403], ['Bearer alice-secret', { type: 'hello' }, 400],
      ['Bearer alice-secret', { ...START, idempotency_key: 'x' }, 400], ['Bearer alice-secret', { ...START, language: 'de' }, 400], ['Bearer alice-secret', { ...START, goal_id: 'not-mine' }, 404]]) {
      const r = await s.open(start, token).done;
      assert.equal(r.status, status, `${token} ${JSON.stringify(start)}`);
    }
    assert.equal(s.meta.sockets.length, 0, 'no realtime socket was opened');
    assert.deepEqual([s.calls.transcribe.length, s.calls.voiceReply, s.calls.tts], [0, 0, 0]);
    assert.equal(s.log.includes('release'), false, 'refused while still holding the database: nothing slow ran');
    // The hourly limit counts live rounds too, and refuses before the socket.
    for (let i = 0; i < VOICE_RATE_LIMIT.requests; i++) s.store.audit(`r${i}`, 'alice', 'POST', VOICE_ROUNDS_PATH, i % 3 === 0 ? 499 : 200, 'x');
    assert.equal((await s.open(START).done).status, 429);
    assert.equal(s.meta.sockets.length, 0);
  } finally { s.cleanup(); }
});

test('live: one realtime session per hold; the reply and its audio go out before the write, and "saved" after it', async () => {
  const s = setup();
  try {
    const round = s.open(START);
    const frames = [pcm(80, 1), pcm(80, 2), pcm(1840, 3)];
    round.audio(frames[0]); // before the session is ready: kept and sent once Meta acknowledges
    await tick();
    assert.equal(s.meta.sockets.length, 1);
    const socket = s.meta.sockets[0];
    assert.match(socket.url, /^wss:\/\/api\.meta\.ai\/v1\/asr\/realtime\?sessionId=/);
    assert.deepEqual(socket.handshake, { authorization: { accessToken: 'Bearer meta-key' }, audioEncoding: 'PCM_24KHZ', model: 'muse-voice-transcribe-1.0',
      mode: 'ENDPOINTING', partialMode: 'CUMULATIVE', languageBias: ['English'], emitAudioProgress: false });
    metaAnswers(socket);
    round.audio(frames[1]); round.audio(frames[2]);
    await tick();
    assert.deepEqual(socket.audio, Buffer.concat(frames), 'every frame reached Meta, in order');
    assert.ok(s.events.some(e => e.type === 'partial' && e.text === 'So, um, I think'), 'the caption follows the hold');
    round.end();
    const result = await round.done;
    assert.equal(result.status, 200);
    await result.speechDone;
    assert.deepEqual(socket.sent.at(-1), { type: 'endStream' }, 'input was ended, not cut');
    assert.equal(s.meta.sockets.length, 1, 'one session per hold');
    const reply = s.events.find(e => e.type === 'reply');
    assert.equal(reply.round_id, result.body.round_id); assert.equal(reply.reply.question, QUESTION); assert.equal(reply.transcription, 'realtime');
    assert.equal(result.body.transcript, ANSWER); assert.equal(result.body.metrics.pauses.status, 'measured');
    assert.equal(result.body.metrics.onset_ms_approx, 1300, 'onset from the realtime turn: 1 s before key-down plus 0.3 s');
    // Order: the reply event and the speech start before the database is taken again for the write.
    const at = name => s.log.indexOf(name);
    assert.ok(at('event:reply') < at('acquire'), 'reply before the write');
    assert.ok(at('event:speech_start') >= 0 && s.audio.length === 2);
    assert.deepEqual(Buffer.concat(s.audio), Buffer.from('mp3-amp3-b'));
    assert.equal(s.events.at(-1).type, 'speech_end');
    assert.deepEqual([s.calls.transcribe.length, s.calls.voiceReply, s.calls.tts], [0, 1, 1], 'no file transcription; one reply; one synthesis');
    const record = s.store.get('alice', 'voice-rounds', result.body.round_id);
    assert.equal(record.transcription.mode, 'realtime'); assert.equal(record.transcription.provider_session_id, 'meta-session-1');
    assert.equal(record.audio_retained, false);
    // The Mac's fallback upload of the same samples with the same key replays this round: no model call.
    const user = 'alice', params = voiceParams({ 'x-language': 'en', 'x-occurred-at': START.occurred_at, 'x-prompt-ended-at': START.prompt_ended_at });
    const replay = await handleVoiceRound(s.store, s.models, user, { params, audio: wavFromPcm(Buffer.concat(frames)) }, START.idempotency_key, 'req');
    assert.equal(replay.replayed, true); assert.equal(replay.round_id, result.body.round_id);
    assert.deepEqual([s.calls.transcribe.length, s.calls.voiceReply], [0, 1]);
    assert.equal(s.store.recentRequests('alice', 'POST', VOICE_ROUNDS_PATH, [200], 60_000), 1, 'counted toward the hourly limit');
  } finally { s.cleanup(); }
});

test('live: if the realtime socket fails, the same audio is transcribed by the file endpoint and the round still answers', async () => {
  const s = setup();
  try {
    const round = s.open({ ...START, idempotency_key: 'live-key-0002' });
    await tick();
    const socket = s.meta.sockets[0];
    socket.ack();
    const audio = pcm(1500);
    round.audio(audio);
    socket.drop(1011); // Meta's backend failed mid-hold
    round.end();
    const result = await round.done;
    assert.equal(result.status, 200);
    assert.equal(s.calls.transcribe.length, 1);
    assert.deepEqual(s.calls.transcribe[0], wavFromPcm(audio), 'the file endpoint got the WAV of exactly what was held');
    assert.equal(s.events.find(e => e.type === 'transcript').transcription, 'file_fallback');
    assert.equal(s.store.get('alice', 'voice-rounds', result.body.round_id).transcription.mode, 'file_fallback');
  } finally { s.cleanup(); }
});

test('live: a hold cancelled before release saves nothing, calls no reply model, and still counts if Meta heard audio', async () => {
  const s = setup();
  try {
    const round = s.open({ ...START, idempotency_key: 'live-key-0003' });
    await tick();
    s.meta.sockets[0].ack();
    round.audio(pcm(400));
    await tick();
    round.cancel();
    const result = await round.done;
    assert.equal(result.status, 499); assert.equal(result.dirty, false);
    assert.equal(s.calls.voiceReply, 0); assert.equal(s.meta.sockets[0].closed !== null, true);
    assert.equal(s.store.list('alice', 'voice-rounds').length, 0);
    assert.equal(s.store.recentRequests('alice', 'POST', VOICE_ROUNDS_PATH, [499], 60_000), 1);
  } finally { s.cleanup(); }
});

test('live: without realtime the round uses the file endpoint; without a voice it says so; a failed reply is a 502', async () => {
  const s = setup({ realtime: false, speech: false });
  try {
    const round = s.open({ ...START, idempotency_key: 'live-key-0004' });
    round.audio(pcm(1200)); round.end();
    const result = await round.done;
    assert.equal(result.status, 200);
    assert.equal(s.events[0].transcription, 'file');
    await result.speechDone;
    assert.equal(s.events.at(-1).type, 'speech_unavailable');
    s.models.voiceReply = async () => ({ status: 'unavailable', reason: 'Reply timed out.', attempts: 1 });
    const failed = s.open({ ...START, idempotency_key: 'live-key-0005' });
    failed.audio(pcm(1200)); failed.end();
    const r = await failed.done;
    assert.equal(r.status, 502); assert.equal(r.body.error, 'reply_failed');
    const quiet = setup();
    try {
      const own = quiet.open({ ...START, idempotency_key: 'live-key-0007', speech: false });
      await tick(); quiet.meta.sockets[0].ack(); own.audio(pcm(1200)); own.end();
      quiet.meta.sockets[0].drop(1011);
      const r2 = await own.done; await r2.speechDone;
      assert.equal(r2.status, 200);
      assert.equal(quiet.calls.tts, 0, 'the Mac speaks with its own voice: no synthesis');
      assert.equal(quiet.events.at(-1).error, 'not_requested');
    } finally { quiet.cleanup(); }
    const short = s.open({ ...START, idempotency_key: 'live-key-0006' });
    short.audio(pcm(100)); short.end();
    assert.equal((await short.done).status, 400, 'too short to be an answer');
  } finally { s.cleanup(); }
});

test('live: the WAV built from streamed samples is the canonical one a client uploads', () => {
  const samples = pcm(500);
  const wav = wavFromPcm(samples);
  assert.equal(wav.length, 44 + samples.length);
  assert.equal(wav.toString('ascii', 0, 4), 'RIFF'); assert.equal(wav.readUInt32LE(24), 24000); assert.equal(wav.readUInt32LE(40), samples.length);
  assert.equal(inspectWav(wav).durationMs, 500);
  assert.equal(liveStart(START).key, 'live-key-0001');
  assert.equal(LIVE_PATH, '/v1/voice-rounds/live');
});

test('live through the hosting worker: a wrong key is refused before anything else, and a held round runs on the same process', async () => {
  const { spawn } = await import('node:child_process');
  const { createInterface } = await import('node:readline');
  const { createHash } = await import('node:crypto');
  const { fileURLToPath } = await import('node:url');
  const dir = mkdtempSync(join(tmpdir(), 'live-worker-'));
  const token = 'live-worker-token';
  const env = { ...process.env, DB_PATH: join(dir, 'w.sqlite'), CONNECTOR_TOKEN_HASH: createHash('sha256').update(token).digest('hex') };
  for (const k of ['MODEL_API_KEY', 'BASETEN_API_KEY', 'SPEECH_PROVIDER']) delete env[k];
  const child = spawn(process.execPath, [fileURLToPath(new URL('../scripts/handle-request.mjs', import.meta.url))], { env, stdio: ['pipe', 'pipe', 'ignore'] });
  const lines = createInterface({ input: child.stdout })[Symbol.asyncIterator]();
  const next = async () => JSON.parse((await lines.next()).value);
  const send = m => child.stdin.write(JSON.stringify(m) + '\n');
  const envelope = auth => ({ method: 'POST', path: LIVE_PATH, headers: { authorization: auth }, base_url: 'https://x--web.us-east.modal.run', body_b64: '', live: START });
  try {
    assert.equal((await next()).ready, true);
    send({ id: 'l1', envelope: envelope('Bearer wrong'), budget_ms: 100_000 });
    const refused = await next();
    assert.equal(refused.response.status, 401); assert.equal(refused.dirty, false);
    assert.deepEqual(await next(), { id: 'l1', closed: true });
    // With the right key: no reply model is configured here, so it is refused before any provider is called (503).
    send({ id: 'l2', envelope: envelope(`Bearer ${token}`), budget_ms: 100_000 });
    const unconfigured = await next();
    assert.equal(unconfigured.response.status, 503);
    assert.equal(JSON.parse(Buffer.from(unconfigured.response.body_b64, 'base64')).error, 'reply_unconfigured');
    assert.deepEqual(await next(), { id: 'l2', closed: true });
  } finally { child.kill(); rmSync(dir, { recursive: true, force: true }); }
});
