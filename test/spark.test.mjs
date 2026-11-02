// The one Muse Spark Open call loop shared by the observation, the screen context card and adjudication.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { sparkJSON, ANALYSIS_MODEL, ANALYSIS_BUDGETS, createModelClients, measure } from '../src/capture.mjs';
import { createScreenModel } from '../src/screen-context.mjs';

const reply = (content, finish = 'stop', status = 200) => new Response(JSON.stringify({ id: 'resp-1', choices: [{ finish_reason: finish, message: { content } }] }), { status });
function scripted(...responses) {
  const bodies = [];
  return { bodies, fetchImpl: async (url, init) => { bodies.push(JSON.parse(init.body)); const next = responses.shift(); if (next instanceof Error) throw next; return next; } };
}
const env = { BASETEN_API_KEY: 'k' };
const accept = parsed => Array.isArray(parsed.items) ? parsed.items : null;

test('sparkJSON: retries a truncated or mis-shaped reply once with the larger budget', async () => {
  const s = scripted(reply('{"items": [1,', 'length'), reply('```json\n{"items":[1,2]}\n```'));
  const result = await sparkJSON({ env, fetchImpl: s.fetchImpl, system: 'sys', user: 'u', accept });
  assert.deepEqual(result, { ok: true, value: [1, 2], provider_request_id: 'resp-1', attempts: 2 });
  assert.deepEqual(s.bodies.map(b => b.max_tokens), ANALYSIS_BUDGETS);
  assert.ok(s.bodies.every(b => b.model === ANALYSIS_MODEL && b.temperature === 0.2));
  const shape = scripted(reply('{"other": 1}'), reply('{"other": 2}'));
  const failed = await sparkJSON({ env, fetchImpl: shape.fetchImpl, system: 's', user: 'u', accept, label: 'Adjudication', temperature: 0 });
  assert.deepEqual(failed, { ok: false, reason: 'Adjudication did not match the expected shape.', attempts: 2 });
  assert.equal(shape.bodies[0].temperature, 0);
});

test('sparkJSON: a 4xx is final, a 429, 5xx or network error is retried, and it never throws', async () => {
  const bad = scripted(new Response('{}', { status: 400 }));
  assert.equal((await sparkJSON({ env, fetchImpl: bad.fetchImpl, system: 's', user: 'u', accept })).reason, 'Analysis returned HTTP 400.');
  assert.equal(bad.bodies.length, 1);
  for (const first of [new Response('{}', { status: 429 }), new Response('{}', { status: 503 }), new TypeError('network')]) {
    const s = scripted(first, reply('{"items":[]}'));
    const result = await sparkJSON({ env, fetchImpl: s.fetchImpl, system: 's', user: 'u', accept });
    assert.equal(result.ok, true); assert.equal(result.attempts, 2);
  }
  const refusal = scripted(reply("I can't help with that."), reply(null));
  assert.deepEqual(await sparkJSON({ env, fetchImpl: refusal.fetchImpl, system: 's', user: 'u', accept }), { ok: false, reason: 'Analysis returned no usable JSON.', attempts: 2 });
});

test('the observation and the screen card both go through the shared loop with their own shapes', async () => {
  const a = scripted(reply('{"observation":"o"}'), reply('{"observation":"o","suggested_exercise":"e"}'));
  const analysis = await createModelClients({ env, fetchImpl: a.fetchImpl }).analyze({ goal: null, transcript: 't', metrics: measure('t', 1000, 'en'), language: 'en' });
  assert.deepEqual(analysis, { status: 'model_observation', observation: 'o', suggested_exercise: 'e', model: ANALYSIS_MODEL, provider_request_id: 'resp-1', attempts: 2 });
  const sc = scripted(reply('{"summary":"s","observation":"o","next_step":" "}'), reply('{"summary":"s","observation":"o","next_step":"n"}'));
  const card = await createScreenModel({ env, fetchImpl: sc.fetchImpl }).describeScreen({ goal: null, text: 'x', language: 'en', purpose: 'reading', app_name: null });
  assert.deepEqual(card, { status: 'model_observation', summary: 's', observation: 'o', next_step: 'n', model: ANALYSIS_MODEL, provider_request_id: 'resp-1', attempts: 2 });
});
