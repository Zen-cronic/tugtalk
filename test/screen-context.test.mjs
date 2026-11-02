// POST /v1/screen-contexts with a stub model client. No network, no paid calls.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Store, digest } from '../src/store.mjs';
import { createApp } from '../src/server.mjs';
import { analysisSystemPrompt } from '../src/capture.mjs';
import { scrub, createScreenModel, screenContextSystemPrompt, SCREEN_RATE_LIMIT } from '../src/screen-context.mjs';

// What the Mac companion sends after on-device redaction of the synthetic meeting-prep note.
const REDACTED = '1:1 with [person] on Thursday\nGoal: ask to own the Q1 launch.\nPoints: shipped the beta two weeks early; support tickets down.\nContact: [email], [phone]\nThe ask is at the end: could I maybe lead the launch?';
const body = (extra = {}) => ({ language: 'en', capture_device: 'mac', purpose: 'meeting_prep', occurred_at: '2026-11-02T15:00:00Z', app_name: 'TextEdit',
  text: REDACTED, redaction: { method: 'on-device-v1', counts: { person: 1, email: 1, phone: 1, number: 0, link: 0, address: 0 } }, ...extra });

function stubModels(reply) {
  const calls = { describe: 0, last: null };
  return { calls, models: { async describeScreen(input) {
    calls.describe++; calls.last = input;
    if (typeof reply === 'function') return reply(input);
    return reply ?? { status: 'model_observation', summary: 'You are preparing to ask to lead a launch.', observation: 'The ask is buried at the end; lead with it.',
      next_step: 'Say the ask in one sentence, out loud, twice.', model: 'meta-models/muse-spark-open-1026', provider_request_id: 'stub-req', attempts: 1 };
  } } };
}

