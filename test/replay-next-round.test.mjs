// The next round's first reply after a hands check (src/voice.mjs with src/replay.mjs): the model sees the counted
// seconds, and any number its question states must be one of them, or code replaces the line. Fake models, no network.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Store } from '../src/store.mjs';
import { createApp } from '../src/server.mjs';
import { FALLBACK_QUESTIONS } from '../src/voice.mjs';

const ANSWER = 'I think we ship the smaller version first.';
function wav(ms) {
  const data = Buffer.alloc(ms * 48), h = Buffer.alloc(44);
  for (let i = 0; i < data.length / 2; i++) data.writeInt16LE(Math.round(Math.sin(i / 7) * 2000), i * 2);
  h.write('RIFF', 0); h.writeUInt32LE(36 + data.length, 4); h.write('WAVE', 8); h.write('fmt ', 12); h.writeUInt32LE(16, 16);
  h.writeUInt16LE(1, 20); h.writeUInt16LE(1, 22); h.writeUInt32LE(24000, 24); h.writeUInt32LE(48000, 28); h.writeUInt16LE(2, 32); h.writeUInt16LE(16, 34);
  h.write('data', 36); h.writeUInt32LE(data.length, 40);
  return Buffer.concat([h, data]);
}

async function withCoach(fn) {
  const dir = mkdtempSync(join(tmpdir(), 'replay-next-'));
  const store = new Store(join(dir, 'r.sqlite'));
  store.addToken('alice-secret', 'alice');
  const prompts = [], script = { question: 'What makes you sure?' };
  const models = {
    voiceReady: () => true,
    async transcribe() { return { transcript: ANSWER, turns: [{ turn_id: 0, start_ms: 200, end_ms: 1800, transcript: ANSWER }], audio_duration_ms: 2000, model: 'fake', provider_session_id: 'fake' }; },
    async voiceReply({ user, allowed }) {
      prompts.push(JSON.parse(user));
      return { status: 'model_reply', reply: { move: allowed.includes('challenge') ? 'challenge' : allowed[0], quote: 'I think', question: script.question }, model: 'fake', provider_request_id: 'fake', attempts: 1 };
    }
  };
  const server = createApp(store, { models }); await new Promise(r => server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${server.address().port}`;
  let n = 0;
  const answer = () => fetch(base + '/v1/voice-rounds', { method: 'POST', body: wav(1500 + (++n)),
    headers: { Authorization: 'Bearer alice-secret', 'Content-Type': 'audio/wav', 'Idempotency-Key': `replay-next-${n}` } }).then(r => r.json());
  // The round that just ended: its wrap-up, with or without a hands check.
  const wrapUp = (seconds, ago = 60_000) => {
    const at = new Date(Date.now() - ago).toISOString();
    store.put('alice', 'voice-rounds', { id: `wrap-${++n}`, version: 2, source: 'voice_round', language: 'en', occurred_at: at, created_at: at, updated_at: at, deleted: false,
      transcript: 'x', metrics: {}, reply: { move: 'wrap_up', question: 'Thanks.', quote: '', quote_verified: false },
      ...(seconds ? { replay: { method: 'sam-3.1-boxes-v1', fps: 10, frames: 80, seconds } } : {}) });
  };
  try { await fn({ answer, wrapUp, prompts, script, store }); }
  finally { await new Promise(r => server.close(r)); store.close(); rmSync(dir, { recursive: true, force: true }); }
}

test('next round: the first reply sees the counted seconds, and a number code did not count is replaced by code\'s line', async () => {
  await withCoach(async ({ answer, wrapUp, prompts, script, store }) => {
    wrapUp({ phone_in_hand: 3.2, paper_in_hand: 0 });
    script.question = 'Your phone was in your hand for 5 seconds. Can you say it again without it?';
    const first = await answer();
    assert.deepEqual(prompts.at(-1).last_round_replay, { phone_in_hand_seconds: 3, paper_in_hand_seconds: 0 }, 'whole seconds, as code counted them');
    assert.equal(first.reply.question, 'Last round, your phone was in your hand for 3 s. Try this answer without it.');
    assert.equal(first.reply.quote, ''); assert.equal(first.reply.quote_verified, false);
    assert.equal(store.get('alice', 'voice-rounds', first.round_id).reply_checks.seconds_replaced, 'number_not_measured');
    // The second answer is not about the hands check: no seconds are sent and its numbers are not checked.
    script.question = 'Give me 2 reasons, in one sentence each.';
    const second = await answer();
    assert.equal('last_round_replay' in prompts.at(-1), false);
    assert.equal(second.reply.question, 'Give me 2 reasons, in one sentence each.');
    assert.equal('seconds_replaced' in store.get('alice', 'voice-rounds', second.round_id).reply_checks, false);
  });
});

test('next round: a question that names the counted seconds, or none, is kept as written', async () => {
  await withCoach(async ({ answer, wrapUp, script, store }) => {
    wrapUp({ phone_in_hand: 0, paper_in_hand: 2.4 });
    script.question = 'You held a paper for about 2 seconds last time. Try it without notes?';
    const kept = await answer();
    assert.equal(kept.reply.question, script.question);
    assert.equal(kept.reply.quote_verified, true, 'the verified quote stays');
    assert.equal(store.get('alice', 'voice-rounds', kept.round_id).reply_checks.seconds_replaced, null, 'checked, not replaced');
  });
});

test('next round: with nothing counted, a stated number is replaced by the fixed question; with no hands check nothing changes', async () => {
  await withCoach(async ({ answer, wrapUp, prompts, script, store }) => {
    wrapUp({ phone_in_hand: 0, paper_in_hand: 0 });
    script.question = 'Your phone was out for 4 seconds. Again?';
    const none = await answer();
    assert.deepEqual(prompts.at(-1).last_round_replay, { phone_in_hand_seconds: 0, paper_in_hand_seconds: 0 });
    assert.equal(none.reply.question, FALLBACK_QUESTIONS.en.challenge);
    assert.equal(store.get('alice', 'voice-rounds', none.round_id).reply_checks.seconds_replaced, 'nothing_counted');
  });
  await withCoach(async ({ answer, wrapUp, prompts, script, store }) => {
    wrapUp(null);
    script.question = 'Give me 3 reasons.';
    const plain = await answer();
    assert.equal('last_round_replay' in prompts.at(-1), false, 'off unless a hands check exists');
    assert.equal(plain.reply.question, 'Give me 3 reasons.');
    assert.equal('seconds_replaced' in store.get('alice', 'voice-rounds', plain.round_id).reply_checks, false);
  });
  await withCoach(async ({ answer, wrapUp, prompts }) => {
    wrapUp({ phone_in_hand: 5, paper_in_hand: 0 }, 16 * 60_000);
    await answer();
    assert.equal('last_round_replay' in prompts.at(-1), false, 'a check older than the 15-minute window is not used');
  });
});
