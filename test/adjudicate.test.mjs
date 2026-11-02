// Spark Open labels ambiguous lexicon hits; code accepts only labels it can check and never lets a count grow.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { adjudicationCandidates, verifyLabels, buildAdjudication, adjudicateCapture, createAdjudicationModel, adjudicationSystemPrompt, ALWAYS_HABIT,
  MODEL_ONLY, MAX_MODEL_ONLY_CANDIDATES, modelOnlyCandidates } from '../src/adjudicate.mjs';
import { loadHeldout, goldSpans, runHeldout, scoreHeldout, rescore, applyRules, stubFetch, heldoutPlan, RULES } from '../src/heldout.mjs';
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

// Model-only words: "like", "genre" and "quoi", behind ADJUDICATE_MODEL_ONLY.
const LIKE = "I like the plan, it's, like, mostly done. I think so.";
const sha = s => createHash('sha256').update(s).digest('hex');
const chatReply = content => new Response(JSON.stringify({ id: 'req', choices: [{ message: { content } }] }), { status: 200 });

test('with the flag off, candidates, stored adjudications and request bodies are byte-identical to before the model-only words', async () => {
  // Hashes computed with the adjudication code as it was before model-only words existed, on the 70 corpus items and 60 held-out transcripts.
  const corpus = JSON.parse(readFileSync(new URL('../eval/corpus.json', import.meta.url), 'utf8')).items.map(i => [i.text.replace(/\[[FHR]:([^\]]*)\]/g, '$1'), i.language]);
  const texts = [...corpus, ...loadHeldout().set.transcripts.map(t => [t.text, t.language])];
  const out = [], bodies = [];
  for (const [t, l] of texts) {
    const { candidates } = adjudicationCandidates(t, l);
    out.push(candidates, buildAdjudication(t, l, null), buildAdjudication(t, l, { status: 'model_labels', labels: candidates.map((c, n) => ({ id: c.id, quote: c.quote, label: n % 2 ? 'habit' : 'content', reason: 'r' })), model: 'm', provider_request_id: 'r', attempts: 1 }));
    await adjudicateCapture({ models: createAdjudicationModel({ env: { BASETEN_API_KEY: 'k' }, fetchImpl: async (u, init) => { bodies.push(init.body); return chatReply('{"labels":[]}'); } }), transcript: t, language: l });
  }
  assert.equal(texts.length, 130);
  assert.equal(sha(JSON.stringify(out)), 'ce50de39fa2eda597f4d026bbf151f7c43e76317cc0381345dbde2d0070b41bc');
  assert.equal(bodies.length, 72);
  assert.equal(sha(bodies.join('\n')), '6c3647cff8f0ae5e31f58671714a89e3a008183e8a4eee860fa5ed27f2240db8');
  assert.ok(out.every(x => Array.isArray(x) || !('model_only' in x)), 'no model_only block with the flag off');
});

test('the flag is on only when ADJUDICATE_MODEL_ONLY is exactly "1"', () => {
  assert.deepEqual(MODEL_ONLY, { en: ['like'], fr: ['genre', 'quoi'] });
  for (const [value, on] of [['1', true], [undefined, false], ['0', false], ['true', false], ['yes', false], [' 1', false]])
    assert.equal(createAdjudicationModel({ env: value === undefined ? {} : { ADJUDICATE_MODEL_ONLY: value } }).adjudicateModelOnly, on, String(value));
});

