// Recompute the offline voice-reply eval and compare it with the committed eval/voice-results.json.
//   npm run eval:voice              print the numbers; exit 1 if they differ from the committed results
//   npm run eval:voice -- --write   regenerate after a deliberate change to the replies or the check
import { readFileSync, writeFileSync } from 'node:fs';
import { runVoiceEval } from '../src/voice-eval.mjs';
import { runCounterpartEval } from '../src/counterpart-eval.mjs';

//   npm run eval:voice -- --counterpart [--write]   the move-gate eval instead (eval/counterpart-results.json)
if (process.argv.includes('--counterpart')) {
  const out = new URL('../eval/counterpart-results.json', import.meta.url);
  const r = await runCounterpartEval();
  const text = JSON.stringify(r, null, 2) + '\n';
  console.log(r.headline);
  console.log(`Matches the expected move on ${r.matches_expected} cases. Gate reasons: ${JSON.stringify(r.counts.reasons)}. Model calls: 0.`);
  console.log(r.provenance);
  if (process.argv.includes('--write')) { writeFileSync(out, text); console.log('\nWrote eval/counterpart-results.json'); process.exit(0); }
  let committed = null;
  try { committed = readFileSync(out, 'utf8'); } catch {}
  if (committed !== text) { console.error('\neval/counterpart-results.json is missing or stale. Re-run with --write after a deliberate change.'); process.exit(1); }
  console.log('\nMatches the committed eval/counterpart-results.json.');
  process.exit(0);
}

const URL_ = new URL('../eval/voice-results.json', import.meta.url);
const result = runVoiceEval();
const text = JSON.stringify(result, null, 2) + '\n';
console.log(result.headline);
console.log(`Matches the expected reply on ${result.matches_expected} cases. Rejections: ${JSON.stringify(result.counts.rejections)}.`);
console.log(`Questions: ${result.counts.questions_stripped} had unsaid quoted words removed, ${result.counts.questions_replaced} replaced by a fixed question, ${result.counts.questions_cut} cut to 25 words, ${result.counts.questions_scrubbed} scrubbed.`);
console.log(result.provenance);
if (process.argv.includes('--write')) { writeFileSync(URL_, text); console.log('\nWrote eval/voice-results.json'); process.exit(0); }
let committed = null;
try { committed = readFileSync(URL_, 'utf8'); } catch {}
if (committed !== text) { console.error('\neval/voice-results.json is missing or stale. Re-run with --write after a deliberate change.'); process.exit(1); }
console.log('\nMatches the committed eval/voice-results.json.');
