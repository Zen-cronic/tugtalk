// Every paid request answers inside the hosting adapter's deadline, so a retry finds its receipt instead of paying again.
// A fake clock throughout: slow fake providers advance it instead of sleeping. No network, no paid calls.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Readable } from 'node:stream';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Store } from '../src/store.mjs';
import { createHandler, RECORDING_RATE_LIMIT } from '../src/server.mjs';
import { createModelClients } from '../src/capture.mjs';
import { createAdjudicationModel } from '../src/adjudicate.mjs';
import { createVoiceModel } from '../src/voice.mjs';
import { createBudget, MODEL_BUDGET_MS, ADAPTER_DEADLINE_MS, MIN_START_MS } from '../src/budget.mjs';

const S = 1000;
const TRANSCRIPT = 'Um, I think we should, sort of, ship the smaller version first because we can test it this week.';

function wav(seconds = 1) {
  const data = Buffer.alloc(Math.round(seconds * 16000) * 2);
  for (let i = 0; i < data.length / 2; i++) data.writeInt16LE(Math.round(Math.sin(i / 5) * 2000), i * 2);
  const h = Buffer.alloc(44);
  h.write('RIFF', 0); h.writeUInt32LE(36 + data.length, 4); h.write('WAVE', 8); h.write('fmt ', 12); h.writeUInt32LE(16, 16);
  h.writeUInt16LE(1, 20); h.writeUInt16LE(1, 22); h.writeUInt32LE(16000, 24); h.writeUInt32LE(32000, 28); h.writeUInt16LE(2, 32); h.writeUInt16LE(16, 34);
  h.write('data', 36); h.writeUInt32LE(data.length, 40);
  return Buffer.concat([h, data]);
}

// A shared fake clock. A call started at time t that takes d ends at t + d even when calls overlap, as real time would.
function fakeClock() {
  const clock = { now: 0 };
  clock.read = () => clock.now;
  clock.take = async ms => { const end = clock.now + ms; await new Promise(r => setImmediate(r)); clock.now = Math.max(clock.now, end); };
  return clock;
}

// Real Meta and Baseten clients over a fake fetch. Each provider call takes the given fake seconds and returns `reply`.
function slowProviders(clock, { asr = 1, analysis = 1, adjudication = 1, reply = 1, empty = false } = {}) {
  const sent = { asr: 0, analysis: 0, adjudication: 0, reply: 0 };
  const chat = content => new Response(JSON.stringify({ choices: [{ message: { content }, finish_reason: empty ? 'length' : 'stop' }] }), { status: 200 });
  const fetchImpl = async (url, init) => {
    if (url.includes('/asr/')) { sent.asr++; await clock.take(asr * S); return new Response(JSON.stringify({ transcript: TRANSCRIPT, sessionId: 'p', turns: [{ turnId: 0, startMs: 100, endMs: 900 }] }), { status: 200 }); }
    const body = JSON.parse(init.body);
    if (body.stream) {
      sent.reply++; await clock.take(reply * S);
      const event = `data: ${JSON.stringify({ choices: [{ delta: { content: '{"move":"challenge","quote":"I think","question":"What makes you sure?"}' }, finish_reason: 'stop' }] })}\n\ndata: [DONE]\n\n`;
      return new Response(event, { status: 200, headers: { 'content-type': 'text/event-stream' } });
    }
    if (/check a word-list count/.test(body.messages[0].content)) { sent.adjudication++; await clock.take(adjudication * S); return chat(empty ? '' : '{"labels":[]}'); }
    sent.analysis++; await clock.take(analysis * S);
    return chat(empty ? '' : '{"observation":"Short and clear.","suggested_exercise":"Say it again."}');
  };
  // Hedges sent (v1 adjudication), so the hedge-only clips still make an adjudication call to time.
  const env = { MODEL_API_KEY: 'test', BASETEN_API_KEY: 'test', ADJUDICATE_HEDGES: '1' };
  return { sent, models: { ...createModelClients({ env, fetchImpl }), ...createAdjudicationModel({ env, fetchImpl }), ...createVoiceModel({ env, fetchImpl }) } };
}

