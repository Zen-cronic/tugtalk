import test from 'node:test';
import assert from 'node:assert/strict';
import { createAdjudicationModel } from '../src/adjudicate.mjs';
import { createModelClients } from '../src/capture.mjs';

const capture = () => {
  const bodies = [];
  const fetchImpl = async (url, init) => { bodies.push(JSON.parse(init.body)); return new Response(JSON.stringify({ choices: [{ message: { content: 'not json' }, finish_reason: 'stop' }] }), { status: 200 }); };
  return { bodies, fetchImpl };
};
const env = { BASETEN_API_KEY: 'test-only' };

test('adjudication asks for low reasoning effort; the observation request does not set it', async () => {
  const a = capture();
  await createAdjudicationModel({ env, fetchImpl: a.fetchImpl }).adjudicateHabits({ transcript: 'um I mean it', language: 'en', candidates: [{ id: 'c1', phrase: 'i mean', category: 'fillers', start: 3, end: 9, text: 'I mean' }] });
  assert.ok(a.bodies.length >= 1);
  for (const body of a.bodies) assert.equal(body.reasoning_effort, 'low');
  const o = capture();
  await createModelClients({ env, fetchImpl: o.fetchImpl }).analyze({ goal: null, transcript: 'um hello', metrics: { word_count: 2, words_per_minute: 60, filler_count: 1, hedge_count: 0, restart_count: 0 }, language: 'en' });
  for (const body of o.bodies) assert.equal('reasoning_effort' in body, false);
});
