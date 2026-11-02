// Recompute the measurement eval and compare it with the committed eval/results.json.
//   npm run eval                       print the numbers; exit 1 if they differ from the committed results
//   npm run eval -- --write            regenerate eval/results.json after a deliberate corpus, lexicon or script change
//   npm run eval -- --live             print what a live adjudication run would cost, and stop
//   npm run eval -- --live --approved  run Muse Spark Open adjudication on the corpus (paid; needs BASETEN_API_KEY)
import { readFileSync, writeFileSync } from 'node:fs';
import { runEval, runLiveAdjudication } from '../src/evaluate.mjs';
import { createAdjudicationModel } from '../src/adjudicate.mjs';

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
