// Deterministic measurement eval: scores measure(), a flat word-list counter and code-checked adjudication of
// scripted model replies against a labelled corpus. No model calls, no clock, no randomness; the same corpus
// and scripted replies always yield byte-identical results. runLiveAdjudication is the separate live arm.
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { measure, LEXICON, LEXICON_VERSION, FORMS, parseObject, shapeOf, ANALYSIS_BUDGETS, ANALYSIS_MODEL } from './capture.mjs';
import { adjudicationCandidates, buildAdjudication, adjudicateCapture, acceptLabels, ADJUDICATION_METHOD, REJECTIONS } from './adjudicate.mjs';

export const CATEGORIES = ['fillers', 'hedges', 'restarts'];
const CODES = { F: 'fillers', H: 'hedges', R: 'restarts' };
const MARK = /\[([FHR]):([^\]]+)\]/g;
export const CORPUS_URL = new URL('../eval/corpus.json', import.meta.url);
export const SCRIPTED_URL = new URL('../eval/scripted-adjudication.json', import.meta.url);

// "[F:Um], the point" -> transcript "Um, the point", gold {fillers: 1, hedges: 0, restarts: 0}.
export function parseItem(text) {
  const gold = Object.fromEntries(CATEGORIES.map(c => [c, 0]));
  for (const [, code] of text.matchAll(MARK)) gold[CODES[code]]++;
  const transcript = text.replace(MARK, (_, __, inner) => inner);
  if (/[[\]]/.test(transcript)) throw new Error(`Malformed markup: ${text}`);
  return { transcript, gold };
}

// Character spans of the gold labels in the transcript, for checking each adjudication label against gold.
export function goldSpans(text) {
  const spans = [];
  let transcript = '', last = 0;
  for (const match of text.matchAll(MARK)) {
    transcript += text.slice(last, match.index);
    spans.push({ category: CODES[match[1]], start: transcript.length, end: transcript.length + match[2].length });
    transcript += match[2]; last = match.index + match[0].length;
  }
  return spans;
}

export function measureCounts(transcript, language) {
  const m = measure(transcript, 60_000, language);
  return { fillers: m.filler_count, hedges: m.hedge_count, restarts: m.restart_count };
}

// Baseline: the same phrases as one flat list, each counted wherever it occurs with Unicode word boundaries.
// No phrase precedence and no one-span-one-category rule, so overlapping phrases are all counted.
const escape = s => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
export function flatListCounts(transcript, language) {
  const text = transcript.toLowerCase().normalize('NFC');
  const counts = Object.fromEntries(CATEGORIES.map(c => [c, 0]));
  for (const category of CATEGORIES)
    for (const phrase of LEXICON[language][category])
      counts[category] += (text.match(new RegExp(`(?<![\\p{L}\\p{N}])${escape(phrase)}(?![\\p{L}\\p{N}])`, 'gu')) ?? []).length;
  return counts;
}

// Replay scripted replies through the same parse, shape check and one-retry rule as sparkJSON (src/capture.mjs).
export function scriptedModelResult(replies) {
  const sent = replies.slice(0, ANALYSIS_BUDGETS.length);
  for (const [n, content] of sent.entries()) {
    const parsed = parseObject(content, shapeOf(acceptLabels)), labels = parsed && acceptLabels(parsed);
    if (labels) return { status: 'model_labels', labels, model: ANALYSIS_MODEL, provider_request_id: null, attempts: n + 1 };
  }
  return { status: 'unavailable', reason: 'No scripted reply held usable JSON.', attempts: sent.length };
}
const countsOf = adjudication => ({ fillers: adjudication.adjudicated_count.fillers, hedges: adjudication.adjudicated_count.hedges, restarts: adjudication.adjudicated_count.restarts });
export function scriptedAdjudication(item, scripted) {
  const { candidates } = adjudicationCandidates(item.transcript, item.language);
  if (!candidates.length) return buildAdjudication(item.transcript, item.language, null);
  const fixture = scripted.get(item.id);
  if (!fixture) throw new Error(`No scripted adjudication reply for ${item.id}`);
  return buildAdjudication(item.transcript, item.language, scriptedModelResult(fixture.replies));
}

