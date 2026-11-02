// The other person in a practice round has a need, and code decides when the round ends.
//
// On the first answer of a practice round, Muse Spark Open picks what the other person needs from the user (one of
// NEEDS), from the screen card's summary. The Mac holds that need for the rest of the round and sends it back with
// each answer (X-Counterpart-Need); it is never stored. For every answer, code measures whether the answer met the
// need (needMet: fixed English and French word patterns) and counts its hedges, and the move gate (allowedMoves)
// decides which moves the reply may make. The model only chooses among them and words the question.
//
// Pure: no I/O, no clock, no model calls.
import { habitHits } from './capture.mjs';

export const NEEDS = ['number', 'date', 'decision', 'owner', 'example'];
export const REPLY_MODES = ['model', 'code'];
export const NEED_METHOD = 'counterpart-needs-v1';
// The answer that ends a practice round whatever was measured.
export const ANSWER_CAP = 4;
export const GATE_REASONS = ['open', 'measured_close', 'answer_cap'];

// A need from a header or a model reply: one of NEEDS, or null. Anything else is ignored, never an error.
export function checkNeed(value) {
  if (typeof value !== 'string') return null;
  const v = value.trim().toLowerCase();
  return NEEDS.includes(v) ? v : null;
}

// Word patterns for each need. Matched on the lower-cased NFC transcript with curly apostrophes made straight.
// They look for the thing itself (a numeral, a month and day, a first-person commitment), not for words about it, so
// "maybe soon" is not a date and "I could lead it" is not an owner.
const EN_MONTHS = 'january|february|march|april|june|july|august|september|october|november|december|jan|feb|mar|apr|jun|jul|aug|sept|sep|oct|nov|dec';
const FR_MONTHS = 'janvier|février|fevrier|mars|avril|mai|juin|juillet|août|aout|septembre|octobre|novembre|décembre|decembre';
const EN_DAYS = 'monday|tuesday|wednesday|thursday|friday|saturday|sunday';
const FR_DAYS = 'lundi|mardi|mercredi|jeudi|vendredi|samedi|dimanche';
// Whole words only. JavaScript's \b is ASCII-only, so "décidé" needs letter-aware edges.
const w = source => new RegExp(`(?<![\\p{L}\\p{N}])(?:${source})(?![\\p{L}\\p{N}])`, 'u');
const PATTERNS = {
  en: {
    number: [/\d/u, w('two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|fifteen|twenty|thirty|forty|fifty|hundred|thousand|million|billion|percent|per cent|half')],
    date: [w(`(?:${EN_MONTHS})\\.? ?\\d{1,2}(?:st|nd|rd|th)?`), w(`\\d{1,2}(?:st|nd|rd|th)? (?:of )?(?:${EN_MONTHS}|may)`), w('may \\d{1,2}(?:st|nd|rd|th)?'),
      w(`(?:by|on|this|next|until|before) (?:${EN_DAYS})`), w('today|tomorrow|tonight'), w('(?:next|this) (?:week|month|quarter|sprint)'),
      w('end of (?:the |this |next )?(?:day|week|month|quarter|year|sprint)'), w('q[1-4]'), w('\\d{4}-\\d{2}-\\d{2}'),
      w('in (?:\\d+|two|three|four|five|six|ten) (?:days|weeks|months)'), w('the \\d{1,2}(?:st|nd|rd|th)')],
    decision: [w('(?:i|we) (?:have )?decided'), w('my decision'), w("(?:i'll|we'll|i will|we will|i'm going to|we're going to|i am going to|we are going to) (?!maybe|probably|try|see|think)\\p{L}+"),
      w("let's (?!see|think|maybe)\\p{L}+"), w('(?:we|i) (?:go|are going|am going) with'), w('the answer is (?:yes|no)'), w('my call is')],
    owner: [w("(?:i'll|i will|i am going to|i'm going to) (?:own|lead|run|drive|take|handle|do)"), w('i (?:own|lead|run|drive) (?:it|this|that|the)'),
      w("(?:i'm|i am) (?:the owner|responsible|accountable|in charge)"), w("it'?s on me"), w('owner|owned by'), w('\\p{L}+ (?:owns|will own) (?:it|this|that|the)')],
    example: [w('for (?:example|instance)'), w('e\\.?g'), w('such as'), w('(?:an|one|another) example'), w('last (?:week|month|quarter|year|time|sprint)'),
      w('case in point'), w('when we (?:did|tried|ran|shipped|launched)')]
  },
  fr: {
    number: [/\d/u, w('deux|trois|quatre|cinq|six|sept|huit|neuf|dix|onze|douze|quinze|vingt|trente|quarante|cinquante|cent|mille|million|milliard|pour cent|moitié')],
    date: [w(`\\d{1,2}(?:er)? (?:${FR_MONTHS})`), w(`(?:${FR_MONTHS}) \\d{4}`), w(`(?:d'ici|avant|pour|jusqu'à|dès|ce) (?:${FR_DAYS})`), w(`(?:${FR_DAYS}) prochain`),
      w("aujourd'hui|demain|ce soir"), w('(?:la semaine|le mois|le trimestre) prochaine?'), w("fin (?:de la |du |de |d')(?:journée|semaine|mois|trimestre|année|sprint)"),
      w('t[1-4]'), w('\\d{4}-\\d{2}-\\d{2}'), w('dans (?:\\d+|deux|trois|quatre|cinq|six|dix) (?:jours|semaines|mois)'), w('le \\d{1,2}(?:er)?')],
    decision: [w("(?:j'ai|nous avons|on a) décidé"), w('ma décision'), w('(?:je vais|nous allons|on va) (?!peut-être|essayer|voir)\\p{L}+'), w('on part sur'),
      w("c'est (?:oui|non)"), w('je choisis')],
    owner: [w("je (?:m'en occupe|m'en charge|pilote|prends|porte)"), w('je (?:suis|serai) (?:le |la )?responsable'), w("c'est moi qui"), w('responsable'),
      w('\\p{L}+ (?:pilote|porte) (?:le|la|ce|cette)')],
    example: [w('par exemple'), w('comme quand'), w('un exemple'), w('notamment'), w("(?:la semaine|le mois|le trimestre|l'année) derni(?:er|ère)"),
      w("quand on a (?:fait|essayé|lancé|livré)")]
  }
};
const norm = text => String(text ?? '').normalize('NFC').toLowerCase().replace(/[’‘]/g, "'").replace(/\s+/g, ' ');