test('with the flag on, every model-only word follows the lexicon candidates as m1, m2, ... with its exact span; the prompt is unchanged', async () => {
  const { candidates } = adjudicationCandidates(LIKE, 'en', { modelOnly: true });
  assert.deepEqual(candidates.map(c => [c.id, c.category, c.quote]), [['c1', 'hedges', 'I think'], ['m1', 'fillers', 'like'], ['m2', 'fillers', 'like']]);
  for (const c of candidates) assert.equal(LIKE.slice(c.start, c.end), c.quote);
  assert.equal(candidates[2].before, "I like the plan, it's, "); assert.equal(candidates[2].after, ', mostly done. I think so');
  assert.deepEqual(modelOnlyCandidates('Genre, on livre quoi ? Ce genre de truc, quoi.', 'fr').candidates.map(c => [c.id, c.quote]), [['m1', 'Genre'], ['m2', 'quoi'], ['m3', 'genre'], ['m4', 'quoi']]);
  assert.deepEqual(modelOnlyCandidates('I likely unlike it. Pourquoi ?', 'en').candidates, [], 'only whole words');
  assert.deepEqual(modelOnlyCandidates('Genre, quoi.', 'en').candidates, [], 'per language');
  const bodies = [];
  const model = { ...createAdjudicationModel({ env: { BASETEN_API_KEY: 'k', ADJUDICATE_MODEL_ONLY: '1' }, fetchImpl: async (u, init) => { bodies.push(JSON.parse(init.body)); return chatReply('{"labels":[]}'); } }) };
  await adjudicateCapture({ models: model, transcript: LIKE, language: 'en' });
  assert.equal(bodies[0].messages[0].content, adjudicationSystemPrompt('en'));
  assert.equal(bodies[0].reasoning_effort, 'low');
  assert.deepEqual(JSON.parse(bodies[0].messages[1].content).candidates.map(c => [c.id, c.kind, c.quote]), [['c1', 'hedge', 'I think'], ['m1', 'filler', 'like'], ['m2', 'filler', 'like']]);
  // A transcript whose only ambiguous words are model-only words is sent with the flag on, and not without it.
  let calls = 0;
  const counting = on => ({ adjudicateModelOnly: on, async adjudicateHabits() { calls++; return { status: 'model_labels', labels: [] }; } });
  assert.equal((await adjudicateCapture({ models: counting(false), transcript: 'It was like, done.', language: 'en' })).status, 'no_candidates'); assert.equal(calls, 0);
  const on = await adjudicateCapture({ models: counting(true), transcript: 'It was like, done.', language: 'en' });
  assert.equal(calls, 1); assert.equal(on.status, 'no_candidates'); assert.equal(on.model_only.status, 'not_counted');
});

test('model_only is counted only when every model-only word has a verified label, and never touches metrics or the lexicon counts', () => {
  const { candidates } = adjudicationCandidates(LIKE, 'en', { modelOnly: true });
  const labels = [label('c1', 'I think', 'content'), label('m1', 'like', 'content'), label('m2', 'like', 'habit')];
  const build = (l, opts = { modelOnly: true }) => buildAdjudication(LIKE, 'en', { status: 'model_labels', labels: l, model: ANALYSIS_MODEL, provider_request_id: 'r', attempts: 1 }, opts);
  const good = build(labels);
  assert.equal(good.model_only.status, 'counted'); assert.equal(good.model_only.reason, null);
  assert.deepEqual(good.model_only.counts, { like: 1 });
  assert.deepEqual(good.model_only.candidates.map(c => [c.id, c.label, c.counted]), [['m1', 'content', false], ['m2', 'habit', true]]);
  // Everything outside model_only is exactly the flag-off record for the same reply.
  const { model_only, ...rest } = good;
  assert.deepEqual(rest, build(labels.slice(0, 1), {}));
  assert.deepEqual(good.lexicon_count, { restarts: 0, fillers: 0, hedges: 1 }); assert.equal(good.adjudicated_count.fillers, 0);
  assert.equal(measure(LIKE, 5000, 'en').filler_count, 0, 'metrics never see the model-only words');
  // Fail closed: one missing, re-quoted, invalid or duplicated label and nothing is counted.
  for (const bad of [labels.slice(0, 2), [...labels.slice(0, 2), label('m2', 'Like', 'habit')], [...labels.slice(0, 2), label('m2', 'like', 'filler')], [...labels, label('m2', 'like', 'content')]]) {
    const r = build(bad);
    assert.equal(r.model_only.status, 'not_counted'); assert.equal(r.model_only.counts, null); assert.match(r.model_only.reason, /1 of 2 model-only labels/);
    assert.ok(r.model_only.candidates.every(c => !c.counted));
  }
  const unavailable = buildAdjudication(LIKE, 'en', { status: 'unavailable', reason: 'Adjudication timed out.' }, { modelOnly: true });
  assert.equal(unavailable.model_only.status, 'not_counted'); assert.equal(unavailable.model_only.reason, 'Adjudication timed out.');
  const none = buildAdjudication('Um, ship it.', 'en', null, { modelOnly: true });
  assert.equal(none.model_only.status, 'counted'); assert.deepEqual(none.model_only.counts, { like: 0 }, 'no model-only words: zero, decided by code');
  const many = Array.from({ length: MAX_MODEL_ONLY_CANDIDATES + 1 }, () => 'like').join(', ');
  const over = adjudicationCandidates(many, 'en', { modelOnly: true });
  assert.equal(over.candidates.length, MAX_MODEL_ONLY_CANDIDATES); assert.equal(over.model_only_over_cap, 1);
  const capped = buildAdjudication(many, 'en', { status: 'model_labels', labels: over.candidates.map(c => label(c.id, c.quote, 'habit')) }, { modelOnly: true });
  assert.equal(capped.model_only.status, 'not_counted'); assert.match(capped.model_only.reason, /More than 20/);
  const fr = buildAdjudication('Genre, on livre quoi ? Bon, quoi.', 'fr', { status: 'model_labels', labels: [label('m1', 'Genre', 'habit'), label('m2', 'quoi', 'content'), label('m3', 'quoi', 'habit')] }, { modelOnly: true });
  assert.deepEqual(fr.model_only.counts, { genre: 1, quoi: 1 });
});

