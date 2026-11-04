// Held-out accuracy of the semantic objective assessment (eval/SEMANTIC.md).
// Each item goes through replyToAnswer (src/voice.mjs), the function a practice-round answer goes through in
// production: the same system prompt, the same user message, the same Muse Spark Open call on Baseten (with its
// one retry) and the same code check of the quoted evidence (validateAssessment, src/practice.mjs).
//
//   node scripts/eval-semantic.mjs                      prints the plan; makes no call
//   node scripts/eval-semantic.mjs --live --approved    runs it (paid; needs BASETEN_API_KEY), writes eval/semantic-results.json
//   node scripts/eval-semantic.mjs --score              recomputes the summary from the saved records and checks it
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { replyToAnswer, createVoiceModel, VOICE_ATTEMPTS, VOICE_EFFORT, VOICE_TIMEOUT_MS } from '../src/voice.mjs';
import { createBudget } from '../src/budget.mjs';
import { SPARK_URL, SPARK_STREAM_MODEL } from '../src/spark-stream.mjs';

const SET = new URL('../eval/semantic-heldout-v1.json', import.meta.url);
const OUT = new URL('../eval/semantic-results.json', import.meta.url);
export const CALL_CAP = 120;
export const RUNS = 2;
export const LABELS = ['addressed', 'partial', 'not_addressed'];
const PREDICTED = [...LABELS, 'unclear'];

export const loadSet = () => JSON.parse(readFileSync(SET, 'utf8'));

// The practice round as production holds it before the first answer (createPracticeRecord, src/practice.mjs).
export function contextFor(item) {
  const round = { request_text: item.request_text, objectives: item.objectives, current_question: item.request_text, assessment: null, answer_count: 0 };
  return { practice: { round }, roundNumber: 1, last: null };
}

// Requests sent to Baseten are counted here, retries included. An item starts only when its worst case
// (VOICE_ATTEMPTS requests) still fits under the cap.
export function countingFetch(fetchImpl = fetch) {
  const counter = { sent: 0 };
  const wrapped = (url, init) => {
    if (url !== SPARK_URL) throw new Error(`Unexpected request to ${url}`);
    if (counter.sent >= CALL_CAP) return Promise.reject(new Error('Call cap reached.'));
    counter.sent++;
    return fetchImpl(url, init);
  };
  return { wrapped, counter };
}

const rawStatus = (raw, id) => {
  const found = Array.isArray(raw?.objectives) ? raw.objectives.filter(o => o?.id === id) : [];
  return found.length === 1 && PREDICTED.includes(found[0]?.status) ? found[0].status : 'missing';
};
const spans = (raw, id) => {
  const o = Array.isArray(raw?.objectives) ? raw.objectives.find(x => x?.id === id) : null;
  return Array.isArray(o?.evidence) ? o.evidence : [];
};

export async function runItem(models, item, run) {
  const sentBefore = models.counter.sent;
  const transcription = { transcript: item.answer, turns: [], audio_duration_ms: null };
  const out = await replyToAnswer(models, contextFor(item), transcription, 20_000, { language: 'en' }, createBudget());
  const raw = out.result?.status === 'model_reply' ? out.result.reply?.assessment : undefined;
  const objectives = item.objectives.map(o => {
    const final = out.assessment.objectives.find(x => x.id === o.id);
    const returned = spans(raw, o.id);
    const verified = returned.filter(e => e && Number.isInteger(e.start) && Number.isInteger(e.end) && e.start >= 0 && e.end > e.start
      && item.answer.slice(e.start, e.end) === e.quote).length;
    const rs = raw === undefined ? 'unavailable' : rawStatus(raw, o.id);
    return { id: o.id, gold: item.gold[o.id], raw_status: rs, final_status: final.status,
      code_check: out.assessment.status === 'unavailable' ? 'unavailable' : rs === final.status ? 'kept' : 'downgraded',
      quotes_returned: returned.length, quotes_verified: verified,
      evidence: final.evidence.map(e => e.quote), missing: final.missing };
  });
  return { run, item: item.id, requests_sent: models.counter.sent - sentBefore, result_status: out.result?.status ?? null,
    reason: out.result?.reason ?? null, assessment_status: out.assessment.status, provider_request_id: out.result?.provider_request_id ?? null,
    model: out.result?.model ?? null, model_ms: out.modelMs, round_outcome: out.gate.reason, objectives };
}

