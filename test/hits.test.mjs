// Lexicon hits carry their exact span in the transcript, and counting them gives the same numbers as the
// original whole-string counter, which is kept here as the reference.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { tokenize, habitHits, measure, LEXICON } from '../src/capture.mjs';
import { parseItem, CORPUS_URL } from '../src/evaluate.mjs';

const norm = text => text.toLowerCase().normalize('NFC').replace(/[’]/g, "'").replace(/[^\p{L}\p{N}' -]+/gu, ' ').replace(/(^| )-+(?= |$)/g, ' ').replace(/\s+/g, ' ').trim();
function referenceCounts(transcript, language) {
  let remaining = ` ${norm(transcript)} `;
  const out = {};
  for (const category of ['restarts', 'fillers', 'hedges']) {
    const counts = {};
    for (const phrase of [...LEXICON[language][category]].sort((a, b) => b.length - a.length)) {
      const pattern = new RegExp(` ${phrase.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}(?= )`, 'g');
      const n = (remaining.match(pattern) ?? []).length;
      if (n) { counts[phrase] = n; remaining = remaining.replace(pattern, ' '); }
    }
    out[category] = counts;
  }
  return out;
}

const corpus = JSON.parse(readFileSync(CORPUS_URL, 'utf8')).items.map(i => ({ ...i, ...parseItem(i.text) }));
const extra = [
  ['en', 'Um um, you you know know, sorry sorry, what I mean is I mean.'],
  ['en', 'Well - I think -- so, kind-of, sort  of, MAYBE… probably!'],
  ['en', 'I mean,\tyou\nknow — basically —basically'],
  ['fr', 'Euh… peut-être, peut être, Pardon, je recommence ; je veux dire du coup.'],
  ['fr', 'Qu’on l’ait fait, ben, bah, en fait, tu vois, disons, un peu.'],
  ['fr', 'Café euh, je pense que je crois.']
];
const cases = [...corpus.map(i => [i.language, i.transcript]), ...extra];

test('tokenize yields the same words as the normalizer', () => {
  for (const [, text] of cases) assert.deepEqual(tokenize(text).tokens.map(t => t.word), norm(text).split(' ').filter(Boolean), text);
});

test('hit counts equal the reference counter on every corpus item and edge case', () => {
  for (const [language, text] of cases) assert.deepEqual(habitHits(text, language).counts, referenceCounts(text, language), text);
});

test('every hit quotes its exact span, spans never overlap, and measure() counts them', () => {
  for (const [language, text] of cases) {
    const { text: nfc, hits } = habitHits(text, language);
    hits.forEach((h, n) => {
      assert.equal(nfc.slice(h.start, h.end), h.quote);
      assert.equal(norm(h.quote), h.phrase, `${h.quote} normalizes to its phrase`);
      if (n) assert.ok(hits[n - 1].end <= h.start, 'sorted and disjoint');
    });
    const m = measure(text, 60_000, language);
    for (const [category, key] of [['fillers', 'filler_count'], ['hedges', 'hedge_count'], ['restarts', 'restart_count']])
      assert.equal(hits.filter(h => h.category === category).length, m[key], `${key}: ${text}`);
  }
  const { hits } = habitHits('It costs too much. What I mean is the setup, you, know.', 'en');
  assert.deepEqual(hits.map(h => [h.category, h.quote]), [['restarts', 'What I mean is'], ['fillers', 'you, know']]);
});