export const SYSTEMS = {
  measure: { describe: 'measure() in src/capture.mjs: normalization, longest phrase first, each span counted once in one category.', count: item => measureCounts(item.transcript, item.language) },
  flat_list_baseline: { describe: 'The same lexicon phrases as one flat list, every occurrence counted with Unicode word boundaries, overlaps counted.', count: item => flatListCounts(item.transcript, item.language) },
  adjudicated_scripted: { describe: 'measure() hits, then the adjudication check in src/adjudicate.mjs applied to scripted adjudication outputs (eval/scripted-adjudication.json), not live model runs.', count: (item, scripted) => countsOf(scriptedAdjudication(item, scripted)) }
};

const round = x => x === null ? null : Math.round(x * 1000) / 1000;
function rates({ tp, fp, fn }) {
  const precision = tp + fp ? tp / (tp + fp) : null, recall = tp + fn ? tp / (tp + fn) : null;
  const f1 = precision && recall ? 2 * precision * recall / (precision + recall) : (precision === null || recall === null ? null : 0);
  return { tp, fp, fn, precision: round(precision), recall: round(recall), f1: round(f1) };
}
const add = (acc, key, cell) => { const t = acc[key] ??= { tp: 0, fp: 0, fn: 0 }; t.tp += cell.tp; t.fp += cell.fp; t.fn += cell.fn; };
const finish = acc => Object.fromEntries(Object.keys(acc).sort().map(k => [k, rates(acc[k])]));

function loadItems(raw) {
  const corpus = JSON.parse(raw.toString('utf8'));
  const items = corpus.items.map(item => ({ ...item, ...parseItem(item.text) }));
  const ids = new Set(items.map(i => i.id));
  if (ids.size !== items.length) throw new Error('Duplicate item id in corpus');
  return { corpus, items };
}

// Scoring unit: one item x one category. tp = min(predicted, gold); the excess on either side is fp or fn.
// Items are short and mostly carry one phenomenon each, which limits offsetting errors inside a cell.
export function scoreSystem(items, predictions) {
  const overall = {}, byCategory = {}, byLanguage = {}, byTag = {};
  let controlFalseCounts = 0;
  items.forEach((item, n) => {
    for (const category of CATEGORIES) {
      const gold = item.gold[category], predicted = predictions[n][category];
      const cell = { tp: Math.min(gold, predicted), fp: Math.max(0, predicted - gold), fn: Math.max(0, gold - predicted) };
      add(overall, 'all', cell); add(byCategory, category, cell); add(byLanguage, item.language, cell);
      for (const tag of item.tags) add(byTag, tag, cell);
      if (item.tags.includes('negative_control')) controlFalseCounts += predicted;
    }
  });
  return { overall: rates(overall.all), by_category: finish(byCategory), by_language: finish(byLanguage), by_tag: finish(byTag),
    negative_control: { items: items.filter(i => i.tags.includes('negative_control')).length, false_counts: controlFalseCounts } };
}

// What a live adjudication run over the corpus would cost: one Spark call per item with ambiguous hits,
// and at most one retry each.
export function livePlan(items) {
  const withCandidates = items.filter(i => adjudicationCandidates(i.transcript, i.language).candidates.length);
  return { model: ANALYSIS_MODEL, calls: withCandidates.length, max_calls_with_retries: withCandidates.length * ANALYSIS_BUDGETS.length,
    candidates: withCandidates.reduce((n, i) => n + adjudicationCandidates(i.transcript, i.language).candidates.length, 0) };
}

