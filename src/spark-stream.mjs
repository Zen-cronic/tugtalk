// One fast Muse Spark Open call on Baseten for a live voice reply: streamed (server-sent events) or plain.
// Separate from sparkJSON (src/capture.mjs) on purpose: that loop and the default observation body stay as
// they are, and this one is built for latency, so it has no larger-budget retry of its own.
//
// Measured on Nov 2, 2026 for our key: only the pinned id below answers (the bare slug returns 403), the
// default reasoning effort stalled or returned empty content on 2 of 3 calls, and low effort answered with
// first content in about 1.7 s while spending 400-950 reasoning tokens. So effort is always set, the token
// budget leaves room for that reasoning, a hard timeout bounds every call, and empty content is a failure.
// Never throws; failures come back as { ok: false, reason }.
import { ANALYSIS_MODEL } from './capture.mjs';

export const SPARK_URL = 'https://inference.baseten.co/v1/chat/completions';
export const SPARK_STREAM_MODEL = ANALYSIS_MODEL; // meta-models/muse-spark-open-1026
export const REASONING_EFFORTS = ['low', 'medium'];
export const MIN_MAX_TOKENS = 1500;
export const DEFAULT_MAX_TOKENS = 2000;
export const DEFAULT_TIMEOUT_MS = 10_000;
// A stream that sends nothing for this long is treated as stalled, even inside the hard timeout.
export const DEFAULT_IDLE_MS = 5_000;

const since = start => Math.round(performance.now() - start);

// Splits a server-sent-events byte stream into the JSON payloads of its "data:" lines; stops at [DONE].
async function* sseEvents(body) {
  const decoder = new TextDecoder();
  let buffer = '';
  for await (const chunk of body) {
    buffer += decoder.decode(chunk, { stream: true });
    let cut;
    while ((cut = buffer.search(/\r?\n/)) >= 0) {
      const line = buffer.slice(0, cut); buffer = buffer.slice(cut + (buffer[cut] === '\r' ? 2 : 1));
      if (!line.startsWith('data:')) continue;
      const data = line.slice(5).trim();
      if (data === '[DONE]') return;
      if (!data) continue;
      try { yield JSON.parse(data); } catch { /* a malformed event is skipped, never fatal */ }
    }
  }
}

// options: system, user (strings); stream (default true); reasoningEffort ('low' default, or 'medium');
// maxTokens (>= 1500); temperature; timeoutMs (whole call); idleMs (gap between stream chunks); onContent(delta).
// Returns { ok: true, content, finish_reason, usage, provider_request_id, timing_ms: { first_chunk, first_content, total } }
// or { ok: false, reason, status?, finish_reason?, timing_ms }.
export async function sparkCall({ env = process.env, fetchImpl = fetch, system, user, stream = true, reasoningEffort = 'low',
  maxTokens = DEFAULT_MAX_TOKENS, temperature = 0.4, timeoutMs = DEFAULT_TIMEOUT_MS, idleMs = DEFAULT_IDLE_MS, onContent, label = 'Reply' } = {}) {
  if (!REASONING_EFFORTS.includes(reasoningEffort)) throw new Error(`reasoningEffort must be one of: ${REASONING_EFFORTS.join(', ')}`);
  if (!Number.isInteger(maxTokens) || maxTokens < MIN_MAX_TOKENS) throw new Error(`maxTokens must be an integer of at least ${MIN_MAX_TOKENS}`);
  if (!env.BASETEN_API_KEY) return { ok: false, reason: `${label} is not configured on this deployment.`, timing_ms: { first_chunk: null, first_content: null, total: 0 } };
  const start = performance.now(), timing = { first_chunk: null, first_content: null, total: null };
  const controller = new AbortController();
  let why = null;
  const abort = reason => { if (!why) { why = reason; controller.abort(); } };
  const hard = setTimeout(() => abort('timeout'), timeoutMs);
  let idle;
  const touch = () => { clearTimeout(idle); idle = setTimeout(() => abort('idle'), idleMs); };
  const failed = (reason, extra = {}) => { timing.total = since(start); return { ok: false, reason, ...extra, timing_ms: timing }; };
  try {
    const response = await fetchImpl(SPARK_URL, {
      method: 'POST', headers: { Authorization: `Api-Key ${env.BASETEN_API_KEY}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ model: SPARK_STREAM_MODEL, max_tokens: maxTokens, temperature, reasoning_effort: reasoningEffort, stream,
        messages: [{ role: 'system', content: system }, { role: 'user', content: user }] }),
      signal: controller.signal });
    const requestId = response.headers.get('x-baseten-request-id');
    if (!response.ok) return failed(`${label} returned HTTP ${response.status}.`, { status: response.status });
    let content = '', finish = null, usage = null, id = null;
    if (stream) {
      if (!response.body) return failed(`${label} returned no stream.`);
      touch();
      for await (const event of sseEvents(response.body)) {
        touch();
        timing.first_chunk ??= since(start);
        id ??= event.id ?? null;
        if (event.usage) usage = event.usage;
        const choice = event.choices?.[0];
        if (!choice) continue;
        const delta = choice.delta?.content;
        if (typeof delta === 'string' && delta) {
          timing.first_content ??= since(start);
          content += delta;
          onContent?.(delta);
        }
        if (choice.finish_reason) finish = choice.finish_reason;
      }
    } else {
      const data = await response.json().catch(() => null);
      if (why) throw Object.assign(new Error(why), { name: 'AbortError' });
      timing.first_chunk = timing.first_content = since(start);
      if (!data || typeof data !== 'object') return failed(`${label} returned a malformed reply.`);
      const choice = data.choices?.[0];
      content = typeof choice?.message?.content === 'string' ? choice.message.content : '';
      finish = choice?.finish_reason ?? null; usage = data.usage ?? null; id = data.id ?? null;
    }
    if (why) throw Object.assign(new Error(why), { name: 'AbortError' });
    if (finish === 'length') return failed(`${label} ran out of tokens before answering.`, { finish_reason: finish });
    if (!content.trim()) return failed(`${label} returned empty content.`, { finish_reason: finish });
    timing.total = since(start);
    return { ok: true, content, finish_reason: finish, usage, provider_request_id: requestId ?? id, timing_ms: timing };
  } catch (error) {
    if (why === 'timeout') return failed(`${label} timed out after ${timeoutMs} ms.`, { timed_out: true });
    if (why === 'idle') return failed(`${label} stream stalled for ${idleMs} ms.`, { timed_out: true });
    return failed(`${label} request failed.`);
  } finally {
    clearTimeout(hard); clearTimeout(idle);
  }
}
