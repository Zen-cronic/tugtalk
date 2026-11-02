// Drills: an exercise the assistant sets with a basis, a count of one habit over the person's own measured
// sessions or voice rounds. Code recounts the basis from the stored metrics before the exercise is saved, and
// refuses a wrong one with the true count. A later capture that names the drill (X-Exercise-Id) records one
// measured result against that basis: one capture, never a trend.
import { randomUUID } from 'node:crypto';
import { ApiError } from './store.mjs';

export const DRILL_HABITS = ['filler', 'hedge', 'restart'];
export const BASIS_MAX_SOURCES = 10;
export const BASIS_WINDOW_DAYS = 14;
export const DUE_MAX_DAYS = 7;
// A due time a little in the past is accepted (clock skew, or "now" written a moment ago).
export const DUE_PAST_GRACE_MS = 60 * 60 * 1000;
const DAY_MS = 24 * 60 * 60 * 1000;
const ID = /^[A-Za-z0-9-]{1,64}$/;
// Shown to people: hedges are called "unsure words".
const SINGULAR = { filler: 'filler', hedge: 'unsure word', restart: 'restart' };
const PLURAL = { filler: 'fillers', hedge: 'unsure words', restart: 'restarts' };
export const habitWord = (habit, n) => n === 1 ? SINGULAR[habit] : PLURAL[habit];

const isPlainObject = v => v !== null && typeof v === 'object' && !Array.isArray(v);
const bad = message => new ApiError(400, 'invalid_value', message);
const withDetails = (error, details) => Object.assign(error, { details });

// The exercise's optional due time: an ISO 8601 timestamp at most DUE_MAX_DAYS ahead. There is no minimum lead
// time, so a drill can be due the same morning it is set. Returns the normalized ISO string.
export function checkDueAt(value, now = Date.now()) {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}T/.test(value) || Number.isNaN(Date.parse(value))) throw bad('due_at must be an ISO 8601 timestamp.');
  const at = Date.parse(value);
  if (at > now + DUE_MAX_DAYS * DAY_MS) throw bad(`due_at must be at most ${DUE_MAX_DAYS} days ahead.`);
  if (at < now - DUE_PAST_GRACE_MS) throw bad('due_at must not be in the past.');
  return new Date(at).toISOString();
}

// An exercise with a basis and no check-in yet.
export const isOpenDrill = (exercise, checkIns) => isPlainObject(exercise.basis) && !checkIns.some(c => c.exercise_id === exercise.id);

function findSource(store, user, id) {
  for (const kind of ['sessions', 'voice-rounds']) {
    try { return { kind, record: store.get(user, kind, id) }; } catch (error) { if (error.status !== 404) throw error; }
  }
  return null;
}

// Why a cited source cannot back a basis, or null when it can. Another account's id reads as not found.
function refusal(source, now) {
  if (!source) return 'not_found';
  const { kind, record } = source;
  if (record.deleted) return 'deleted';
  if (kind === 'sessions' && (record.source !== 'capture' || record.measurement_status !== 'measured')) return 'not_measured';
  if (!isPlainObject(record.metrics)) return 'not_measured';
  const at = Date.parse(record.occurred_at);
  if (!Number.isFinite(at) || at < now - BASIS_WINDOW_DAYS * DAY_MS) return `older_than_${BASIS_WINDOW_DAYS}_days`;
  return null;
}

// Checks a basis for an exercise on goalId and returns what is stored with it. Runs inside the write transaction.
//   400 invalid_value       the basis is not {habit, source_ids, claimed_count}
//   409 drill_open          the goal already has an open drill
//   422 basis_source_invalid a cited id is not a measured capture or voice round of this account from the last 14 days
//   422 basis_mismatch      claimed_count is not the code-measured sum; the body carries the recomputed count
export function checkBasis(store, user, goalId, basis, now = Date.now()) {
  if (!isPlainObject(basis)) throw bad('basis must be an object: {habit, source_ids, claimed_count}.');
  for (const k of Object.keys(basis)) if (!['habit', 'source_ids', 'claimed_count'].includes(k)) throw bad(`basis has an unsupported field: ${k}`);
  const { habit, source_ids, claimed_count } = basis;
  if (!DRILL_HABITS.includes(habit)) throw bad(`basis.habit must be one of: ${DRILL_HABITS.join(', ')}.`);
  if (!Array.isArray(source_ids) || source_ids.length < 1 || source_ids.length > BASIS_MAX_SOURCES || source_ids.some(id => typeof id !== 'string' || !ID.test(id)))
    throw bad(`basis.source_ids must list 1–${BASIS_MAX_SOURCES} session or voice-round ids.`);
  if (new Set(source_ids).size !== source_ids.length) throw bad('basis.source_ids must not repeat an id.');
  if (!Number.isInteger(claimed_count) || claimed_count < 0 || claimed_count > 10000) throw bad('basis.claimed_count must be a whole number from 0.');

  const checkIns = store.list(user, 'check-ins');
  const open = store.list(user, 'exercises').find(e => e.goal_id === goalId && isOpenDrill(e, checkIns));
  if (open) throw withDetails(new ApiError(409, 'drill_open', `Goal already has an open drill (exercise ${open.id}). Record a check-in for it, completed or skipped, before setting another.`), { open_exercise_id: open.id });

  const sources = source_ids.map(id => ({ id, source: findSource(store, user, id) }));
  const refused = sources.map(({ id, source }) => ({ id, reason: refusal(source, now) })).filter(r => r.reason);
  if (refused.length) throw withDetails(new ApiError(422, 'basis_source_invalid', 'Cite only measured captures or voice rounds of this account from the last 14 days, not fixtures or hidden sessions.'), { refused });

  const field = `${habit}_count`;
  const per_source = sources.map(({ id, source }) => ({ id, kind: source.kind === 'sessions' ? 'session' : 'voice_round', count: Number.isInteger(source.record.metrics[field]) ? source.record.metrics[field] : 0 }));
  const count = per_source.reduce((n, s) => n + s.count, 0);
  if (count !== claimed_count) throw withDetails(new ApiError(422, 'basis_mismatch', `The basis claims ${claimed_count} ${habitWord(habit, claimed_count)}; code counts ${count} in the cited ${source_ids.length === 1 ? 'source' : 'sources'}. Correct claimed_count and retry with a new Idempotency-Key.`),
    { recomputed: { habit, count, per_source: per_source.map(({ id, count }) => ({ id, count })) } });
  return { habit, source_ids: [...source_ids], claimed_count, per_source, checked: 'recounted by the server from stored metrics', checked_at: new Date(now).toISOString() };
}