function loadScripted(raw, items) {
  const fixtures = JSON.parse(raw.toString('utf8'));
  const scripted = new Map(fixtures.items.map(f => [f.id, f]));
  if (scripted.size !== fixtures.items.length) throw new Error('Duplicate item id in scripted adjudication replies');
  const needed = new Set(items.filter(i => adjudicationCandidates(i.transcript, i.language).candidates.length).map(i => i.id));
  for (const id of scripted.keys()) if (!needed.has(id)) throw new Error(`Scripted reply for ${id}, which has no candidates`);
  for (const id of needed) if (!scripted.has(id)) throw new Error(`No scripted adjudication reply for ${id}`);
  return { fixtures, scripted };
}

// Code accepts or rejects each scripted label; this tallies what it did and, against gold, what it could not catch.
function adjudicationReport(items, scripted, fixtures, scriptedRaw) {
  const statuses = {}, rejected = Object.fromEntries(REJECTIONS.map(r => [r, 0])), faults = {};
  let candidates = 0, alwaysHabit = 0, verified = 0, correct = 0, wrong = 0, ignored = 0, noUsableReply = 0, retried = 0;
  for (const item of items) {
    const result = scriptedAdjudication(item, scripted);
    alwaysHabit += result.summary.always_habit;
    if (result.status === 'no_candidates') continue;
    statuses[result.status] = (statuses[result.status] ?? 0) + 1;
    candidates += result.summary.candidates; ignored += result.summary.ignored_entries;
    if (result.model === null) noUsableReply++;
    else if (result.attempts > 1) retried++;
    const spans = goldSpans(item.text);
    for (const c of result.candidates) {
      if (c.rejection) rejected[c.rejection]++;
      if (!c.verified) continue;
      verified++;
      const goldHabit = spans.some(s => c.start >= s.start && c.end <= s.end);
      if ((c.label === 'habit') === goldHabit) correct++; else wrong++;
    }
  }
  for (const f of fixtures.items) if (f.fault) faults[f.fault] = (faults[f.fault] ?? 0) + 1;
  const rejectedTotal = Object.values(rejected).reduce((x, y) => x + y, 0);
  return {
    label: 'Scripted adjudication outputs, not live model runs.',
    method: ADJUDICATION_METHOD, replies: fixtures.name, replies_sha256: createHash('sha256').update(scriptedRaw).digest('hex'), provenance: fixtures.provenance,
    items_with_candidates: fixtures.items.length, candidates, always_habit_hits: alwaysHabit,
    scripted_faults: Object.fromEntries(Object.keys(faults).sort().map(k => [k, faults[k]])),
    statuses: Object.fromEntries(Object.keys(statuses).sort().map(k => [k, statuses[k]])),
    labels: { verified, rejected: rejectedTotal, rejected_by_reason: rejected, fell_back_without_labels: candidates - verified - rejectedTotal, ignored_entries: ignored },
    items_without_usable_reply: noUsableReply, items_answered_on_retry: retried,
    accepted_labels_against_gold: { correct, wrong, note: 'The check cannot catch a wrong label that quotes the span correctly; those are counted here.' },
    live_plan: livePlan(items)
  };
}

