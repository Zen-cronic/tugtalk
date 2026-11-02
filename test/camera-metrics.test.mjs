// X-Camera-Metrics on POST /v1/voice-rounds: strict validation, metrics.camera in the record, the overview and the
// connector text. Fake models; no network, no paid calls.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Store } from '../src/store.mjs';
import { createApp, connectorDocument } from '../src/server.mjs';
import { parseCameraMetrics, CAMERA_METHOD, CAMERA_HEADER_MAX_BYTES } from '../src/camera-metrics.mjs';
import { voiceParams } from '../src/voice.mjs';
import { createLiveRound } from '../src/live-voice.mjs';

// The exact header the Mac sends (CameraMeterTests.testHeaderIsSortedCompactJSONAndValuesAreClamped).
const MAC_HEADER = '{"faced_camera_pct":62,"frames":148,"longest_look_away_ms":4100,"looked_away_count":3}';
const STORED = { faced_camera_pct: 62, looked_away_count: 3, longest_look_away_ms: 4100, frames: 148, method: CAMERA_METHOD };

function wav(seconds = 2, rate = 24000) {
  const samples = Math.round(seconds * rate), data = Buffer.alloc(samples * 2);
  for (let i = 0; i < samples; i++) data.writeInt16LE(Math.round(Math.sin(i / 9) * 2500 + (i % 17) * 7), i * 2);
  const h = Buffer.alloc(44);
  h.write('RIFF', 0); h.writeUInt32LE(36 + data.length, 4); h.write('WAVE', 8); h.write('fmt ', 12); h.writeUInt32LE(16, 16);
  h.writeUInt16LE(1, 20); h.writeUInt16LE(1, 22); h.writeUInt32LE(rate, 24); h.writeUInt32LE(rate * 2, 28); h.writeUInt16LE(2, 32); h.writeUInt16LE(16, 34);
  h.write('data', 36); h.writeUInt32LE(data.length, 40);
  return Buffer.concat([h, data]);
}

function fakeModels() {
  const calls = { transcribe: 0, voiceReply: 0, prompts: [] };
  return { calls, models: {
    async transcribe() { calls.transcribe++; return { transcript: 'Um, I think we should ship the smaller version first.', turns: [{ turn_id: 0, start_ms: 300, end_ms: 2600 }], audio_duration_ms: 3000, model: 'muse-voice-transcribe-1.0', provider_session_id: 'asr-1' }; },
    async voiceReply(input) { calls.voiceReply++; calls.prompts.push(input);
      return { status: 'model_reply', reply: { move: 'follow_up', quote: '', question: 'Why the smaller version first?' }, model: 'meta-models/muse-spark-open-1026', provider_request_id: 'req-c', attempts: 1 }; }
  } };
}

