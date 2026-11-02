// "Keep my recordings": off by default and then nothing is stored; on, the original WAV is kept with its record, can be
// downloaded only by its owner, deleted, capped, and re-measured as a new session version. No network, no paid calls.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Store, digest } from '../src/store.mjs';
import { createApp } from '../src/server.mjs';
import { keepMedia, MEDIA_CAP_BYTES, MEDIA_DOWNLOAD_LIMIT } from '../src/media.mjs';

function wav(seconds = 1, rate = 16000, tone = 330) {
  const samples = Math.round(seconds * rate), data = Buffer.alloc(samples * 2);
  for (let i = 0; i < samples; i++) data.writeInt16LE(Math.round(Math.sin(2 * Math.PI * tone * i / rate) * 3000 + (i % 17) * 7), i * 2);
  const h = Buffer.alloc(44);
  h.write('RIFF', 0); h.writeUInt32LE(36 + data.length, 4); h.write('WAVE', 8); h.write('fmt ', 12); h.writeUInt32LE(16, 16);
  h.writeUInt16LE(1, 20); h.writeUInt16LE(1, 22); h.writeUInt32LE(rate, 24); h.writeUInt32LE(rate * 2, 28); h.writeUInt16LE(2, 32); h.writeUInt16LE(16, 34);
  h.write('data', 36); h.writeUInt32LE(data.length, 40);
  return Buffer.concat([h, data]);
}

function fakeModels() {
  const calls = { transcribe: 0, audio: [] };
  const models = {
    async transcribe(audio) {
      calls.transcribe++; calls.audio.push(Buffer.from(audio));
      const transcript = calls.nextTranscript ?? 'Ah, we ship it. Um, today.';
      return { transcript, turns: [{ turn_id: 0, start_ms: 100, end_ms: 900, transcript }], audio_duration_ms: 1000, model: 'muse-voice-transcribe-1.0', provider_session_id: 'fake' };
    },
    async analyze() { return { status: 'model_observation', observation: 'Two fillers.', suggested_exercise: 'Answer once.', model: 'fake', provider_request_id: 'fake' }; },
    async voiceReply() { return { status: 'model_reply', reply: { move: 'follow_up', quote: 'we ship it', question: 'Why today?' }, model: 'fake', provider_request_id: 'fake', attempts: 1 }; }
  };
  return { calls, models };
}

