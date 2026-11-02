// A malformed reply from the transcription provider must return the documented 502 and save nothing.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Store } from '../src/store.mjs';
import { createApp } from '../src/server.mjs';
import { createModelClients } from '../src/capture.mjs';

function wav(seconds = 1, rate = 16000) {
  const data = Buffer.alloc(Math.round(seconds * rate) * 2);
  for (let i = 0; i < data.length / 2; i++) data.writeInt16LE(Math.round(Math.sin(i / 5) * 2000), i * 2);
  const h = Buffer.alloc(44);
  h.write('RIFF', 0); h.writeUInt32LE(36 + data.length, 4); h.write('WAVE', 8); h.write('fmt ', 12); h.writeUInt32LE(16, 16);
  h.writeUInt16LE(1, 20); h.writeUInt16LE(1, 22); h.writeUInt32LE(rate, 24); h.writeUInt32LE(rate * 2, 28); h.writeUInt16LE(2, 32); h.writeUInt16LE(16, 34);
  h.write('data', 36); h.writeUInt32LE(data.length, 40);
  return Buffer.concat([h, data]);
}

test('transcription: a malformed provider reply returns 502 and saves nothing; odd turns and durations are dropped', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'transcribe-guard-'));
  const store = new Store(join(dir, 'guard.sqlite'));
  store.addToken('guard-secret', 'guard-user'); store.seed('guard-user');
  let reply;
  const fetchImpl = async () => new Response(reply, { status: 200 });
  const analyze = async () => ({ status: 'unavailable', reason: 'Not used.' });
  const models = { transcribe: createModelClients({ env: { MODEL_API_KEY: 'k' }, fetchImpl }).transcribe, analyze };
  const server = createApp(store, { models }); await new Promise(r => server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${server.address().port}`;
  let n = 0;
  const upload = async body => {
    reply = body;
    const r = await fetch(base + '/v1/recordings', { method: 'POST', body: wav(),
      headers: { Authorization: 'Bearer guard-secret', 'Content-Type': 'audio/wav', 'Idempotency-Key': `guard-key-${++n}` } });
    return { status: r.status, data: await r.json() };
  };
  try {
    for (const [body, code] of [['not json', 'transcription_failed'], ['null', 'transcription_failed'], ['"text"', 'transcription_failed'],
      ['{"transcript": 5}', 'transcription_empty'], ['[]', 'transcription_empty']]) {
      const { status, data } = await upload(body);
      assert.equal(status, 502, `reply ${body}`); assert.equal(data.error, code, `reply ${body}`);
    }
    assert.equal(store.list('guard-user', 'sessions').filter(s => s.source === 'capture').length, 0, 'a failed transcription saves no session');
    const ok = await upload(JSON.stringify({ transcript: 'Um, ship it.', turns: [null, 'x', { turnId: 1, startMs: 0, endMs: 900, transcript: 'Um, ship it.' }], audioDurationMs: 'long' }));
    assert.equal(ok.status, 200);
    assert.deepEqual(ok.data.record.turns, [{ turn_id: 1, start_ms: 0, end_ms: 900, transcript: 'Um, ship it.' }]);
    assert.equal(ok.data.record.metrics.duration_ms, 1000, 'a non-numeric duration falls back to the WAV header');
    const notArray = await upload(JSON.stringify({ transcript: 'Ship it.', turns: 'none' }));
    assert.equal(notArray.status, 200); assert.deepEqual(notArray.data.record.turns, []);
  } finally { await new Promise(r => server.close(r)); store.close(); rmSync(dir, { recursive: true, force: true }); }
});
