// Offline eval of code's check on voice replies: scripted model text in, the reply code would return out.
// No model calls, no clock, no randomness. Measures the checking code, not the model.
//
// Baseline: trusting the model, i.e. speaking its question and quote as written. The number that matters is how
// many replies would put words in the person's mouth that they never said, with and without the check.
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { parseObject, shapeOf } from './capture.mjs';
import { acceptReply, checkReply, verifyQuote } from './voice.mjs';

export const VOICE_REPLIES_URL = new URL('../eval/voice-replies.json', import.meta.url);
const QUOTED = /["“”«»]\s*([^"“”«»]{1,300}?)\s*["“”«»]|(?<!\p{L})['‘’]([^'‘’]{1,300}?)['‘’](?!\p{L})/gu;

// Quoted spans in a question whose words are not in the transcript, plus the quote field if it is not.
export function unsaidWords(transcript, { quote, question }) {
  let n = quote && !verifyQuote(transcript, quote).verified ? 1 : 0;
  for (const [, a, b] of question.matchAll(QUOTED)) if (!verifyQuote(transcript, a ?? b).verified) n++;
  return n;
}

export function runVoiceEval(raw = readFileSync(VOICE_REPLIES_URL)) {
  const fixtures = JSON.parse(raw);
  const cases = [], tally = { cases: 0, usable: 0, unusable: 0, quotes_offered: 0, quotes_accepted: 0, quotes_rejected: 0, rejections: {},
    questions_stripped: 0, questions_replaced: 0, questions_cut: 0, questions_scrubbed: 0 };
  let baselineUnsaid = 0, checkedUnsaid = 0, agree = 0;
  for (const c of fixtures.cases) {
    tally.cases++;
    const parsed = acceptReply(parseObject(c.raw, shapeOf(acceptReply)));
    if (!parsed) {
      tally.unusable++;
      const ok = c.expect.unusable === true; if (ok) agree++;
      cases.push({ id: c.id, unusable: true, matches_expected: ok });
      continue;
    }
    tally.usable++;
    const { reply, checks } = checkReply(parsed, c.transcript, c.language);
    if (checks.quote_offered) { tally.quotes_offered++; reply.quote_verified ? tally.quotes_accepted++ : tally.quotes_rejected++; }
    if (checks.quote_rejection) tally.rejections[checks.quote_rejection] = (tally.rejections[checks.quote_rejection] ?? 0) + 1;
    if (checks.stripped_quotes) tally.questions_stripped++;
    if (checks.replaced) tally.questions_replaced++;
    if (checks.cut_to_words) tally.questions_cut++;
    if (checks.scrubbed) tally.questions_scrubbed++;
    const before = unsaidWords(c.transcript, parsed), after = unsaidWords(c.transcript, reply);
    if (before) baselineUnsaid++;
    if (after) checkedUnsaid++;
    const e = c.expect;
    const ok = !e.unusable && reply.quote === e.quote && reply.quote_verified === e.quote_verified && reply.question === e.question
      && (!('rejection' in e) || checks.quote_rejection === e.rejection);
    if (ok) agree++;
    cases.push({ id: c.id, reply, checks, unsaid_before_check: before, unsaid_after_check: after, matches_expected: ok });
  }
  return {
    eval: 'voice-reply-checks', label: 'Scripted voice replies, not live model runs.', replies: fixtures.name,
    replies_sha256: createHash('sha256').update(raw).digest('hex'), provenance: fixtures.provenance,
    counts: tally,
    baseline: { describe: 'Trust the model: speak its quote and question as written.', replies_with_unsaid_words: baselineUnsaid },
    checked: { describe: 'Code\'s check (src/voice.mjs checkReply).', replies_with_unsaid_words: checkedUnsaid },
    matches_expected: `${agree} of ${tally.cases}`,
    headline: `On ${tally.cases} scripted voice replies: code accepted ${tally.quotes_accepted} of ${tally.quotes_offered} offered quotes and rejected ${tally.quotes_rejected}; replies that would speak words the person never said: ${baselineUnsaid} when trusting the model, ${checkedUnsaid} after the check; ${tally.unusable} unusable replies sent for one retry.`,
    cases
  };
}
