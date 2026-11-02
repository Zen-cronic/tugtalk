// Recompute the measurement eval and compare it with the committed eval/results.json.
//   npm run eval                       print the numbers; exit 1 if they differ from the committed results
//   npm run eval -- --write            regenerate eval/results.json after a deliberate corpus, lexicon or script change
//   npm run eval -- --live             print what a live adjudication run would cost, and stop
//   npm run eval -- --live --approved  run Muse Spark Open adjudication on the corpus (paid; needs BASETEN_API_KEY)
//   npm run eval -- --heldout          score the held-out set (eval/heldout-v1.json) with stub replies, no calls; and the
//                                      saved live run, if there is one, recomputed from its stored labels
//   npm run eval -- --heldout --live   print what a live held-out run would cost, and stop
//   npm run eval -- --heldout --live --approved [--call-log <file.jsonl>] [--call-fields '<json>']
//                                      run it once (paid; needs BASETEN_API_KEY); writes eval/heldout-live-results.json.
//                                      --call-log appends one line per request sent, with --call-fields merged in.
import { readFileSync, writeFileSync, appendFileSync } from 'node:fs';
import { runEval, runLiveAdjudication } from '../src/evaluate.mjs';
import { createAdjudicationModel } from '../src/adjudicate.mjs';
import { ANALYSIS_MODEL } from '../src/capture.mjs';
import { loadHeldout, runHeldout, scoreHeldout, rescore, applyRules, stubFetch, heldoutPlan, HELDOUT_LIVE_URL, SYSTEMS, RULES } from '../src/heldout.mjs';

if (process.argv.includes('--heldout')) await heldout();

const RESULTS_URL = new URL('../eval/results.json', import.meta.url);
const LIVE_URL = new URL('../eval/live-results.json', import.meta.url);
const result = runEval();
const text = JSON.stringify(result, null, 2) + '\n';
const pct = x => x === null ? '  n/a' : x.toFixed(3);
const table = systems => {
  console.log('category   system                precision  recall  f1     tp  fp  fn');
  for (const category of ['all', 'fillers', 'hedges', 'restarts'])
    for (const [name, s] of Object.entries(systems)) {
      const r = category === 'all' ? s.overall : s.by_category[category];
      console.log(`${category.padEnd(10)} ${name.padEnd(21)} ${pct(r.precision).padStart(9)}  ${pct(r.recall).padStart(6)}  ${pct(r.f1)}  ${String(r.tp).padStart(2)}  ${String(r.fp).padStart(2)}  ${String(r.fn).padStart(2)}`);
    }
};

if (process.argv.includes('--live')) {
  const plan = result.adjudication.live_plan;
  console.log(`Live adjudication would make ${plan.calls} ${plan.model} calls: one per corpus item with ambiguous hits (${plan.candidates} candidates), and at most ${plan.max_calls_with_retries} if every first reply is unusable and retried.`);
  if (!process.argv.includes('--approved')) { console.log('Not run. Live calls are paid; re-run with --live --approved once they are approved.'); process.exit(0); }
  if (!process.env.BASETEN_API_KEY) { console.error('BASETEN_API_KEY is not set in this shell.'); process.exit(1); }
  const live = await runLiveAdjudication({ models: createAdjudicationModel() });
  table(live.systems);
  console.log(`\nAttempts reported: ${live.attempts_reported}. Live results are not compared with the committed file.`);
  writeFileSync(LIVE_URL, JSON.stringify({ ...live, ran_at: new Date().toISOString() }, null, 2) + '\n');
  console.log('Wrote eval/live-results.json');
  process.exit(0);
}

console.log(result.headline);
console.log(result.adjudication_headline + '\n');
table(result.systems);
console.log(`\nNegative control: ${result.systems.measure.negative_control.false_counts} false counts on ${result.systems.measure.negative_control.items} clean transcripts.`);
console.log(`Corpus ${result.corpus} (${result.counts.items} items, sha256 ${result.corpus_sha256.slice(0, 12)}…). ${result.provenance}`);
console.log(`Adjudication replies ${result.adjudication.replies} (${result.adjudication.items_with_candidates} items, sha256 ${result.adjudication.replies_sha256.slice(0, 12)}…). ${result.adjudication.provenance}`);
console.log(`A live run would make ${result.adjudication.live_plan.calls} Spark calls (at most ${result.adjudication.live_plan.max_calls_with_retries}); see --live.`);

if (process.argv.includes('--write')) {
  writeFileSync(RESULTS_URL, text);
  console.log('\nWrote eval/results.json');
} else {
  let committed = null;
  try { committed = readFileSync(RESULTS_URL, 'utf8'); } catch {}
  if (committed !== text) { console.error('\neval/results.json is missing or stale. Re-run with --write after a deliberate change.'); process.exit(1); }
  console.log('\nMatches the committed eval/results.json.');
}

function heldoutTable(score) {
  const pct = x => x === null || x === undefined ? '  n/a' : x.toFixed(3);
  console.log('class              system         precision  recall  f1     tp  fp  fn');
  for (const [name, systems] of Object.entries(score.classes))
    for (const system of SYSTEMS) {
      const r = systems[system];
      if (!r) { console.log(`${name.padEnd(18)} ${system.padEnd(14)} not applicable: the model-only words are not hedges`); continue; }
      console.log(`${name.padEnd(18)} ${system.padEnd(14)} ${pct(r.precision).padStart(9)}  ${pct(r.recall).padStart(6)}  ${pct(r.f1)}  ${String(r.tp).padStart(2)}  ${String(r.fp).padStart(2)}  ${String(r.fn).padStart(2)}`);
    }
  console.log(`model_only status not_counted on ${score.model_only_not_counted} of ${score.items} transcripts (nothing counted there).`);
  if (score.unmatched.model_only.length || score.unmatched.lexicon_hedges.length) console.log(`Unlabelled: ${[...score.unmatched.model_only, ...score.unmatched.lexicon_hedges].join(', ')}`);
}

