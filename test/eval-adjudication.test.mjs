// The adjudicated eval arm runs the real checking code on scripted model replies; the live arm is planned, not run.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { runEval, runLiveAdjudication, scriptedAdjudication, scriptedModelResult, parseItem, measureCounts, CORPUS_URL, SCRIPTED_URL } from '../src/evaluate.mjs';
import { createAdjudicationModel, adjudicationCandidates } from '../src/adjudicate.mjs';
import { ANALYSIS_MODEL } from '../src/capture.mjs';

const committed = JSON.parse(readFileSync(new URL('../eval/results.json', import.meta.url), 'utf8'));
const corpus = JSON.parse(readFileSync(CORPUS_URL, 'utf8')).items.map(i => ({ ...i, ...parseItem(i.text) }));
const fixtures = JSON.parse(readFileSync(SCRIPTED_URL, 'utf8'));
const scripted = new Map(fixtures.items.map(f => [f.id, f]));
const ROOT = fileURLToPath(new URL('..', import.meta.url));

test('the scripted arm is labelled as scripted everywhere it is reported', () => {
  assert.match(committed.adjudication.label, /^Scripted adjudication outputs, not live model runs\.$/);
  assert.match(committed.adjudication_headline, /scripted adjudication outputs \(not live model runs\)/);
  assert.match(fixtures.provenance, /^Scripted adjudication outputs, not live model runs\./);
  assert.match(committed.systems.adjudicated_scripted.describe, /scripted adjudication outputs/);
});

test('adjudication only removes hits: per item it never exceeds the lexicon, and clean controls stay at zero', () => {
  for (const item of corpus) {
    const adjudicated = scriptedAdjudication(item, scripted).adjudicated_count, lexicon = measureCounts(item.transcript, item.language);
    for (const c of ['fillers', 'hedges', 'restarts']) assert.ok(adjudicated[c] <= lexicon[c], `${item.id} ${c}`);
  }
  assert.equal(committed.systems.adjudicated_scripted.negative_control.false_counts, 0);
  const a = committed.systems.adjudicated_scripted.overall, m = committed.systems.measure.overall;
  assert.ok(a.precision > m.precision, 'removing verified content hits raises precision');
  assert.ok(a.tp + a.fn === m.tp + m.fn, 'same gold');
});

test('each scripted fault meets the check it was written to exercise', () => {
  const expected = { quote_mismatch: 'quote_mismatch', invalid_label: 'invalid_label', missing: 'missing', duplicate_id: 'duplicate_id', missing_reason: 'missing_reason' };
  for (const f of fixtures.items) {
    const item = corpus.find(i => i.id === f.id), result = scriptedAdjudication(item, scripted);
    if (expected[f.fault]) assert.ok(result.candidates.some(c => c.rejection === expected[f.fault]), `${f.id} ${f.fault}`);
    if (f.fault === 'invented_candidate') { assert.equal(result.summary.ignored_entries, 1); assert.equal(result.status, 'adjudicated'); }
    if (f.fault === 'truncated_then_recovered') { assert.equal(result.attempts, 2); assert.equal(result.status, 'adjudicated'); }
    if (f.fault === 'no_json') { assert.equal(result.status, 'fallback'); assert.deepEqual(result.adjudicated_count, result.lexicon_count); }
    if (f.fault === 'wrong_label') assert.ok(result.candidates.every(c => c.verified), `${f.id}: a well-formed wrong label passes the check`);
    if (f.fault === null) assert.equal(result.status, 'adjudicated', f.id);
  }
  assert.equal(committed.adjudication.accepted_labels_against_gold.wrong, fixtures.items.filter(f => f.fault === 'wrong_label').length);
  assert.equal(scriptedModelResult(['nope', 'still nope', '{"labels":[]}']).status, 'unavailable', 'never more replies than the retry budget');
});

test('the live plan counts one call per item with candidates, and the live arm makes exactly that many when replies are good', async () => {
  const withCandidates = corpus.filter(i => adjudicationCandidates(i.transcript, i.language).candidates.length);
  assert.deepEqual(committed.adjudication.live_plan, { model: ANALYSIS_MODEL, calls: withCandidates.length, max_calls_with_retries: withCandidates.length * 2,
    candidates: withCandidates.reduce((n, i) => n + adjudicationCandidates(i.transcript, i.language).candidates.length, 0) });
  let calls = 0;
  const fetchImpl = async (url, init) => {
    calls++;
    const { candidates } = JSON.parse(JSON.parse(init.body).messages[1].content);
    const labels = candidates.map(c => ({ id: c.id, quote: c.quote, label: 'habit', reason: 'r' }));
    return new Response(JSON.stringify({ id: `live-${calls}`, choices: [{ message: { content: JSON.stringify({ labels }) } }] }), { status: 200 });
  };
  const live = await runLiveAdjudication({ models: createAdjudicationModel({ env: { BASETEN_API_KEY: 'test' }, fetchImpl }) });
  assert.equal(calls, committed.adjudication.live_plan.calls);
  assert.equal(live.attempts_reported, calls);
  assert.deepEqual(live.systems.adjudicated_live.overall, live.systems.measure.overall, 'all-habit labels reproduce the lexicon');
});

test('npm run eval -- --live prints the call count and makes no call without --approved', () => {
  const run = spawnSync(process.execPath, ['--import', 'data:text/javascript,globalThis.fetch=()=>{throw new Error("network used")}', 'scripts/eval.mjs', '--live'],
    { cwd: ROOT, env: { ...process.env, BASETEN_API_KEY: 'not-a-real-key' }, encoding: 'utf8' });
  assert.equal(run.status, 0, run.stderr);
  assert.match(run.stdout, new RegExp(`would make ${committed.adjudication.live_plan.calls} `));
  assert.match(run.stdout, /Not run\./);
});
