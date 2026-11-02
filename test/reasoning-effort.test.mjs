import test from 'node:test';
import assert from 'node:assert/strict';
import { createAdjudicationModel } from '../src/adjudicate.mjs';
import { createModelClients, ANALYSIS_EFFORTS } from '../src/capture.mjs';
import { createScreenModel } from '../src/screen-context.mjs';

const capture = () => {
  const bodies = [];
  const fetchImpl = async (url, init) => { bodies.push(JSON.parse(init.body)); return new Response(JSON.stringify({ choices: [{ message: { content: 'not json' }, finish_reason: 'stop' }] }), { status: 200 }); };
  return { bodies, fetchImpl };
};
const env = { BASETEN_API_KEY: 'test-only' };

test('adjudication asks for low reasoning effort; the observation request does not set it by default', async () => {
  const a = capture();
  await createAdjudicationModel({ env, fetchImpl: a.fetchImpl }).adjudicateHabits({ transcript: 'um I mean it', language: 'en', candidates: [{ id: 'c1', phrase: 'i mean', category: 'fillers', start: 3, end: 9, text: 'I mean' }] });
  assert.ok(a.bodies.length >= 1);
  for (const body of a.bodies) assert.equal(body.reasoning_effort, 'low');
  const o = capture();
  await createModelClients({ env, fetchImpl: o.fetchImpl }).analyze({ goal: null, transcript: 'um hello', metrics: { word_count: 2, words_per_minute: 60, filler_count: 1, hedge_count: 0, restart_count: 0 }, language: 'en' });
  for (const body of o.bodies) assert.equal('reasoning_effort' in body, false);
});

async function bodies(env) {
  const sent = [];
  const answer = content => async (url, init) => { sent.push(init.body); return new Response(JSON.stringify({ choices: [{ message: { content } }] }), { status: 200 }); };
  await createModelClients({ env, fetchImpl: answer('{"observation":"o","suggested_exercise":"e"}') })
    .analyze({ goal: null, transcript: 'um hello', metrics: { word_count: 2, words_per_minute: 60, filler_count: 1, hedge_count: 0, restart_count: 0 }, language: 'en' });
  await createScreenModel({ env, fetchImpl: answer('{"summary":"s","observation":"o","next_step":"n"}') })
    .describeScreen({ goal: null, text: 'Agenda for the 1:1', language: 'en', purpose: 'meeting_prep', app_name: 'Notes' });
  assert.equal(sent.length, 2);
  return sent.map(body => JSON.parse(body));
}

test('ANALYSIS_EFFORT=medium adds reasoning_effort to the observation and the screen card, and nothing else changes', async () => {
  const [observation, card] = await bodies({ ...env, ANALYSIS_EFFORT: 'medium' });
  const [plainObservation, plainCard] = await bodies(env);
  for (const [withEffort, plain] of [[observation, plainObservation], [card, plainCard]]) {
    assert.equal(withEffort.reasoning_effort, 'medium');
    assert.equal('reasoning_effort' in plain, false);
    const { reasoning_effort, ...rest } = withEffort;
    assert.deepEqual(rest, plain);
  }
});

test('ANALYSIS_EFFORT accepts low, medium, high and xhigh; any other value is ignored', async () => {
  assert.deepEqual(ANALYSIS_EFFORTS, ['low', 'medium', 'high', 'xhigh']);
  for (const effort of ANALYSIS_EFFORTS) for (const body of await bodies({ ...env, ANALYSIS_EFFORT: effort })) assert.equal(body.reasoning_effort, effort);
  for (const effort of ['', 'max', 'Medium', 'none'])
    for (const body of await bodies({ ...env, ANALYSIS_EFFORT: effort })) assert.equal('reasoning_effort' in body, false, `ANALYSIS_EFFORT=${effort}`);
});