const rate = (n, d) => d ? Math.round((n / d) * 1000) / 1000 : null;
function confusion(objs, key) {
  const m = Object.fromEntries(LABELS.map(g => [g, Object.fromEntries(PREDICTED.map(p => [p, 0]))]));
  for (const o of objs) { const p = PREDICTED.includes(o[key]) ? o[key] : 'unclear'; m[o.gold][p]++; }
  return m;
}
function scoreRun(records, key) {
  const objs = records.flatMap(r => r.objectives);
  const right = objs.filter(o => o[key] === o.gold).length;
  const notFull = objs.filter(o => o.gold !== 'addressed');
  const falseAddressed = notFull.filter(o => o[key] === 'addressed').length;
  const roundsNotDone = records.filter(r => r.objectives.some(o => o.gold !== 'addressed'));
  const roundsDone = records.filter(r => r.objectives.every(o => o.gold === 'addressed'));
  const closes = r => r.objectives.every(o => o[key] === 'addressed');
  const perClass = Object.fromEntries(LABELS.map(g => { const of = objs.filter(o => o.gold === g); return [g, { n: of.length, right: of.filter(o => o[key] === g).length, accuracy: rate(of.filter(o => o[key] === g).length, of.length) }]; }));
  return { objectives: objs.length, right, accuracy: rate(right, objs.length), per_gold_class: perClass, confusion: confusion(objs, key),
    false_addressed: { count: falseAddressed, of: notFull.length, rate: rate(falseAddressed, notFull.length),
      gold_partial: objs.filter(o => o.gold === 'partial' && o[key] === 'addressed').length, gold_not_addressed: objs.filter(o => o.gold === 'not_addressed' && o[key] === 'addressed').length },
    unclear: objs.filter(o => o[key] === 'unclear').length,
    round_close: { false_close: roundsNotDone.filter(closes).length, of_not_done: roundsNotDone.length, true_close: roundsDone.filter(closes).length, of_done: roundsDone.length } };
}
function quoteCheck(records) {
  const claims = records.flatMap(r => r.objectives).filter(o => ['addressed', 'partial'].includes(o.raw_status));
  const kept = claims.filter(o => o.code_check === 'kept').length;
  const returned = records.flatMap(r => r.objectives).reduce((n, o) => n + o.quotes_returned, 0);
  const verified = records.flatMap(r => r.objectives).reduce((n, o) => n + o.quotes_verified, 0);
  return { claims_with_evidence_required: claims.length, kept, downgraded_to_unclear: claims.length - kept, pass_rate: rate(kept, claims.length),
    spans_returned: returned, spans_verified: verified, span_pass_rate: rate(verified, returned) };
}
function agreement(records, key) {
  const byRun = run => new Map(records.filter(r => r.run === run).flatMap(r => r.objectives.map(o => [`${r.item}/${o.id}`, o[key]])));
  const a = byRun(1), b = byRun(2), both = [...a.keys()].filter(k => b.has(k));
  const same = both.filter(k => a.get(k) === b.get(k)).length;
  const items = [...new Set(records.filter(r => r.run === 1).map(r => r.item))].filter(id => records.some(r => r.run === 2 && r.item === id));
  const itemSame = items.filter(id => { const r1 = records.find(r => r.run === 1 && r.item === id), r2 = records.find(r => r.run === 2 && r.item === id);
    return r1.objectives.every((o, i) => o[key] === r2.objectives[i][key]); }).length;
  return { objectives_compared: both.length, same_label: same, rate: rate(same, both.length), items_compared: items.length, items_identical: itemSame, item_rate: rate(itemSame, items.length) };
}
export function summarize(records, set) {
  const runs = Object.fromEntries([1, 2].map(run => { const rs = records.filter(r => r.run === run);
    return [`run${run}`, rs.length ? { items: rs.length, unavailable_items: rs.filter(r => r.assessment_status === 'unavailable').length,
      final: scoreRun(rs, 'final_status'), raw: scoreRun(rs, 'raw_status'), quote_check: quoteCheck(rs) } : null]; }));
  const ran = records.map(r => r.item);
  return { set: set.version, items: set.items.length, objectives: set.items.reduce((n, i) => n + i.objectives.length, 0),
    gold: Object.fromEntries(LABELS.map(g => [g, set.items.reduce((n, i) => n + Object.values(i.gold).filter(x => x === g).length, 0)])),
    requests_sent: records.reduce((n, r) => n + r.requests_sent, 0), items_run: ran.length, items_not_run: RUNS * set.items.length - ran.length,
    ...runs, agreement: { final: agreement(records, 'final_status'), raw: agreement(records, 'raw_status') },
    pooled: { final: scoreRun(records, 'final_status'), raw: scoreRun(records, 'raw_status'), quote_check: quoteCheck(records) } };
}