test('a capture keeps metrics and both counts unchanged with the flag on, and adds model_only beside them', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'model-only-test-'));
  const store = new Store(join(dir, 't.sqlite')); store.addToken('a-secret', 'u'); store.seed('u');
  const transcript = "Um, I think it's, like, done.";
  const base = {
    async transcribe() { return { transcript, turns: [], audio_duration_ms: 6000, model: 'muse-voice-transcribe-1.0', provider_session_id: 'p' }; },
    async analyze() { return { status: 'model_observation', observation: 'o', suggested_exercise: 'e', model: ANALYSIS_MODEL, provider_request_id: 'r' }; },
    async adjudicateHabits({ candidates }) { return { status: 'model_labels', model: ANALYSIS_MODEL, provider_request_id: 'adj', attempts: 1, labels: candidates.map(c => label(c.id, c.quote, 'habit')) }; }
  };
  const run = async (models, key, seconds) => {
    const server = createApp(store, { models }); await new Promise(r => server.listen(0, '127.0.0.1', r));
    try { return (await fetch(`http://127.0.0.1:${server.address().port}/v1/recordings`, { method: 'POST', headers: { Authorization: 'Bearer a-secret', 'Content-Type': 'audio/wav', 'Idempotency-Key': key }, body: wav(seconds) }).then(r => r.json())).record; }
    finally { await new Promise(r => server.close(r)); }
  };
  try {
    const off = await run(base, 'model-only-off', 2), on = await run({ ...base, adjudicateModelOnly: true }, 'model-only-on', 3);
    assert.equal('model_only' in off.adjudication, false);
    assert.deepEqual(on.adjudication.model_only.counts, { like: 1 }); assert.equal(on.adjudication.model_only.status, 'counted');
    assert.equal(on.metrics.filler_count, off.metrics.filler_count); assert.equal(on.metrics.filler_count, 1, '"Um" only');
    assert.deepEqual(on.adjudication.lexicon_count, off.adjudication.lexicon_count);
    assert.deepEqual(on.adjudication.adjudicated_count, off.adjudication.adjudicated_count);
  } finally { store.close(); rmSync(dir, { recursive: true, force: true }); }
});

test('held-out set: every label resolves to one span, and the counts match what the file states', () => {
  const { set } = loadHeldout(), items = set.transcripts;
  const all = items.flatMap(i => goldSpans(i).map(g => ({ ...g, language: i.language })));
  const n = (family, value) => all.filter(g => g.family === family && g.label === value).length;
  assert.equal(items.length, 60); assert.equal(items.filter(i => i.language === 'en').length, 30);
  assert.deepEqual([n('like', 'filler'), n('like', 'content'), n('genre', 'filler'), n('genre', 'content'), n('quoi', 'filler'), n('quoi', 'content'), n('hedge', 'hedge'), n('hedge', 'not_hedge')], [24, 23, 9, 8, 11, 11, 31, 13]);
  // Every model-only word in the text is labelled, so code proposes exactly the labelled occurrences.
  for (const item of items) assert.deepEqual(modelOnlyCandidates(item.text, item.language).candidates.map(c => c.start), goldSpans(item).filter(g => g.family !== 'hedge').map(g => g.start).sort((a, b) => a - b), item.id);
  assert.deepEqual(heldoutPlan(items), { calls: 60, max_calls_with_retries: 120, model: ANALYSIS_MODEL });
});

