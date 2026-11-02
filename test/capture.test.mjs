import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Store } from '../src/store.mjs';
import { createApp } from '../src/server.mjs';
import { measure, inspectWav, createModelClients } from '../src/capture.mjs';

// Mono 16-bit PCM WAV of a quiet tone; content is irrelevant because models are stubbed.
function wav(seconds = 2, rate = 24000, tone = 440) {
  const samples = Math.round(seconds * rate), data = Buffer.alloc(samples * 2);
  for (let i = 0; i < samples; i++) data.writeInt16LE(Math.round(Math.sin(2 * Math.PI * tone * i / rate) * 3000), i * 2);
  const header = Buffer.alloc(44);
  header.write('RIFF', 0); header.writeUInt32LE(36 + data.length, 4); header.write('WAVE', 8);
  header.write('fmt ', 12); header.writeUInt32LE(16, 16); header.writeUInt16LE(1, 20); header.writeUInt16LE(1, 22);
  header.writeUInt32LE(rate, 24); header.writeUInt32LE(rate * 2, 28); header.writeUInt16LE(2, 32); header.writeUInt16LE(16, 34);
  header.write('data', 36); header.writeUInt32LE(data.length, 40);
  return Buffer.concat([header, data]);
}

function stubModels({ transcript = 'Um, so I think the main point is, uh, ship the smaller version first. Sorry, let me restart. Ship it first because we can test this week.', failTranscribe = false, analysis } = {}) {
  const calls = { transcribe: 0, analyze: 0, lastAnalyze: null };
  return { calls, models: {
    async transcribe(audio, { language }) {
      calls.transcribe++;
      if (failTranscribe) { const { ApiError } = await import('../src/store.mjs'); throw new ApiError(502, 'transcription_failed', 'Transcription returned HTTP 500.'); }
      return { transcript, turns: [{ turn_id: 0, start_ms: 0, end_ms: 1900, transcript }], audio_duration_ms: 12000, model: 'muse-voice-transcribe-1.0', provider_session_id: `stub-${language}` };
    },
    async analyze(input) {
      calls.analyze++; calls.lastAnalyze = input;
      return analysis ?? { status: 'model_observation', observation: 'You reached the main point on the second attempt.', suggested_exercise: 'Answer once starting with "The main point is".', model: 'meta-models/muse-spark-open-1026', provider_request_id: 'stub-req' };
    }
  } };
}

