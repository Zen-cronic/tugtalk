import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { runEval, parseItem, measureCounts, flatListCounts, CORPUS_URL } from '../src/evaluate.mjs';
import { Store } from '../src/store.mjs';
import { createApp } from '../src/server.mjs';

const committed = JSON.parse(readFileSync(new URL('../eval/results.json', import.meta.url), 'utf8'));
const corpus = JSON.parse(readFileSync(CORPUS_URL, 'utf8'));

test('the committed eval results regenerate exactly from the corpus', () => {
  assert.deepEqual(runEval(), committed);
  assert.deepEqual(runEval(), runEval(), 'deterministic');
});

test('markup parsing yields the transcript and per-category gold counts', () => {
  assert.deepEqual(parseItem('[F:Um], [R:what I mean is], we can, [F:uh], cut it. [H:Maybe].'),
    { transcript: 'Um, what I mean is, we can, uh, cut it. Maybe.', gold: { fillers: 2, hedges: 1, restarts: 1 } });
  assert.throws(() => parseItem('[X:oops] text'), /Malformed/);
});

test('negative control: clean transcripts produce zero counts', () => {
  const controls = corpus.items.filter(i => i.tags.includes('negative_control'));
  assert.ok(controls.length >= 10 && controls.some(i => i.language === 'fr') && controls.some(i => i.language === 'en'));
  for (const item of controls) {
    assert.doesNotMatch(item.text, /\[[FHR]:/, `${item.id} must carry no labels`);
    assert.deepEqual(measureCounts(item.text, item.language), { fillers: 0, hedges: 0, restarts: 0 }, item.id);
  }
  assert.equal(committed.systems.measure.negative_control.false_counts, 0);
});

test('the corpus covers both languages and the tricky cases', () => {
  const tags = new Set(corpus.items.flatMap(i => i.tags));
  for (const tag of ['plain', 'overlap', 'content_trap', 'out_of_lexicon', 'repeat', 'dash', 'asr_variant', 'multi_phrase_event', 'negative_control']) assert.ok(tags.has(tag), tag);
  assert.ok(committed.counts.by_language.en >= 30 && committed.counts.by_language.fr >= 30);
  // "vous vous" and "that that" are grammatical repeats, never restarts.
  assert.equal(measureCounts('Vous vous souvenez de la réunion ?', 'fr').restarts, 0);
  assert.equal(measureCounts('She said that that report was ready.', 'en').restarts, 0);
});

test('phrase precedence is what separates measure() from the flat-list baseline', () => {
  const text = 'I mean, the demo works. What I mean is the demo works on the watch.';
  assert.deepEqual(measureCounts(text, 'en'), { fillers: 1, hedges: 0, restarts: 1 });
  assert.deepEqual(flatListCounts(text, 'en'), { fillers: 2, hedges: 0, restarts: 1 });
  const m = committed.systems.measure.overall, b = committed.systems.flat_list_baseline.overall;
  assert.ok(m.precision > b.precision && m.recall === b.recall);
});

test('README eval line states the committed headline numbers', () => {
  const first = readFileSync(new URL('../docs/technical.md', import.meta.url), 'utf8').split('\n').find(line => line.startsWith('**Measured habit counts'));
  assert.ok(first, 'README has the eval line');
  const m = committed.systems.measure, b = committed.systems.flat_list_baseline;
  for (const value of [m.overall.precision, m.overall.recall, b.overall.precision, b.overall.recall, committed.counts.items, m.negative_control.items])
    assert.ok(first.includes(String(value)), `README eval line should include ${value}: ${first}`);
  assert.match(first, /synthetic/i);
});

test('GET /v1/eval is public, read-only and recomputes the committed results', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'eval-test-'));
  const store = new Store(join(dir, 'test.sqlite'));
  const server = createApp(store); await new Promise(r => server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    const r = await fetch(base + '/v1/eval');
    assert.equal(r.status, 200);
    assert.equal(r.headers.get('cache-control'), 'no-store');
    assert.deepEqual(await r.json(), committed);
    const post = await fetch(base + '/v1/eval', { method: 'POST' });
    assert.equal(post.status, 401, 'writes to the path still need a token');
    assert.equal((await fetch(base + '/v1/overview')).status, 401, 'other /v1 paths stay authenticated');
  } finally { await new Promise(r => server.close(r)); store.close(); rmSync(dir, { recursive: true, force: true }); }
});
