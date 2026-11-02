// The fast Spark Open call used for voice replies, against a fake fetch: request body, streaming, plain mode,
// timeouts, stalls, truncation and empty replies. No network.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { sparkCall, SPARK_URL, SPARK_STREAM_MODEL, MIN_MAX_TOKENS } from '../src/spark-stream.mjs';

const env = { BASETEN_API_KEY: 'test-only' };
const enc = new TextEncoder();
const event = payload => `data: ${JSON.stringify(payload)}\n\n`;
const delta = (content, extra = {}) => event({ id: 'chatcmpl-1', choices: [{ delta: { content }, ...extra }] });
const reasoning = text => event({ id: 'chatcmpl-1', choices: [{ delta: { reasoning_content: text } }] });

// A fake fetch that streams the given chunks (strings, or numbers = pause in ms), honours the abort signal,
// and records every request. `hang: true` keeps the stream open after the last chunk.
function streaming(chunks, { status = 200, hang = false, headers = { 'x-baseten-request-id': 'req-1' } } = {}) {
  const requests = [];
  const fetchImpl = async (url, init) => {
    requests.push({ url, body: JSON.parse(init.body), headers: init.headers });
    const body = new ReadableStream({
      async start(controller) {
        init.signal.addEventListener('abort', () => controller.error(new DOMException('aborted', 'AbortError')));
        for (const chunk of chunks) {
          if (init.signal.aborted) return;
          if (typeof chunk === 'number') await new Promise(r => setTimeout(r, chunk));
          else controller.enqueue(enc.encode(chunk));
        }
        if (!hang && !init.signal.aborted) controller.close();
      }
    });
    return new Response(body, { status, headers: { 'content-type': 'text/event-stream', ...headers } });
  };
  return { requests, fetchImpl };
}

test('sparkCall sends the pinned model, low effort, a 1500+ token budget and stream: true', async () => {
  const s = streaming([reasoning('thinking'), delta('{"move":'), delta('"follow_up"}', { finish_reason: 'stop' }), 'data: [DONE]\n\n']);
  const seen = [];
  const r = await sparkCall({ env, fetchImpl: s.fetchImpl, system: 'sys', user: 'u', onContent: d => seen.push(d) });
  assert.equal(r.ok, true);
  assert.equal(r.content, '{"move":"follow_up"}');
  assert.deepEqual(seen, ['{"move":', '"follow_up"}']);
  assert.equal(r.finish_reason, 'stop');
  assert.equal(r.provider_request_id, 'req-1');
  assert.ok(r.timing_ms.first_chunk <= r.timing_ms.first_content && r.timing_ms.first_content <= r.timing_ms.total);
  const [{ url, body, headers }] = s.requests;
  assert.equal(url, SPARK_URL);
  assert.equal(body.model, 'meta-models/muse-spark-open-1026');
  assert.equal(body.model, SPARK_STREAM_MODEL);
  assert.equal(body.reasoning_effort, 'low');
  assert.ok(body.max_tokens >= MIN_MAX_TOKENS);
  assert.equal(body.stream, true);
  assert.deepEqual(body.messages.map(m => m.role), ['system', 'user']);
  assert.equal(headers.Authorization, 'Api-Key test-only');
});

test('sparkCall refuses the default effort, a small budget, and runs nothing without a key', async () => {
  const s = streaming([delta('x')]);
  await assert.rejects(() => sparkCall({ env, fetchImpl: s.fetchImpl, system: 's', user: 'u', reasoningEffort: 'xhigh' }), /reasoningEffort/);
  await assert.rejects(() => sparkCall({ env, fetchImpl: s.fetchImpl, system: 's', user: 'u', maxTokens: 1000 }), /maxTokens/);
  const r = await sparkCall({ env: {}, fetchImpl: s.fetchImpl, system: 's', user: 'u' });
  assert.equal(r.ok, false); assert.match(r.reason, /not configured/);
  assert.equal(s.requests.length, 0);
});

test('sparkCall: plain mode reads one JSON reply', async () => {
  const requests = [];
  const fetchImpl = async (url, init) => { requests.push(JSON.parse(init.body));
    return new Response(JSON.stringify({ id: 'chatcmpl-9', choices: [{ finish_reason: 'stop', message: { content: '{"a":1}' } }], usage: { completion_tokens: 12 } }), { status: 200 }); };
  const r = await sparkCall({ env, fetchImpl, system: 's', user: 'u', stream: false, reasoningEffort: 'medium' });
  assert.equal(r.ok, true); assert.equal(r.content, '{"a":1}'); assert.equal(r.provider_request_id, 'chatcmpl-9');
  assert.deepEqual(r.usage, { completion_tokens: 12 });
  assert.equal(requests[0].stream, false); assert.equal(requests[0].reasoning_effort, 'medium');
});

test('sparkCall: a hard timeout aborts a slow stream mid-reply', async () => {
  const s = streaming([reasoning('a'), delta('{"move"'), 2000], { hang: true });
  const t0 = performance.now();
  const r = await sparkCall({ env, fetchImpl: s.fetchImpl, system: 's', user: 'u', timeoutMs: 200, idleMs: 5000 });
  assert.equal(r.ok, false); assert.equal(r.timed_out, true); assert.match(r.reason, /timed out after 200 ms/);
  assert.ok(performance.now() - t0 < 1500, 'returned soon after the deadline');
});

