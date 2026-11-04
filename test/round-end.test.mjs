// Where a practice round starts when a device ends it without a wrap-up (POST /v1/voice-rounds/end, src/voice.mjs):
// the watch's End round, the Mac's bubble closed, and a round that moves between the two. Fake models, no network.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Store } from '../src/store.mjs';
import { createApp } from '../src/server.mjs';
import { createLiveRound } from '../src/live-voice.mjs';
import { ROUND_WINDOW_MS } from '../src/voice.mjs';

const ANSWER = 'I think we ship the smaller version first.';
const pcm = ms => { const b = Buffer.alloc(ms * 48); for (let i = 0; i < b.length / 2; i++) b.writeInt16LE(Math.round(Math.sin(i / 7) * 2000), i * 2); return b; };
const wav = ms => {
  const data = pcm(ms), h = Buffer.alloc(44);
  h.write('RIFF', 0); h.writeUInt32LE(36 + data.length, 4); h.write('WAVE', 8); h.write('fmt ', 12); h.writeUInt32LE(16, 16);
  h.writeUInt16LE(1, 20); h.writeUInt16LE(1, 22); h.writeUInt32LE(24000, 24); h.writeUInt32LE(48000, 28); h.writeUInt16LE(2, 32); h.writeUInt16LE(16, 34);
  h.write('data', 36); h.writeUInt32LE(data.length, 40);
  return Buffer.concat([h, data]);
};