export async function runAll({ env = process.env, fetchImpl = fetch, set = loadSet(), log = () => {} } = {}) {
  const { wrapped, counter } = countingFetch(fetchImpl);
  const models = { ...createVoiceModel({ env, fetchImpl: wrapped }), counter };
  const records = [];
  for (let run = 1; run <= RUNS; run++) for (const item of set.items) {
    if (counter.sent + VOICE_ATTEMPTS > CALL_CAP) { log(`cap: stopping before run ${run} ${item.id}`); return { records, counter }; }
    const r = await runItem(models, item, run);
    records.push(r);
    log(`run ${run} ${item.id}: ${r.assessment_status} ${r.objectives.map(o => `${o.id}=${o.final_status}${o.final_status === o.gold ? '' : `(gold ${o.gold})`}`).join(' ')} [sent ${counter.sent}]`);
  }
  return { records, counter };
}

async function main() {
  const args = process.argv.slice(2), set = loadSet();
  if (args.includes('--score')) {
    const saved = JSON.parse(readFileSync(OUT, 'utf8'));
    const again = summarize(saved.records, set);
    if (JSON.stringify(again) !== JSON.stringify(saved.summary)) { console.error('Summary drifted from the saved records.'); process.exit(1); }
    console.log(JSON.stringify(again, null, 2));
    return;
  }
  const plan = { set: set.version, items: set.items.length, objectives: set.items.reduce((n, i) => n + i.objectives.length, 0), runs: RUNS,
    planned_requests: RUNS * set.items.length, worst_case_with_retries: RUNS * set.items.length * VOICE_ATTEMPTS, call_cap: CALL_CAP,
    model: SPARK_STREAM_MODEL, reasoning_effort: VOICE_EFFORT, timeout_ms_per_attempt: VOICE_TIMEOUT_MS };
  if (!(args.includes('--live') && args.includes('--approved'))) { console.log(JSON.stringify({ ...plan, paid_calls: 0, note: 'Add --live --approved to run.' }, null, 2)); return; }
  if (!process.env.BASETEN_API_KEY) { console.error('BASETEN_API_KEY is not set.'); process.exit(1); }
  const started = new Date().toISOString();
  const { records, counter } = await runAll({ log: line => console.error(line) });
  const summary = summarize(records, set);
  if (summary.requests_sent !== counter.sent) throw new Error('Request count mismatch.');
  writeFileSync(OUT, JSON.stringify({ plan, started_at: started, finished_at: new Date().toISOString(), summary, records }, null, 2) + '\n');
  console.log(JSON.stringify(summary, null, 2));
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) await main();
export const paths = { set: fileURLToPath(SET), out: fileURLToPath(OUT) };