// The handler called the way the hosting worker calls it, so a test can pass budgetMs as the adapter does.
// budgetClock: the clock the request budget reads; one that never moves gives the old, unbudgeted behaviour.
async function withHandler(models, clock, fn, { budgetClock = clock.read } = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'budget-test-'));
  const store = new Store(join(dir, 'budget.sqlite'));
  store.addToken('budget-secret', 'budget-user'); store.seed('budget-user');
  const handler = createHandler(store, { models, clock: budgetClock });
  const call = async (path, { key, budgetMs, audio = wav(), token = 'budget-secret' } = {}) => {
    const req = Readable.from([audio]);
    Object.assign(req, { method: 'POST', url: path, headers: { authorization: `Bearer ${token}`, 'content-type': 'audio/wav', 'idempotency-key': key }, budgetMs });
    let out;
    const res = { writeHead(status) { this.status = status; }, end(body) { out = { status: this.status, data: JSON.parse(body) }; }, write() {}, on() {} };
    const started = clock.now;
    await handler(req, res);
    return { ...out, elapsed: clock.now - started };
  };
  try { await fn({ call, store }); } finally { store.close(); rmSync(dir, { recursive: true, force: true }); }
}

test('a budget refuses a step without enough time before any network call, and cuts off a call when it runs out', async () => {
  let now = 0, sent = 0, signal;
  const b = createBudget({ totalMs: 30_000, clock: () => now });
  const fetchImpl = async (url, init) => { sent++; signal = init.signal; return new Response('{}'); };
  const step = b.fetch(fetchImpl, { step: 'analysis', minStartMs: 15_000 });
  await step('https://x'); assert.equal(sent, 1); assert.ok(signal instanceof AbortSignal);
  now = 20_000; // 10 s left
  await assert.rejects(step('https://x'), e => e.budgetRefused && e.name === 'TimeoutError');
  assert.equal(sent, 1, 'refused without sending');
  assert.equal(b.allows(10_000), true); assert.equal(b.allows(15_000), false);
  now = 99_000; assert.equal(b.remaining(), 0);
  assert.equal(ADAPTER_DEADLINE_MS - MODEL_BUDGET_MS, 30_000, 'the budget ends 30 s before the adapter answers');
});

test('worst-case recording: without the budget it runs 160 s, past the 150 s deadline; with it, it saves a partial session by 110 s', async () => {
  // Transcription takes 60 s, its own cut-off. Every Spark call takes 50 s, its own cut-off, and comes back empty, so each wants a retry.
  const worst = { asr: 60, analysis: 50, adjudication: 50, empty: true };
  const unbounded = fakeClock(), before = slowProviders(unbounded, worst);
  await withHandler(before.models, unbounded, async ({ call }) => {
    const r = await call('/v1/recordings', { key: 'worst-unbounded' });
    assert.equal(r.status, 200);
    assert.equal(r.elapsed, 160_000); assert.ok(r.elapsed > ADAPTER_DEADLINE_MS, 'the old path answers after the adapter has given up');
    assert.deepEqual(before.sent, { asr: 1, analysis: 2, adjudication: 2, reply: 0 });
  }, { budgetClock: () => 0 });
  const clock = fakeClock(), { sent, models } = slowProviders(clock, worst);
  await withHandler(models, clock, async ({ call }) => {
    const r = await call('/v1/recordings', { key: 'worst-budgeted' });
    assert.equal(r.status, 200);
    assert.equal(r.elapsed, 110_000); assert.ok(r.elapsed <= MODEL_BUDGET_MS);
    assert.deepEqual(sent, { asr: 1, analysis: 1, adjudication: 1, reply: 0 }, 'neither retry was sent: 10 s left is under the 15 s a Spark call needs');
    const s = r.data.record;
    assert.equal(s.measurement_status, 'measured'); assert.equal(s.metrics.word_count, 19, 'code-measured numbers are saved');
    assert.equal(s.analysis.status, 'unavailable'); assert.match(s.analysis.reason, /not enough time/);
    assert.equal(s.adjudication.status, 'fallback'); assert.match(s.adjudication.reason, /not enough time/);
    const again = await call('/v1/recordings', { key: 'worst-budgeted' });
    assert.equal(again.data.replayed, true); assert.equal(again.elapsed, 0);
    assert.deepEqual(sent, { asr: 1, analysis: 1, adjudication: 1, reply: 0 }, 'the retry paid for nothing');
  });
});

