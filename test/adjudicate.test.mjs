// Spark Open labels ambiguous lexicon hits; code accepts only labels it can check and never lets a count grow.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { adjudicationCandidates, verifyLabels, buildAdjudication, adjudicateCapture, createAdjudicationModel, adjudicationSystemPrompt, ALWAYS_HABIT } from '../src/adjudicate.mjs';
import { measure, ANALYSIS_MODEL, ANALYSIS_BUDGETS } from '../src/capture.mjs';
import { Store } from '../src/store.mjs';
import { createApp } from '../src/server.mjs';

const TEXT = 'Um, what kind of report do you need? I think it is, you know, kind of late.';
const label = (id, quote, value, reason = 'Short reason.') => ({ id, quote, label: value, reason });

test('code proposes every ambiguous hit with its exact span and neighbouring words; pure vocal fillers are not sent', () => {
  const { candidates, hits } = adjudicationCandidates(TEXT, 'en');
  assert.deepEqual(candidates.map(c => [c.id, c.category, c.quote]), [['c1', 'hedges', 'kind of'], ['c2', 'hedges', 'I think'], ['c3', 'fillers', 'you know'], ['c4', 'hedges', 'kind of']]);
  assert.equal(hits.length, 5, '"Um" is a hit but not a candidate');
  assert.equal(candidates[0].before, 'Um, what '); assert.equal(candidates[0].after, ' report do you need? I think');
  for (const c of candidates) assert.equal(TEXT.slice(c.start, c.end), c.quote);
  assert.deepEqual(adjudicationCandidates('Euh, bah, um.', 'fr').candidates, []);
  assert.deepEqual(ALWAYS_HABIT, { en: ['um', 'uh', 'erm'], fr: ['euh', 'bah'] });
});

test('a label counts only if it names a proposed id once, copies the quote exactly and has a valid label and reason', () => {
  const { candidates } = adjudicationCandidates(TEXT, 'en');
  const { results, ignored } = verifyLabels(candidates, [
    label('c1', 'kind of', 'content'),
    label('c2', 'i think', 'content'),              // case differs from the transcript
    label('c3', 'you know', 'filler'),              // not a label code accepts
    label('c4', 'kind of', 'habit'), label('c4', 'kind of', 'content'), // conflicting duplicate
    label('c9', 'like', 'habit'), 'junk', null       // invented candidate and junk are ignored
  ]);
  assert.deepEqual(results.map(r => [r.id, r.verified, r.rejection, r.counted]),
    [['c1', true, null, false], ['c2', false, 'quote_mismatch', true], ['c3', false, 'invalid_label', true], ['c4', false, 'duplicate_id', true]]);
  assert.equal(ignored, 3);
  const noReason = verifyLabels(candidates.slice(0, 1), [{ id: 'c1', quote: 'kind of', label: 'content', reason: '  ' }]).results[0];
  assert.equal(noReason.rejection, 'missing_reason');
  assert.equal(verifyLabels(candidates.slice(0, 1), []).results[0].rejection, 'missing');
  const long = verifyLabels(candidates.slice(0, 1), [label('c1', 'kind of', 'content', 'word '.repeat(80) + '\nsecond line')]).results[0];
  assert.ok(long.reason.length <= 160 && !long.reason.includes('\n'));
});

test('the adjudicated count never exceeds the lexicon count and keeps both numbers', () => {
  const m = measure(TEXT, 10_000, 'en');
  const all = labels => buildAdjudication(TEXT, 'en', { status: 'model_labels', labels, model: ANALYSIS_MODEL, provider_request_id: 'r', attempts: 1 });
  const good = all([label('c1', 'kind of', 'content'), label('c2', 'I think', 'habit'), label('c3', 'you know', 'habit'), label('c4', 'kind of', 'habit')]);
  assert.equal(good.status, 'adjudicated');
  assert.deepEqual(good.lexicon_count, { restarts: m.restart_count, fillers: m.filler_count, hedges: m.hedge_count });
  assert.deepEqual(good.adjudicated_count, { restarts: 0, fillers: 2, hedges: 2 });
  assert.equal(good.summary.content, 1); assert.equal(good.summary.always_habit, 1);
  const everything = all([1, 2, 3, 4].map(n => label(`c${n}`, adjudicationCandidates(TEXT, 'en').candidates[n - 1].quote, 'content')).concat([label('c5', 'Um', 'habit')]));
  assert.deepEqual(everything.adjudicated_count, { restarts: 0, fillers: 1, hedges: 0 }, '"Um" is never removable and nothing is added');
  const partial = all([label('c1', 'kind of', 'content')]);
  assert.equal(partial.status, 'partial'); assert.equal(partial.summary.rejected, 3);
  const rejected = all([label('c1', 'kind of report', 'content')]);
  assert.equal(rejected.status, 'fallback'); assert.deepEqual(rejected.adjudicated_count, rejected.lexicon_count);
  const failed = buildAdjudication(TEXT, 'en', { status: 'unavailable', reason: 'Adjudication timed out.', attempts: 2 });
  assert.equal(failed.status, 'fallback'); assert.equal(failed.reason, 'Adjudication timed out.'); assert.deepEqual(failed.adjudicated_count, failed.lexicon_count);
  assert.equal(buildAdjudication('Um, ship it.', 'en', null).status, 'no_candidates');
});

