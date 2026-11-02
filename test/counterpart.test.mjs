// The other person's need and the move gate (src/counterpart.mjs), alone and wired into voice rounds. Fake models only.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Store } from '../src/store.mjs';
import { createApp, connectorDocument } from '../src/server.mjs';
import { NEEDS, ANSWER_CAP, checkNeed, needMet, gateReason, allowedMoves, codeOnlyReply } from '../src/counterpart.mjs';
import { voiceParams, voiceFingerprint, acceptReply, createVoiceModel, FALLBACK_QUESTIONS } from '../src/voice.mjs';
import { liveStart, createLiveRound } from '../src/live-voice.mjs';

test('needMet: each need in English, with the near misses that must not count', () => {
  const yes = {
    number: ['Conversion is up 8%.', 'It saves two hours a week.', 'About half the tickets.'],
    date: ['We ship by March 14.', 'On the 14th.', 'By Friday.', 'Tomorrow.', 'End of the quarter.', 'In two weeks.', 'Q1.', 'May 3rd works.'],
    decision: ['We decided to ship the beta.', "I'll ship the smaller version.", "Let's go with option B.", 'The answer is yes.'],
    owner: ["I'll own it.", 'I will lead the launch.', "I'm responsible for the rollout.", "It's on me.", 'Dana owns it.'],
    example: ['For example, the beta cut tickets.', 'Last quarter we did this.', 'Such as the pilot.', 'When we shipped the pilot it worked.']
  };
  const no = {
    number: ['A few more people.', 'The one thing is speed.'],
    date: ['Maybe soon.', 'At some point.', 'Eventually, later on.', 'We may ship it.', 'Some day next to the release.'],
    decision: ["I'll maybe do it.", "We'll see.", 'We could ship it.', "Let's think about it."],
    owner: ['I could lead it.', 'Someone should own this.', 'Maybe I lead.'],
    example: ['It works well.', 'Trust me.']
  };
  for (const need of NEEDS) {
    for (const text of yes[need]) assert.equal(needMet(text, need, 'en'), true, `${need}: ${text}`);
    for (const text of no[need]) assert.equal(needMet(text, need, 'en'), false, `${need} (no): ${text}`);
  }
  assert.equal(needMet('By March 14.', 'teapot', 'en'), false, 'an unknown need is never met');
  assert.equal(needMet('By March 14.', 'date', 'de'), false, 'an unknown language is never met');
});

test('needMet: each need in French, including words that end in an accented letter', () => {
  const yes = { number: ['On gagne 8 %.', 'Deux semaines.'], date: ['Le 14 mars.', "D'ici vendredi.", 'Demain.', 'Fin de la journée.', 'Dans trois semaines.'],
    decision: ["J'ai décidé.", 'On va livrer la petite version.', "C'est oui."], owner: ["Je m'en occupe.", 'Je m’en charge.', 'Je suis responsable.', "C'est moi qui pilote."],
    example: ['Par exemple, le pilote.', 'Le mois dernier, on a livré.'] };
  const no = { number: ['Quelques personnes.'], date: ['Bientôt.', 'Un jour, peut-être.'], decision: ['On va peut-être livrer.', 'On pourrait livrer.'],
    owner: ['Je pourrais le faire.'], example: ['Ça marche bien.'] };
  for (const need of NEEDS) {
    for (const text of yes[need]) assert.equal(needMet(text, need, 'fr'), true, `${need}: ${text}`);
    for (const text of no[need]) assert.equal(needMet(text, need, 'fr'), false, `${need} (no): ${text}`);
  }
});

test('checkNeed: only the listed needs; any other value is ignored', () => {
  for (const need of NEEDS) assert.equal(checkNeed(need), need);
  assert.equal(checkNeed(' Date '), 'date');
  for (const v of ['', 'deadline', 'date,owner', null, undefined, 3, {}]) assert.equal(checkNeed(v), null, String(v));
});

