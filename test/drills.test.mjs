// Drills: the assistant sets an exercise with a basis, code recounts it before saving, and a capture that names
// the drill records one measured check-in. No network, no paid calls.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { Store } from '../src/store.mjs';
import { createApp } from '../src/server.mjs';
import { checkDueAt, drillParams, DUE_MAX_DAYS, checkBasis, basisFreshness } from '../src/drills.mjs';

function wav(seconds = 1, rate = 16000, tone = 330) {
  const samples = Math.round(seconds * rate), data = Buffer.alloc(samples * 2);
  for (let i = 0; i < samples; i++) data.writeInt16LE(Math.round(Math.sin(2 * Math.PI * tone * i / rate) * 3000 + (i % 17) * 7), i * 2);
  const h = Buffer.alloc(44);
  h.write('RIFF', 0); h.writeUInt32LE(36 + data.length, 4); h.write('WAVE', 8); h.write('fmt ', 12); h.writeUInt32LE(16, 16);
  h.writeUInt16LE(1, 20); h.writeUInt16LE(1, 22); h.writeUInt32LE(rate, 24); h.writeUInt32LE(rate * 2, 28); h.writeUInt16LE(2, 32); h.writeUInt16LE(16, 34);
  h.write('data', 36); h.writeUInt32LE(data.length, 40);
  return Buffer.concat([h, data]);
}

