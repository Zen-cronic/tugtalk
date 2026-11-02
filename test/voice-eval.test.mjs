// The offline voice-reply eval regenerates exactly, matches every expected reply, and never speaks unsaid words.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runVoiceEval, unsaidWords } from '../src/voice-eval.mjs';

const committed = JSON.parse(readFileSync(new URL('../eval/voice-results.json', import.meta.url), 'utf8'));

test('the committed voice-reply results regenerate exactly and are labelled scripted', () => {
  assert.deepEqual(runVoiceEval(), committed);
  assert.match(committed.label, /^Scripted voice replies, not live model runs\.$/);
  assert.match(committed.provenance, /^Scripted voice replies, not live model runs\./);
});

test('every case matches its expected reply; the check covers acceptance and rejection', () => {
  const [agree, total] = committed.matches_expected.split(' of ').map(Number);
  assert.equal(agree, total);
  assert.ok(committed.counts.quotes_accepted >= 5 && committed.counts.quotes_rejected >= 5);
  for (const reason of ['not_in_transcript', 'too_long']) assert.ok(committed.counts.rejections[reason] >= 1, reason);
  assert.ok(committed.counts.unusable >= 3);
});

test('after the check no reply speaks words the person never said; trusting the model would', () => {
  assert.equal(committed.checked.replies_with_unsaid_words, 0);
  assert.ok(committed.baseline.replies_with_unsaid_words > 0, 'the baseline is not a strawman with nothing to catch');
  for (const c of committed.cases.filter(c => !c.unusable)) assert.equal(c.unsaid_after_check, 0, c.id);
  assert.equal(unsaidWords('We grew a bit.', { quote: '', question: 'You said "we doubled"?' }), 1);
  assert.equal(unsaidWords('We grew a bit.', { quote: 'grew a bit', question: 'Why "a bit"?' }), 0);
});