test('the move gate: code decides when the round ends', () => {
  const g = input => [allowedMoves(input), gateReason(input)];
  const open = [['follow_up', 'challenge'], 'open'];
  assert.deepEqual(g({ need: 'date', needMet: true, hedges: 0, answerIndex: 2 }), [['wrap_up'], 'measured_close']);
  assert.deepEqual(g({ need: 'date', needMet: true, hedges: 1, answerIndex: 2 }), open, 'met, but with a hedge');
  assert.deepEqual(g({ need: 'date', needMet: false, hedges: 0, answerIndex: 2 }), open, 'no hedge, but the need is not met');
  assert.deepEqual(g({ need: null, needMet: false, hedges: 0, answerIndex: 2 }), [['wrap_up'], 'measured_close'], 'no need: no hedges from answer 2');
  assert.deepEqual(g({ need: null, needMet: false, hedges: 0, answerIndex: 1 }), open, 'the first answer never closes');
  assert.deepEqual(g({ need: 'date', needMet: true, hedges: 0, answerIndex: 1 }), open);
  assert.deepEqual(g({ need: 'date', needMet: false, hedges: 3, answerIndex: ANSWER_CAP }), [['wrap_up'], 'answer_cap']);
  assert.deepEqual(g({ need: 'date', needMet: true, hedges: 0, answerIndex: ANSWER_CAP + 2 }), [['wrap_up'], 'measured_close']);
  assert.deepEqual(g({ need: null, needMet: false, hedges: 2, answerIndex: ANSWER_CAP - 1 }), open);
  assert.equal(ANSWER_CAP, 4);
});

test('codeOnlyReply: quotes the first hedge (else filler) with the fixed challenge; otherwise the fixed question for the gate', () => {
  const en = FALLBACK_QUESTIONS.en;
  assert.deepEqual(codeOnlyReply({ transcript: 'Um, I think we could maybe lead it.', language: 'en', allowed: ['follow_up', 'challenge'], questions: en }),
    { move: 'challenge', quote: 'I think', question: `You said "I think". ${en.challenge}` });
  assert.deepEqual(codeOnlyReply({ transcript: 'Um, we ship it.', language: 'en', allowed: ['follow_up', 'challenge'], questions: en }),
    { move: 'challenge', quote: 'Um', question: `You said "Um". ${en.challenge}` });
  assert.deepEqual(codeOnlyReply({ transcript: 'We ship by March 14.', language: 'en', allowed: ['follow_up', 'challenge'], questions: en }),
    { move: 'follow_up', quote: '', question: en.follow_up });
  assert.deepEqual(codeOnlyReply({ transcript: 'I think, maybe.', language: 'en', allowed: ['wrap_up'], questions: en }),
    { move: 'wrap_up', quote: '', question: en.wrap_up }, 'a closed round is not challenged');
  assert.equal(codeOnlyReply({ transcript: 'Je pense que oui.', language: 'fr', allowed: ['follow_up', 'challenge'], questions: FALLBACK_QUESTIONS.fr }).question,
    `Vous avez dit « Je pense ». ${FALLBACK_QUESTIONS.fr.challenge}`);
});

test('voiceParams, liveStart and the fingerprint: the need and the reply mode', () => {
  assert.deepEqual(voiceParams({ 'x-counterpart-need': 'date', 'x-reply-mode': 'code' }),
    { language: 'en', goalId: null, screenContextId: null, promptEndedAt: null, occurredAt: null, need: 'date', replyMode: 'code' });
  assert.equal('need' in voiceParams({ 'x-counterpart-need': 'deadline' }), false, 'an invalid need is ignored');
  assert.equal('replyMode' in voiceParams({ 'x-reply-mode': 'model' }), false, 'model is the default');
  assert.throws(() => voiceParams({ 'x-reply-mode': 'auto' }), e => e.status === 400);
  const base = { language: 'en', goalId: null, screenContextId: null, promptEndedAt: null, occurredAt: null };
  assert.deepEqual(Object.keys(voiceFingerprint(base, Buffer.from('a'))).sort(), ['audio_sha256', 'goal_id', 'language', 'occurred_at', 'prompt_ended_at', 'screen_context_id'],
    'earlier rounds keep their fingerprint');
  assert.equal(voiceFingerprint({ ...base, need: 'date', replyMode: 'code' }, Buffer.from('a')).need, 'date');
  const live = liveStart({ type: 'start', idempotency_key: 'live-key-0001', need: 'owner', reply_mode: 'code' });
  assert.deepEqual([live.params.need, live.params.replyMode], ['owner', 'code']);
});

test('acceptReply: a move outside the list is unusable; a need is kept only when it is listed', () => {
  assert.equal(acceptReply({ move: 'wrap_up', question: 'Done?' }, ['follow_up', 'challenge']), null);
  assert.deepEqual(acceptReply({ move: 'challenge', question: 'When?', quote: '', need: 'date' }), { move: 'challenge', question: 'When?', quote: '', need: 'date' });
  assert.deepEqual(acceptReply({ move: 'challenge', question: 'When?', need: 'vibes' }), { move: 'challenge', question: 'When?', quote: '' });
});

