// Kept recordings: the original upload of a recording or voice round, stored only when the person turned on
// "Keep my recordings" (src/settings.mjs). Off by default; with it off nothing here writes a byte.
//
// Files live next to the database, under <database dir>/media/<user>/<id>.<ext> (on Modal: /data/media/...), so the
// hosting adapter's volume commit, which runs before every write is answered, holds the file and its record together.
// The record that owns a file carries media: { kept: true, kind, bytes, sha256, content_type, kept_at, duration_ms }; that
// reference is the only index. A file is written inside the record's write transaction, so a retry that replays the
// receipt never writes it twice.
//
// Kept audio is never logged and never sent to any model, except when the person asks for a re-transcription
// (POST /v1/sessions/{id}/remeasure with retranscribe: true, src/remeasure.mjs).
import { closeSync, existsSync, fstatSync, fsyncSync, mkdirSync, openSync, readFileSync, readSync, renameSync, rmSync, writeSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { ApiError, digest } from './store.mjs';
import { keepRecordingsOn } from './settings.mjs';
import { wavDurationMs } from './capture.mjs';

// Only audio is wired today. Video is accepted by the API so a later clip feature needs no new storage shape.
export const MEDIA_KINDS = { audio: { ext: 'wav', content_type: 'audio/wav' }, video: { ext: 'mp4', content_type: 'video/mp4' } };
// The record kinds that can own kept media.
export const MEDIA_RECORD_KINDS = ['sessions', 'voice-rounds'];
export const MEDIA_CAP_BYTES = 200 * 1000 * 1000; // 200 MB per account, about 70 minutes of 24 kHz mono audio
export const MEDIA_DOWNLOAD_LIMIT = { requests: 120, windowMs: 60 * 60 * 1000 };
// A test may set store.mediaCapBytes to a smaller cap.
const capOf = store => store.mediaCapBytes ?? MEDIA_CAP_BYTES;
export const fullMessage = cap => `Your kept recordings are full (${Math.round(cap / 1e6)} MB). Delete some to keep new ones.`;
const ID = /^[A-Za-z0-9-]{1,64}$/;

export const mediaRoot = store => join(dirname(resolve(store.path)), 'media');
// A user id is used as the folder name when it is a plain token; anything else gets a digest.
const userFolder = user => /^[A-Za-z0-9_-]{1,64}$/.test(user) ? user : `u-${digest(user).slice(0, 32)}`;
export function mediaPath(store, user, id, kind = 'audio') {
  if (!ID.test(id)) throw new ApiError(400, 'invalid_value', 'Invalid media id.');
  if (!Object.hasOwn(MEDIA_KINDS, kind)) throw new ApiError(400, 'invalid_value', `kind must be one of: ${Object.keys(MEDIA_KINDS).join(', ')}.`);
  return join(mediaRoot(store), userFolder(user), `${id}.${MEDIA_KINDS[kind].ext}`);
}

// Every record of this user that holds kept media.
function owners(store, user) {
  return MEDIA_RECORD_KINDS.flatMap(kind => store.list(user, kind).filter(r => r.media?.kept === true).map(record => ({ kind, record })));
}
// The audio's length from the stored file's WAV header, for files kept before duration_ms was recorded. Only the
// header is read, and the answer is cached by content digest, so a listing does not reread the audio. null if unreadable.
const durations = new Map();
function storedDurationMs(store, user, record) {
  if (record.media.kind !== 'audio') return null;
  const cached = durations.get(record.media.sha256);
  if (cached !== undefined) return cached;
  let ms = null, fd;
  try {
    fd = openSync(mediaPath(store, user, record.id, 'audio'), 'r');
    const header = Buffer.alloc(4096), n = readSync(fd, header, 0, header.length, 0);
    ms = wavDurationMs(header.subarray(0, n), fstatSync(fd).size);
  } catch { ms = null; } finally { if (fd !== undefined) closeSync(fd); }
  if (ms !== null && record.media.sha256) durations.set(record.media.sha256, ms);
  return ms;
}
const view = (store, user) => ({ kind, record }) => ({ id: record.id, record_kind: kind, record_version: record.version, kind: record.media.kind, bytes: record.media.bytes,
  sha256: record.media.sha256, content_type: record.media.content_type, kept_at: record.media.kept_at, occurred_at: record.occurred_at ?? null, record_hidden: record.deleted === true,
  duration_ms: Number.isFinite(record.media.duration_ms) ? record.media.duration_ms : storedDurationMs(store, user, record) });

export function listMedia(store, user) {
  return owners(store, user).map(view(store, user)).sort((a, b) => (b.occurred_at ?? '').localeCompare(a.occurred_at ?? '') || b.id.localeCompare(a.id));
}
export function mediaUsage(store, user) {
  const list = owners(store, user);
  return { recordings: list.length, bytes: list.reduce((n, o) => n + o.record.media.bytes, 0), cap_bytes: capOf(store) };
}

// Writes one file and returns the reference its record stores. Throws 409 media_full over the cap.
// meta: optional { content_type } for a kind with several encodings later; today the kind decides it.
export function keepMedia(store, user, kind, id, bytes, meta = {}) {
  const path = mediaPath(store, user, id, kind);
  if (!Buffer.isBuffer(bytes) || !bytes.length) throw new ApiError(400, 'invalid_value', 'Nothing to keep.');
  if (mediaUsage(store, user).bytes + bytes.length > capOf(store)) throw new ApiError(409, 'media_full', fullMessage(capOf(store)));
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  // Written to a temporary name, flushed, then renamed, so a reader or a commit never sees half a file.
  const temp = `${path}.part`, fd = openSync(temp, 'w', 0o600);
  try { writeSync(fd, bytes); fsyncSync(fd); } finally { closeSync(fd); }
  renameSync(temp, path);
  const durationMs = kind === 'audio' ? wavDurationMs(bytes) : null;
  return { kept: true, kind, bytes: bytes.length, sha256: digest(bytes), content_type: meta.content_type ?? MEDIA_KINDS[kind].content_type, kept_at: new Date().toISOString(),
    ...(durationMs !== null ? { duration_ms: durationMs } : {}) };
}

// The one call the recording and voice-round routes make, inside their write transaction, just before the record
// is put. With the setting off it does nothing at all: no file, no field. When the account is full the capture is
// still saved, with media: { kept: false, reason: "full", message } so the device can say why.
export function attachMedia(store, user, recordKind, record, bytes, kind = 'audio') {
  if (!MEDIA_RECORD_KINDS.includes(recordKind) || !keepRecordingsOn(store, user)) return record;
  try {
    record.media = keepMedia(store, user, kind, record.id, bytes);
    record.audio_retained = true;
  } catch (error) {
    if (error.code !== 'media_full') throw error;
    record.media = { kept: false, kind, reason: 'full', message: error.message };
  }
  return record;
}

function owner(store, user, id) {
  if (!ID.test(id)) throw new ApiError(404, 'not_found', 'No kept recording with this id.');
  const found = owners(store, user).find(o => o.record.id === id);
  if (!found) throw new ApiError(404, 'not_found', 'No kept recording with this id.');
  return found;
}

// The bytes of one of this user's kept recordings. Another user's id is a 404, as is a missing file.
export function getMedia(store, user, id) {
  const found = owner(store, user, id), path = mediaPath(store, user, id, found.record.media.kind);
  if (!existsSync(path)) throw new ApiError(404, 'not_found', 'The kept recording file is missing.');
  return { ...view(store, user)(found), data: readFileSync(path) };
}

// Removes the file and the record's reference to it; the record gets a new version. Runs inside a write transaction.
function forget(store, user, { kind, record }, timestamp) {
  rmSync(mediaPath(store, user, record.id, record.media.kind), { force: true });
  const updated = { ...record, media: { kept: false, kind: record.media.kind, deleted_at: timestamp }, audio_retained: false, version: record.version + 1, updated_at: timestamp };
  store.put(user, kind, updated);
  return updated;
}
export function deleteMedia(store, user, id) {
  return forget(store, user, owner(store, user, id), new Date().toISOString());
}
// Deletes every kept recording of this user, and anything else left in their media folder.
export function deleteAllMedia(store, user) {
  const timestamp = new Date().toISOString(), list = owners(store, user);
  const bytes = list.reduce((n, o) => n + o.record.media.bytes, 0);
  for (const o of list) forget(store, user, o, timestamp);
  rmSync(join(mediaRoot(store), userFolder(user)), { recursive: true, force: true });
  return { recordings: list.length, bytes };
}