async function withServer(fn) {
  const dir = mkdtempSync(join(tmpdir(), 'drill-test-'));
  const store = new Store(join(dir, 'drill.sqlite'));
  store.addToken('alice-secret', 'alice'); store.addToken('bob-secret', 'bob');
  store.seed('alice'); store.seed('bob');
  const calls = { transcribe: 0, analyze: 0, transcripts: [] };
  const models = {
    async transcribe() {
      calls.transcribe++;
      const transcript = calls.transcripts.shift() ?? 'We ship it today.';
      return { transcript, turns: [{ turn_id: 0, start_ms: 100, end_ms: 900, transcript }], audio_duration_ms: 3000, model: 'muse-voice-transcribe-1.0', provider_session_id: 'fake' };
    },
    async analyze() { calls.analyze++; return { status: 'model_observation', observation: 'o', suggested_exercise: 'e', model: 'fake', provider_request_id: 'fake' }; },
    async voiceReply() { return { status: 'model_reply', reply: { move: 'follow_up', quote: 'we ship', question: 'Why today?' }, model: 'fake', provider_request_id: 'fake', attempts: 1 }; }
  };
  const server = createApp(store, { models }); await new Promise(r => server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${server.address().port}`;
  const json = async (method, path, body, { token = 'alice-secret', key = randomUUID() } = {}) => {
    const r = await fetch(base + path, { method, headers: { Authorization: `Bearer ${token}`, 'Idempotency-Key': key, ...(body ? { 'Content-Type': 'application/json' } : {}) }, ...(body ? { body: JSON.stringify(body) } : {}) });
    return { status: r.status, data: await r.json() };
  };
  // One capture with the given transcript; headers add X-Goal-Id, X-Exercise-Id and so on.
  const capture = async (transcript, headers = {}, { token = 'alice-secret', key = randomUUID(), path = '/v1/recordings' } = {}) => {
    if (transcript !== null) calls.transcripts.push(transcript);
    const r = await fetch(base + path, { method: 'POST', body: wav(1.2), headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'audio/wav', 'Idempotency-Key': key, 'X-Capture-Device': 'watch', ...headers } });
    return { status: r.status, data: await r.json() };
  };
  const goal = async (token = 'alice-secret') => (await json('POST', '/v1/goals', { title: 'Say it plainly', target: 'Fewer hedges' }, { token })).data.record.id;
  try { await fn({ store, calls, json, capture, goal, base }); }
  finally { await new Promise(r => server.close(r)); store.close(); rmSync(dir, { recursive: true, force: true }); }
}

const drill = (goalId, basis, extra = {}) => ({ goal_id: goalId, title: 'Answer without hedges', instructions: 'Give the decision in one sentence, then one reason.', basis, ...extra });

test('a correct basis is saved with the recount; a wrong count returns 422 with the true count, and nothing is saved', async () => {
  await withServer(async ({ json, capture, goal }) => {
    const g = await goal();
    const a = (await capture('I think we should maybe ship it. I guess today.')).data.record; // 3 hedges
    const c = (await capture('Probably we ship.')).data.record; // 1 hedge
    assert.equal(a.metrics.hedge_count, 3); assert.equal(c.metrics.hedge_count, 1);

    const wrong = await json('POST', '/v1/exercises', drill(g, { habit: 'hedge', source_ids: [a.id, c.id], claimed_count: 3 }));
    assert.equal(wrong.status, 422);
    assert.equal(wrong.data.error, 'basis_mismatch');
    assert.deepEqual(wrong.data.recomputed, { habit: 'hedge', count: 4, per_source: [{ id: a.id, count: 3 }, { id: c.id, count: 1 }] });
    assert.match(wrong.data.message, /code counts 4/);
    assert.equal((await json('GET', `/v1/goals/${g}/context`)).data.exercises.length, 0, 'a refused basis saves nothing');

    const right = await json('POST', '/v1/exercises', drill(g, { habit: 'hedge', source_ids: [a.id, c.id], claimed_count: 4 }));
    assert.equal(right.status, 200);
    assert.ok(right.data.receipt_id);
    const ex = right.data.record;
    assert.equal(ex.set_via, 'connector'); assert.equal(ex.status, 'assigned');
    assert.deepEqual({ ...ex.basis, checked_at: null }, { habit: 'hedge', source_ids: [a.id, c.id], claimed_count: 4, checked_at: null,
      per_source: [{ id: a.id, kind: 'session', version: 1, count: 3 }, { id: c.id, kind: 'session', version: 1, count: 1 }], checked: 'recounted by the server from stored metrics' });
  });
});

test('voice rounds count toward a basis; fixtures, hidden sessions, other accounts and old captures are refused', async () => {
  await withServer(async ({ store, json, capture, goal }) => {
    const g = await goal();
    const round = (await capture('Maybe. Sort of.', {}, { path: '/v1/voice-rounds' })).data; // 2 hedges
    assert.ok(round.round_id, JSON.stringify(round));
    const ok = await json('POST', '/v1/exercises', drill(g, { habit: 'hedge', source_ids: [round.round_id], claimed_count: 2 }));
    assert.equal(ok.status, 200, JSON.stringify(ok.data));
    assert.equal(ok.data.record.basis.per_source[0].kind, 'voice_round');

    const g2 = await goal();
    const hidden = (await capture('I think so.')).data.record;
    assert.equal((await json('PATCH', `/v1/sessions/${hidden.id}`, { expected_version: 1, deleted: true, correction_reason: 'not me' })).status, 200);
    const bobs = (await capture('I think so.', {}, { token: 'bob-secret' })).data.record;
    const old = (await capture('I think so.', { 'X-Occurred-At': new Date(Date.now() - 15 * 86_400_000).toISOString() })).data.record;
    const refused = await json('POST', '/v1/exercises', drill(g2, { habit: 'hedge', source_ids: ['session-before', hidden.id, bobs.id, old.id, 'no-such-id'], claimed_count: 1 }));
    assert.equal(refused.status, 422);
    assert.equal(refused.data.error, 'basis_source_invalid');
    assert.deepEqual(refused.data.refused, [
      { id: 'session-before', reason: 'not_measured' }, { id: hidden.id, reason: 'deleted' }, { id: bobs.id, reason: 'not_found' },
      { id: old.id, reason: 'older_than_14_days' }, { id: 'no-such-id', reason: 'not_found' }]);
    assert.equal(store.list('alice', 'exercises').filter(e => e.goal_id === g2).length, 0);

    for (const basis of [{ habit: 'pause', source_ids: [old.id], claimed_count: 0 }, { habit: 'hedge', source_ids: [], claimed_count: 0 },
      { habit: 'hedge', source_ids: [old.id, old.id], claimed_count: 2 }, { habit: 'hedge', source_ids: [old.id], claimed_count: -1 },
      { habit: 'hedge', source_ids: [old.id], claimed_count: 1, note: 'x' }, ['hedge'], null])
      assert.equal((await json('POST', '/v1/exercises', drill(g2, basis))).status, 400, JSON.stringify(basis));
  });
});

test('one open drill per goal: a second is 409 until the first has a check-in; exercises without a basis are unaffected', async () => {
  await withServer(async ({ json, capture, goal }) => {
    const g = await goal();
    const s = (await capture('I think so.')).data.record;
    const first = (await json('POST', '/v1/exercises', drill(g, { habit: 'hedge', source_ids: [s.id], claimed_count: 1 }))).data.record;
    const second = await json('POST', '/v1/exercises', drill(g, { habit: 'hedge', source_ids: [s.id], claimed_count: 1 }));
    assert.equal(second.status, 409); assert.equal(second.data.error, 'drill_open'); assert.equal(second.data.open_exercise_id, first.id);
    const plain = await json('POST', '/v1/exercises', { goal_id: g, title: 'Read it aloud', instructions: 'Once.' });
    assert.equal(plain.status, 200);
    assert.deepEqual(Object.keys(plain.data.record).sort(), ['goal_id', 'id', 'instructions', 'status', 'title', 'updated_at', 'version'], 'no drill fields without a basis');
    const other = await goal();
    assert.equal((await json('POST', '/v1/exercises', drill(other, { habit: 'hedge', source_ids: [s.id], claimed_count: 1 }))).status, 200, 'another goal may have its own');
    assert.equal((await json('POST', '/v1/check-ins', { goal_id: g, exercise_id: first.id, status: 'skipped', feedback: 'Not today.' })).status, 200);
    assert.equal((await json('POST', '/v1/exercises', drill(g, { habit: 'hedge', source_ids: [s.id], claimed_count: 1 }))).status, 200);
  });
});

test('due_at: same morning is fine, at most 7 days ahead, not in the past', async () => {
  const now = Date.parse('2026-11-03T14:00:00Z');
  assert.equal(checkDueAt('2026-11-03T15:30:00Z', now), '2026-11-03T15:30:00.000Z', 'no 12-hour minimum');
  assert.equal(checkDueAt(new Date(now + DUE_MAX_DAYS * 86_400_000).toISOString(), now), '2026-11-10T14:00:00.000Z');
  assert.throws(() => checkDueAt(new Date(now + DUE_MAX_DAYS * 86_400_000 + 1000).toISOString(), now), /at most 7 days/);
  assert.throws(() => checkDueAt('2026-11-02T10:00:00Z', now), /past/);
  assert.throws(() => checkDueAt('tomorrow', now), /ISO 8601/);
  await withServer(async ({ json, capture, goal }) => {
    const g = await goal(), s = (await capture('I think so.')).data.record;
    const due = new Date(Date.now() + 90 * 60_000).toISOString();
    const r = await json('POST', '/v1/exercises', drill(g, { habit: 'hedge', source_ids: [s.id], claimed_count: 1 }, { due_at: due }));
    assert.equal(r.status, 200); assert.equal(r.data.record.due_at, due);
    assert.equal((await json('POST', '/v1/exercises', { goal_id: g, title: 't', instructions: 'i', due_at: new Date(Date.now() + 8 * 86_400_000).toISOString() })).status, 400);
  });
});

test('a capture with X-Exercise-Id records one measured check-in, once; a retry replays it', async () => {
  await withServer(async ({ store, calls, json, capture, goal }) => {
    const g = await goal();
    const a = (await capture('I think we should maybe ship it.')).data.record; // 2 hedges
    const b = (await capture('Probably today.')).data.record; // 1 hedge
    const ex = (await json('POST', '/v1/exercises', drill(g, { habit: 'hedge', source_ids: [a.id, b.id], claimed_count: 3 }))).data.record;

    const key = randomUUID();
    const result = await capture('We ship it today because the tests pass.', { 'X-Goal-Id': g, 'X-Exercise-Id': ex.id }, { key });
    assert.equal(result.status, 200);
    const session = result.data.record;
    assert.equal(session.drill.status, 'measured');
    assert.deepEqual(session.drill.measured, { habit: 'hedge', capture_count: 0, basis_count: 3, basis_sources: 2, basis_source_word: 'sessions', session_id: session.id, capture_device: 'watch' });
    const checkIns = (await json('GET', `/v1/goals/${g}/context`)).data.check_ins;
    assert.equal(checkIns.length, 1);
    const c = checkIns[0];
    assert.equal(c.id, session.drill.check_in_id); assert.equal(c.exercise_id, ex.id); assert.equal(c.status, 'completed');
    assert.equal(c.evidence_type, 'measured');
    assert.equal(c.feedback, `Measured by code: 0 unsure words in this capture (session ${session.id}). The drill's basis was 3 unsure words in 2 sessions. One measured result, not a trend.`);
    assert.doesNotMatch(c.feedback, /improv/i);

    const before = calls.transcribe;
    const retry = await capture(null, { 'X-Goal-Id': g, 'X-Exercise-Id': ex.id }, { key });
    assert.equal(retry.data.replayed, true); assert.equal(retry.data.record.drill.check_in_id, c.id); assert.equal(calls.transcribe, before, 'no model call on retry');
    assert.equal((await capture(null, { 'X-Goal-Id': g }, { key })).status, 409, 'the same key without the drill is a different request');

    const again = (await capture('Maybe later.', { 'X-Goal-Id': g, 'X-Exercise-Id': ex.id })).data.record;
    assert.deepEqual(again.drill, { exercise_id: ex.id, status: 'not_measured', reason: 'already_recorded' });
    assert.equal(store.list('alice', 'check-ins').length, 1, 'recorded once');

    const overview = (await json('GET', '/v1/overview')).data;
    const summary = overview.goals.find(x => x.id === g);
    assert.equal(summary.progress.self_reported_completions, 0, 'a measured check-in is not a self-report');
    assert.equal(summary.progress.pending_exercises, 0);
    assert.equal(summary.progress.measured_improvement, null);
  });
});