const enc = new TextEncoder();
const stream = text => new Response(new ReadableStream({ start(c) { c.enqueue(enc.encode(`data: ${JSON.stringify({ choices: [{ delta: { content: text }, finish_reason: 'stop' }] })}\n\ndata: [DONE]\n\n`)); c.close(); } }), { status: 200 });

test('createVoiceModel: a move outside allowed_moves gets the one retry; a second one is returned for code to replace', async () => {
  let n = 0;
  const replies = ['{"move":"wrap_up","quote":"","question":"Great, done."}', '{"move":"challenge","quote":"","question":"When exactly?"}'];
  const ok = await createVoiceModel({ env: { BASETEN_API_KEY: 'k' }, fetchImpl: async () => stream(replies[n++]) }).voiceReply({ system: 's', user: 'u', allowed: ['follow_up', 'challenge'] });
  assert.equal(n, 2); assert.equal(ok.attempts, 2); assert.equal(ok.reply.move, 'challenge');
  n = 0;
  const twice = await createVoiceModel({ env: { BASETEN_API_KEY: 'k' }, fetchImpl: async () => { n++; return stream('{"move":"wrap_up","quote":"","question":"Done."}'); } })
    .voiceReply({ system: 's', user: 'u', allowed: ['follow_up', 'challenge'] });
  assert.equal(n, 2); assert.equal(twice.status, 'model_reply'); assert.equal(twice.reply.move, 'wrap_up'); assert.equal(twice.attempts, 2);
});

function wav(seconds = 1.2, rate = 24000) {
  const samples = Math.round(seconds * rate), data = Buffer.alloc(samples * 2);
  for (let i = 0; i < samples; i++) data.writeInt16LE(Math.round(Math.sin(i / 9 + seconds) * 2500), i * 2);
  const h = Buffer.alloc(44);
  h.write('RIFF', 0); h.writeUInt32LE(36 + data.length, 4); h.write('WAVE', 8); h.write('fmt ', 12); h.writeUInt32LE(16, 16);
  h.writeUInt16LE(1, 20); h.writeUInt16LE(1, 22); h.writeUInt32LE(rate, 24); h.writeUInt32LE(rate * 2, 28); h.writeUInt16LE(2, 32); h.writeUInt16LE(16, 34);
  h.write('data', 36); h.writeUInt32LE(data.length, 40);
  return Buffer.concat([h, data]);
}

