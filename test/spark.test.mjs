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

test('parseObject: braces in the prose do not break it; the last object of the expected shape wins', async () => {
  const { parseObject, shapeOf } = await import('../src/capture.mjs');
  const items = shapeOf(accept);
  assert.deepEqual(parseObject('The ask {in braces} is buried. {"items":[1]}', items), { items: [1] });
  assert.deepEqual(parseObject('Draft: {"items": "no"} then final {"items":[2]} {not json}', items), { items: [2] });
  assert.deepEqual(parseObject('{"items":[3]} and an aside {"other":1}', items), { items: [3] }, 'a later object of the wrong shape is skipped');
  assert.deepEqual(parseObject('Example {"items":[0]}\n```json\n{"items":[4]}\n```\nDone {x}', items), { items: [4] }, 'a fenced block comes first');
  assert.deepEqual(parseObject('{"items":[{"a":"}"}]}', items), { items: [{ a: '}' }] }, 'braces inside strings are skipped');
  assert.deepEqual(parseObject('{"outer":{"items":[5]}}'), { outer: { items: [5] } }, 'a nested object is not taken out of its parent');
  assert.deepEqual(parseObject('Unclosed {note {"items":[6]}', items), { items: [6] });
  assert.deepEqual(parseObject('{"other": 1}', items), { other: 1 }, 'with no match, the object that parsed comes back for the shape check');
  assert.equal(parseObject('{"items": [1, "cut off'), null);
  assert.equal(parseObject('no json {here}'), null);
  assert.equal(parseObject('[1, 2]'), null);
  assert.equal(parseObject('{'.repeat(5000) + '"a":1'), null, 'a pathological reply ends quickly');
});

test('sparkJSON: braces in the prose cost no retry, and attempts counts the requests actually sent', async () => {
  const prose = scripted(reply('Here {as asked} is the answer: {"items":[1]} (see {notes}).'));
  assert.deepEqual(await sparkJSON({ env, fetchImpl: prose.fetchImpl, system: 's', user: 'u', accept }), { ok: true, value: [1], provider_request_id: 'resp-1', attempts: 1 });
  assert.equal(prose.bodies.length, 1);
  for (const status of [400, 401, 403, 404]) {
    const s = scripted(new Response('{}', { status }));
    const result = await sparkJSON({ env, fetchImpl: s.fetchImpl, system: 's', user: 'u', accept });
    assert.deepEqual({ ok: result.ok, attempts: result.attempts, sent: s.bodies.length }, { ok: false, attempts: 1, sent: 1 }, `HTTP ${status}`);
  }
  const twice = scripted(new Response('{}', { status: 503 }), new TypeError('network'));
  assert.deepEqual(await sparkJSON({ env, fetchImpl: twice.fetchImpl, system: 's', user: 'u', accept }), { ok: false, reason: 'Analysis request failed.', attempts: 2 });
  let calls = 0;
  const refuse = async () => { calls++; if (calls === 1) return new Response('{}', { status: 503 }); throw Object.assign(new Error('refused'), { budgetRefused: true }); };
  assert.deepEqual(await sparkJSON({ env, fetchImpl: refuse, system: 's', user: 'u', accept }),
    { ok: false, reason: 'Analysis skipped: not enough time left in this request.', attempts: 1, skipped_for_time: true });
  const adjudicated = await createModelClients({ env, fetchImpl: scripted(new Response('{}', { status: 400 })).fetchImpl })
    .analyze({ goal: null, transcript: 't', metrics: measure('t', 1000, 'en'), language: 'en' });
  assert.deepEqual(adjudicated, { status: 'unavailable', reason: 'Analysis returned HTTP 400.', attempts: 1 });
  const { scriptedModelResult } = await import('../src/evaluate.mjs');
  assert.equal(scriptedModelResult(['no json']).attempts, 1, 'the offline replay counts the replies it read');
  assert.equal(scriptedModelResult(['{"labels": "x"} then {"labels": []}']).attempts, 1);
});

// The offline eval cannot wait on fetch, so scriptedModelResult (src/evaluate.mjs) applies sparkJSON's rule synchronously.
// This keeps the two from drifting: every scripted reply set, plus edge cases, gives the same outcome through the live loop.
test('scriptedModelResult: every scripted reply set gives the same labels and attempts as sparkJSON', async () => {
  const { readFileSync } = await import('node:fs');
  const { scriptedModelResult, SCRIPTED_URL } = await import('../src/evaluate.mjs');
  const { acceptLabels } = await import('../src/adjudicate.mjs');
  const sets = JSON.parse(readFileSync(SCRIPTED_URL, 'utf8')).items.map(i => i.replies);
  sets.push(['no json'], ['no json', '{"labels": []}'], ['{"labels": "x"}', 'still no'], ['nope', 'still nope', '{"labels": []}'], ['{"labels": [{"id": "c1"}]} and {"other": 1}']);
  for (const replies of sets) {
    // Past the scripted replies nothing more is sent, as if the time budget refused the next call.
    let n = 0;
    const fetchImpl = async () => { if (n >= replies.length) throw Object.assign(new Error('no more'), { budgetRefused: true }); return reply(replies[n++]); };
    const live = await sparkJSON({ env, fetchImpl, system: 's', user: 'u', accept: acceptLabels, temperature: 0, label: 'Adjudication' });
    const offline = scriptedModelResult(replies);
    assert.deepEqual({ ok: offline.status === 'model_labels', labels: offline.labels ?? null, attempts: offline.attempts },
      { ok: live.ok, labels: live.ok ? live.value : null, attempts: live.attempts }, JSON.stringify(replies));
  }
});
