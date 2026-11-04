// POST /v1/voice-rounds and its pure parts, with fake models. No network, no paid calls.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Store } from '../src/store.mjs';
import { createApp } from '../src/server.mjs';
import { MAX_AUDIO_BYTES } from '../src/capture.mjs';
import { verifyQuote, safeQuestion, checkReply, createVoiceModel, voiceParams, FALLBACK_QUESTIONS, MAX_QUESTION_WORDS, VOICE_TIMEOUT_MS } from '../src/voice.mjs';

function wav(seconds = 2, rate = 24000) {
  const samples = Math.round(seconds * rate), data = Buffer.alloc(samples * 2);
  for (let i = 0; i < samples; i++) data.writeInt16LE(Math.round(Math.sin(i / 9) * 2500 + (i % 17) * 7), i * 2);
  const h = Buffer.alloc(44);
  h.write('RIFF', 0); h.writeUInt32LE(36 + data.length, 4); h.write('WAVE', 8); h.write('fmt ', 12); h.writeUInt32LE(16, 16);
  h.writeUInt16LE(1, 20); h.writeUInt16LE(1, 22); h.writeUInt32LE(rate, 24); h.writeUInt32LE(rate * 2, 28); h.writeUInt16LE(2, 32); h.writeUInt16LE(16, 34);
  h.write('data', 36); h.writeUInt32LE(data.length, 40);
  return Buffer.concat([h, data]);
}

const ANSWER = 'So, um, I think we could maybe lead the launch. Conversion is up 8% and the team is ready.';

test('verifyQuote: accepts the speaker\'s own words, word for word, and cuts the quote from the transcript', () => {
  assert.deepEqual(verifyQuote(ANSWER, 'we could maybe lead the launch'), { verified: true, quote: 'we could maybe lead the launch', reason: null });
  // Case and punctuation do not matter; the kept quote is the transcript's own text.
  assert.equal(verifyQuote(ANSWER, 'So um I THINK').quote, 'So, um, I think');
  assert.equal(verifyQuote(ANSWER, '"conversion is up 8%."').quote, 'Conversion is up 8');
  for (const [quote, reason] of [['we should lead the launch', 'not_in_transcript'], ['lead we could', 'not_in_transcript'], ['the laun', 'not_in_transcript'],
    ['Conversion is up 9%', 'not_in_transcript'], ['', 'empty'], ['  ...  ', 'empty'], [Array(31).fill('so').join(' '), 'too_long']])
    assert.deepEqual(verifyQuote(ANSWER, quote), { verified: false, quote: '', reason }, quote);
});

test('safeQuestion: removes quoted words the speaker never said, keeps the ones they did, and stays speakable', () => {
  const kept = safeQuestion('You said "maybe lead the launch". Why maybe?', ANSWER, 'challenge', 'en');
  assert.equal(kept.question, 'You said "maybe lead the launch". Why maybe?'); assert.equal(kept.checks.stripped_quotes, 0);
  const stripped = safeQuestion('You said "we will triple revenue". What backs that up?', ANSWER, 'challenge', 'en');
  assert.equal(stripped.question, 'What backs that up?'); assert.equal(stripped.checks.stripped_quotes, 1);
  const curly = safeQuestion('Why “definitely” and not ‘maybe’? Don\'t hedge.', ANSWER, 'challenge', 'en');
  assert.equal(curly.question, 'Why and not ‘maybe’? Don\'t hedge.', 'apostrophes are not quote marks');
  const empty = safeQuestion('"We will triple revenue"?', ANSWER, 'follow_up', 'en');
  assert.equal(empty.question, FALLBACK_QUESTIONS.en.follow_up); assert.equal(empty.checks.replaced, true);
  const long = safeQuestion(Array(40).fill('word').join(' ') + '?', ANSWER, 'follow_up', 'en');
  assert.equal(long.question.split(' ').length, MAX_QUESTION_WORDS); assert.equal(long.checks.cut_to_words, MAX_QUESTION_WORDS);
  assert.match(safeQuestion('Email kemi@example.com your numbers, then tell me why?', ANSWER, 'follow_up', 'en').question, /\[email\]/);
  assert.equal(safeQuestion('« Vous allez tripler » ?', 'Je pense que oui.', 'challenge', 'fr').question, FALLBACK_QUESTIONS.fr.challenge);
});