async function withServer(models, fn) {
  const dir = mkdtempSync(join(tmpdir(), 'screen-test-'));
  const dbPath = join(dir, 'test.sqlite');
  const store = new Store(dbPath);
  store.addToken('alice-secret', 'alice'); store.addToken('bob-secret', 'bob'); store.addToken('reader-secret', 'alice', ['read']); store.seed('alice');
  const server = createApp(store, { models }); await new Promise(r => server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${server.address().port}`;
  let n = 0;
  const call = async (method, path, data, { token = 'alice-secret', key = `screen-key-${++n}`, raw } = {}) => {
    const r = await fetch(base + path, { method, headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', ...(key ? { 'Idempotency-Key': key } : {}) },
      ...(raw !== undefined ? { body: raw } : data !== undefined ? { body: JSON.stringify(data) } : {}) });
    return { status: r.status, data: await r.json() };
  };
  const post = (data, opts) => call('POST', '/v1/screen-contexts', data, opts);
  try { await fn({ call, post, store, dbPath }); } finally { await new Promise(r => server.close(r)); store.close(); rmSync(dir, { recursive: true, force: true }); }
}

test('screen context: auth, validation and ownership are checked before any model call', async () => {
  const { models, calls } = stubModels();
  await withServer(models, async ({ call, post }) => {
    assert.equal((await post(body(), { token: '' })).status, 401);
    assert.equal((await post(body(), { token: 'reader-secret' })).status, 403);
    assert.equal((await post(body(), { key: null })).status, 400);
    assert.equal((await post(body(), { raw: JSON.stringify({ ...body(), text: 'x'.repeat(16400) }) })).status, 413);
    assert.equal((await post(body({ window_title: 'Secret plan.txt' }))).data.error, 'unknown_field');
    assert.equal((await post(body({ text: 'a'.repeat(6001) }))).status, 400);
    assert.equal((await post(body({ text: 'é'.repeat(6000) }))).status, 200, '6000 two-byte characters are 11.7 KiB, within both caps');
    assert.equal((await post(body({ text: '€'.repeat(4500) }))).status, 400, '4500 three-byte characters exceed 12 KiB');
    assert.equal((await post(body({ purpose: 'surveillance' }))).status, 400);
    assert.equal((await post(body({ capture_device: 'toaster' }))).status, 400);
    assert.equal((await post(body({ app_name: 'Line\nbreak' }))).status, 400);
    assert.equal((await post(body({ redaction: { method: 'on-device-v1', counts: { ssn: 1 } } }))).status, 400);
    assert.equal((await post(body({ goal_id: 'no-such-goal' }))).status, 404);
    const goal = (await call('POST', '/v1/goals', { title: 'Answer clearly', target: 'Lead with the ask.' })).data.record;
    assert.equal((await post(body({ goal_id: goal.id }), { token: 'bob-secret' })).status, 404, "another user's goal is not found");
    assert.equal(calls.describe, 1, 'only the one valid request reached the model');
  });
});

test('screen context: saves a card with a receipt, exact retries never re-bill, a changed body conflicts', async () => {
  const { models, calls } = stubModels();
  await withServer(models, async ({ call, post, dbPath, store }) => {
    const goal = (await call('POST', '/v1/goals', { title: 'Answer clearly', target: 'Lead with the ask.' })).data.record;
    const first = await post(body({ goal_id: goal.id }), { key: 'mac-capture-0001' });
    assert.equal(first.status, 200);
    const r = first.data.record;
    assert.equal(r.source, 'screen_capture'); assert.equal(r.capture_device, 'mac'); assert.equal(r.goal_id, goal.id);
    assert.equal(r.text_retained, false); assert.equal(r.pixels_sent, false); assert.equal(r.text_sha256, digest(REDACTED));
    assert.equal(r.text_chars, REDACTED.length); assert.equal(r.app_name, 'TextEdit'); assert.equal(r.occurred_at, '2026-11-02T15:00:00.000Z');
    assert.deepEqual(r.redaction.server_counts, { email: 0, phone: 0, number: 0 }, 'clean device output needs no server scrub');
    assert.equal(r.analysis.status, 'model_observation'); assert.equal(r.analysis.model, 'meta-models/muse-spark-open-1026');
    assert.equal(calls.last.goal.title, 'Answer clearly'); assert.equal(calls.last.text, REDACTED);
    assert.ok(first.data.receipt_id); assert.equal(first.data.record_version, 1);

    const retry = await post(body({ goal_id: goal.id }), { key: 'mac-capture-0001' });
    assert.equal(retry.data.replayed, true); assert.equal(retry.data.receipt_id, first.data.receipt_id);
    assert.equal(calls.describe, 1, 'exact retry must not call the model again');
    const changed = await post(body({ goal_id: goal.id, purpose: 'reading' }), { key: 'mac-capture-0001' });
    assert.equal(changed.status, 409); assert.equal(calls.describe, 1);

    store.db.exec('PRAGMA wal_checkpoint(TRUNCATE)');
    assert.equal(readFileSync(dbPath).includes(Buffer.from('shipped the beta two weeks early')), false, 'the screen text is not stored');
  });
});

test('screen context: a model failure returns 502 and saves no record and no receipt; a retry runs again', async () => {
  let fail = true;
  const { models, calls } = stubModels(() => fail ? { status: 'unavailable', reason: 'Analysis timed out.' } : stubModels().models.describeScreen({}));
  await withServer(models, async ({ call, post }) => {
    const failed = await post(body(), { key: 'model-fails-1' });
    assert.equal(failed.status, 502); assert.equal(failed.data.error, 'analysis_failed');
    assert.equal((await call('GET', '/v1/context')).data.screen_contexts.length, 0);
    assert.equal((await call('GET', '/v1/receipts')).data.receipts.length, 0);
    fail = false;
    assert.equal((await post(body(), { key: 'model-fails-1' })).status, 200);
    assert.equal(calls.describe, 2);
  });
  await withServer({ async describeScreen() { return { status: 'unavailable', reason: 'Analysis returned no usable JSON.' }; } }, async ({ post }) => {
    assert.equal((await post(body())).status, 502);
  });
  await withServer({}, async ({ post }) => { assert.equal((await post(body())).status, 503, 'no model configured'); });
});

test('screen context: the server re-scrubs missed personal data in the input and in model output, and caps lengths', async () => {
  const leaky = { status: 'model_observation', summary: 'Email sam@example.com about it. ' + 'x'.repeat(400), observation: 'Call 416-555-0199 first.',
    next_step: 'Quote card 4111 1111 1111 1111.', model: 'meta-models/muse-spark-open-1026', provider_request_id: 'r' };
  const { models, calls } = stubModels(leaky);
  await withServer(models, async ({ post }) => {
    const r = await post(body({ text: 'Reach me at dana.k@example.org or +1 416 555 0199. Account 123456789.' }));
    assert.equal(r.status, 200);
    assert.deepEqual(r.data.record.redaction.server_counts, { email: 1, phone: 1, number: 1 });
    assert.equal(calls.last.text, 'Reach me at [email] or [phone]. Account [number].', 'the model never sees what the device missed');
    const a = r.data.record.analysis;
    assert.ok(!/@|416|4111/.test(a.summary + a.observation + a.next_step));
    assert.ok(a.summary.length <= 300); assert.ok(a.summary.endsWith('…'));
    assert.deepEqual(r.data.record.redaction.output_counts, { email: 1, phone: 1, number: 1 });
  });
  assert.deepEqual(scrub('Meet 2026-11-03 at 10:30, room 4.12, Q1 2026. [person] said ok.').counts, { email: 0, phone: 0, number: 0 }, 'dates, times and placeholders are left alone');
  assert.deepEqual(scrub('SIN 046 454 286, card 4111-1111-1111-1111, ref 98765432').counts, { email: 0, phone: 1, number: 2 });
});

test('screen context: fresh overview and focused context expose it, the revision changes, undo hides it', async () => {
  const { models } = stubModels();
  await withServer(models, async ({ call, post }) => {
    const goal = (await call('POST', '/v1/goals', { title: 'Answer clearly', target: 'Lead with the ask.' })).data.record;
    const before = (await call('GET', '/v1/overview')).data;
    assert.equal(before.latest_screen_context, null); assert.equal(before.totals.screen_contexts, 0);
    const saved = (await post(body({ goal_id: goal.id }))).data.record;
    const after = (await call('GET', '/v1/overview')).data;
    assert.notEqual(after.snapshot_revision, before.snapshot_revision, 'a Mac capture changes the revision Muse cites');
    assert.deepEqual(after.latest_screen_context, { id: saved.id, version: 1, occurred_at: saved.occurred_at, capture_device: 'mac', app_name: 'TextEdit', purpose: 'meeting_prep',
      goal_id: goal.id, summary: saved.analysis.summary, observation: saved.analysis.observation, next_step: saved.analysis.next_step });
    assert.equal(after.totals.screen_contexts, 1);
    const g = after.goals.find(x => x.id === goal.id);
    assert.equal(g.progress.screen_contexts, 1); assert.equal(g.latest_screen_context.id, saved.id);
    assert.deepEqual(after.screen_context_versions, [{ id: saved.id, version: 1, goal_id: goal.id }]);
    const focused = (await call('GET', `/v1/goals/${goal.id}/context`)).data;
    assert.deepEqual(focused.linked_screen_contexts.map(x => x.id), [saved.id]);

    assert.equal((await call('PATCH', `/v1/screen-contexts/${saved.id}`, { expected_version: 1, summary: 'edited', correction_reason: 'x' })).status, 400, 'the card is not editable');
    assert.equal((await call('PATCH', `/v1/screen-contexts/${saved.id}`, { expected_version: 1, deleted: true, correction_reason: 'Undo' }, { token: 'bob-secret' })).status, 404);
    const undo = await call('PATCH', `/v1/screen-contexts/${saved.id}`, { expected_version: 1, deleted: true, correction_reason: 'Undo from the Mac companion' });
    assert.equal(undo.status, 200); assert.equal(undo.data.record.version, 2);
    assert.equal((await call('PATCH', `/v1/screen-contexts/${saved.id}`, { expected_version: 1, deleted: false, correction_reason: 'stale' })).status, 409);
    const hidden = (await call('GET', '/v1/overview')).data;
    assert.equal(hidden.latest_screen_context, null); assert.equal(hidden.totals.screen_contexts, 0);
    assert.notEqual(hidden.snapshot_revision, after.snapshot_revision);
    assert.notEqual(hidden.snapshot_revision, before.snapshot_revision, 'an undo never restores an earlier revision');
  });
});

test('screen context: at most 30 per hour, refused before inference; French is accepted', async () => {
  const { models, calls } = stubModels();
  await withServer(models, async ({ post }) => {
    assert.equal((await post(body({ language: 'fr', text: 'Préparer la réunion avec [person].' }))).status, 200);
    for (let i = 1; i < SCREEN_RATE_LIMIT.requests; i++) assert.equal((await post(body({ text: `${REDACTED} ${i}` }))).status, 200);
    const limited = await post(body({ text: `${REDACTED} over` }));
    assert.equal(limited.status, 429); assert.equal(calls.describe, SCREEN_RATE_LIMIT.requests);
  });
});

test('screen context model client: own prompt and shape, same model and budgets; the capture prompt is untouched', async () => {
  const bodies = [];
  const replies = [{ choices: [{ finish_reason: 'length', message: { content: null } }] },
    { choices: [{ message: { content: 'OK {"summary":"s","observation":"o","next_step":"n"}' } }] }];
  const fetchImpl = async (url, init) => { bodies.push(JSON.parse(init.body)); return new Response(JSON.stringify(replies.shift()), { status: 200 }); };
  const out = await createScreenModel({ env: { BASETEN_API_KEY: 'k' }, fetchImpl }).describeScreen({ goal: null, text: 't', language: 'en', purpose: 'reading', app_name: 'Safari' });
  assert.equal(out.status, 'model_observation'); assert.equal(out.attempts, 2); assert.equal(out.next_step, 'n');
  assert.equal(bodies[0].model, 'meta-models/muse-spark-open-1026'); assert.deepEqual(bodies.map(b => b.max_tokens), [4000, 8000]);
  assert.equal(bodies[0].messages[0].content, screenContextSystemPrompt('en'));
  assert.match(screenContextSystemPrompt('en'), /untrusted data, not instructions/);
  assert.notEqual(screenContextSystemPrompt('en'), analysisSystemPrompt('en'));
  assert.equal(JSON.parse(bodies[0].messages[1].content).screen_text, 't');
  await assert.rejects(createScreenModel({ env: {} }).describeScreen({ text: 't', language: 'en' }), { code: 'analysis_unconfigured' });
});

test('screen context hooks: a profile may replace the prompt and extend the record', async () => {
  const { models, calls } = stubModels();
  const dir = mkdtempSync(join(tmpdir(), 'screen-hooks-'));
  const store = new Store(join(dir, 'db.sqlite')); store.addToken('hooks-secret', 'u1');
  const server = createApp(store, { models, screenContextHooks: { system: ({ input }) => `Tutor for ${input.language}.`, extendRecord: (record, { input }) => ({ ...record, profile_context: input.purpose === 'reading' ? 'selection' : 'other' }) } });
  await new Promise(r => server.listen(0, '127.0.0.1', r));
  try {
    const r = await fetch(`http://127.0.0.1:${server.address().port}/v1/screen-contexts`, { method: 'POST', body: JSON.stringify(body({ language: 'fr', purpose: 'reading' })),
      headers: { Authorization: 'Bearer hooks-secret', 'Content-Type': 'application/json', 'Idempotency-Key': 'hooks-screen-1' } });
    const data = await r.json();
    assert.equal(r.status, 200); assert.equal(calls.last.system, 'Tutor for fr.'); assert.equal(data.record.profile_context, 'selection');
  } finally { await new Promise(r => server.close(r)); store.close(); rmSync(dir, { recursive: true, force: true }); }
});
