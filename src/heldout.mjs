// The held-out check for the model-only words and for hedge adjudication (eval/heldout-v1.json, eval/README.md).
//
// The set was written and labelled by a separate agent that never saw the adjudication prompt or eval/corpus.json.
// It is synthetic text, not real speech. Two classes are scored, occurrence by occurrence:
//   model-only: every "like" (en), "genre" and "quoi" (fr); a positive is one labelled filler.
//   hedge: every labelled hedge-family span; a positive is one labelled hedge.
// Five systems: the lexicon (measure()'s word list), adjudication (the lexicon after code-checked labels), model-only
// (the model_only block, which counts nothing unless its status is "counted"), and two baselines, count-all and count-none.
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { habitHits, ANALYSIS_MODEL } from './capture.mjs';
import { adjudicationCandidates, buildAdjudication, adjudicateCapture, MODEL_ONLY } from './adjudicate.mjs';

export const HELDOUT_URL = new URL('../eval/heldout-v1.json', import.meta.url);
export const HELDOUT_LIVE_URL = new URL('../eval/heldout-live-results.json', import.meta.url);
export const SYSTEMS = ['lexicon', 'adjudication', 'model_only', 'count_all', 'count_none'];
// Pre-registered in eval/README.md before the live run; never changed after it.
export const RULES = { model_only_precision_floor: 0.8, hedge_recall_drop: 0.2 };

export function loadHeldout(url = HELDOUT_URL) {
  const raw = readFileSync(url, 'utf8');
  return { raw, set: JSON.parse(raw), sha256: createHash('sha256').update(raw).digest('hex') };
}

const boundary = "[\\p{L}\\p{N}'’-]";
const escape = s => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
// Character spans of every labelled occurrence: the n-th whole-word, case-sensitive match of its text.
export function goldSpans(item) {
  return item.occurrences.map(o => {
    const matches = [...item.text.matchAll(new RegExp(`(?<!${boundary})${escape(o.text)}(?!${boundary})`, 'gu'))];
    const match = matches[o.occurrence - 1];
    if (!match) throw new Error(`${item.id}: "${o.text}" #${o.occurrence} is not in the text`);
    return { ...o, start: match.index, end: match.index + o.text.length };
  });
}

const tally = () => ({ tp: 0, fp: 0, fn: 0, tn: 0 });
const add = (t, gold, predicted) => { t[gold ? (predicted ? 'tp' : 'fn') : (predicted ? 'fp' : 'tn')]++; };
const round = x => Math.round(x * 1000) / 1000;
// Precision is null when nothing is counted; F1 is then 0 (nothing found).
export function prf({ tp, fp, fn, tn }) {
  const precision = tp + fp ? round(tp / (tp + fp)) : null, recall = tp + fn ? round(tp / (tp + fn)) : null;
  const f1 = tp + fp + fn ? round(2 * tp / (2 * tp + fp + fn)) : null;
  return { precision, recall, f1, tp, fp, fn, tn };
}

// adjudications: item id -> the stored adjudication built with modelOnly on (buildAdjudication or adjudicateCapture).
export function scoreHeldout(items, adjudications) {
  const words = [...new Set(Object.values(MODEL_ONLY).flat())];
  const classes = Object.fromEntries(['model_only', ...words.map(w => `model_only:${w}`), 'hedge'].map(c => [c, Object.fromEntries(SYSTEMS.map(s => [s, tally()]))]));
  const unmatched = { model_only: [], lexicon_hedges: [] };
  let notCounted = 0;
  for (const item of items) {
    const adjudication = adjudications.get(item.id);
    if (!adjudication?.model_only) throw new Error(`${item.id}: no adjudication with a model_only block`);
    if (adjudication.model_only.status !== 'counted') notCounted++;
    const gold = goldSpans(item);
    const { hits } = habitHits(item.text, item.language);
    const lexiconHedges = hits.filter(h => h.category === 'hedges');
    const removed = new Set(adjudication.candidates.filter(c => c.category === 'hedges' && !c.counted).map(c => c.start));
    const modelOnly = new Map(adjudication.model_only.candidates.map(c => [c.start, c]));
    for (const g of gold) {
      if (g.family === 'hedge') {
        const hit = lexiconHedges.find(h => h.start === g.start && h.end === g.end);
        const predicted = { lexicon: !!hit, adjudication: !!hit && !removed.has(hit.start), model_only: null, count_all: true, count_none: false };
        for (const s of SYSTEMS) if (predicted[s] !== null) add(classes.hedge[s], g.label === 'hedge', predicted[s]);
      } else {
        const candidate = modelOnly.get(g.start);
        const predicted = { lexicon: false, adjudication: false, model_only: !!candidate?.counted, count_all: true, count_none: false };
        for (const c of ['model_only', `model_only:${g.family}`]) for (const s of SYSTEMS) add(classes[c][s], g.label === 'filler', predicted[s]);
      }
    }
    // Counts that no label covers are false counts.
    for (const c of adjudication.model_only.candidates) if (!gold.some(g => g.start === c.start && g.family !== 'hedge')) {
      unmatched.model_only.push(`${item.id}:${c.quote}`);
      if (c.counted) { classes.model_only.model_only.fp++; classes[`model_only:${c.phrase}`].model_only.fp++; }
    }
    for (const h of lexiconHedges) if (!gold.some(g => g.family === 'hedge' && g.start === h.start && g.end === h.end)) {
      unmatched.lexicon_hedges.push(`${item.id}:${h.quote}`);
      classes.hedge.lexicon.fp++;
      if (!removed.has(h.start)) classes.hedge.adjudication.fp++;
    }
  }
  const scored = Object.fromEntries(Object.entries(classes).map(([c, systems]) => [c, Object.fromEntries(SYSTEMS.map(s =>
    [s, c === 'hedge' && s === 'model_only' ? null : prf(systems[s])]))]));
  return { classes: scored, items: items.length, model_only_not_counted: notCounted, unmatched };
}

