// Recompute the measurement eval and compare it with the committed eval/results.json.
//   npm run eval            print the numbers; exit 1 if they differ from the committed results
//   npm run eval -- --write regenerate eval/results.json after a deliberate corpus or lexicon change
import { readFileSync, writeFileSync } from 'node:fs';
import { runEval } from '../src/evaluate.mjs';

const RESULTS_URL = new URL('../eval/results.json', import.meta.url);
const result = runEval();
const text = JSON.stringify(result, null, 2) + '\n';
const pct = x => x === null ? '  n/a' : x.toFixed(3);

console.log(result.headline + '\n');
console.log('category   system               precision  recall  f1     tp  fp  fn');
for (const category of ['all', 'fillers', 'hedges', 'restarts'])
  for (const [name, s] of Object.entries(result.systems)) {
    const r = category === 'all' ? s.overall : s.by_category[category];
    console.log(`${category.padEnd(10)} ${name.padEnd(20)} ${pct(r.precision).padStart(9)}  ${pct(r.recall).padStart(6)}  ${pct(r.f1)}  ${String(r.tp).padStart(2)}  ${String(r.fp).padStart(2)}  ${String(r.fn).padStart(2)}`);
  }
console.log(`\nNegative control: ${result.systems.measure.negative_control.false_counts} false counts on ${result.systems.measure.negative_control.items} clean transcripts.`);
console.log(`Corpus ${result.corpus} (${result.counts.items} items, sha256 ${result.corpus_sha256.slice(0, 12)}…). ${result.provenance}`);

if (process.argv.includes('--write')) {
  writeFileSync(RESULTS_URL, text);
  console.log('\nWrote eval/results.json');
} else {
  let committed = null;
  try { committed = readFileSync(RESULTS_URL, 'utf8'); } catch {}
  if (committed !== text) { console.error('\neval/results.json is missing or stale. Re-run with --write after a deliberate change.'); process.exit(1); }
  console.log('\nMatches the committed eval/results.json.');
}