// The drill a capture names, from its headers. Kept apart from captureParams, whose output other products compare.
export function drillParams(headers) {
  const exerciseId = headers['x-exercise-id'] ?? null;
  if (exerciseId === null) return null;
  if (typeof exerciseId !== 'string' || !ID.test(exerciseId)) throw new ApiError(400, 'invalid_value', 'Invalid X-Exercise-Id.');
  return { exerciseId };
}

// Before any model call: the named exercise must exist on this account and, when the capture names a goal, belong to it.
export function checkDrillTarget(store, user, exerciseId, goalId) {
  const exercise = store.get(user, 'exercises', exerciseId);
  if (goalId && exercise.goal_id !== goalId) throw new ApiError(400, 'goal_mismatch', 'X-Exercise-Id belongs to a different goal than X-Goal-Id.');
  return exercise;
}

const sourceWord = (basis, n) => {
  const kinds = new Set((basis.per_source ?? []).map(s => s.kind));
  const [word, words] = kinds.size === 1 && kinds.has('voice_round') ? ['voice round', 'voice rounds'] : kinds.size === 1 ? ['session', 'sessions'] : ['recording', 'recordings'];
  return n === 1 ? word : words;
};

// Inside the capture's write transaction: writes one measured check-in for the drill, unless the exercise has no
// basis or already has a check-in. Returns the drill block saved on the session.
export function recordDrillResult(store, user, session, exerciseId, timestamp = new Date().toISOString()) {
  let exercise;
  try { exercise = store.get(user, 'exercises', exerciseId); } catch (error) { if (error.status === 404) return { exercise_id: exerciseId, status: 'not_measured', reason: 'not_found' }; throw error; }
  if (!isPlainObject(exercise.basis)) return { exercise_id: exerciseId, status: 'not_measured', reason: 'no_basis' };
  if (store.list(user, 'check-ins').some(c => c.exercise_id === exerciseId)) return { exercise_id: exerciseId, status: 'not_measured', reason: 'already_recorded' };
  const { habit, claimed_count: basisCount, source_ids } = exercise.basis;
  const captureCount = session.metrics[`${habit}_count`];
  const measured = { habit, capture_count: captureCount, basis_count: basisCount, basis_sources: source_ids.length, basis_source_word: sourceWord(exercise.basis, source_ids.length),
    session_id: session.id, capture_device: session.capture_device };
  const feedback = `Measured by code: ${captureCount} ${habitWord(habit, captureCount)} in this capture (session ${session.id}). `
    + `The drill's basis was ${basisCount} ${habitWord(habit, basisCount)} in ${source_ids.length} ${measured.basis_source_word}. One measured result, not a trend.`;
  const checkIn = { id: randomUUID(), version: 1, goal_id: exercise.goal_id, exercise_id: exercise.id, status: 'completed', feedback,
    evidence_type: 'measured', measured, updated_at: timestamp };
  store.put(user, 'check-ins', checkIn);
  return { exercise_id: exercise.id, status: 'measured', check_in_id: checkIn.id, measured };
}

// Wraps a product's recording hooks so one capture records the drill it names. The exercise id joins the
// idempotency fingerprint, so a retry must name the same drill. Without X-Exercise-Id the hooks are not wrapped.
export function withDrill(hooks, exerciseId, baseParams) {
  return { ...hooks,
    params: headers => ({ ...(hooks.params ? hooks.params(headers) : baseParams(headers)), exercise_id: exerciseId }),
    prepare: ctx => { checkDrillTarget(ctx.store, ctx.user, exerciseId, ctx.params.goalId); return hooks.prepare ? hooks.prepare(ctx) : undefined; },
    extendRecord: (record, ctx) => {
      const saved = hooks.extendRecord ? hooks.extendRecord(record, ctx) : record;
      return { ...saved, drill: recordDrillResult(ctx.store, ctx.user, saved, exerciseId, ctx.timestamp) };
    } };
}
