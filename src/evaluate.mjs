// Deterministic measurement eval: scores measure() and a flat word-list counter against a labelled corpus.
// No model calls, no clock, no randomness; the same corpus always yields byte-identical results.
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { measure, LEXICON } from './capture.mjs';

export const CATEGORIES = ['fillers', 'hedges', 'restarts'];
const CODES = { F: 'fillers', H: 'hedges', R: 'restarts' };
const MARK = /\[([FHR]):([^\]]+)\]/g;
export const CORPUS_URL = new URL('../eval/corpus.json', import.meta.url);

// "[F:Um], the point" -> transcript "Um, the point", gold {fillers: 1, hedges: 0, restarts: 0}.
export function parseItem(text) {
  const gold = Object.fromEntries(CATEGORIES.map(c => [c, 0]));
  for (const [, code] of text.matchAll(MARK)) gold[CODES[code]]++;
  const transcript = text.replace(MARK, (_, __, inner) => inner);
  if (/[[\]]/.test(transcript)) throw new Error(`Malformed markup: ${text}`);
  return { transcript, gold };
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

export const SYSTEMS = {
  measure: { describe: 'measure() in src/capture.mjs: normalization, longest phrase first, each span counted once in one category.', count: measureCounts },
  flat_list_baseline: { describe: 'The same lexicon phrases as one flat list, every occurrence counted with Unicode word boundaries, overlaps counted.', count: flatListCounts }
};

const round = x => x === null ? null : Math.round(x * 1000) / 1000;
function rates({ tp, fp, fn }) {
  const precision = tp + fp ? tp / (tp + fp) : null, recall = tp + fn ? tp / (tp + fn) : null;
  const f1 = precision && recall ? 2 * precision * recall / (precision + recall) : (precision === null || recall === null ? null : 0);
  return { tp, fp, fn, precision: round(precision), recall: round(recall), f1: round(f1) };
}
const add = (acc, key, cell) => { const t = acc[key] ??= { tp: 0, fp: 0, fn: 0 }; t.tp += cell.tp; t.fp += cell.fp; t.fn += cell.fn; };
const finish = acc => Object.fromEntries(Object.keys(acc).sort().map(k => [k, rates(acc[k])]));

// Scoring unit: one item x one category. tp = min(predicted, gold); the excess on either side is fp or fn.
// Items are short and mostly carry one phenomenon each, which limits offsetting errors inside a cell.
export function runEval(raw = readFileSync(CORPUS_URL)) {
  const corpus = JSON.parse(raw.toString('utf8'));
  const items = corpus.items.map(item => ({ ...item, ...parseItem(item.text) }));
  const ids = new Set(items.map(i => i.id));
  if (ids.size !== items.length) throw new Error('Duplicate item id in corpus');
  const systems = {}, disagreements = [];
  const predictions = Object.fromEntries(Object.entries(SYSTEMS).map(([name, s]) => [name, items.map(i => s.count(i.transcript, i.language))]));
  for (const [name, system] of Object.entries(SYSTEMS)) {
    const overall = {}, byCategory = {}, byLanguage = {}, byTag = {};
    let controlFalseCounts = 0;
    items.forEach((item, n) => {
      for (const category of CATEGORIES) {
        const gold = item.gold[category], predicted = predictions[name][n][category];
        const cell = { tp: Math.min(gold, predicted), fp: Math.max(0, predicted - gold), fn: Math.max(0, gold - predicted) };
        add(overall, 'all', cell); add(byCategory, category, cell); add(byLanguage, item.language, cell);
        for (const tag of item.tags) add(byTag, tag, cell);
        if (item.tags.includes('negative_control')) controlFalseCounts += predicted;
      }
    });
    systems[name] = { describe: system.describe, overall: rates(overall.all), by_category: finish(byCategory), by_language: finish(byLanguage), by_tag: finish(byTag),
      negative_control: { items: items.filter(i => i.tags.includes('negative_control')).length, false_counts: controlFalseCounts } };
  }
  items.forEach((item, n) => {
    for (const category of CATEGORIES) {
      const row = { id: item.id, category, gold: item.gold[category], ...Object.fromEntries(Object.keys(SYSTEMS).map(s => [s, predictions[s][n][category]])) };
      if (Object.keys(SYSTEMS).some(s => row[s] !== row.gold)) disagreements.push(row);
    }
  });
  const gold = Object.fromEntries(CATEGORIES.map(c => [c, items.reduce((sum, i) => sum + i.gold[c], 0)]));
  const languages = [...new Set(items.map(i => i.language))].sort();
  const m = systems.measure, b = systems.flat_list_baseline;
  return {
    eval: 'habit-count-measurement', corpus: corpus.name, corpus_sha256: createHash('sha256').update(raw).digest('hex'),
    provenance: corpus.provenance,
    methods: languages.map(l => `lexicon-${l}-v1`),
    counts: { items: items.length, negative_controls: m.negative_control.items, by_language: Object.fromEntries(languages.map(l => [l, items.filter(i => i.language === l).length])), gold_labels: gold },
    scoring: 'Per item and category, tp = min(predicted, gold), fp = excess predicted, fn = missed gold. Micro-averaged. Negative controls carry no gold labels, so every count on them is a false positive.',
    headline: `measure(): precision ${m.overall.precision}, recall ${m.overall.recall} vs flat word list ${b.overall.precision} / ${b.overall.recall} on ${items.length} synthetic labelled en/fr transcripts; ${m.negative_control.false_counts} false counts on ${m.negative_control.items} clean controls.`,
    systems, disagreements
  };
}
