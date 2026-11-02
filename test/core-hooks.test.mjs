// Extension points another product uses to reuse this core. Defaults must stay exactly as before.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Store, ApiError, digest } from '../src/store.mjs';
import { createApp, validate, bodyOf, audioOf, captureParams, requireIdempotencyKey, handleRecording, NO_PHASES } from '../src/server.mjs';
import { createModelClients, measure, analysisSystemPrompt } from '../src/capture.mjs';

function wav(seconds = 1.5, rate = 16000) {
  const samples = Math.round(seconds * rate), data = Buffer.alloc(samples * 2);
  for (let i = 0; i < samples; i++) data.writeInt16LE(Math.round(Math.sin(i / 5) * 2000), i * 2);
  const h = Buffer.alloc(44); h.write('RIFF', 0); h.writeUInt32LE(36 + data.length, 4); h.write('WAVE', 8); h.write('fmt ', 12); h.writeUInt32LE(16, 16);
  h.writeUInt16LE(1, 20); h.writeUInt16LE(1, 22); h.writeUInt32LE(rate, 24); h.writeUInt32LE(rate * 2, 28); h.writeUInt16LE(2, 32); h.writeUInt16LE(16, 34); h.write('data', 36); h.writeUInt32LE(data.length, 40);
  return Buffer.concat([h, data]);
}

async function analyzeBody(extra = {}) {
  let body;
  const fetchImpl = async (url, init) => { body = init.body; return new Response(JSON.stringify({ choices: [{ message: { content: '{"observation":"o","suggested_exercise":"e"}' } }] }), { status: 200 }); };
  const metrics = measure('Um, I think we ship it. Sorry, let me restart.', 6000, 'fr');
  await createModelClients({ env: { BASETEN_API_KEY: 'k' }, fetchImpl }).analyze({ goal: { title: 'Be concise', target: 'Fewer fillers' }, transcript: 'Um, I think we ship it.', metrics, language: 'fr', ...extra });
  return body;
}

test('analyze: the default request is byte-for-byte unchanged; a custom system prompt replaces only the system message', async () => {
  const body = await analyzeBody();
  // Hash of the request body produced before the hook existed (commit 9314c77).
  assert.equal(createHash('sha256').update(body).digest('hex'), 'a3a59c9c4addc4d85e6581d5861f313681da8d68b487e821e60ce8833f616b10');
  assert.equal(JSON.parse(body).messages[0].content, analysisSystemPrompt('fr'));
  const custom = JSON.parse(await analyzeBody({ system: 'You are a French tutor. Reply with JSON only.' }));
  const original = JSON.parse(body);
  assert.equal(custom.messages[0].content, 'You are a French tutor. Reply with JSON only.');
  assert.deepEqual({ ...custom, messages: [custom.messages[1]] }, { ...original, messages: [original.messages[1]] });
});

test('server helpers are exported for reuse', () => {
  for (const fn of [validate, bodyOf, audioOf, captureParams, requireIdempotencyKey, handleRecording]) assert.equal(typeof fn, 'function');
  assert.deepEqual(captureParams({ 'x-language': 'fr', 'x-capture-device': 'watch' }), { language: 'fr', device: 'watch', goalId: null, occurredAt: null });
  assert.throws(() => requireIdempotencyKey({ 'idempotency-key': 'short' }), { code: 'idempotency_required' });
  assert.equal(typeof NO_PHASES.release, 'function');
});

function withStore(options, fn) {
  const dir = mkdtempSync(join(tmpdir(), 'hooks-test-'));
  const store = new Store(join(dir, 'db.sqlite'), options);
  store.addToken('hooks-secret', 'u1'); store.seed('u1');
  return Promise.resolve(fn(store)).finally(() => { store.close(); rmSync(dir, { recursive: true, force: true }); });
}

test('freshContext: default revision covers the four core kinds; extendFresh adds fields and revision inside the snapshot', async () => {
  await withStore({}, store => {
    const fresh = store.freshContext('u1'), c = store.context('u1');
    assert.equal(fresh.snapshot_revision, digest(JSON.stringify({ goals: c.goals, exercises: c.exercises, check_ins: c.check_ins, sessions: c.sessions })));
  });
  const seen = [];
  await withStore({ extendFresh({ user, goalId, context }) {
    seen.push({ inTransaction: this.db.isTransaction, goalId, sessions: context.sessions.length });
    const items = this.list(user, 'items');
    return { fields: { items, item_count: items.length }, revision: items };
  } }, store => {
    const before = store.freshContext('u1');
    assert.deepEqual(before.items, []); assert.equal(before.item_count, 0);
    store.put('u1', 'items', { id: 'item-1', version: 1, text: 'je suis allé' });
    const after = store.freshContext('u1');
    assert.equal(after.item_count, 1);
    assert.notEqual(after.snapshot_revision, before.snapshot_revision, 'a change in an extended kind changes the revision');
    assert.deepEqual(seen[0], { inTransaction: true, goalId: undefined, sessions: 2 });
  });
});