function rulesReport(rules) {
  const r1 = rules.rule1_model_only_ships, r2 = rules.rule2_hedges_leave_adjudication;
  console.log(`Rule 1, model-only class ships: ${r1.pass ? 'PASS' : 'FAIL'} (F1 ${r1.f1} vs count-all ${r1.count_all_f1} and count-none ${r1.count_none_f1}; precision ${r1.precision} vs floor ${r1.precision_floor})`);
  console.log(`Rule 2, hedges leave adjudication: ${r2.fires ? 'FIRES' : 'does not fire'} (hedge recall: lexicon ${r2.lexicon_recall}, adjudication ${r2.adjudication_recall}; drop ${r2.drop} vs ${r2.threshold})`);
}

async function heldout() {
  const { set, sha256 } = loadHeldout(), items = set.transcripts, plan = heldoutPlan(items);
  console.log(`Held-out set ${set.name}: ${items.length} synthetic transcripts written and labelled by a separate agent, not real speech (sha256 ${sha256.slice(0, 12)}…).\n`);
  if (process.argv.includes('--live')) await heldoutLive(set, sha256, items, plan);

  const stub = stubFetch();
  const { adjudications } = await runHeldout({ models: createAdjudicationModel({ env: { BASETEN_API_KEY: 'stub' }, fetchImpl: stub }), items });
  console.log(`Stub replies, not a model: every candidate labelled "habit", through the real request, parser and label check (${stub.calls} stub requests, 0 paid calls).`);
  console.log('So adjudication equals the lexicon and model-only equals count-all; this checks the pipeline and the scoring, not Spark Open.\n');
  heldoutTable(scoreHeldout(items, adjudications));
  console.log(`\nPre-registered thresholds (eval/README.md): model-only precision >= ${RULES.model_only_precision_floor} and F1 above both baselines; hedge recall drop > ${RULES.hedge_recall_drop}.`);

  let live = null;
  try { live = JSON.parse(readFileSync(HELDOUT_LIVE_URL, 'utf8')); } catch {}
  if (!live) { console.log(`No live run saved yet. A live run would make ${plan.calls} Spark calls (at most ${plan.max_calls_with_retries}); see --heldout --live.`); process.exit(0); }
  if (live.heldout_sha256 !== sha256) { console.error('\neval/heldout-live-results.json was run on a different held-out file.'); process.exit(1); }
  const score = rescore(items, live.items);
  console.log(`\nLive run, ${live.ran_at}, recomputed from its stored labels (${live.calls_sent} requests sent):\n`);
  heldoutTable(score); console.log(); rulesReport(applyRules(score));
  process.exit(0);
}

async function heldoutLive(set, sha256, items, plan) {
  console.log(`A live run makes ${plan.calls} ${plan.model} calls with the model-only words on (one per transcript), at most ${plan.max_calls_with_retries} if every first reply needs the retry.`);
  if (!process.argv.includes('--approved')) { console.log('Not run. Live calls are paid; re-run with --heldout --live --approved once they are approved.'); process.exit(0); }
  if (!process.env.BASETEN_API_KEY) { console.error('BASETEN_API_KEY is not set in this shell.'); process.exit(1); }
  const arg = name => { const i = process.argv.indexOf(name); return i > 0 ? process.argv[i + 1] : undefined; };
  const callLog = arg('--call-log'), fields = arg('--call-fields') ? JSON.parse(arg('--call-fields')) : {};
  let current = null, attempt = 0, sent = 0;
  // Counts every request sent and, with --call-log, appends one line each; the key is never logged.
  const fetchImpl = async (url, init) => {
    const t = new Date().toISOString(), purpose = `held-out ${current} attempt ${++attempt}`; sent++;
    const log = extra => { if (callLog) appendFileSync(callLog, JSON.stringify({ t, ...fields, service: 'spark', model: ANALYSIS_MODEL, ...extra, purpose }) + '\n'); };
    let response;
    try { response = await fetch(url, init); } catch (error) { log({ request_id: null, error: error.name }); throw error; }
    let body = null; try { body = await response.clone().json(); } catch {}
    log({ request_id: response.headers.get('x-baseten-request-id') ?? body?.id ?? null, http_status: response.status, finish_reason: body?.choices?.[0]?.finish_reason ?? null });
    return response;
  };
  const started = Date.now();
  const { adjudications, records } = await runHeldout({ models: createAdjudicationModel({ fetchImpl }), items,
    beforeItem: item => { current = item.id; attempt = 0; },
    onItem: r => console.log(`${r.id}  ${r.status}  model_only ${r.model_only_status}  attempts ${r.attempts}`) });
  const score = scoreHeldout(items, adjudications), rules = applyRules(score);
  writeFileSync(HELDOUT_LIVE_URL, JSON.stringify({ eval: 'heldout-live', label: 'Live Muse Spark Open adjudication, model-only words on, one run.', heldout: set.name, heldout_sha256: sha256,
    model: ANALYSIS_MODEL, reasoning_effort: 'low', ran_at: new Date().toISOString(), seconds: Math.round((Date.now() - started) / 1000), calls_sent: sent,
    score, rules, items: records }, null, 2) + '\n');
  console.log(`\n${sent} requests sent. Wrote eval/heldout-live-results.json.\n`);
}