test('held-out scoring: an all-habit stub equals the lexicon and count-all; gold replies score 1; the rules apply their thresholds', async () => {
  const items = loadHeldout().set.transcripts;
  const score = async labelOf => { const fetchImpl = stubFetch(labelOf); const { adjudications, records } = await runHeldout({ models: createAdjudicationModel({ env: { BASETEN_API_KEY: 'k' }, fetchImpl }), items }); return { score: scoreHeldout(items, adjudications), records, calls: fetchImpl.calls }; };
  const stub = await score();
  assert.equal(stub.calls, 60);
  const m = stub.score.classes.model_only, h = stub.score.classes.hedge;
  assert.deepEqual(m.model_only, m.count_all); assert.deepEqual(m.lexicon, m.count_none); assert.deepEqual(h.adjudication, h.lexicon);
  assert.deepEqual([m.count_all.precision, m.count_all.recall, m.count_all.f1, m.count_none.f1], [0.512, 1, 0.677, 0]);
  assert.deepEqual([h.lexicon.precision, h.lexicon.recall, h.lexicon.tp, h.lexicon.fp, h.lexicon.fn], [0.676, 0.742, 23, 11, 8]);
  assert.equal(h.model_only, null);
  assert.deepEqual(rescore(items, stub.records), stub.score, 'the stored labels recompute the same score');
  // Gold replies: the label each held-out occurrence has, so the scorer must find every one.
  const gold = new Map(items.map(i => [i.text, goldSpans(i)]));
  const goldLabel = c => {
    const item = items.find(i => i.text.includes(c.before + c.quote + c.after));
    const g = gold.get(item.text).find(g => g.start === item.text.indexOf(c.before + c.quote + c.after) + c.before.length);
    return !g ? 'habit' : g.family === 'hedge' ? (g.label === 'hedge' ? 'habit' : 'content') : g.label === 'filler' ? 'habit' : 'content';
  };
  const oracle = await score(goldLabel);
  const om = oracle.score.classes.model_only, oh = oracle.score.classes.hedge;
  assert.deepEqual([om.model_only.precision, om.model_only.recall, om.model_only.f1], [1, 1, 1]);
  assert.deepEqual([oh.adjudication.precision, oh.adjudication.recall], [1, 0.742], 'adjudication can remove false hedges, never find unlisted ones');
  const oracleRules = applyRules(oracle.score);
  assert.equal(oracleRules.rule1_model_only_ships.pass, true); assert.equal(oracleRules.rule2_hedges_leave_adjudication.fires, false);
  const stubRules = applyRules(stub.score);
  assert.equal(stubRules.rule1_model_only_ships.pass, false, 'count-all does not beat count-all');
  // Rule 2 fires only above the pre-registered drop; rule 1 needs the precision floor.
  const fake = (precision, f1, lexR, adjR) => ({ classes: { model_only: { model_only: { precision, f1 }, count_all: { f1: 0.677 }, count_none: { f1: 0 } }, hedge: { lexicon: { recall: lexR }, adjudication: { recall: adjR } } } });
  assert.deepEqual(RULES, { model_only_precision_floor: 0.8, hedge_recall_drop: 0.2 });
  assert.equal(applyRules(fake(0.79, 0.9, 0.7, 0.5)).rule1_model_only_ships.pass, false);
  assert.equal(applyRules(fake(0.8, 0.678, 0.7, 0.5)).rule1_model_only_ships.pass, true);
  assert.equal(applyRules(fake(0.95, 0.677, 0.7, 0.5)).rule1_model_only_ships.pass, false, 'a tie with count-all does not ship');
  assert.equal(applyRules(fake(1, 1, 0.742, 0.542)).rule2_hedges_leave_adjudication.fires, false, 'a drop of exactly 0.2 does not fire');
  assert.equal(applyRules(fake(1, 1, 0.742, 0.5)).rule2_hedges_leave_adjudication.fires, true);
});