async function withCoach(fn) {
  const dir = mkdtempSync(join(tmpdir(), 'round-end-'));
  const store = new Store(join(dir, 'round.sqlite'));
  const prompts = [];
  const models = {
    voiceReady: () => true,
    async transcribe() { return { transcript: ANSWER, turns: [{ turn_id: 0, start_ms: 200, end_ms: 1800, transcript: ANSWER }], audio_duration_ms: 2000, model: 'muse-voice-transcribe-1.0', provider_session_id: 'fake' }; },
    async voiceReply({ user, allowed }) {
      prompts.push(JSON.parse(user));
      return { status: 'model_reply', reply: { move: allowed.includes('challenge') ? 'challenge' : allowed[0], quote: 'I think', question: 'What makes you sure?', need: 'date' }, model: 'fake', provider_request_id: 'fake', attempts: 1 };
    }
  };
  const server = createApp(store, { models }); await new Promise(r => server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${server.address().port}`;
  let n = 0;
  const users = new Set();
  const account = name => {
    if (!users.has(name)) { store.addToken(`${name}-secret`, name); users.add(name); }
    // The Mac's screen card for this account, so the first answer of a round asks the model to choose a need.
    store.put(name, 'screen-contexts', { id: 'card-1', version: 1, deleted: false, purpose: 'meeting_prep', app_name: 'Mail', goal_id: null,
      occurred_at: new Date().toISOString(), analysis: { summary: 'An email asking when the launch ships.' } });
    const auth = { Authorization: `Bearer ${name}-secret` };
    return {
      // The watch: a WAV upload, with the screen card id it read from the overview.
      watch: (key = `watch-key-${++n}`) => fetch(base + '/v1/voice-rounds', { method: 'POST', body: wav(1500 + n),
        headers: { ...auth, 'Content-Type': 'audio/wav', 'Idempotency-Key': key, 'X-Screen-Context-Id': 'card-1' } }).then(r => r.json()),
      // The Mac: a live round over the socket's handler (file transcription; no realtime in these tests).
      mac: async (key = `mac-live-key-${++n}`) => {
        const round = createLiveRound({ store, models, token: `Bearer ${name}-secret`, phases: { async release() {}, async acquire() {} },
          start: { type: 'start', idempotency_key: key, language: 'en', screen_context_id: 'card-1', speech: false } });
        round.audio(pcm(1500 + (++n))); round.end();
        const result = await round.done;
        assert.equal(result.status, 200, JSON.stringify(result.body));
        return result.body;
      },
      end: (key = `end-key-${++n}`, body = {}, after = null) => fetch(base + '/v1/voice-rounds/end', { method: 'POST', body: JSON.stringify(body),
        headers: { ...auth, 'Content-Type': 'application/json', 'Idempotency-Key': key, ...(after ? { 'X-After-Round': after } : {}) } }).then(async r => ({ status: r.status, ...(await r.json()) }))
    };
  };
  try { await fn({ account, prompts, store }); }
  finally { await new Promise(r => server.close(r)); store.close(); rmSync(dir, { recursive: true, force: true }); }
}

const step = r => [r.counterpart.answer, r.counterpart.reason, r.reply.move];

test('round end: the watch ends a round after 3 answers; the next answer is answer 1 and the need is chosen again', async () => {
  await withCoach(async ({ account, prompts }) => {
    // Without the end, the fourth answer is the round's last: the gate allows only a wrap-up.
    const control = account('control');
    for (let i = 0; i < 3; i++) await control.watch();
    assert.deepEqual(step(await control.watch()), [4, 'answer_cap', 'wrap_up']);
    prompts.length = 0;
    const watch = account('wrist');
    const answers = [];
    for (let i = 0; i < 3; i++) answers.push(step(await watch.watch()));
    assert.deepEqual(answers, [[1, 'open', 'challenge'], [2, 'open', 'challenge'], [3, 'open', 'challenge']]);
    assert.deepEqual(prompts.map(p => Boolean(p.choose_need)), [true, false, false], 'the need is chosen on answer 1 only');
    const ended = await watch.end();
    assert.equal(ended.status, 200); assert.equal(ended.replayed, false); assert.match(ended.record.ended_at, /^\d{4}-\d{2}-\d{2}T/);
    const next = await watch.watch();
    assert.deepEqual(step(next), [1, 'open', 'challenge']);
    assert.equal(next.counterpart.need, 'date', 'the model chose a need for the new round');
    const prompt = prompts.at(-1);
    assert.ok(prompt.choose_need, 'choose_need runs again'); assert.equal(prompt.round_number, 1); assert.equal(prompt.your_last_question, null);
  });
});

test('round end: closing the Mac bubble mid-round starts the next live answer at 1', async () => {
  await withCoach(async ({ account, prompts }) => {
    const mac = account('desk');
    assert.deepEqual([step(await mac.mac()), step(await mac.mac())], [[1, 'open', 'challenge'], [2, 'open', 'challenge']]);
    assert.equal((await mac.end()).status, 200);
    const next = await mac.mac();
    assert.deepEqual(step(next), [1, 'open', 'challenge']);
    assert.ok(prompts.at(-1).choose_need); assert.equal(prompts.at(-1).your_last_question, null);
  });
});

test('round end: a round moves between the Mac and the watch, and an end from either starts the next; a late retry moves nothing', async () => {
  await withCoach(async ({ account }) => {
    const both = account('both');
    // One practice round across two devices: the server counts it.
    assert.equal((await both.watch()).counterpart.answer, 1);
    assert.equal((await both.mac()).counterpart.answer, 2);
    // The watch ends it; the Mac's next answer starts a new round.
    const first = await both.end('watch-end-0001');
    assert.equal((await both.mac()).counterpart.answer, 1);
    // The watch resends its end with the same key after the Mac answered: the receipt replays and the round goes on.
    const late = await both.end('watch-end-0001');
    assert.equal(late.replayed, true); assert.equal(late.record.ended_at, first.record.ended_at);
    assert.equal((await both.watch()).counterpart.answer, 2);
    // A body with anything in it is refused, and a key is required.
    assert.equal((await both.end('watch-end-0002', { reason: 'x' })).status, 400);
    assert.equal((await both.end('short')).status, 400);
  });
});

test('round end: an end older than the 15-minute window changes nothing', async () => {
  await withCoach(async ({ account, store }) => {
    const old = account('old');
    store.put('old', 'voice-round-ends', { id: 'latest', version: 1, ended_at: new Date(Date.now() - ROUND_WINDOW_MS - 60_000).toISOString() });
    assert.equal((await old.watch()).counterpart.answer, 1);
    assert.equal((await old.watch()).counterpart.answer, 2);
  });
});

test('round end: an end that names its last answer changes nothing once another device has answered since', async () => {
  await withCoach(async ({ account }) => {
    const both = account('handoff');
    // The Mac answers, then the round moves to the watch.
    const macAnswer = await both.mac();
    assert.equal(macAnswer.counterpart.answer, 1);
    assert.equal((await both.watch()).counterpart.answer, 2);
    // The Mac's idle end names its own last answer: the watch answered since, so the round stays open.
    const stale = await both.end('mac-end-after-1', {}, macAnswer.round_id);
    assert.equal(stale.status, 200); assert.equal(stale.record.skipped, 'answered_since'); assert.equal(stale.record.ended_at, null);
    assert.equal((await both.watch()).counterpart.answer, 3, 'the watch round goes on');
    // The same key again replays the same decision.
    assert.equal((await both.end('mac-end-after-1', {}, macAnswer.round_id)).replayed, true);
    // An end that names the newest answer applies.
    const lastWatch = await both.watch();
    assert.equal(lastWatch.counterpart.answer, 4);
    const fresh = await both.end('watch-end-after-1', {}, lastWatch.round_id);
    assert.equal(fresh.record.skipped, undefined); assert.match(fresh.record.ended_at, /^\d{4}-/);
    assert.equal((await both.mac()).counterpart.answer, 1);
    // A malformed round id is refused.
    assert.equal((await both.end('mac-end-after-2', {}, 'not a round id!')).status, 400);
  });
});
