// Re-measure a captured session: the "improvement metrics" that kept recordings make possible.
// POST /v1/sessions/{id}/remeasure re-runs the code metrics (today's lexicon and pause rules) on the stored transcript.
// Free: no model call. With retranscribe: true it first sends the kept recording to Meta's transcription again (paid,
// so it must be asked for explicitly, and only a session whose recording was kept can do it).
// The new metrics are a new version of the session; every earlier measurement stays in `measurements`, oldest first.
// The analysis and the adjudication are not rewritten: they still describe the first measurement.
import { ApiError } from './store.mjs';
import { measure } from './capture.mjs';
import { getMedia } from './media.mjs';
import { createBudget, MIN_START_MS } from './budget.mjs';

const NO_PHASES = { async release() {}, async acquire() {} };
export const REMEASURE_PATH = /^\/v1\/sessions\/([A-Za-z0-9-]{1,64})\/remeasure$/;
// Counted together, free or paid: a re-transcription is a paid call, so the limit is set by it.
export const REMEASURE_RATE_LIMIT = { requests: 30, windowMs: 60 * 60 * 1000 };
const FIELDS = ['expected_version', 'retranscribe'];
const COUNTS = ['word_count', 'words_per_minute', 'filler_count', 'hedge_count', 'restart_count', 'fillers_per_100_words'];

export function validateRemeasure(body) {
  if (!body || Array.isArray(body) || typeof body !== 'object') throw new ApiError(400, 'invalid_body', 'Expected a JSON object.');
  for (const k of Object.keys(body)) if (!FIELDS.includes(k)) throw new ApiError(400, 'unknown_field', `Unsupported field: ${k}`);
  if (!Number.isInteger(body.expected_version) || body.expected_version < 1) throw new ApiError(400, 'missing_field', 'expected_version must be the session version from a fresh read.');
  if ('retranscribe' in body && typeof body.retranscribe !== 'boolean') throw new ApiError(400, 'invalid_type', 'Invalid retranscribe');
}

function measurable(store, user, id, expectedVersion) {
  const session = store.get(user, 'sessions', id);
  if (session.deleted) throw new ApiError(404, 'not_found', 'Record not found.');
  if (session.source !== 'capture' || session.measurement_status !== 'measured') throw new ApiError(400, 'not_measured', 'Only captured sessions can be re-measured.');
  if (session.version !== expectedVersion) throw new ApiError(409, 'version_conflict', `Current version is ${session.version}. Re-read before changing.`);
  return session;
}

export async function handleRemeasure(store, models, user, id, body, key, requestId, phases = NO_PHASES, budget = createBudget()) {
  validateRemeasure(body);
  const path = `/v1/sessions/${id}/remeasure`, retranscribe = body.retranscribe === true;
  // An exact retry returns the saved version without measuring or paying again.
  const previous = store.replay(user, 'POST', path, body, key);
  if (previous) return previous;
  const session = measurable(store, user, id, body.expected_version);
  if (retranscribe && session.media?.kept !== true)
    throw new ApiError(409, 'recording_not_kept', 'This session\'s recording was not kept, so it cannot be transcribed again. Re-measure without retranscribe uses the saved transcript.');
  if (store.recentRequestsMatching(user, 'POST', '/v1/sessions/%/remeasure', [200, 502], REMEASURE_RATE_LIMIT.windowMs) >= REMEASURE_RATE_LIMIT.requests)
    throw new ApiError(429, 'rate_limited', `At most ${REMEASURE_RATE_LIMIT.requests} re-measures per hour.`);
  let transcription = null;
  if (retranscribe) {
    const audio = getMedia(store, user, id).data;
    if (!budget.allows(MIN_START_MS.transcription)) throw new ApiError(503, 'time_budget', 'Not enough time left to transcribe; retry with the same Idempotency-Key.');
    await phases.release();
    try { transcription = await models.transcribe(audio, { language: session.language, sessionId: requestId, budget }); }
    finally { await phases.acquire(); }
  }
  return store.mutate(user, 'POST', path, body, key, () => {
    const current = measurable(store, user, id, body.expected_version);
    const transcript = transcription?.transcript ?? current.transcript, turns = transcription?.turns ?? current.turns ?? [];
    const metrics = measure(transcript, transcription?.audio_duration_ms ?? current.metrics.duration_ms, current.language, turns);
    const timestamp = new Date().toISOString();
    const earlier = { version: current.version, measured_at: current.remeasured?.at ?? current.occurred_at, metrics: current.metrics,
      ...(transcription ? { transcript: current.transcript, turns: current.turns, transcription: current.transcription } : {}) };
    const record = { ...current, version: current.version + 1, metrics, measurements: [...(current.measurements ?? []), earlier],
      ...(transcription ? { transcript, turns, transcription: { model: transcription.model, provider_session_id: transcription.provider_session_id } } : {}),
      remeasured: { at: timestamp, from_version: current.version, method: metrics.method, retranscribed: Boolean(transcription),
        changed: COUNTS.some(k => metrics[k] !== current.metrics[k]) || JSON.stringify(metrics.pauses) !== JSON.stringify(current.metrics.pauses),
        unchanged_fields: ['analysis', 'adjudication'] },
      updated_at: timestamp };
    store.put(user, 'sessions', record);
    return record;
  });
}