test('handleRecording hooks: extra params are fingerprinted, prepare runs before models, afterAnalyze feeds extendRecord in one transaction', async () => {
  const calls = { transcribe: 0, analyze: [], after: 0 };
  const models = {
    async transcribe() { calls.transcribe++; return { transcript: 'Euh, je suis allé au marché.', turns: [], audio_duration_ms: 1500, model: 'muse-voice-transcribe-1.0', provider_session_id: 'p' }; },
    async analyze(input) { calls.analyze.push(input); return { status: 'model_observation', observation: 'o', suggested_exercise: 'e', model: 'm', provider_request_id: 'r' }; }
  };
  const recordingHooks = {
    params(headers) {
      const base = captureParams({ ...headers, 'x-language': headers['x-language'] ?? 'fr' });
      const consent = headers['x-consent-basis'] ?? null;
      if (!['self_only', 'all_parties'].includes(consent)) throw new ApiError(400, 'consent_required', 'X-Consent-Basis is required.');
      return { ...base, consent_basis: consent };
    },
    prepare({ extra }) { if (extra.consent_basis === 'all_parties') throw new ApiError(400, 'not_supported', 'Only self captures here.'); return { checked: true }; },
    system: ({ params }) => `Tutor for ${params.language}. JSON only.`,
    async afterAnalyze({ transcription, prepared }) { calls.after++; return { candidates: transcription.transcript.includes('allé') ? ['allé'] : [], prepared }; },
    extendRecord(record, { store, user, after, extra }) {
      store.put(user, 'items', { id: `item-${record.id}`, version: 1, evidence_id: record.id, text: after.candidates[0] });
      return { ...record, consent_basis: extra.consent_basis, candidate_count: after.candidates.length, prepared: after.prepared.checked };
    }
  };
  await withStore({}, async store => {
    const server = createApp(store, { models, recordingHooks }); await new Promise(r => server.listen(0, '127.0.0.1', r));
    const base = `http://127.0.0.1:${server.address().port}`;
    const upload = (key, headers = {}) => fetch(base + '/v1/recordings', { method: 'POST', body: wav(),
      headers: { Authorization: 'Bearer hooks-secret', 'Content-Type': 'audio/wav', 'Idempotency-Key': key, ...headers } }).then(async r => ({ status: r.status, data: await r.json() }));
    try {
      assert.equal((await upload('hooks-key-0')).data.error, 'consent_required');
      assert.equal((await upload('hooks-key-1', { 'X-Consent-Basis': 'all_parties' })).data.error, 'not_supported');
      assert.equal(calls.transcribe, 0, 'rejected before any model call');
      const first = await upload('hooks-key-2', { 'X-Consent-Basis': 'self_only' });
      assert.equal(first.status, 200);
      assert.equal(first.data.record.language, 'fr');
      assert.equal(first.data.record.consent_basis, 'self_only');
      assert.equal(first.data.record.candidate_count, 1);
      assert.equal(first.data.record.prepared, true);
      assert.equal(calls.analyze[0].system, 'Tutor for fr. JSON only.');
      assert.equal(store.get('u1', 'items', `item-${first.data.record.id}`).evidence_id, first.data.record.id);
      assert.equal(store.get('u1', 'sessions', first.data.record.id).consent_basis, 'self_only');
      const retry = await upload('hooks-key-2', { 'X-Consent-Basis': 'self_only' });
      assert.equal(retry.data.replayed, true); assert.equal(calls.transcribe, 1); assert.equal(calls.after, 1);
      const changed = await upload('hooks-key-2', { 'X-Consent-Basis': 'all_parties' });
      assert.equal(changed.status, 409, 'extra params are part of the idempotency fingerprint');
    } finally { await new Promise(r => server.close(r)); }
  });
});

test('handleRecording hooks cannot overwrite core fingerprint fields', async () => {
  await withStore({}, async store => {
    const req = { headers: { 'content-type': 'audio/wav' }, async *[Symbol.asyncIterator]() { yield wav(); } };
    const hooks = { params: () => ({ language: 'en', device: 'api', goalId: null, occurredAt: null, audio_sha256: 'forged' }) };
    await assert.rejects(handleRecording(store, {}, 'u1', req, 'hooks-key-9', 'req-1', NO_PHASES, hooks), /collides with a core field/);
  });
});
