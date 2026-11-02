// Per-person settings. Today one: "Keep my recordings" (keep_recordings), off by default.
// The setting is one versioned record (kind "settings", id "settings"). An account that never changed it has no row
// and reads the default at version 1, so its snapshot revision is the same as before settings existed.
import { ApiError } from './store.mjs';

export const SETTINGS_PATH = '/v1/settings';
export const SETTINGS_KIND = 'settings';
export const SETTINGS_ID = 'settings';
export const DEFAULT_SETTINGS = Object.freeze({ keep_recordings: false });
export const KEEP_LABEL = 'Keep my recordings';
const FIELDS = ['expected_version', 'keep_recordings', 'delete_kept_recordings'];

// The stored record, or the default one (version 1, never saved).
export function readSettings(store, user) {
  const saved = store.list(user, SETTINGS_KIND).find(s => s.id === SETTINGS_ID);
  return saved ?? { id: SETTINGS_ID, version: 1, ...DEFAULT_SETTINGS, updated_at: null };
}

export const keepRecordingsOn = (store, user) => readSettings(store, user).keep_recordings === true;

// PATCH body: { expected_version, keep_recordings, delete_kept_recordings? }. delete_kept_recordings is accepted only
// when turning the setting off: "Turn off and delete kept recordings".
export function validateSettingsPatch(body) {
  if (!body || Array.isArray(body) || typeof body !== 'object') throw new ApiError(400, 'invalid_body', 'Expected a JSON object.');
  for (const k of Object.keys(body)) if (!FIELDS.includes(k)) throw new ApiError(400, 'unknown_field', `Unsupported field: ${k}`);
  if (!('expected_version' in body)) throw new ApiError(400, 'missing_field', 'Missing expected_version');
  if (!Number.isInteger(body.expected_version) || body.expected_version < 1) throw new ApiError(400, 'invalid_type', 'Invalid expected_version');
  if (!('keep_recordings' in body)) throw new ApiError(400, 'missing_field', 'Missing keep_recordings');
  if (typeof body.keep_recordings !== 'boolean') throw new ApiError(400, 'invalid_type', 'Invalid keep_recordings');
  if ('delete_kept_recordings' in body && typeof body.delete_kept_recordings !== 'boolean') throw new ApiError(400, 'invalid_type', 'Invalid delete_kept_recordings');
  if (body.delete_kept_recordings && body.keep_recordings) throw new ApiError(400, 'invalid_value', 'delete_kept_recordings needs keep_recordings false: turn the setting off to delete what is kept.');
}

// Runs inside store.mutate. deleteKept(store, user) deletes kept media when asked (src/media.mjs), in the same write.
export function applySettingsPatch(store, user, body, { deleteKept } = {}) {
  const current = readSettings(store, user);
  if (current.version !== body.expected_version) throw new ApiError(409, 'version_conflict', `Current version is ${current.version}. Re-read before changing.`);
  const record = { ...current, keep_recordings: body.keep_recordings, version: current.version + 1, updated_at: new Date().toISOString() };
  const deleted = body.delete_kept_recordings && deleteKept ? deleteKept(store, user) : null;
  if (deleted) record.last_deleted = { recordings: deleted.recordings, bytes: deleted.bytes, at: record.updated_at };
  store.put(user, SETTINGS_KIND, record);
  return record;
}