test('a drill without a basis is never measured; a wrong or unknown exercise is refused before any model call', async () => {
  await withServer(async ({ store, calls, json, capture, goal }) => {
    const g = await goal(), other = await goal();
    const plain = (await json('POST', '/v1/exercises', { goal_id: g, title: 'Read it aloud', instructions: 'Once.' })).data.record;
    const r = (await capture('I think so.', { 'X-Goal-Id': g, 'X-Exercise-Id': plain.id })).data.record;
    assert.deepEqual(r.drill, { exercise_id: plain.id, status: 'not_measured', reason: 'no_basis' });
    assert.equal(store.list('alice', 'check-ins').length, 0);

    const before = calls.transcribe;
    assert.equal((await capture(null, { 'X-Exercise-Id': 'no-such-exercise' })).status, 404);
    assert.equal((await capture(null, { 'X-Goal-Id': other, 'X-Exercise-Id': plain.id })).data.error, 'goal_mismatch');
    assert.equal((await capture(null, { 'X-Exercise-Id': plain.id }, { token: 'bob-secret' })).status, 404, "another account's exercise");
    assert.equal((await capture(null, { 'X-Exercise-Id': 'bad id!' })).status, 400);
    assert.equal(calls.transcribe, before, 'refused before transcription');

    const s = (await capture('Without a drill header.')).data.record;
    assert.equal('drill' in s, false, 'a capture without the header is unchanged');
  });
});