test('checkReply: an unverified quote is dropped and flagged; a verified one is kept', () => {
  const bad = checkReply({ move: 'challenge', quote: 'we will triple revenue', question: 'Why do you say "we will triple revenue"?' }, ANSWER, 'en');
  assert.deepEqual(bad.reply, { move: 'challenge', question: 'Why do you say?', quote: '', quote_verified: false });
  assert.equal(bad.checks.quote_rejection, 'not_in_transcript');
  const good = checkReply({ move: 'follow_up', quote: 'Conversion is up 8%', question: 'Up 8% since when?' }, ANSWER, 'en');
  assert.deepEqual(good.reply, { move: 'follow_up', question: 'Up 8% since when?', quote: 'Conversion is up 8', quote_verified: true });
  const none = checkReply({ move: 'wrap_up', quote: '', question: 'Thanks, that was clear. Anything else?' }, ANSWER, 'en');
  assert.equal(none.reply.quote_verified, false); assert.equal(none.checks.quote_offered, false); assert.equal(none.checks.quote_rejection, null);
});

test('voiceParams: defaults, accepted values and refusals', () => {
  assert.deepEqual(voiceParams({}), { language: 'en', goalId: null, screenContextId: null, promptEndedAt: null, occurredAt: null });
  assert.equal(voiceParams({ 'x-language': 'fr', 'x-prompt-ended-at': '2026-11-02T15:00:00-05:00' }).promptEndedAt, '2026-11-02T20:00:00.000Z');
  for (const headers of [{ 'x-language': 'de' }, { 'x-goal-id': 'bad id' }, { 'x-screen-context-id': '../x' }, { 'x-prompt-ended-at': 'yesterday' }, { 'x-occurred-at': '2026-13-40T00:00:00Z' }])
    assert.throws(() => voiceParams(headers), err => err.status === 400, JSON.stringify(headers));
});

const enc = new TextEncoder();
const sse = (...chunks) => async (url, init) => new Response(new ReadableStream({ start(c) { for (const x of chunks) c.enqueue(enc.encode(x)); c.close(); } }),
  { status: 200, headers: { 'x-baseten-request-id': 'req-v' } });
const content = text => `data: ${JSON.stringify({ choices: [{ delta: { content: text }, finish_reason: 'stop' }] })}\n\ndata: [DONE]\n\n`;

test('createVoiceModel: one streamed low-effort call; a second only after an unusable reply, never after a timeout or 4xx', async () => {
  const bodies = [];
  const replies = [content('Sure! No JSON here.'), content('{"move":"challenge","quote":"maybe","question":"Why maybe?"}')];
  const fetchImpl = async (url, init) => { bodies.push(JSON.parse(init.body)); return sse(replies.shift())(url, init); };
  const r = await createVoiceModel({ env: { BASETEN_API_KEY: 'k' }, fetchImpl }).voiceReply({ system: 's', user: 'u' });
  assert.equal(r.status, 'model_reply'); assert.equal(r.attempts, 2); assert.deepEqual(r.reply, { move: 'challenge', quote: 'maybe', question: 'Why maybe?' });
  for (const b of bodies) { assert.equal(b.model, 'meta-models/muse-spark-open-1026'); assert.equal(b.reasoning_effort, 'low'); assert.equal(b.stream, true); assert.ok(b.max_tokens >= 1500); }
  let calls = 0;
  const forbidden = await createVoiceModel({ env: { BASETEN_API_KEY: 'k' }, fetchImpl: async () => { calls++; return new Response('{}', { status: 403 }); } }).voiceReply({ system: 's', user: 'u' });
  assert.equal(forbidden.status, 'unavailable'); assert.equal(calls, 1);
  assert.equal(createVoiceModel({ env: {} }).voiceReady(), false);
  assert.ok(VOICE_TIMEOUT_MS <= 10_000, 'a stalled reply is cut off well inside the hosting deadline');
});

function fakeModels({ transcript = ANSWER, reply = { move: 'challenge', quote: 'we could maybe lead the launch', question: 'You said "maybe". Why should it be you, and why now?' },
  turns = [{ turn_id: 0, start_ms: 600, end_ms: 3000 }, { turn_id: 1, start_ms: 4400, end_ms: 6500 }], fail } = {}) {
  const calls = { transcribe: 0, voiceReply: 0, prompts: [] };
  return { calls, models: {
    async transcribe() { calls.transcribe++; if (fail === 'asr') { const { ApiError } = await import('../src/store.mjs'); throw new ApiError(502, 'transcription_failed', 'Transcription returned HTTP 500.'); }
      return { transcript, turns, audio_duration_ms: 7000, model: 'muse-voice-transcribe-1.0', provider_session_id: 'asr-1' }; },
    async voiceReply(input) { calls.voiceReply++; calls.prompts.push(input);
      if (fail === 'model') return { status: 'unavailable', reason: 'Reply timed out after 8000 ms.', attempts: 1 };
      return { status: 'model_reply', reply, model: 'meta-models/muse-spark-open-1026', provider_request_id: 'req-v', attempts: 1, model_ms: 5 }; }
  } };
}