test('the model client sends one Spark Open request with the candidates, falls back on a refusal, and needs a key', async () => {
  const bodies = [];
  const replies = ["I can't help with that.", '{"labels": [{"id": "c1", "quote": "kind of", "label": "content", "reason": "Part of what kind of report."}]}'];
  const fetchImpl = async (url, init) => { bodies.push(JSON.parse(init.body)); return new Response(JSON.stringify({ id: 'req-9', choices: [{ message: { content: replies.shift() } }] }), { status: 200 }); };
  const model = createAdjudicationModel({ env: { BASETEN_API_KEY: 'k' }, fetchImpl });
  const result = await adjudicateCapture({ models: model, transcript: 'What kind of report?', language: 'en' });
  assert.equal(bodies.length, 2, 'a refusal is retried once with the larger budget, like every Spark call');
  assert.deepEqual(bodies.map(b => b.max_tokens), ANALYSIS_BUDGETS);
  assert.ok(bodies.every(b => b.model === ANALYSIS_MODEL && b.temperature === 0 && b.messages[0].content === adjudicationSystemPrompt('en')));
  const user = JSON.parse(bodies[0].messages[1].content);
  assert.deepEqual(user, { transcript: 'What kind of report?', candidates: [{ id: 'c1', kind: 'hedge', before: 'What ', quote: 'kind of', after: ' report' }] });
  assert.equal(result.status, 'adjudicated'); assert.equal(result.adjudicated_count.hedges, 0); assert.equal(result.provider_request_id, 'req-9'); assert.equal(result.attempts, 2);
  const refused = await adjudicateCapture({ models: createAdjudicationModel({ env: { BASETEN_API_KEY: 'k' }, fetchImpl: async () => new Response(JSON.stringify({ choices: [{ message: { content: 'No.' } }] })) }), transcript: 'What kind of report?', language: 'en' });
  assert.equal(refused.status, 'fallback'); assert.equal(refused.adjudicated_count.hedges, 1);
  let called = 0;
  const unconfigured = await adjudicateCapture({ models: createAdjudicationModel({ env: {}, fetchImpl: async () => { called++; } }), transcript: 'What kind of report?', language: 'en' });
  assert.equal(called, 0); assert.equal(unconfigured.status, 'fallback'); assert.match(unconfigured.reason, /not configured/);
  const thrown = await adjudicateCapture({ models: { adjudicateHabits: async () => { throw new Error('boom'); } }, transcript: 'What kind of report?', language: 'en' });
  assert.equal(thrown.status, 'fallback');
});

function wav(seconds = 2, rate = 16000) {
  const data = Buffer.alloc(Math.round(seconds * rate) * 2), h = Buffer.alloc(44);
  h.write('RIFF', 0); h.writeUInt32LE(36 + data.length, 4); h.write('WAVE', 8); h.write('fmt ', 12); h.writeUInt32LE(16, 16);
  h.writeUInt16LE(1, 20); h.writeUInt16LE(1, 22); h.writeUInt32LE(rate, 24); h.writeUInt32LE(rate * 2, 28); h.writeUInt16LE(2, 32); h.writeUInt16LE(16, 34); h.write('data', 36); h.writeUInt32LE(data.length, 40);
  return Buffer.concat([h, data]);
}

test('a capture stores both counts beside unchanged metrics; a retry or an unambiguous clip makes no adjudication call', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'adjudicate-test-'));
  const store = new Store(join(dir, 't.sqlite')); store.addToken('a-secret', 'u'); store.seed('u');
  let transcript = 'Um, what kind of report? I think, uh, the short one.';
  const calls = { adjudicate: 0, analyze: [] };
  const models = {
    async transcribe() { return { transcript, turns: [], audio_duration_ms: 6000, model: 'muse-voice-transcribe-1.0', provider_session_id: 'p' }; },
    async analyze(input) { calls.analyze.push(input); return { status: 'model_observation', observation: 'o', suggested_exercise: 'e', model: ANALYSIS_MODEL, provider_request_id: 'r' }; },
    async adjudicateHabits({ candidates }) { calls.adjudicate++; return { status: 'model_labels', model: ANALYSIS_MODEL, provider_request_id: 'adj-1', attempts: 1,
      labels: candidates.map(c => label(c.id, c.quote, c.quote === 'kind of' ? 'content' : 'habit')) }; }
  };
  const server = createApp(store, { models }); await new Promise(r => server.listen(0, '127.0.0.1', r));
  const post = (key, audio = wav()) => fetch(`http://127.0.0.1:${server.address().port}/v1/recordings`, { method: 'POST', headers: { Authorization: 'Bearer a-secret', 'Content-Type': 'audio/wav', 'Idempotency-Key': key }, body: audio }).then(r => r.json());
  try {
    const { record } = await post('adjudicate-1');
    assert.equal(record.metrics.hedge_count, 2, 'the measured lexicon count is unchanged');
    assert.equal(record.adjudication.status, 'adjudicated');
    assert.deepEqual(record.adjudication.lexicon_count, { restarts: 0, fillers: 2, hedges: 2 });
    assert.deepEqual(record.adjudication.adjudicated_count, { restarts: 0, fillers: 2, hedges: 1 });
    assert.equal(record.adjudication.provider_request_id, 'adj-1');
    assert.equal(calls.analyze[0].metrics.hedge_count, 2, 'the observation still sees the lexicon count');
    assert.equal((await post('adjudicate-1')).replayed, true);
    assert.equal(calls.adjudicate, 1, 'an exact retry does not pay again');
    transcript = 'Um, the short one, uh.';
    const plain = (await post('adjudicate-2', wav(3))).record;
    assert.equal(plain.adjudication.status, 'no_candidates'); assert.equal(calls.adjudicate, 1);
  } finally { await new Promise(r => server.close(r)); store.close(); rmSync(dir, { recursive: true, force: true }); }
});