// The pre-registered rules, applied to a score. Rule 3 (report both either way) is not a computation.
export function applyRules(score) {
  const m = score.classes.model_only, h = score.classes.hedge;
  const f1 = m.model_only.f1 ?? 0, precision = m.model_only.precision;
  const ships = f1 > (m.count_all.f1 ?? 0) && f1 > (m.count_none.f1 ?? 0) && precision !== null && precision >= RULES.model_only_precision_floor;
  const drop = round((h.lexicon.recall ?? 0) - (h.adjudication.recall ?? 0));
  return {
    rule1_model_only_ships: { pass: ships, f1, precision, count_all_f1: m.count_all.f1, count_none_f1: m.count_none.f1 ?? 0, precision_floor: RULES.model_only_precision_floor },
    rule2_hedges_leave_adjudication: { fires: drop > RULES.hedge_recall_drop, lexicon_recall: h.lexicon.recall, adjudication_recall: h.adjudication.recall, drop, threshold: RULES.hedge_recall_drop }
  };
}

// A stub reply for every candidate, through the real request, parser and label check: every label "habit". It tests
// the pipeline, not the model: adjudication then equals the lexicon and model-only equals count-all.
export function stubFetch(label = () => 'habit') {
  const fetchImpl = async (url, init) => {
    fetchImpl.calls++;
    const { candidates } = JSON.parse(JSON.parse(init.body).messages[1].content);
    const labels = candidates.map(c => ({ id: c.id, quote: c.quote, label: label(c), reason: 'Stub reply.' }));
    return new Response(JSON.stringify({ id: 'stub', choices: [{ message: { content: JSON.stringify({ labels }) }, finish_reason: 'stop' }] }), { status: 200 });
  };
  fetchImpl.calls = 0;
  return fetchImpl;
}

// One adjudication per transcript with the model-only words on, through the production client (models.adjudicateHabits).
// Returns the stored adjudications and, per item, the raw labels the model sent, so the score can be recomputed offline.
export async function runHeldout({ models, items, beforeItem = () => {}, onItem = () => {} }) {
  const adjudications = new Map(), records = [];
  for (const item of items) {
    let raw = null;
    beforeItem(item);
    const recording = { ...models, adjudicateModelOnly: true,
      async adjudicateHabits(args) { const result = await models.adjudicateHabits(args); raw = result; return result; } };
    const adjudication = await adjudicateCapture({ models: recording, transcript: item.text, language: item.language });
    adjudications.set(item.id, adjudication);
    const record = { id: item.id, language: item.language, status: adjudication.status, model_only_status: adjudication.model_only.status,
      attempts: adjudication.attempts, provider_request_id: adjudication.provider_request_id,
      reply: raw ? { status: raw.status, labels: raw.status === 'model_labels' ? raw.labels : null, reason: raw.reason ?? null } : null };
    records.push(record); onItem(record, item);
  }
  return { adjudications, records };
}

// Rebuild each stored adjudication from the saved raw labels (the same check code runs on a capture).
export function rescore(items, records) {
  const byId = new Map(records.map(r => [r.id, r]));
  const adjudications = new Map(items.map(item => {
    const r = byId.get(item.id);
    if (!r) throw new Error(`No live record for ${item.id}`);
    const result = r.reply?.status === 'model_labels' ? { status: 'model_labels', labels: r.reply.labels, model: ANALYSIS_MODEL, provider_request_id: r.provider_request_id, attempts: r.attempts }
      : r.reply ? { status: r.reply.status, reason: r.reply.reason, attempts: r.attempts } : null;
    return [item.id, buildAdjudication(item.text, item.language, result, { modelOnly: true })];
  }));
  return scoreHeldout(items, adjudications);
}

// What a live run costs: one call per transcript with any candidate, at most two with the larger-budget retry.
export function heldoutPlan(items) {
  const calls = items.filter(i => adjudicationCandidates(i.text, i.language, { modelOnly: true }).candidates.length).length;
  return { calls, max_calls_with_retries: calls * 2, model: ANALYSIS_MODEL };
}