async function withServer(models, fn) {
  const dir = mkdtempSync(join(tmpdir(), 'voice-test-'));
  const dbPath = join(dir, 'voice.sqlite');
  const store = new Store(dbPath);
  store.addToken('alice-secret', 'alice'); store.addToken('reader-secret', 'alice', ['read']); store.seed('alice');
  const server = createApp(store, { models }); await new Promise(r => server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${server.address().port}`;
  const round = async (audio, { token = 'alice-secret', key = 'voice-key-0001', headers = {}, type = 'audio/wav' } = {}) => {
    const r = await fetch(base + '/v1/voice-rounds', { method: 'POST', headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), 'Content-Type': type, ...(key ? { 'Idempotency-Key': key } : {}), ...headers }, body: audio });
    return { status: r.status, data: await r.json() };
  };
  const json = async (method, path, body) => {
    const r = await fetch(base + path, { method, headers: { Authorization: 'Bearer alice-secret', 'Content-Type': 'application/json', 'Idempotency-Key': `j-${Math.random().toString(36).slice(2, 12)}` }, ...(body ? { body: JSON.stringify(body) } : {}) });
    return r.json();
  };
  try { await fn({ round, json, store, dbPath }); } finally { await new Promise(r => server.close(r)); store.close(); rmSync(dir, { recursive: true, force: true }); }
}

test('POST /v1/voice-rounds: the contract response, a stored round without audio, and the overview', async () => {
  const { models, calls } = fakeModels();
  await withServer(models, async ({ round, json, store, dbPath }) => {
    const before = await json('GET', '/v1/overview');
    assert.equal(before.latest_voice_round, null);
    const goal = (await json('POST', '/v1/goals', { title: 'Lead the Q1 launch', target: 'Ask without hedging' })).record;
    const audio = wav(7);
    const { status, data } = await round(audio, { headers: { 'X-Goal-Id': goal.id, 'X-Prompt-Ended-At': '2026-11-02T15:00:00.000Z', 'X-Occurred-At': '2026-11-02T15:00:01.200Z' } });
    assert.equal(status, 200);
    assert.deepEqual(Object.keys(data).sort(), ['counterpart', 'gate', 'latency_ms', 'metrics', 'model', 'provider_request_id', 'receipt_id', 'replayed', 'reply', 'reply_mode', 'round_id', 'transcript'].sort());
    assert.deepEqual(data.gate, { allowed: ['follow_up', 'challenge'], reason: 'open', hedges: 2, coerced: false });
    assert.deepEqual(data.counterpart, { need: null, need_met: null, allowed: ['follow_up', 'challenge'], reason: 'open', answer: 1, reply_mode: 'model' });
    assert.deepEqual(Object.keys(data.metrics).sort(), ['filler_count', 'hedge_count', 'onset_ms_approx', 'pauses', 'restart_count', 'word_count', 'words_per_minute'].sort());
    assert.deepEqual(Object.keys(data.reply).sort(), ['move', 'question', 'quote', 'quote_verified']);
    assert.deepEqual(Object.keys(data.latency_ms).sort(), ['asr', 'model', 'total']);
    assert.equal(data.replayed, false); assert.equal(data.transcript, ANSWER);
    assert.equal(data.model, 'meta-models/muse-spark-open-1026'); assert.equal(data.provider_request_id, 'req-v');
    assert.deepEqual(data.reply, { move: 'challenge', quote: 'we could maybe lead the launch', quote_verified: true, question: 'You said "maybe". Why should it be you, and why now?' });
    assert.equal(data.metrics.filler_count, 1); assert.equal(data.metrics.hedge_count, 2);
    assert.equal(data.metrics.pauses.longest_pause_ms, 1400);
    assert.equal(data.metrics.onset_ms_approx, 1800, '1.2 s from the end of the question to key-down, plus 0.6 s to the first speech');
    assert.ok(data.latency_ms.total >= data.latency_ms.asr + data.latency_ms.model);
    // Stored: transcript, metrics, reply. Not the audio.
    const record = store.get('alice', 'voice-rounds', data.round_id);
    assert.equal(record.audio_retained, false); assert.equal('audio_sha256' in record, false);
    store.db.exec('PRAGMA wal_checkpoint(TRUNCATE)');
    assert.equal(readFileSync(dbPath).includes(audio.subarray(2000, 2064)), false, 'audio bytes are not in the database');
    const after = await json('GET', '/v1/overview');
    assert.notEqual(after.snapshot_revision, before.snapshot_revision);
    assert.equal(after.latest_voice_round.id, data.round_id);
    assert.deepEqual(after.latest_voice_round.reply, data.reply);
    assert.equal(after.latest_voice_round.metrics.onset_ms_approx, 1800);
    assert.equal((await json('GET', '/v1/context')).voice_rounds.length, 1);
    assert.deepEqual([calls.transcribe, calls.voiceReply], [1, 1]);
  });
});

test('POST /v1/voice-rounds: an exact retry replays with no model call; the same key with other audio is a 409', async () => {
  const { models, calls } = fakeModels();
  await withServer(models, async ({ round }) => {
    const audio = wav(3);
    const first = await round(audio, { key: 'voice-retry-1' }), second = await round(audio, { key: 'voice-retry-1' });
    assert.equal(second.status, 200); assert.equal(second.data.replayed, true);
    assert.equal(second.data.round_id, first.data.round_id); assert.equal(second.data.receipt_id, first.data.receipt_id);
    assert.deepEqual(second.data.reply, first.data.reply); assert.deepEqual(second.data.latency_ms, first.data.latency_ms);
    assert.deepEqual([calls.transcribe, calls.voiceReply], [1, 1], 'no model call on the replay');
    assert.equal((await round(wav(3.5), { key: 'voice-retry-1' })).status, 409);
    assert.equal((await round(audio, { key: 'voice-retry-1', headers: { 'X-Language': 'fr' } })).status, 409, 'headers are part of the request');
  });
});

test('POST /v1/voice-rounds: a missing or hidden screen card has its own 404 code; a missing goal keeps not_found', async () => {
  const { models, calls } = fakeModels();
  await withServer(models, async ({ round, store }) => {
    store.put('alice', 'screen-contexts', { id: 'hidden-card', version: 2, deleted: true });
    for (const [headers, error] of [[{ 'X-Screen-Context-Id': 'hidden-card' }, 'screen_context_not_found'],
      [{ 'X-Screen-Context-Id': 'no-such-card' }, 'screen_context_not_found'], [{ 'X-Goal-Id': 'no-such-goal' }, 'not_found'],
      [{ 'X-Goal-Id': 'no-such-goal', 'X-Screen-Context-Id': 'hidden-card' }, 'not_found']]) {
      const r = await round(wav(2), { headers, key: `card-${error}-${Object.keys(headers).length}` });
      assert.equal(r.status, 404, JSON.stringify(headers)); assert.equal(r.data.error, error, JSON.stringify(headers));
    }
    assert.deepEqual([calls.transcribe, calls.voiceReply], [0, 0]);
  });
});

test('POST /v1/voice-rounds: auth, the goal, headers and the body are checked before any model call', async () => {
  const { models, calls } = fakeModels();
  await withServer(models, async ({ round }) => {
    const audio = wav(2);
    const expect = async (status, error, options) => { const r = await round(options.audio ?? audio, options); assert.equal(r.status, status, JSON.stringify(options.headers ?? options)); assert.equal(r.data.error, error); assert.ok(r.data.request_id); };
    await expect(401, 'unauthorized', { token: null });
    await expect(401, 'unauthorized', { token: 'wrong' });
    await expect(403, 'forbidden', { token: 'reader-secret' });
    await expect(400, 'idempotency_required', { key: null });
    await expect(400, 'invalid_value', { headers: { 'X-Language': 'de' } });
    await expect(400, 'invalid_value', { headers: { 'X-Prompt-Ended-At': 'soon' } });
    await expect(404, 'not_found', { headers: { 'X-Goal-Id': 'no-such-goal' } });
    await expect(404, 'screen_context_not_found', { headers: { 'X-Screen-Context-Id': 'no-such-card' } });
    await expect(415, 'content_type', { type: 'application/json' });
    await expect(400, 'unsupported_audio', { audio: Buffer.from('not a wav file at all, just text padding it out past 44 bytes') });
    await expect(413, 'too_large', { audio: Buffer.alloc(MAX_AUDIO_BYTES + 1) });
    assert.deepEqual([calls.transcribe, calls.voiceReply], [0, 0]);
  });
  const unconfigured = fakeModels();
  unconfigured.models.voiceReady = () => false;
  await withServer(unconfigured.models, async ({ round }) => {
    const r = await round(wav(2));
    assert.equal(r.status, 503); assert.equal(r.data.error, 'reply_unconfigured');
    assert.equal(unconfigured.calls.transcribe, 0, 'no paid transcription when no reply can follow');
  });
});

test('POST /v1/voice-rounds: a failed transcription or reply returns 502 and saves nothing', async () => {
  for (const fail of ['asr', 'model']) {
    const { models } = fakeModels({ fail });
    await withServer(models, async ({ round, store }) => {
      const r = await round(wav(2));
      assert.equal(r.status, 502); assert.equal(r.data.error, fail === 'asr' ? 'transcription_failed' : 'reply_failed');
      assert.equal(store.list('alice', 'voice-rounds').length, 0);
    });
  }
});

test('POST /v1/voice-rounds: a quote the speaker never said is dropped, and the question is cleaned before it is spoken', async () => {
  const { models } = fakeModels({ reply: { move: 'challenge', quote: 'we will triple revenue', question: 'You said "we will triple revenue". What is that based on?' } });
  await withServer(models, async ({ round, store }) => {
    const { data } = await round(wav(2));
    assert.deepEqual(data.reply, { move: 'challenge', question: 'What is that based on?', quote: '', quote_verified: false });
    const record = store.get('alice', 'voice-rounds', data.round_id);
    assert.equal(record.reply_checks.quote_rejection, 'not_in_transcript'); assert.equal(record.reply_checks.stripped_quotes, 1);
  });
});

test('POST /v1/voice-rounds: the prompt is grounded in the goal, the latest watch session, the screen card and the last question', async () => {
  const { models, calls } = fakeModels();
  await withServer(models, async ({ round, json, store }) => {
    const goal = (await json('POST', '/v1/goals', { title: 'Lead the Q1 launch', target: 'Ask without hedging' })).record;
    const at = '2026-11-02T14:00:00.000Z';
    store.put('alice', 'sessions', { id: 'watch-1', version: 1, source: 'capture', capture_device: 'watch', measurement_status: 'measured', occurred_at: at, deleted: false,
      transcript: 'x', metrics: { word_count: 40, words_per_minute: 150, filler_count: 2, hedge_count: 3, restart_count: 0, pauses: { longest_pause_ms: 1400 } } });
    store.put('alice', 'sessions', { id: 'mac-1', version: 1, source: 'capture', capture_device: 'mac', measurement_status: 'measured', occurred_at: '2026-11-02T14:30:00.000Z', deleted: false,
      transcript: 'y', metrics: { word_count: 1, words_per_minute: 1, filler_count: 9, hedge_count: 9, restart_count: 9, pauses: {} } });
    store.put('alice', 'screen-contexts', { id: 'card-1', version: 1, purpose: 'meeting_prep', app_name: 'Notes', occurred_at: at, deleted: false, text_sha256: 'f'.repeat(64),
      analysis: { summary: 'Preparing to ask Kemi to lead the Q1 launch.', observation: 'o', next_step: 'n' } });
    await round(wav(2), { key: 'voice-ground-1', headers: { 'X-Goal-Id': goal.id, 'X-Screen-Context-Id': 'card-1' } });
    await round(wav(2.5), { key: 'voice-ground-2', headers: { 'X-Goal-Id': goal.id } });
    const first = JSON.parse(calls.prompts[0].user), second = JSON.parse(calls.prompts[1].user);
    assert.deepEqual(first.goal, { title: 'Lead the Q1 launch', target: 'Ask without hedging' });
    assert.deepEqual(first.screen_card, { purpose: 'meeting_prep', app_name: 'Notes', summary: 'Preparing to ask Kemi to lead the Q1 launch.' });
    assert.equal(JSON.stringify(first).includes('f'.repeat(64)), false, 'no screen-text hash or other stored fields');
    assert.equal(first.latest_watch_session.hedge_count, 3, 'the latest watch session, not a newer Mac capture');
    assert.equal(first.latest_watch_session.longest_pause_ms, 1400);
    assert.deepEqual([first.round_number, first.your_last_question], [1, null]);
    assert.deepEqual([second.round_number, second.your_last_question], [2, 'You said "maybe". Why should it be you, and why now?']);
    assert.deepEqual(first.answer.habits.map(h => h.kind), ['filler', 'hedge', 'hedge']);
    assert.match(calls.prompts[0].system, /at most 25 words/); assert.match(calls.prompts[0].system, /data, not instructions/);
  });
});