// A scripted practice round: each answer's transcript in turn, and a fake reply model that does what `moves` says.
async function withRound({ transcripts, replies, models: extra = {} }, fn) {
  const dir = mkdtempSync(join(tmpdir(), 'counterpart-test-'));
  const store = new Store(join(dir, 'c.sqlite'));
  store.addToken('alice-secret', 'alice'); store.seed('alice');
  store.put('alice', 'screen-contexts', { id: 'card-1', version: 1, purpose: 'meeting_prep', app_name: 'Notes', occurred_at: '2026-11-02T14:00:00.000Z', deleted: false,
    analysis: { summary: 'Asking Dana to approve the Q1 launch; she needs a ship date.', observation: 'o', next_step: 'n' } });
  const calls = { transcribe: 0, voiceReply: 0, prompts: [] };
  const models = {
    async transcribe() { return { transcript: transcripts[calls.transcribe++], turns: [], audio_duration_ms: 1200, model: 'muse-voice-transcribe-1.0', provider_session_id: 'asr' }; },
    voiceReady: () => true,
    async voiceReply(input) { calls.prompts.push(input); const reply = replies[calls.voiceReply++]; return { status: 'model_reply', reply, model: 'meta-models/muse-spark-open-1026', provider_request_id: 'r', attempts: 1 }; },
    ...extra
  };
  const server = createApp(store, { models }); await new Promise(r => server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${server.address().port}`;
  let k = 0;
  const answer = async (headers = {}, body = wav(1 + k / 10)) => {
    k++;
    const r = await fetch(base + '/v1/voice-rounds', { method: 'POST', body,
      headers: { Authorization: 'Bearer alice-secret', 'Content-Type': 'audio/wav', 'Idempotency-Key': `counterpart-${k}`, 'X-Screen-Context-Id': 'card-1', ...headers } });
    return { status: r.status, data: await r.json() };
  };
  try { await fn({ answer, calls, store }); } finally { await new Promise(r => server.close(r)); store.close(); rmSync(dir, { recursive: true, force: true }); }
}

test('a practice round: the model picks the need on answer 1, code ends the round on answer 2, and the need is never stored', async () => {
  const transcripts = ['Um, I think we could maybe ship the launch sometime soon.', "I'll own it, and ship by March 14, with the beta's 18% fewer tickets."];
  const replies = [{ move: 'challenge', quote: 'maybe', question: 'You said "maybe". What date can you commit to?', need: 'date' },
    { move: 'wrap_up', quote: '', question: 'March 14 works. Thank you.' }];
  await withRound({ transcripts, replies }, async ({ answer, calls, store }) => {
    const one = await answer();
    assert.equal(one.status, 200);
    const p1 = JSON.parse(calls.prompts[0].user);
    assert.deepEqual(p1.allowed_moves, ['follow_up', 'challenge']); assert.deepEqual(p1.choose_need, NEEDS); assert.equal('your_need' in p1, false);
    assert.deepEqual(calls.prompts[0].allowed, ['follow_up', 'challenge']);
    assert.match(calls.prompts[0].system, /Choose only from allowed_moves/);
    assert.deepEqual(one.data.counterpart, { need: 'date', need_met: false, allowed: ['follow_up', 'challenge'], reason: 'open', answer: 1, reply_mode: 'model' });
    // The Mac sends the need back with answer 2.
    const two = await answer({ 'X-Counterpart-Need': one.data.counterpart.need });
    const p2 = JSON.parse(calls.prompts[1].user);
    assert.deepEqual(p2.allowed_moves, ['wrap_up']); assert.equal('choose_need' in p2, false);
    assert.deepEqual(p2.your_need, { need: 'date', met_in_this_answer: true });
    assert.deepEqual(two.data.counterpart, { need: 'date', need_met: true, allowed: ['wrap_up'], reason: 'measured_close', answer: 2, reply_mode: 'model' });
    assert.deepEqual(two.data.gate, { allowed: ['wrap_up'], reason: 'measured_close', hedges: 0, coerced: false });
    assert.equal(two.data.reply.move, 'wrap_up');
    for (const id of [one.data.round_id, two.data.round_id]) {
      const record = store.get('alice', 'voice-rounds', id);
      assert.equal(JSON.stringify(record).includes('"date"'), false, 'the need is not in the record');
      assert.equal('need' in record || 'counterpart' in record, false);
      assert.equal(record.reply_mode, 'model');
    }
    // A wrap-up ends the practice round: the next answer is answer 1 again, with no last question.
    calls.prompts.length = 0; transcripts.push('Next topic: I think the budget.'); replies.push({ move: 'challenge', quote: '', question: 'What budget?' });
    const three = await answer();
    const p3 = JSON.parse(calls.prompts[0].user);
    assert.deepEqual([p3.round_number, p3.your_last_question, three.data.counterpart.answer], [1, null, 1]);
  });
});

test('a disallowed move never reaches the speaker: code replaces it with the fixed question for the gate', async () => {
  const transcripts = ['I think maybe.', 'Still, I think, maybe.'];
  const replies = [{ move: 'wrap_up', quote: '', question: 'Sounds great, we are done.' }, { move: 'challenge', quote: '', question: 'Why?' }];
  await withRound({ transcripts, replies }, async ({ answer, store }) => {
    const one = await answer();
    assert.deepEqual(one.data.reply, { move: 'follow_up', question: FALLBACK_QUESTIONS.en.follow_up, quote: '', quote_verified: false });
    assert.equal(one.data.gate.coerced, true);
    assert.equal(store.get('alice', 'voice-rounds', one.data.round_id).gate.coerced, true);
  });
});

test('the answer cap: answer 4 is a wrap-up whatever the model says', async () => {
  const t = 'Um, I think maybe.';
  await withRound({ transcripts: [t, t, t, t], replies: Array(4).fill({ move: 'challenge', quote: 'maybe', question: 'Why "maybe"?' }) }, async ({ answer }) => {
    const reasons = [];
    for (let i = 0; i < 4; i++) reasons.push((await answer()).data.gate);
    assert.deepEqual(reasons.map(g => g.reason), ['open', 'open', 'open', 'answer_cap']);
    assert.deepEqual(reasons.map(g => g.coerced), [false, false, false, true]);
  });
});

test('X-Reply-Mode: code makes no model call, needs no reply model, and stores model null', async () => {
  const transcripts = ['Um, I think we could maybe ship it soon.', 'We ship by March 14.'];
  await withRound({ transcripts, replies: [], models: { voiceReady: () => false } }, async ({ answer, calls, store }) => {
    const one = await answer({ 'X-Reply-Mode': 'code' });
    assert.equal(one.status, 200);
    assert.deepEqual(one.data.reply, { move: 'challenge', question: `You said "I think". ${FALLBACK_QUESTIONS.en.challenge}`, quote: 'I think', quote_verified: true });
    assert.equal(one.data.model, null); assert.equal(one.data.reply_mode, 'code');
    assert.deepEqual(one.data.counterpart, { need: null, need_met: null, allowed: ['follow_up', 'challenge'], reason: 'open', answer: 1, reply_mode: 'code' });
    const two = await answer({ 'X-Reply-Mode': 'code', 'X-Counterpart-Need': 'date' });
    assert.deepEqual([two.data.reply.move, two.data.gate.reason, two.data.counterpart.need_met], ['wrap_up', 'measured_close', true]);
    assert.equal(calls.voiceReply, 0, 'no model call');
    const record = store.get('alice', 'voice-rounds', two.data.round_id);
    assert.deepEqual([record.model, record.reply_mode, record.attempts], [null, 'code', 0]);
    // Without the header, the same deployment refuses before transcription: code mode is never an automatic fallback.
    const before = calls.transcribe;
    const refused = await answer();
    assert.deepEqual([refused.status, refused.data.error, calls.transcribe], [503, 'reply_unconfigured', before]);
  });
});

test('a replayed receipt carries the stored gate but no counterpart', async () => {
  await withRound({ transcripts: ['Um, I think so.'], replies: [{ move: 'challenge', quote: '', question: 'Why?', need: 'owner' }] }, async ({ answer, calls }) => {
    const headers = { 'Idempotency-Key': 'counterpart-replay-1' }, audio = wav(2);
    const first = await answer(headers, audio), again = await answer(headers, audio);
    assert.equal(first.data.counterpart.need, 'owner');
    assert.equal(again.data.replayed, true); assert.equal(calls.voiceReply, 1);
    assert.deepEqual(again.data.gate, first.data.gate);
    assert.equal('counterpart' in again.data, false);
  });
});

test('live round: the start frame carries need and reply_mode; the reply event and the saved body carry the counterpart', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'counterpart-live-'));
  const store = new Store(join(dir, 'l.sqlite'));
  store.addToken('alice-secret', 'alice'); store.seed('alice');
  try {
    const models = { async transcribe() { return { transcript: 'We ship by March 14.', turns: [], audio_duration_ms: 1200, model: 'muse-voice-transcribe-1.0', provider_session_id: 'f' }; } };
    const events = [];
    const pcm = Buffer.alloc(1200 * 48, 1);
    // Answer 1 of a practice round, sent with a need: code mode, so the reply needs no model.
    const round = createLiveRound({ store, models, token: 'Bearer alice-secret', phases: { async release() {}, async acquire() {} }, emit: e => events.push(e),
      start: { type: 'start', idempotency_key: 'live-need-0001', language: 'en', need: 'date', reply_mode: 'code', speech: false } });
    round.audio(pcm); round.end();
    const done = await round.done;
    assert.equal(done.status, 200);
    const reply = events.find(e => e.type === 'reply');
    assert.deepEqual(reply.counterpart, { need: 'date', need_met: true, allowed: ['follow_up', 'challenge'], reason: 'open', answer: 1, reply_mode: 'code' });
    assert.equal(reply.model, null); assert.equal(reply.reply_mode, 'code');
    assert.deepEqual(done.body.counterpart, reply.counterpart);
    assert.equal(store.get('alice', 'voice-rounds', done.body.round_id).reply_mode, 'code');
  } finally { store.close(); rmSync(dir, { recursive: true, force: true }); }
});

test('connector text: Muse is told who ends the round and that a code-only round has no model reply', () => {
  const doc = connectorDocument('http://127.0.0.1:4318');
  assert.match(doc, /gate\.reason measured_close means code measured that the answer closed the round; the model chose the words\./);
  assert.match(doc, /Code-only rounds \(reply_mode code\) have no model reply\./);
  assert.equal(/counterpart|X-Counterpart-Need/.test(doc), false, 'the need is not readable by the assistant');
});