async function withServer(models, fn) {
  const dir = mkdtempSync(join(tmpdir(), 'capture-test-'));
  const store = new Store(join(dir, 'test.sqlite'));
  store.addToken('alice-secret', 'alice'); store.addToken('bob-secret', 'bob'); store.addToken('reader-secret', 'alice', ['read']); store.seed('alice');
  const server = createApp(store, { models }); await new Promise(r => server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${server.address().port}`;
  const json = async (method, path, body, token = 'alice-secret', key = `json-${Math.random().toString(36).slice(2)}`) => {
    const r = await fetch(base + path, { method, headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', 'Idempotency-Key': key }, ...(body ? { body: JSON.stringify(body) } : {}) });
    return { status: r.status, data: await r.json() };
  };
  const upload = async (audio, { token = 'alice-secret', key = 'capture-key-1', headers = {} } = {}) => {
    const r = await fetch(base + '/v1/recordings', { method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'audio/wav', ...(key ? { 'Idempotency-Key': key } : {}), ...headers }, body: audio });
    return { status: r.status, data: await r.json() };
  };
  try { await fn({ json, upload, store }); } finally { await new Promise(r => server.close(r)); store.close(); rmSync(dir, { recursive: true, force: true }); }
}

test('measure counts English and French habits conservatively', () => {
  const en = measure('Um, so I think the main point is, uh, basically ship it. Sorry, let me restart. I would like to ship it it now.', 12000, 'en');
  assert.equal(en.filler_count, 3); // um, uh, basically; "like" is deliberately not counted
  assert.equal(en.hedge_count, 1);
  assert.equal(en.restarts['let me restart'], 1);
  assert.equal(en.immediate_repeats, 1);
  assert.equal(en.restart_count, 2, 'repeats are reported separately, not as restarts');
  assert.equal(en.words_per_minute, Math.round(en.word_count / 0.2));
  const fr = measure("Euh, du coup je pense que, euh, j'en ai besoin. Pardon, je recommence : j'en ai besoin demain.", 10000, 'fr');
  assert.equal(fr.fillers.euh, 2); assert.equal(fr.fillers['du coup'], 1); assert.equal(fr.hedge_count, 1);
  assert.equal(fr.restarts.pardon, 1); assert.equal(fr.restarts['je recommence'], 1);
});

test('inspectWav rejects unsupported audio before inference', () => {
  assert.equal(inspectWav(wav(2)).durationMs, 2000);
  assert.throws(() => inspectWav(Buffer.from('not audio at all, definitely not a wav file header')), { code: 'unsupported_audio' });
  assert.throws(() => inspectWav(wav(2, 44100)), { code: 'unsupported_audio' });
  assert.throws(() => inspectWav(wav(0.2)), { code: 'unsupported_audio' });
});

test('analysis client treats empty reasoning-model content as unavailable, not success', async () => {
  const fetchImpl = async () => new Response(JSON.stringify({ choices: [{ message: { content: null } }] }), { status: 200 });
  const result = await createModelClients({ env: { BASETEN_API_KEY: 'k' }, fetchImpl }).analyze({ goal: null, transcript: 't', metrics: measure('t', 1000, 'en'), language: 'en' });
  assert.equal(result.status, 'unavailable');
});

test('capture creates a measured, goal-linked session visible to fresh reads; retries never re-bill', async () => {
  const { models, calls } = stubModels();
  await withServer(models, async ({ json, upload }) => {
    const goal = (await json('POST', '/v1/goals', { title: 'Answer clearly', target: 'Main point first, then one detail.' })).data.record;
    const first = await upload(wav(), { headers: { 'X-Goal-Id': goal.id, 'X-Capture-Device': 'watch', 'X-Language': 'en' } });
    assert.equal(first.status, 200);
    const s = first.data.record;
    assert.equal(s.source, 'capture'); assert.equal(s.measurement_status, 'measured'); assert.equal(s.capture_device, 'watch');
    assert.equal(s.goal_id, goal.id); assert.equal(s.audio_retained, false);
    assert.equal(s.metrics.filler_count, 2); assert.equal(s.metrics.duration_ms, 12000);
    assert.equal(s.analysis.status, 'model_observation');
    assert.deepEqual(calls.lastAnalyze.goal.title, 'Answer clearly');

    const retry = await upload(wav(), { headers: { 'X-Goal-Id': goal.id, 'X-Capture-Device': 'watch', 'X-Language': 'en' } });
    assert.equal(retry.data.replayed, true); assert.equal(retry.data.receipt_id, first.data.receipt_id);
    assert.equal(calls.transcribe, 1, 'exact retry must not call transcription again');

    const conflict = await upload(wav(3), { headers: { 'X-Goal-Id': goal.id, 'X-Capture-Device': 'watch' } });
    assert.equal(conflict.status, 409); assert.equal(calls.transcribe, 1);

    const overview = (await json('GET', '/v1/overview')).data;
    const g = overview.goals.find(x => x.id === goal.id);
    assert.equal(g.progress.measured_sessions, 1); assert.equal(g.progress.measured_improvement, null);
    assert.equal(g.latest_measurement.id, s.id); assert.equal(overview.totals.measured_sessions, 1);
    const focused = (await json('GET', `/v1/goals/${goal.id}/context`)).data;
    assert.deepEqual(focused.linked_sessions.map(x => x.id), [s.id]);
    assert.ok(focused.shared_evidence.every(x => !x.goal_id));
    const receipts = (await json('GET', '/v1/receipts')).data.receipts;
    assert.ok(receipts.some(r => r.receipt_id === first.data.receipt_id));
  });
});

test('capture validates before spending and saves nothing on transcription failure', async () => {
  const { models, calls } = stubModels({ failTranscribe: true });
  await withServer(models, async ({ json, upload }) => {
    assert.equal((await upload(wav(), { token: 'reader-secret' })).status, 403);
    assert.equal((await upload(wav(), { key: null })).status, 400);
    assert.equal((await upload(Buffer.from('x'.repeat(100)), { key: 'bad-audio-1' })).status, 400);
    assert.equal((await upload(wav(), { key: 'bad-lang-1', headers: { 'X-Language': 'de' } })).status, 400);
    assert.equal((await upload(wav(), { key: 'missing-goal', headers: { 'X-Goal-Id': 'no-such-goal' } })).status, 404);
    assert.equal(calls.transcribe, 0, 'no inference before validation passes');
    const failed = await upload(wav(), { key: 'fails-upstream' });
    assert.equal(failed.status, 502); assert.equal(failed.data.error, 'transcription_failed');
    const ctx = (await json('GET', '/v1/context')).data;
    assert.equal(ctx.sessions.filter(x => x.source === 'capture').length, 0);
    assert.equal((await json('GET', '/v1/receipts')).data.receipts.length, 0);
  });
});

test('a French capture still saves measured evidence when analysis is unavailable, and stays user-scoped', async () => {
  const { models } = stubModels({ transcript: "Euh, du coup, j'en ai besoin pour la réunion.", analysis: { status: 'unavailable', reason: 'Analysis timed out.' } });
  await withServer(models, async ({ json, upload }) => {
    const r = await upload(wav(), { key: 'french-capture-1', headers: { 'X-Language': 'fr', 'X-Capture-Device': 'mac', 'X-Occurred-At': '2026-11-01T22:00:00Z' } });
    assert.equal(r.status, 200);
    assert.equal(r.data.record.language, 'fr'); assert.equal(r.data.record.metrics.filler_count, 2);
    assert.equal(r.data.record.analysis.status, 'unavailable'); assert.equal(r.data.record.occurred_at, '2026-11-01T22:00:00.000Z');
    const bob = (await json('GET', '/v1/context', null, 'bob-secret')).data;
    assert.equal(bob.sessions.length, 0);
  });
});

test('review regressions: inherited names, double counting, dashes, offsets, measured-session edits', async () => {
  const both = measure('What I mean is we ship.', 10000, 'en');
  assert.equal(both.restart_count, 1); assert.equal(both.filler_count, 0, 'a phrase counts in one category only');
  assert.equal(measure('Well - I think -- so', 6000, 'en').word_count, 4);
  assert.equal(measure('Vous vous trompez.', 3000, 'fr').restart_count, 0);
  const { models, calls } = stubModels();
  await withServer(models, async ({ json, upload }) => {
    assert.equal((await upload(wav(), { key: 'inherited-1', headers: { 'X-Language': 'toString' } })).status, 400);
    assert.equal(calls.transcribe, 0);
    const r = await upload(wav(), { key: 'offset-1', headers: { 'X-Occurred-At': '2026-11-01T10:00:00-07:00' } });
    assert.equal(r.data.record.occurred_at, '2026-11-01T17:00:00.000Z');
    const edit = await json('PATCH', `/v1/sessions/${r.data.record.id}`, { expected_version: 1, transcript: 'Edited', correction_reason: 'test' });
    assert.equal(edit.status, 400); assert.equal(edit.data.error, 'measured_session_immutable');
    const hide = await json('PATCH', `/v1/sessions/${r.data.record.id}`, { expected_version: 1, deleted: true, correction_reason: 'Wrong clip' });
    assert.equal(hide.status, 200);
  });
});

test('analysis retries once when the reasoning budget runs out, and parses wrapped JSON', async () => {
  const { parseObject } = await import('../src/capture.mjs');
  assert.deepEqual(parseObject('Here you go:\n```json\n{"a":1}\n```'), { a: 1 });
  assert.equal(parseObject('{"observation": "cut off mid'), null);
  const bodies = [];
  const replies = [
    { choices: [{ finish_reason: 'length', message: { content: '{"observation": "You asked' } }] },
    { choices: [{ finish_reason: 'stop', message: { content: 'Sure. {"observation":"Grounded.","suggested_exercise":"Try once."}' } }] }
  ];
  const fetchImpl = async (url, init) => { bodies.push(JSON.parse(init.body)); return new Response(JSON.stringify(replies.shift()), { status: 200 }); };
  const result = await createModelClients({ env: { BASETEN_API_KEY: 'k' }, fetchImpl }).analyze({ goal: null, transcript: 't', metrics: measure('t', 1000, 'en'), language: 'en' });
  assert.equal(result.status, 'model_observation'); assert.equal(result.attempts, 2);
  assert.ok(bodies[1].max_tokens > bodies[0].max_tokens);
});

test('recording releases the database during model calls and reacquires it even when transcription fails', async () => {
  for (const failTranscribe of [false, true]) {
    const { models } = stubModels({ failTranscribe });
    const events = [];
    const wrapped = { transcribe: async (...a) => { events.push('transcribe'); return models.transcribe(...a); }, analyze: async (...a) => { events.push('analyze'); return models.analyze(...a); } };
    const dir = mkdtempSync(join(tmpdir(), 'phases-test-'));
    const store = new Store(join(dir, 't.sqlite')); store.addToken('alice-secret', 'alice'); store.seed('alice');
    const phases = { async release() { events.push('release'); store.close(); }, async acquire() { events.push('acquire'); store.reopen(); } };
    const server = createApp(store, { models: wrapped, phases }); await new Promise(r => server.listen(0, '127.0.0.1', r));
    try {
      const r = await fetch(`http://127.0.0.1:${server.address().port}/v1/recordings`, { method: 'POST', headers: { Authorization: 'Bearer alice-secret', 'Content-Type': 'audio/wav', 'Idempotency-Key': 'phase-test-1' }, body: wav() });
      assert.equal(r.status, failTranscribe ? 502 : 200);
      assert.deepEqual(events, failTranscribe ? ['release', 'transcribe', 'acquire'] : ['release', 'transcribe', 'analyze', 'acquire']);
    } finally { await new Promise(r => server.close(r)); store.close(); rmSync(dir, { recursive: true, force: true }); }
  }
});