async function withServer(fn) {
  const dir = mkdtempSync(join(tmpdir(), 'keep-test-'));
  const dbPath = join(dir, 'keep.sqlite');
  const store = new Store(dbPath);
  store.addToken('alice-secret', 'alice'); store.addToken('bob-secret', 'bob'); store.addToken('alice-reader', 'alice', ['read']);
  store.seed('alice'); store.seed('bob');
  const { calls, models } = fakeModels();
  const server = createApp(store, { models }); await new Promise(r => server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${server.address().port}`;
  let n = 0;
  const call = async (method, path, { body, token = 'alice-secret', key = `keep-key-${++n}`, raw = false } = {}) => {
    const headers = { Authorization: `Bearer ${token}`, 'Idempotency-Key': key };
    if (body !== undefined) headers['Content-Type'] = 'application/json';
    const r = await fetch(base + path, { method, headers, ...(body !== undefined ? { body: JSON.stringify(body) } : {}) });
    return { status: r.status, headers: r.headers, data: raw ? Buffer.from(await r.arrayBuffer()) : await r.json() };
  };
  const post = async (path, audio, { token = 'alice-secret', key = `audio-key-${++n}` } = {}) => {
    const r = await fetch(base + path, { method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'audio/wav', 'Idempotency-Key': key, 'X-Capture-Device': path === '/v1/recordings' ? 'watch' : 'api' }, body: audio });
    return { status: r.status, data: await r.json() };
  };
  const setKeep = async (on, extra = {}, token = 'alice-secret') => {
    const current = (await call('GET', '/v1/settings', { token })).data.settings;
    return call('PATCH', '/v1/settings', { token, body: { expected_version: current.version, keep_recordings: on, ...extra } });
  };
  const mediaDir = user => join(dir, 'media', user);
  const files = user => existsSync(mediaDir(user)) ? readdirSync(mediaDir(user)) : [];
  try { await fn({ call, post, setKeep, store, calls, dbPath, mediaDir, files }); }
  finally { await new Promise(r => server.close(r)); store.close(); rmSync(dir, { recursive: true, force: true }); }
}

test('keep recordings: off by default, and then no audio is stored anywhere', async () => {
  await withServer(async ({ call, post, store, dbPath, files }) => {
    const { status, data } = await call('GET', '/v1/settings');
    assert.equal(status, 200);
    assert.deepEqual({ ...data.settings, updated_at: undefined }, { keep_recordings: false, label: 'Keep my recordings', version: 1, updated_at: undefined, kept: { recordings: 0, bytes: 0, cap_bytes: MEDIA_CAP_BYTES } });
    const audio = wav(1.2);
    const saved = await post('/v1/recordings', audio);
    assert.equal(saved.status, 200);
    assert.equal(saved.data.record.audio_retained, false);
    assert.equal('media' in saved.data.record, false, 'the record is exactly as before the setting existed');
    const round = await post('/v1/voice-rounds', wav(0.8));
    assert.equal(round.status, 200); assert.equal('media' in round.data, false);
    assert.equal(store.list('alice', 'voice-rounds')[0].audio_retained, false);
    assert.deepEqual(files('alice'), [], 'no media folder is written');
    store.db.exec('PRAGMA wal_checkpoint(TRUNCATE)');
    assert.equal(readFileSync(dbPath).includes(audio.subarray(2000, 2064)), false, 'the audio is not in the database');
    const overview = (await call('GET', '/v1/overview')).data;
    assert.deepEqual(overview.settings, { keep_recordings: false, version: 1, kept_recordings: 0, kept_bytes: 0 });
    assert.equal((await call('GET', `/v1/media/${saved.data.record.id}`)).status, 404);
    assert.deepEqual((await call('GET', '/v1/media')).data.media, []);
  });
});

test('keep recordings: on keeps the original WAV with its hash, once per exact retry, for recordings and voice rounds', async () => {
  await withServer(async ({ call, post, setKeep, calls, mediaDir, files }) => {
    const before = (await call('GET', '/v1/overview')).data.snapshot_revision;
    const on = await setKeep(true);
    assert.equal(on.status, 200); assert.equal(on.data.record.keep_recordings, true); assert.equal(on.data.record_version, 2);
    assert.equal(on.data.settings.keep_recordings, true);
    assert.notEqual((await call('GET', '/v1/overview')).data.snapshot_revision, before, 'turning it on changes the revision Muse cites');
    const audio = wav(1.5);
    const first = await post('/v1/recordings', audio, { key: 'kept-capture-1' });
    assert.equal(first.status, 200);
    const record = first.data.record;
    assert.equal(record.audio_retained, true);
    assert.deepEqual({ ...record.media, kept_at: undefined }, { kept: true, kind: 'audio', bytes: audio.length, sha256: digest(audio), content_type: 'audio/wav', kept_at: undefined });
    assert.equal(record.media.sha256, record.audio_sha256);
    assert.deepEqual(readFileSync(join(mediaDir('alice'), `${record.id}.wav`)), audio, 'the stored file is the uploaded bytes');
    // An exact retry replays the receipt: no model call, no second file.
    const retry = await post('/v1/recordings', audio, { key: 'kept-capture-1' });
    assert.equal(retry.data.replayed, true); assert.equal(retry.data.receipt_id, first.data.receipt_id);
    assert.equal(calls.transcribe, 1);
    assert.deepEqual(files('alice'), [`${record.id}.wav`]);
    // A voice round is kept the same way, and its reply says so.
    const roundAudio = wav(0.9, 24000);
    const round = await post('/v1/voice-rounds', roundAudio);
    assert.equal(round.status, 200); assert.equal(round.data.media.kept, true); assert.equal(round.data.media.sha256, digest(roundAudio));
    assert.deepEqual(files('alice').sort(), [`${record.id}.wav`, `${round.data.round_id}.wav`].sort());
    // The owner sees, and downloads, exactly what was kept.
    const list = (await call('GET', '/v1/media')).data;
    assert.equal(list.recordings, 2); assert.equal(list.bytes, audio.length + roundAudio.length);
    assert.deepEqual(list.media.map(m => m.record_kind).sort(), ['sessions', 'voice-rounds']);
    const download = await call('GET', `/v1/media/${record.id}`, { raw: true });
    assert.equal(download.status, 200); assert.equal(download.headers.get('content-type'), 'audio/wav');
    assert.equal(download.headers.get('x-media-sha256'), digest(audio));
    assert.deepEqual(download.data, audio);
    const overview = (await call('GET', '/v1/overview')).data;
    assert.deepEqual(overview.settings, { keep_recordings: true, version: 2, kept_recordings: 2, kept_bytes: audio.length + roundAudio.length });
  });
});

test('keep recordings: another account never sees, downloads or deletes your audio; downloads are rate-limited and never logged', async () => {
  await withServer(async ({ call, post, setKeep, store, files }) => {
    await setKeep(true);
    const audio = wav(1);
    const { data } = await post('/v1/recordings', audio);
    const id = data.record.id;
    assert.equal((await call('GET', `/v1/media/${id}`, { token: 'bob-secret' })).status, 404);
    assert.equal((await call('DELETE', `/v1/media/${id}`, { token: 'bob-secret' })).status, 404);
    assert.deepEqual((await call('GET', '/v1/media', { token: 'bob-secret' })).data.media, []);
    assert.equal((await call('DELETE', '/v1/media', { token: 'bob-secret' })).data.record.deleted.recordings, 0);
    assert.deepEqual(files('alice'), [`${id}.wav`], 'bob deleting all touched nothing of alice');
    assert.equal((await call('DELETE', `/v1/media/${id}`, { token: 'alice-reader' })).status, 403, 'a read-only key cannot delete');
    assert.equal((await call('PATCH', '/v1/settings', { token: 'alice-reader', body: { expected_version: 2, keep_recordings: false } })).status, 403);
    // The request log never holds a hash of the audio.
    const hashes = store.db.prepare('SELECT response_hash FROM requests').all().map(r => r.response_hash);
    assert.equal(hashes.includes(digest(audio)), false);
    let status;
    let downloads = 0;
    while (downloads < MEDIA_DOWNLOAD_LIMIT.requests && (status = (await call('GET', `/v1/media/${id}`, { raw: true })).status) === 200) downloads++;
    assert.equal(downloads, MEDIA_DOWNLOAD_LIMIT.requests);
    assert.equal((await call('GET', `/v1/media/${id}`)).status, 429, `download ${MEDIA_DOWNLOAD_LIMIT.requests + 1} in an hour is refused`);
  });
});

test('keep recordings: delete removes the file and the reference; turning off can delete everything kept', async () => {
  await withServer(async ({ call, post, setKeep, store, files }) => {
    await setKeep(true);
    const a = (await post('/v1/recordings', wav(1))).data.record, b = (await post('/v1/recordings', wav(1.1, 16000, 500))).data.record;
    const round = (await post('/v1/voice-rounds', wav(0.7))).data;
    const del = await call('DELETE', `/v1/media/${a.id}`, { key: 'delete-one-1' });
    assert.equal(del.status, 200); assert.equal(del.data.record_version, 2);
    assert.equal(del.data.record.media.kept, false); assert.equal('sha256' in del.data.record.media, false); assert.equal(del.data.record.audio_retained, false);
    assert.equal(store.get('alice', 'sessions', a.id).version, 2);
    assert.equal(files('alice').includes(`${a.id}.wav`), false, 'the file is gone');
    assert.equal((await call('GET', `/v1/media/${a.id}`)).status, 404);
    assert.equal((await call('DELETE', `/v1/media/${a.id}`, { key: 'delete-one-1' })).data.replayed, true, 'an exact retry replays the receipt');
    assert.equal((await call('DELETE', `/v1/media/${a.id}`)).status, 404, 'a new delete of a deleted recording is a 404');
    // Turning the setting on is not allowed together with deleting.
    assert.equal((await call('PATCH', '/v1/settings', { body: { expected_version: 2, keep_recordings: true, delete_kept_recordings: true } })).status, 400);
    assert.equal((await call('PATCH', '/v1/settings', { body: { expected_version: 1, keep_recordings: false } })).status, 409, 'a stale version is refused');
    // "Turn off and delete kept recordings".
    const off = await setKeep(false, { delete_kept_recordings: true });
    assert.equal(off.status, 200); assert.equal(off.data.record.keep_recordings, false);
    assert.equal(off.data.record.last_deleted.recordings, 2);
    assert.deepEqual(off.data.settings.kept, { recordings: 0, bytes: 0, cap_bytes: MEDIA_CAP_BYTES });
    assert.deepEqual(files('alice'), []);
    assert.equal(store.get('alice', 'sessions', b.id).media.kept, false);
    assert.equal(store.get('alice', 'voice-rounds', round.round_id).media.kept, false);
    // Off again: a new capture stores nothing.
    const after = (await post('/v1/recordings', wav(1, 16000, 700))).data.record;
    assert.equal('media' in after, false); assert.deepEqual(files('alice'), []);
    // DELETE /v1/media deletes all in one call.
    await setKeep(true);
    await post('/v1/recordings', wav(1, 16000, 800));
    const all = await call('DELETE', '/v1/media');
    assert.equal(all.status, 200); assert.equal(all.data.record.deleted.recordings, 1);
    assert.deepEqual(files('alice'), []);
  });
});

test('keep recordings: the per-account cap saves the capture without its audio and says why', async () => {
  await withServer(async ({ call, post, setKeep, store, files }) => {
    await setKeep(true);
    const audio = wav(1);
    store.mediaCapBytes = Math.floor(audio.length * 1.5);
    const first = (await post('/v1/recordings', audio)).data.record;
    assert.equal(first.media.kept, true);
    const second = await post('/v1/recordings', wav(1, 16000, 600));
    assert.equal(second.status, 200, 'the capture is still saved');
    assert.deepEqual(second.data.record.media, { kept: false, kind: 'audio', reason: 'full', message: 'Your kept recordings are full (0 MB). Delete some to keep new ones.' });
    assert.equal(second.data.record.audio_retained, false);
    assert.deepEqual(files('alice'), [`${first.id}.wav`]);
    assert.throws(() => keepMedia(store, 'alice', 'audio', 'direct-1', audio), e => e.code === 'media_full' && e.status === 409);
    assert.throws(() => keepMedia(store, 'alice', 'photo', 'direct-2', audio), e => e.status === 400, 'only audio and video kinds');
    store.mediaCapBytes = undefined;
    assert.equal(keepMedia(store, 'alice', 'video', 'direct-3', Buffer.from('not really video')).kind, 'video', 'the API accepts video for a later clip feature');
    assert.match(MEDIA_CAP_BYTES.toString(), /^200000000$/);
    const view = (await call('GET', '/v1/settings')).data.settings;
    assert.equal(view.kept.cap_bytes, MEDIA_CAP_BYTES);
  });
});

test('re-measure: the code metrics are recomputed as a new version and the old ones are kept; re-transcribing needs a kept recording and the flag', async () => {
  await withServer(async ({ call, post, setKeep, store, calls }) => {
    // A session measured before "ah" counted as a filler (lexicon-en-v1): rewrite its stored metrics to that state.
    const session = (await post('/v1/recordings', wav(1))).data.record;
    const old = { ...session.metrics, method: 'lexicon-en-v1', filler_count: 1, fillers: { um: 1 }, fillers_per_100_words: 16.7 };
    store.put('alice', 'sessions', { ...session, metrics: old });
    const path = `/v1/sessions/${session.id}/remeasure`;
    const r = await call('POST', path, { body: { expected_version: 1 }, key: 'remeasure-1' });
    assert.equal(r.status, 200);
    const v2 = r.data.record;
    assert.equal(v2.version, 2); assert.equal(v2.metrics.method, 'lexicon-en-v2');
    assert.equal(v2.metrics.filler_count, 2); assert.deepEqual(v2.metrics.fillers, { uh: 1, um: 1 });
    assert.deepEqual(v2.measurements, [{ version: 1, measured_at: session.occurred_at, metrics: old }]);
    assert.equal(v2.remeasured.changed, true); assert.equal(v2.remeasured.retranscribed, false); assert.equal(v2.remeasured.from_version, 1);
    assert.equal(v2.transcript, session.transcript); assert.deepEqual(v2.analysis, session.analysis, 'the observation is not rewritten');
    assert.equal(calls.transcribe, 1, 'a code re-measure makes no model call');
    assert.equal((await call('POST', path, { body: { expected_version: 1 }, key: 'remeasure-1' })).data.replayed, true);
    assert.equal((await call('POST', path, { body: { expected_version: 1 } })).status, 409, 'a stale version is refused');
    assert.equal((await call('POST', path, { body: { expected_version: 2, retranscribe: true } })).data.error, 'recording_not_kept');
    assert.equal(calls.transcribe, 1, 'refused before any model call');
    assert.equal((await call('POST', '/v1/sessions/session-before/remeasure', { body: { expected_version: 1 } })).data.error, 'not_measured');
    assert.equal((await call('POST', path, { body: { expected_version: 2 }, token: 'bob-secret' })).status, 404);
    // With the recording kept, an explicit retranscribe sends exactly the kept bytes to transcription once.
    await setKeep(true);
    const audio = wav(1.3, 16000, 450);
    const kept = (await post('/v1/recordings', audio)).data.record;
    calls.nextTranscript = 'Er, we ship it today.';
    const again = await call('POST', `/v1/sessions/${kept.id}/remeasure`, { body: { expected_version: 1, retranscribe: true } });
    assert.equal(again.status, 200);
    assert.equal(calls.transcribe, 3); assert.deepEqual(calls.audio.at(-1), audio);
    const v = again.data.record;
    assert.equal(v.transcript, 'Er, we ship it today.'); assert.equal(v.remeasured.retranscribed, true);
    assert.equal(v.measurements[0].transcript, kept.transcript, 'the earlier transcript is kept with its metrics');
    assert.equal(v.metrics.filler_count, 1);
    assert.equal(v.media.kept, true, 'the recording stays kept');
  });
});