async function withServer(models, fn) {
  const dir = mkdtempSync(join(tmpdir(), 'camera-test-'));
  const store = new Store(join(dir, 'camera.sqlite'));
  store.addToken('alice-secret', 'alice'); store.seed('alice');
  const server = createApp(store, { models }); await new Promise(r => server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${server.address().port}`;
  const round = async (audio, { key, headers = {} }) => {
    const r = await fetch(base + '/v1/voice-rounds', { method: 'POST', headers: { Authorization: 'Bearer alice-secret', 'Content-Type': 'audio/wav', 'Idempotency-Key': key, ...headers }, body: audio });
    return { status: r.status, data: await r.json() };
  };
  const get = async path => (await fetch(base + path, { headers: { Authorization: 'Bearer alice-secret' } })).json();
  try { await fn({ round, get, store }); } finally { await new Promise(r => server.close(r)); store.close(); rmSync(dir, { recursive: true, force: true }); }
}

test('parseCameraMetrics: the Mac header is accepted, stamped with its method, and absence is null', () => {
  assert.deepEqual(parseCameraMetrics(MAC_HEADER), STORED);
  assert.deepEqual(parseCameraMetrics(JSON.parse(MAC_HEADER)), STORED, 'an already-parsed object (a live round) works the same');
  assert.equal(parseCameraMetrics(undefined), null);
  assert.equal(parseCameraMetrics(null), null);
  assert.deepEqual(parseCameraMetrics('{"faced_camera_pct":100,"looked_away_count":0,"longest_look_away_ms":0,"frames":5}'),
    { faced_camera_pct: 100, looked_away_count: 0, longest_look_away_ms: 0, frames: 5, method: CAMERA_METHOD });
  assert.deepEqual(parseCameraMetrics('{"faced_camera_pct":0,"looked_away_count":1200,"longest_look_away_ms":120000,"frames":1200}').frames, 1200, 'the upper bounds');
  assert.deepEqual(voiceParams({ 'x-camera-metrics': MAC_HEADER }).camera, STORED);
  assert.equal('camera' in voiceParams({}), false, 'no header, no camera field');
});

test('parseCameraMetrics: anything but four bounded, consistent integers is a 400', () => {
  const base = JSON.parse(MAC_HEADER);
  const bad = [
    ['not json', 'must be a JSON object'], ['[1,2]', 'must be a JSON object'], ['null', 'must be a JSON object'], ['62', 'must be a JSON object'],
    ['"62"', 'must be a JSON object'], [MAC_HEADER + ', ' + MAC_HEADER, 'must be a JSON object'],
    [{ ...base, extra: 1 }, 'unsupported field: extra'], [{ ...base, image: 'AAAA' }, 'unsupported field: image'],
    [{ faced_camera_pct: 62, looked_away_count: 3, longest_look_away_ms: 4100 }, 'frames must be an integer'],
    [{ ...base, faced_camera_pct: 62.5 }, 'faced_camera_pct must be an integer'], [{ ...base, faced_camera_pct: '62' }, 'faced_camera_pct must be an integer'],
    [{ ...base, faced_camera_pct: null }, 'faced_camera_pct must be an integer'], [{ ...base, frames: true }, 'frames must be an integer'],
    [{ ...base, faced_camera_pct: 101 }, 'faced_camera_pct must be from 0 to 100'], [{ ...base, faced_camera_pct: -1 }, 'faced_camera_pct must be from 0 to 100'],
    [{ ...base, frames: 0 }, 'frames must be from 1 to 1200'], [{ ...base, frames: 1201 }, 'frames must be from 1 to 1200'],
    [{ ...base, longest_look_away_ms: 120001 }, 'longest_look_away_ms must be from 0 to 120000'], [{ ...base, looked_away_count: -2 }, 'looked_away_count must be from 0 to 1200'],
    [{ ...base, looked_away_count: 149 }, 'looked_away_count cannot exceed frames'],
    [{ ...base, looked_away_count: 0 }, 'longest_look_away_ms must be 0 exactly when'], [{ ...base, longest_look_away_ms: 0 }, 'longest_look_away_ms must be 0 exactly when'],
    [MAC_HEADER.replace('{', '{' + ' '.repeat(CAMERA_HEADER_MAX_BYTES)), `at most ${CAMERA_HEADER_MAX_BYTES} bytes`]
  ];
  for (const [value, message] of bad) {
    assert.throws(() => parseCameraMetrics(typeof value === 'string' ? value : JSON.stringify(value)),
      e => e.status === 400 && e.code === 'invalid_value' && e.message.startsWith('X-Camera-Metrics ') && e.message.includes(message), JSON.stringify(value).slice(0, 80));
  }
});

test('POST /v1/voice-rounds with X-Camera-Metrics: metrics.camera in the reply, the record, the overview and the context', async () => {
  const { models, calls } = fakeModels();
  await withServer(models, async ({ round, get, store }) => {
    const { status, data } = await round(wav(3), { key: 'camera-round-1', headers: { 'X-Camera-Metrics': MAC_HEADER } });
    assert.equal(status, 200);
    assert.deepEqual(data.metrics.camera, STORED);
    assert.equal(data.metrics.filler_count, 1, 'the speech numbers are unchanged');
    assert.deepEqual(store.get('alice', 'voice-rounds', data.round_id).metrics.camera, STORED);
    assert.deepEqual((await get('/v1/overview')).latest_voice_round.metrics.camera, STORED, 'Muse reads it from the overview');
    assert.deepEqual((await get('/v1/context')).voice_rounds[0].metrics.camera, STORED);
    // The reply model is not given the camera numbers: they are for the person and for Muse, read from the record.
    assert.equal(calls.prompts[0].user.includes('faced_camera'), false);

    // Without the header there is no camera field at all.
    const plain = await round(wav(2.5), { key: 'camera-round-2' });
    assert.equal(plain.status, 200);
    assert.equal('camera' in plain.data.metrics, false);
    assert.equal('camera' in (await get('/v1/overview')).latest_voice_round.metrics, false);

    // The camera numbers are not part of the fingerprint: a retry with the same key and audio replays the first round.
    const retry = await round(wav(3), { key: 'camera-round-1', headers: { 'X-Camera-Metrics': '{"faced_camera_pct":10,"looked_away_count":0,"longest_look_away_ms":0,"frames":9}' } });
    assert.equal(retry.data.replayed, true);
    assert.deepEqual(retry.data.metrics.camera, STORED);
    assert.deepEqual([calls.transcribe, calls.voiceReply], [2, 2]);
  });
});

test('POST /v1/voice-rounds with a bad X-Camera-Metrics: 400 before any model call, nothing saved', async () => {
  const { models, calls } = fakeModels();
  await withServer(models, async ({ round, get }) => {
    for (const [i, header] of ['{"faced_camera_pct":140,"looked_away_count":3,"longest_look_away_ms":4100,"frames":148}', 'yes', '{"frames":148}',
      MAC_HEADER.replace('}', ',"jpeg":"/9j/4AAQ"}')].entries()) {
      const { status, data } = await round(wav(2), { key: `camera-bad-${i}0`, headers: { 'X-Camera-Metrics': header } });
      assert.equal(status, 400, header); assert.equal(data.error, 'invalid_value'); assert.match(data.message, /^X-Camera-Metrics /);
    }
    assert.deepEqual([calls.transcribe, calls.voiceReply], [0, 0]);
    assert.equal((await get('/v1/context')).voice_rounds.length, 0);
  });
});

test('connector text: Muse is told what metrics.camera is, in plain terms', () => {
  const doc = connectorDocument('http://127.0.0.1:4318');
  assert.match(doc, /metrics\.camera/);
  assert.match(doc, /faced_camera_pct/);
  assert.match(doc, /head direction, not gaze/);
  assert.match(doc, /say "faced the camera"/);
  assert.match(doc, /No camera image is stored or sent/);
  for (const banned of ['confident', 'nervous', 'body language', 'personality', 'emotion', 'mood', 'energy']) assert.equal(doc.toLowerCase().includes(banned), false, banned);
});

test('live round: the camera numbers on the end message reach the reply event and the saved round; bad ones are dropped, not fatal', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'camera-live-'));
  const store = new Store(join(dir, 'live.sqlite'));
  store.addToken('alice-secret', 'alice'); store.seed('alice');
  const phases = { async release() {}, async acquire() {} };
  const run = async (key, extra) => {
    const events = [];
    const round = createLiveRound({ store, models: fakeModels().models, token: 'Bearer alice-secret', phases, emit: e => events.push(e),
      start: { type: 'start', idempotency_key: key, language: 'en', speech: false } });
    round.audio(Buffer.alloc(48 * 1500, 1));
    round.end(extra);
    return { result: await round.done, events };
  };
  try {
    const ok = await run('camera-live-0001', { camera: JSON.parse(MAC_HEADER) });
    assert.equal(ok.result.status, 200);
    assert.deepEqual(ok.result.body.metrics.camera, STORED);
    assert.deepEqual(ok.events.find(e => e.type === 'reply').metrics.camera, STORED, 'the card gets it with the reply');
    assert.deepEqual(store.get('alice', 'voice-rounds', ok.result.body.round_id).metrics.camera, STORED);

    const bad = await run('camera-live-0002', { camera: { ...JSON.parse(MAC_HEADER), faced_camera_pct: 400 } });
    assert.equal(bad.result.status, 200, 'the answer is still saved');
    assert.equal('camera' in bad.result.body.metrics, false);
    assert.match(bad.events.find(e => e.type === 'camera_ignored').message, /^X-Camera-Metrics faced_camera_pct must be from 0 to 100/);

    const none = await run('camera-live-0003');
    assert.equal(none.result.status, 200);
    assert.equal('camera' in none.result.body.metrics, false);
    assert.equal(none.events.some(e => e.type === 'camera_ignored'), false);
  } finally { store.close(); rmSync(dir, { recursive: true, force: true }); }
});