test('drillParams reads only X-Exercise-Id', () => {
  assert.equal(drillParams({}), null);
  assert.deepEqual(drillParams({ 'x-exercise-id': 'abc-123' }), { exerciseId: 'abc-123' });
  assert.throws(() => drillParams({ 'x-exercise-id': 'a/b' }), { code: 'invalid_value' });
});

// A bare store with one measured capture, for basis checks that need no HTTP server.
function withStore(fn) {
  const dir = mkdtempSync(join(tmpdir(), 'drill-basis-'));
  const store = new Store(join(dir, 'basis.sqlite'));
  store.put('alice', 'goals', { id: 'goal-a', version: 1, title: 'Pace', target: 'Slow down' });
  const capture = metrics => ({ id: 'capture-a', version: 1, source: 'capture', measurement_status: 'measured', goal_id: 'goal-a', deleted: false, occurred_at: new Date().toISOString(), metrics });
  try { return fn(store, capture); } finally { store.close(); rmSync(dir, { recursive: true, force: true }); }
}

test('a source without the habit metric counts 0 and stays current, as the basis check counted it', () => withStore((store, capture) => {
  store.put('alice', 'sessions', capture({ filler_count: 2 }));
  const basis = checkBasis(store, 'alice', 'goal-a', { habit: 'restart', source_ids: ['capture-a'], claimed_count: 0 });
  assert.equal(basis.per_source[0].count, 0);
  assert.deepEqual(basisFreshness(store, 'alice', basis), { status: 'current', stale_source_ids: [] });
  // A real change to the counted metric still makes the basis stale.
  store.put('alice', 'sessions', capture({ filler_count: 2, restart_count: 1 }));
  assert.deepEqual(basisFreshness(store, 'alice', { ...basis, per_source: [{ ...basis.per_source[0], version: undefined }] }), { status: 'stale', stale_source_ids: ['capture-a'] });
}));
