// Offline eval of the move gate on scripted model replies: what the model said, and what code lets reach the speaker.
// No model calls, no clock, no randomness. Measures the gate, not the model.
//
// Baseline: trusting the model, i.e. speaking the move it chose. The numbers that matter are how many replies would
// make a move the gate does not allow (end a round code has not measured as closed, or keep pressing on one it has),
// with and without the gate, and how many invalid needs would be used.
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { parseObject, shapeOf } from './capture.mjs';
import { acceptReply, replyToAnswer, MOVES } from './voice.mjs';
import { checkNeed } from './counterpart.mjs';
import { createBudget } from './budget.mjs';

export const COUNTERPART_REPLIES_URL = new URL('../eval/counterpart-replies.json', import.meta.url);

// One answer through the shipped replyToAnswer (src/voice.mjs), with a model that returns the scripted text parsed the
// way createVoiceModel parses it (one attempt), and the same answer in code-only mode.
export async function gateCase(c) {
  const context = { goal: null, watch: null, last: null, roundNumber: c.answer,
    screen: c.screen ? { purpose: 'meeting_prep', app_name: 'Notes', analysis: { summary: 'Asking a manager to approve the launch.' } } : null };
  const transcription = { transcript: c.transcript, turns: [], audio_duration_ms: 3000 };
  const params = { language: c.language, ...(c.need ? { need: c.need } : {}) };
  const model = { async voiceReply() {
    const reply = acceptReply(parseObject(c.raw, shapeOf(acceptReply)));
    return reply ? { status: 'model_reply', reply, model: 'scripted', attempts: 1 } : { status: 'unavailable', reason: 'Reply did not match the expected shape.', attempts: 1 };
  } };
  const code = await replyToAnswer({}, context, transcription, 3000, { ...params, replyMode: 'code' }, createBudget());
  const r = await replyToAnswer(model, context, transcription, 3000, params, createBudget());
  const { allowed, reason, hedges } = code.gate;
  if (!r.checked) return { allowed, reason, hedges, unusable: true, code_only: code.checked.reply.question };
  const raw = parseObject(c.raw, () => true);
  const offeredNeed = raw && typeof raw.need === 'string' ? raw.need : null;
  return { allowed, reason, hedges, need: r.counterpart.need, need_met: r.counterpart.need_met, model_move: r.result.reply.move, coerced: r.gate.coerced,
    spoken: r.checked.reply, invalid_need_offered: Boolean(offeredNeed && !checkNeed(offeredNeed)), code_only: code.checked.reply.question };
}

export async function runCounterpartEval(raw = readFileSync(COUNTERPART_REPLIES_URL)) {
  const fixtures = JSON.parse(raw);
  const cases = [], tally = { cases: 0, usable: 0, unusable: 0, outside_gate: 0, early_wrap_up: 0, missed_close: 0, invalid_needs: 0, needs_chosen: 0,
    reasons: { open: 0, measured_close: 0, answer_cap: 0 } };
  let agree = 0, spokenOutside = 0;
  for (const c of fixtures.cases) {
    tally.cases++;
    const r = await gateCase(c);
    const e = c.expect;
    if (r.unusable) {
      tally.unusable++;
      const ok = e.unusable === true; if (ok) agree++;
      cases.push({ id: c.id, unusable: true, allowed: r.allowed, reason: r.reason, code_only: r.code_only, matches_expected: ok });
      continue;
    }
    tally.usable++; tally.reasons[r.reason]++;
    if (r.coerced) { tally.outside_gate++; if (r.model_move === 'wrap_up') tally.early_wrap_up++; else tally.missed_close++; }
    if (r.invalid_need_offered) tally.invalid_needs++;
    if (c.answer === 1 && r.need) tally.needs_chosen++;
    if (!r.allowed.includes(r.spoken.move) || !MOVES.includes(r.spoken.move)) spokenOutside++;
    const ok = !e.unusable && r.reason === e.reason && r.spoken.move === e.move && r.coerced === e.coerced && r.need === e.need;
    if (ok) agree++;
    cases.push({ id: c.id, ...r, matches_expected: ok });
  }
  return {
    eval: 'counterpart-move-gate', label: 'Scripted replies, not live model runs.', replies: fixtures.name,
    replies_sha256: createHash('sha256').update(raw).digest('hex'), provenance: fixtures.provenance,
    counts: tally,
    baseline: { describe: 'Trust the model: speak the move it chose.', replies_outside_gate_spoken: tally.outside_gate },
    gated: { describe: 'Code\'s move gate (src/counterpart.mjs allowedMoves, applied in src/voice.mjs replyToAnswer).', replies_outside_gate_spoken: spokenOutside },
    matches_expected: `${agree} of ${tally.cases}`,
    headline: `On ${tally.cases} scripted replies: ${tally.outside_gate} chose a move the gate did not allow (${tally.early_wrap_up} ended the round early, ${tally.missed_close} kept going after code measured it closed); trusting the model, all ${tally.outside_gate} would be spoken, after the gate ${spokenOutside}; ${tally.invalid_needs} invalid need ignored; ${tally.unusable} unusable replies sent for one retry.`,
    cases
  };
}