test('slow transcription leaves no time for Spark: the session saves with its measured numbers and the lexicon count', async () => {
  const clock = fakeClock(), { sent, models } = slowProviders(clock, { asr: 110 });
  await withHandler(models, clock, async ({ call }) => {
    const r = await call('/v1/recordings', { key: 'slow-asr' });
    assert.equal(r.status, 200); assert.equal(r.elapsed, 110_000);
    assert.deepEqual(sent, { asr: 1, analysis: 0, adjudication: 0, reply: 0 });
    assert.equal(r.data.record.analysis.status, 'unavailable');
    assert.equal(r.data.record.adjudication.status, 'fallback');
    assert.deepEqual(r.data.record.adjudication.adjudicated_count, r.data.record.adjudication.lexicon_count);
  });
});

test('behind the adapter the budget is what is left of the deadline: too little and the request is refused before any paid call', async () => {
  const clock = fakeClock(), { sent, models } = slowProviders(clock);
  await withHandler(models, clock, async ({ call }) => {
    const refused = await call('/v1/recordings', { key: 'late-start', budgetMs: MIN_START_MS.transcription - 1 });
    assert.equal(refused.status, 503); assert.equal(refused.data.error, 'time_budget');
    const voice = await call('/v1/voice-rounds', { key: 'late-voice', budgetMs: 2_000 });
    assert.equal(voice.status, 503); assert.equal(voice.data.error, 'time_budget');
    assert.deepEqual(sent, { asr: 0, analysis: 0, adjudication: 0, reply: 0 }, 'nothing was sent or billed');
    // The same key later, with time to spare, runs normally: nothing was saved, so there is nothing to replay.
    const ok = await call('/v1/recordings', { key: 'late-start' });
    assert.equal(ok.status, 200); assert.equal(ok.data.replayed, false);
  });
});

test('a voice round answers before its budget runs out: with no time left for the reply it is a 502, and no reply call is made', async () => {
  const clock = fakeClock(), { sent, models } = slowProviders(clock, { asr: 58 });
  await withHandler(models, clock, async ({ call }) => {
    const r = await call('/v1/voice-rounds', { key: 'voice-late', budgetMs: 60_000 });
    assert.equal(r.status, 502); assert.equal(r.data.error, 'reply_failed'); assert.match(r.data.message, /not enough time/);
    assert.ok(r.elapsed <= 60_000);
    assert.deepEqual(sent, { asr: 1, analysis: 0, adjudication: 0, reply: 0 });
    const ok = await call('/v1/voice-rounds', { key: 'voice-ok' });
    assert.equal(ok.status, 200); assert.equal(ok.data.reply.move, 'challenge'); assert.equal(sent.reply, 1);
  });
});

test(`at most ${RECORDING_RATE_LIMIT.requests} recordings per hour per user, refused before any model call; exact retries still replay`, async () => {
  const clock = fakeClock(), { sent, models } = slowProviders(clock, { asr: 0, analysis: 0, adjudication: 0 });
  await withHandler(models, clock, async ({ call, store }) => {
    let saved = 0;
    let last;
    while (saved < 100 && (last = await call('/v1/recordings', { key: `rate-key-${saved}`, audio: wav(0.6 + saved / 1000) })).status === 200) saved++;
    assert.equal(last.status, 429, JSON.stringify(last.data));
    assert.equal(saved, RECORDING_RATE_LIMIT.requests);
    const before = { ...sent };
    const refused = await call('/v1/recordings', { key: 'rate-extra', audio: wav(0.9) });
    assert.equal(refused.status, 429); assert.equal(refused.data.error, 'rate_limited');
    assert.deepEqual(sent, before, 'refused before any model call');
    const replay = await call('/v1/recordings', { key: 'rate-key-0', audio: wav(0.6) });
    assert.equal(replay.status, 200); assert.equal(replay.data.replayed, true);
    // The count is per user: another account is not limited.
    store.addToken('other-secret', 'other-user');
    assert.equal((await call('/v1/recordings', { key: 'other-key-1', token: 'other-secret' })).status, 200);
  });
});
