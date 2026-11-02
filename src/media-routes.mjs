// Routes for "Keep my recordings": the setting, the kept files, and re-measuring. One call from src/server.mjs, after
// authentication, returns true when it answered the request.
//   GET    /v1/settings                    the setting and what is kept (count, bytes, cap)
//   PATCH  /v1/settings                    { expected_version, keep_recordings, delete_kept_recordings? }
//   GET    /v1/media                       this account's kept recordings (no audio)
//   GET    /v1/media/{id}                  the audio of one kept recording, as audio/wav; another account's id is a 404
//   DELETE /v1/media/{id}                  delete one: the file and the record's reference (new record version)
//   DELETE /v1/media                       delete all
//   POST   /v1/sessions/{id}/remeasure     { expected_version, retranscribe? } (src/remeasure.mjs)
// Every write takes an Idempotency-Key, as all writes do. Audio is never logged: a download's request-log row hashes
// a fixed label, not the bytes.
import { ApiError } from './store.mjs';
import { SETTINGS_PATH, KEEP_LABEL, readSettings, validateSettingsPatch, applySettingsPatch } from './settings.mjs';
import { listMedia, mediaUsage, getMedia, deleteMedia, deleteAllMedia, MEDIA_DOWNLOAD_LIMIT, MEDIA_KINDS } from './media.mjs';
import { handleRemeasure, REMEASURE_PATH } from './remeasure.mjs';

export const MEDIA_PATH = '/v1/media';
const ONE = /^\/v1\/media\/([^/]+)$/;

export function settingsView(store, user) {
  const s = readSettings(store, user);
  return { keep_recordings: s.keep_recordings === true, label: KEEP_LABEL, version: s.version, updated_at: s.updated_at, kept: mediaUsage(store, user) };
}

// helpers: { res, send, requestId, phases, budget, bodyOf, requireIdempotencyKey, audit } from the main handler.
export async function handleKeepRoutes(store, models, user, req, path, { res, send, requestId, phases, budget, bodyOf, requireIdempotencyKey, audit }) {
  const method = req.method;
  if (path === SETTINGS_PATH) {
    if (method === 'GET') { send(200, { settings: settingsView(store, user), request_id: requestId }); return true; }
    if (method === 'PATCH') {
      const key = requireIdempotencyKey(req.headers), body = await bodyOf(req);
      validateSettingsPatch(body);
      const receipt = store.mutate(user, 'PATCH', SETTINGS_PATH, body, key, () => applySettingsPatch(store, user, body, { deleteKept: deleteAllMedia }));
      send(200, { ...receipt, settings: settingsView(store, user) }); return true;
    }
    throw new ApiError(405, 'method_not_allowed', 'Use GET or PATCH.');
  }
  if (path === MEDIA_PATH) {
    if (method === 'GET') { send(200, { media: listMedia(store, user), ...mediaUsage(store, user), request_id: requestId }); return true; }
    if (method === 'DELETE') {
      const key = requireIdempotencyKey(req.headers);
      const receipt = store.mutate(user, 'DELETE', MEDIA_PATH, {}, key, () => ({ id: 'kept-recordings', version: 1, deleted: deleteAllMedia(store, user) }));
      send(200, receipt); return true;
    }
    throw new ApiError(405, 'method_not_allowed', 'Use GET or DELETE.');
  }
  const one = path.match(ONE);
  if (one) {
    const id = one[1];
    if (method === 'GET') {
      if (store.recentRequestsMatching(user, 'GET', `${MEDIA_PATH}/%`, [200], MEDIA_DOWNLOAD_LIMIT.windowMs) >= MEDIA_DOWNLOAD_LIMIT.requests)
        throw new ApiError(429, 'rate_limited', `At most ${MEDIA_DOWNLOAD_LIMIT.requests} recording downloads per hour.`);
      const media = getMedia(store, user, id);
      audit(200, `media ${media.id} ${media.bytes}`);
      res.writeHead(200, { 'Content-Type': media.content_type, 'Content-Length': String(media.data.length), 'Content-Disposition': `attachment; filename="${media.id}.${MEDIA_KINDS[media.kind].ext}"`,
        'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', 'X-Request-Id': requestId, 'X-Media-Sha256': media.sha256 });
      res.end(media.data);
      return true;
    }
    if (method === 'DELETE') {
      const key = requireIdempotencyKey(req.headers);
      send(200, store.mutate(user, 'DELETE', path, {}, key, () => deleteMedia(store, user, id))); return true;
    }
    throw new ApiError(405, 'method_not_allowed', 'Use GET or DELETE.');
  }
  const remeasure = method === 'POST' && path.match(REMEASURE_PATH);
  if (remeasure) {
    const key = requireIdempotencyKey(req.headers);
    send(200, await handleRemeasure(store, models, user, remeasure[1], await bodyOf(req), key, requestId, phases, budget)); return true;
  }
  return false;
}
