// Pause and pace metrics from the speech segments ("turns") that Meta muse-voice-transcribe-1.0 returns in
// ENDPOINTING mode. Code computes every number here; no model is asked.
//
// What a turn boundary is: the transcriber's endpointer closes a turn when it detects the end of a stretch of
// speech, so the time between two turns is silence it detected. It is not a word timing. A pause shorter than
// the endpointer's own silence window stays inside a turn and is invisible here, and a filled pause ("um")
// is speech, not silence. So these numbers are a floor on pausing, not a full account of it.

export const PAUSE_METHOD = 'turn-gaps-v1';
// A gap counts as a pause from 250 ms, a threshold often used for silent pauses in fluency research.
export const PAUSE_MIN_MS = 250;
export const LONG_PAUSE_MS = 1000;
// Turns may end slightly after the measured clip length (rounding on either side). Beyond this, the turns
// and the clip disagree and nothing is reported.
export const CLIP_TOLERANCE_MS = 1000;
export const MAX_LISTED_GAPS = 100;

export const PAUSE_CAVEATS = [
  'Pauses are gaps between the speech segments the transcriber returned, not word timings; short pauses inside a segment are not seen.',
  'A filled pause such as "um" is speech, so it appears in the filler count, not here.',
  'Silence before the first segment includes the time between starting the recording and starting to speak.',
  'Speaking time is the time inside segments, so it still includes any pauses the transcriber kept inside a segment.'
];

const empty = (status, clipMs, reason) => ({
  status, method: PAUSE_METHOD, reason, turn_count: 0, clip_ms: clipMs ?? null, speaking_ms: null, speaking_ratio: null,
  words_per_speaking_minute: null, pause_min_ms: PAUSE_MIN_MS, pause_count: 0, pause_total_ms: null, longest_pause_ms: null,
  long_pause_ms: LONG_PAUSE_MS, long_pause_count: 0, silence_before_first_turn_ms: null, silence_after_last_turn_ms: null, gaps_ms: [],
  caveats: PAUSE_CAVEATS
});

const isTime = v => typeof v === 'number' && Number.isFinite(v) && v >= 0;
const ratio = (a, b) => Math.round(a / b * 1000) / 1000;

// turns: [{ start_ms, end_ms }] in clip time. clipMs: the clip length used for pace. wordCount: words in the transcript.
export function measurePauses(turns, clipMs, wordCount) {
  if (!Array.isArray(turns) || turns.length === 0) return empty('no_turns', clipMs, 'The transcription returned no speech segments.');
  if (!isTime(clipMs) || clipMs <= 0) return empty('invalid_turns', clipMs, 'The clip length is unknown.');
  if (turns.some(t => !t || !isTime(t.start_ms) || !isTime(t.end_ms) || t.end_ms < t.start_ms))
    return empty('invalid_turns', clipMs, 'A speech segment has a missing, negative or reversed time.');
  if (turns.some(t => t.end_ms > clipMs + CLIP_TOLERANCE_MS))
    return empty('invalid_turns', clipMs, 'A speech segment ends after the clip does.');
  // Sort and merge overlapping or touching segments, so overlaps never count as speaking twice or as a pause.
  const spans = turns.map(t => [t.start_ms, Math.min(t.end_ms, clipMs)]).sort((a, b) => a[0] - b[0] || a[1] - b[1]);
  const merged = [];
  for (const [start, end] of spans) {
    const last = merged.at(-1);
    if (last && start <= last[1]) last[1] = Math.max(last[1], end);
    else merged.push([start, end]);
  }
  const speakingMs = merged.reduce((sum, [start, end]) => sum + (end - start), 0);
  const gaps = merged.slice(1).map(([start], i) => start - merged[i][1]).filter(gap => gap >= PAUSE_MIN_MS);
  return {
    status: 'measured', method: PAUSE_METHOD, reason: null, turn_count: turns.length, clip_ms: clipMs,
    speaking_ms: speakingMs, speaking_ratio: ratio(speakingMs, clipMs),
    words_per_speaking_minute: speakingMs > 0 && Number.isInteger(wordCount) ? Math.round(wordCount / (speakingMs / 60000)) : null,
    pause_min_ms: PAUSE_MIN_MS, pause_count: gaps.length, pause_total_ms: gaps.reduce((a, b) => a + b, 0),
    longest_pause_ms: gaps.length ? Math.max(...gaps) : null,
    long_pause_ms: LONG_PAUSE_MS, long_pause_count: gaps.filter(gap => gap >= LONG_PAUSE_MS).length,
    silence_before_first_turn_ms: merged[0][0], silence_after_last_turn_ms: Math.max(0, clipMs - merged.at(-1)[1]),
    gaps_ms: gaps.slice(0, MAX_LISTED_GAPS),
    caveats: PAUSE_CAVEATS
  };
}
