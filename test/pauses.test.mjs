// Pause and pace metrics from transcription turns: code-measured, honest about what a turn boundary is.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { measurePauses, PAUSE_METHOD, PAUSE_MIN_MS, LONG_PAUSE_MS } from '../src/pauses.mjs';
import { measure } from '../src/capture.mjs';
import { Store } from '../src/store.mjs';
import { createApp } from '../src/server.mjs';

const turn = (start_ms, end_ms) => ({ turn_id: start_ms, start_ms, end_ms, transcript: 'x' });

test('gaps between turns become pauses; speaking time drives pace', () => {
  // 12 s clip: speech 0.8–4.0, 4.3–7.0 (300 ms gap), 8.5–11.0 (1500 ms gap).
  const p = measurePauses([turn(800, 4000), turn(4300, 7000), turn(8500, 11000)], 12000, 30);
  assert.equal(p.status, 'measured'); assert.equal(p.method, PAUSE_METHOD);
  assert.equal(p.turn_count, 3);
  assert.equal(p.speaking_ms, 3200 + 2700 + 2500);
  assert.equal(p.speaking_ratio, 0.7);
  assert.equal(p.words_per_speaking_minute, Math.round(30 / (8400 / 60000)));
  assert.deepEqual(p.gaps_ms, [300, 1500]);
  assert.equal(p.pause_count, 2); assert.equal(p.pause_total_ms, 1800);
  assert.equal(p.longest_pause_ms, 1500); assert.equal(p.long_pause_count, 1);
  assert.equal(p.silence_before_first_turn_ms, 800); assert.equal(p.silence_after_last_turn_ms, 1000);
  assert.ok(p.caveats.some(c => /not word timings/.test(c)));
});

test('thresholds are inclusive at 250 ms and 1000 ms; shorter gaps are not pauses', () => {
  const at = gap => measurePauses([turn(0, 1000), turn(1000 + gap, 3000)], 5000, 5);
  assert.equal(at(PAUSE_MIN_MS - 1).pause_count, 0);
  assert.equal(at(PAUSE_MIN_MS - 1).longest_pause_ms, null, 'no visible pause is unknown, not zero');
  assert.equal(at(PAUSE_MIN_MS).pause_count, 1);
  assert.equal(at(LONG_PAUSE_MS - 1).long_pause_count, 0);
  assert.equal(at(LONG_PAUSE_MS).long_pause_count, 1);
});

test('unordered, overlapping and touching turns are merged, never double counted', () => {
  const p = measurePauses([turn(5000, 6000), turn(0, 2000), turn(1500, 3000), turn(3000, 3500)], 6000, 12);
  assert.equal(p.speaking_ms, 3500 + 1000);
  assert.deepEqual(p.gaps_ms, [1500]);
  assert.equal(p.turn_count, 4);
});

test('missing or impossible turn times report nothing rather than a wrong number', () => {
  assert.equal(measurePauses([], 5000, 3).status, 'no_turns');
  assert.equal(measurePauses(undefined, 5000, 3).status, 'no_turns');
  for (const bad of [[turn(0, null)], [turn(-5, 100)], [turn(900, 100)], [{ start_ms: '0', end_ms: 100 }], [turn(0, 9000)]]) {
    const p = measurePauses(bad, 5000, 3);
    assert.equal(p.status, 'invalid_turns', JSON.stringify(bad));
    assert.equal(p.speaking_ms, null); assert.equal(p.pause_count, 0); assert.equal(p.longest_pause_ms, null);
  }
  assert.equal(measurePauses([turn(0, 100)], 0, 3).status, 'invalid_turns');
  // Within the tolerance a turn may end just after the clip; it is clipped to the clip length.
  assert.equal(measurePauses([turn(0, 5400)], 5000, 3).speaking_ms, 5000);
});

test('measure() adds pauses and leaves every earlier field as it was', () => {
  const text = 'Um, I think we ship it. Sorry, let me restart.';
  const without = measure(text, 6000, 'en'), withTurns = measure(text, 6000, 'en', [turn(200, 2500), turn(3600, 5800)]);
  const { pauses: p0, ...rest0 } = without, { pauses: p1, ...rest1 } = withTurns;
  assert.deepEqual(rest0, rest1);
  assert.equal(p0.status, 'no_turns');
  assert.equal(p1.status, 'measured'); assert.equal(p1.longest_pause_ms, 1100);
  assert.equal(p1.words_per_speaking_minute, Math.round(withTurns.word_count / (4500 / 60000)));
  assert.ok(withTurns.words_per_minute < p1.words_per_speaking_minute, 'pace on speaking time is faster than pace on clip time');
});

test('a capture saves pause metrics measured from the transcription turns', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'pauses-test-'));
  const store = new Store(join(dir, 't.sqlite')); store.addToken('p-secret', 'u'); store.seed('u');
  const models = {
    async transcribe() { return { transcript: 'The main point is speed. Then trust.', turns: [turn(600, 2600), turn(4100, 6000)], audio_duration_ms: 7000, model: 'muse-voice-transcribe-1.0', provider_session_id: 'p' }; },
    async analyze() { return { status: 'unavailable', reason: 'off' }; }
  };
  const server = createApp(store, { models }); await new Promise(r => server.listen(0, '127.0.0.1', r));
  try {
    const wavHeader = Buffer.alloc(44); const data = Buffer.alloc(16000 * 2 * 7);
    wavHeader.write('RIFF', 0); wavHeader.writeUInt32LE(36 + data.length, 4); wavHeader.write('WAVE', 8); wavHeader.write('fmt ', 12); wavHeader.writeUInt32LE(16, 16);
    wavHeader.writeUInt16LE(1, 20); wavHeader.writeUInt16LE(1, 22); wavHeader.writeUInt32LE(16000, 24); wavHeader.writeUInt32LE(32000, 28); wavHeader.writeUInt16LE(2, 32); wavHeader.writeUInt16LE(16, 34);
    wavHeader.write('data', 36); wavHeader.writeUInt32LE(data.length, 40);
    const r = await fetch(`http://127.0.0.1:${server.address().port}/v1/recordings`, { method: 'POST', headers: { Authorization: 'Bearer p-secret', 'Content-Type': 'audio/wav', 'Idempotency-Key': 'pause-capture-1' }, body: Buffer.concat([wavHeader, data]) });
    const { record } = await r.json();
    assert.equal(r.status, 200);
    assert.equal(record.metrics.pauses.status, 'measured');
    assert.equal(record.metrics.pauses.longest_pause_ms, 1500);
    assert.equal(record.metrics.pauses.silence_before_first_turn_ms, 600);
    assert.equal(record.metrics.words_per_minute, Math.round(7 / (7000 / 60000)), 'clip-time pace is unchanged');
  } finally { await new Promise(r => server.close(r)); store.close(); rmSync(dir, { recursive: true, force: true }); }
});