// Whether the answer contains the thing the other person needs. Code-measured; false for an unknown need or language.
export function needMet(transcript, need, language = 'en') {
  const patterns = PATTERNS[language]?.[need];
  if (!patterns) return false;
  const text = norm(transcript);
  return patterns.some(p => p.test(text));
}

// The move gate. Code decides when the round ends; the model only chooses among the allowed moves.
//   need set, met and no hedges (from answer 2)   -> [wrap_up], measured_close
//   no need and no hedges (from answer 2)         -> [wrap_up], measured_close
//   answer ANSWER_CAP or later                    -> [wrap_up], answer_cap
//   otherwise                                     -> [follow_up, challenge], open
// The first answer never closes the round: the other person always asks at least one question.
export function gateReason({ need = null, needMet: met = false, hedges = 0, answerIndex = 1 }) {
  if (answerIndex >= 2 && hedges === 0 && (need ? met : true)) return 'measured_close';
  if (answerIndex >= ANSWER_CAP) return 'answer_cap';
  return 'open';
}
export function allowedMoves(input) {
  return gateReason(input) === 'open' ? ['follow_up', 'challenge'] : ['wrap_up'];
}

// The reply with no model at all (X-Reply-Mode: code). With a hedge (or else a filler) in the answer and challenge
// allowed, it quotes the first one, cut from the transcript by code, and asks the fixed challenge question; otherwise
// it asks the fixed question for the first allowed move. questions: the fixed questions for the language.
export function codeOnlyReply({ transcript, language = 'en', allowed, questions }) {
  const { hits } = habitHits(String(transcript ?? ''), language);
  const hit = hits.find(h => h.category === 'hedges') ?? hits.find(h => h.category === 'fillers');
  if (hit && allowed.includes('challenge')) {
    const lead = language === 'fr' ? `Vous avez dit « ${hit.quote} ».` : `You said "${hit.quote}".`;
    return { move: 'challenge', quote: hit.quote, question: `${lead} ${questions.challenge}` };
  }
  return { move: allowed[0], quote: '', question: questions[allowed[0]] };
}