test('sparkCall: a stream that goes quiet is treated as stalled', async () => {
  const s = streaming([reasoning('a')], { hang: true });
  const r = await sparkCall({ env, fetchImpl: s.fetchImpl, system: 's', user: 'u', timeoutMs: 5000, idleMs: 150 });
  assert.equal(r.ok, false); assert.equal(r.timed_out, true); assert.match(r.reason, /stalled/);
});

test('sparkCall: a reply cut off by max_tokens, or with reasoning but no content, is a failure', async () => {
  const cut = streaming([reasoning('long thought'), delta('{"move":"chal', { finish_reason: 'length' }), 'data: [DONE]\n\n']);
  const r1 = await sparkCall({ env, fetchImpl: cut.fetchImpl, system: 's', user: 'u' });
  assert.equal(r1.ok, false); assert.equal(r1.finish_reason, 'length'); assert.match(r1.reason, /ran out of tokens/);
  const empty = streaming([reasoning('only thinking'), event({ choices: [{ delta: {}, finish_reason: 'stop' }] }), 'data: [DONE]\n\n']);
  const r2 = await sparkCall({ env, fetchImpl: empty.fetchImpl, system: 's', user: 'u' });
  assert.equal(r2.ok, false); assert.match(r2.reason, /empty content/);
});

test('sparkCall: an HTTP error (the bare-slug 403) or a network failure never throws', async () => {
  const forbidden = streaming([], { status: 403 });
  const r = await sparkCall({ env, fetchImpl: forbidden.fetchImpl, system: 's', user: 'u' });
  assert.deepEqual([r.ok, r.status, r.reason], [false, 403, 'Reply returned HTTP 403.']);
  const r2 = await sparkCall({ env, fetchImpl: async () => { throw new TypeError('network'); }, system: 's', user: 'u' });
  assert.equal(r2.ok, false); assert.equal(r2.reason, 'Reply request failed.');
});

test('sparkCall: SSE split across chunk boundaries, CRLF lines and malformed events', async () => {
  const whole = delta('{"q":"hi"}', { finish_reason: 'stop' });
  const s = streaming([': keep-alive\r\n\r\n', 'data: {not json}\n\n', whole.slice(0, 9), whole.slice(9).replace('\n\n', '\r\n\r\n'), 'data: [DONE]\n\n']);
  const r = await sparkCall({ env, fetchImpl: s.fetchImpl, system: 's', user: 'u' });
  assert.equal(r.ok, true); assert.equal(r.content, '{"q":"hi"}');
});

test('sparkCall with stopWhen: leaves the stream once the JSON closes, without waiting for its tail', async () => {
  const { jsonClosed } = await import('../src/spark-stream.mjs');
  // The reply closes, then the provider would keep the stream open for another 3 s.
  const s = streaming([reasoning('thinking'), delta('{"move":"challenge","quote":"maybe",'), delta('"question":"Why {you}?"}'), 3000, delta(' '), 'data: [DONE]\n\n']);
  const started = performance.now();
  const r = await sparkCall({ env, fetchImpl: s.fetchImpl, system: 'sys', user: 'u', stopWhen: jsonClosed });
  assert.equal(r.ok, true);
  assert.equal(r.content, '{"move":"challenge","quote":"maybe","question":"Why {you}?"}');
  assert.equal(r.timing_ms.stopped_early, true);
  assert.ok(performance.now() - started < 1000, 'did not wait for the tail');
  assert.equal(jsonClosed('{"a":"}"'), false, 'a brace inside a string does not close it');
  assert.equal(jsonClosed('{"a":"x\\"}"}'), true);
});

test('voice reply stream: braces in prose before the JSON do not stop it; the reply parses on the first attempt', async () => {
  const { createVoiceModel, replyClosed } = await import('../src/voice.mjs');
  const { jsonClosed } = await import('../src/spark-stream.mjs');
  const prose = 'Sure, pressing on {the ask}: ';
  assert.equal(jsonClosed(prose), true, 'the cheap check alone would stop here');
  assert.equal(replyClosed(prose), false);
  const json = '{"move":"challenge","quote":"","question":"What exactly is the ask?"}';
  assert.equal(replyClosed(prose + json.slice(0, -1)), false, 'not before the reply object closes');
  assert.equal(replyClosed(prose + json), true);
  // Then the provider would keep the stream open for another 3 s: the reply is read without waiting for it.
  const s = streaming([reasoning('thinking'), delta(prose), delta(json.slice(0, 30)), delta(json.slice(30)), 3000, delta(' '), 'data: [DONE]\n\n']);
  const started = performance.now();
  const r = await createVoiceModel({ env, fetchImpl: s.fetchImpl }).voiceReply({ system: 's', user: 'u' });
  assert.equal(r.status, 'model_reply'); assert.equal(r.attempts, 1); assert.equal(s.requests.length, 1);
  assert.deepEqual(r.reply, { move: 'challenge', question: 'What exactly is the ask?', quote: '' });
  assert.ok(performance.now() - started < 1000, 'stopped once the reply closed');
});