export function runEval(raw = readFileSync(CORPUS_URL), scriptedRaw = readFileSync(SCRIPTED_URL)) {
  const { corpus, items } = loadItems(raw);
  const { fixtures, scripted } = loadScripted(scriptedRaw, items);
  const systems = {}, disagreements = [];
  const predictions = Object.fromEntries(Object.entries(SYSTEMS).map(([name, s]) => [name, items.map(i => s.count(i, scripted))]));
  for (const [name, system] of Object.entries(SYSTEMS)) systems[name] = { describe: system.describe, ...scoreSystem(items, predictions[name]) };
  items.forEach((item, n) => {
    for (const category of CATEGORIES) {
      const row = { id: item.id, category, gold: item.gold[category], ...Object.fromEntries(Object.keys(SYSTEMS).map(s => [s, predictions[s][n][category]])) };
      if (Object.keys(SYSTEMS).some(s => row[s] !== row.gold)) disagreements.push(row);
    }
  });
  const gold = Object.fromEntries(CATEGORIES.map(c => [c, items.reduce((sum, i) => sum + i.gold[c], 0)]));
  const languages = [...new Set(items.map(i => i.language))].sort();
  const m = systems.measure, b = systems.flat_list_baseline, a = systems.adjudicated_scripted;
  const adjudication = adjudicationReport(items, scripted, fixtures, scriptedRaw);
  return {
    eval: 'habit-count-measurement', corpus: corpus.name, corpus_sha256: createHash('sha256').update(raw).digest('hex'),
    provenance: corpus.provenance,
    methods: languages.map(l => LEXICON_VERSION[l]),
    lexicon_changes: `After the corpus was written: lexicon-en-v2 (2026-11-02) counts ${Object.entries(FORMS.en).map(([p, f]) => f.map(x => `"${x}"`).join(' and ') + ` as "${p}"`).join('; ')}, because Meta's transcription wrote a spoken "uh" as "ah". The corpus contains neither spelling, so no score changed.`,
    counts: { items: items.length, negative_controls: m.negative_control.items, by_language: Object.fromEntries(languages.map(l => [l, items.filter(i => i.language === l).length])), gold_labels: gold },
    scoring: 'Per item and category, tp = min(predicted, gold), fp = excess predicted, fn = missed gold. Micro-averaged. Negative controls carry no gold labels, so every count on them is a false positive.',
    headline: `measure(): precision ${m.overall.precision}, recall ${m.overall.recall} vs flat word list ${b.overall.precision} / ${b.overall.recall} on ${items.length} synthetic labelled en/fr transcripts; ${m.negative_control.false_counts} false counts on ${m.negative_control.items} clean controls.`,
    adjudication_headline: `Adjudicated, on scripted adjudication outputs (not live model runs): precision ${a.overall.precision}, recall ${a.overall.recall} vs lexicon only ${m.overall.precision} / ${m.overall.recall} vs flat word list ${b.overall.precision} / ${b.overall.recall}; code rejected ${adjudication.labels.rejected} of ${adjudication.candidates} scripted labels, had no usable reply for ${adjudication.labels.fell_back_without_labels} more and kept the lexicon count for all of them; it accepted ${adjudication.accepted_labels_against_gold.wrong} wrong labels that no span check can catch.`,
    adjudication, systems, disagreements
  };
}

// The live arm: the real Muse Spark Open adjudication over the corpus. Paid; scripts/eval.mjs runs it only with
// --live --approved. models must provide adjudicateHabits (createAdjudicationModel in src/adjudicate.mjs).
// The corpus eval scores v1 adjudication (hedges sent, no model-only words), whatever the production defaults are.
export async function runLiveAdjudication({ models: client, raw = readFileSync(CORPUS_URL) }) {
  const models = { ...client, adjudicateModelOnly: false, adjudicateHedges: true };
  const { corpus, items } = loadItems(raw);
  const plan = livePlan(items), predictions = [], records = [];
  let attempts = 0;
  for (const item of items) {
    const result = await adjudicateCapture({ models, transcript: item.transcript, language: item.language });
    attempts += result.attempts; predictions.push(countsOf(result));
    if (result.status !== 'no_candidates') records.push({ id: item.id, status: result.status, attempts: result.attempts, provider_request_id: result.provider_request_id,
      reason: result.reason, labels: result.candidates.map(({ id, quote, label, verified, rejection, reason }) => ({ id, quote, label, verified, rejection, reason })) });
  }
  return { eval: 'habit-count-adjudication-live', label: 'Live Muse Spark Open adjudication runs.', corpus: corpus.name, corpus_sha256: createHash('sha256').update(raw).digest('hex'),
    method: ADJUDICATION_METHOD, plan, attempts_reported: attempts,
    systems: { measure: scoreSystem(items, items.map(i => measureCounts(i.transcript, i.language))), adjudicated_live: scoreSystem(items, predictions) }, items: records };
}
