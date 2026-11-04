// Helpers shared by practice rounds (src/practice.mjs) and follow-up exercises (src/practice-exercises.mjs).
import { ApiError } from './store.mjs';

export const ID = /^[A-Za-z0-9_-]{1,64}$/;
export const now = () => new Date().toISOString();
export const object = x => x !== null && typeof x === 'object' && !Array.isArray(x);
// A nonempty string of at most max characters.
export const text = (value, max) => typeof value === 'string' && value.trim().length > 0 && value.length <= max;
export const fail = (code, message, status = 409) => { throw new ApiError(status, code, message); };
// The record, or null when it does not exist (or belongs to another account).
export const find = (store, user, kind, id) => { try { return store.get(user, kind, id); } catch (e) { if (e.status === 404) return null; throw e; } };
// Refuses a body that is not an object or has a field outside names. Each module keeps its own message.
export function fields(body, names, message) {
  if (!object(body) || Object.keys(body).some(k => !names.includes(k))) fail('invalid_body', message, 400);
}
