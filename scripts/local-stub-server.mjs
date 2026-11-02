// Local server with stub models, for developing capture clients without paid calls.
// Creates a throwaway database and a local-only token in a temporary directory (or STUB_DIR).
// The token file path is printed; the token itself is not. Nothing here touches .data/.
//   --live-models  use the real Meta and Baseten clients instead (paid; needs MODEL_API_KEY and BASETEN_API_KEY
//                  in the environment), still with the throwaway database and token. For latency runs only.
import { mkdtempSync, writeFileSync, mkdirSync, readFileSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Store } from '../src/store.mjs';
import { createApp } from '../src/server.mjs';
import { habitHits } from '../src/capture.mjs';
import { createSpeechModel } from '../src/speech.mjs';

const dir = process.env.STUB_DIR ?? mkdtempSync(join(tmpdir(), 'comms-coach-stub-'));
mkdirSync(dir, { recursive: true, mode: 0o700 });
const port = Number(process.env.PORT ?? 4319);
const store = new Store(join(dir, 'stub.sqlite'));
const token = randomBytes(32).toString('base64url');
store.addToken(token, 'local-stub'); store.seed('local-stub');
const tokenFile = join(dir, 'local-token.txt');
writeFileSync(tokenFile, token, { mode: 0o600 });

const live = process.argv.includes('--live-models');
if (live && (!process.env.MODEL_API_KEY || !process.env.BASETEN_API_KEY)) { console.error('--live-models needs MODEL_API_KEY and BASETEN_API_KEY in the environment.'); process.exit(1); }
const STUB = 'stub (local, no model call)';
const delay = Number(process.env.STUB_DELAY_MS ?? 1500);
const wait = () => new Promise(r => setTimeout(r, delay));
// STUB_TRANSCRIPTS="first|second|…": each transcription returns the next one, then the last one again (for drill checks).
const transcripts = (process.env.STUB_TRANSCRIPTS ?? 'Um, the main point is we ship first.').split('|');
const models = {
  async transcribe() {
    await wait();
    const transcript = transcripts.length > 1 ? transcripts.shift() : transcripts[0];
    return { transcript, turns: [{ turn_id: 0, start_ms: 400, end_ms: 2600, transcript }], audio_duration_ms: 3000, model: STUB, provider_session_id: 'stub' };
  },
  // Presses on the first habit it finds (STUB_MOVE=wrap_up ends the round instead). STUB_BAD_QUOTE=1 returns a quote the speaker never said, to show the check dropping it.
  // Like the real model, it keeps to allowed_moves (STUB_IGNORE_GATE=1 does not, to show code replacing the move) and, when
  // choose_need is sent, returns need STUB_NEED (default date).
  async voiceReply({ user }) {
    await wait();
    if (process.env.STUB_FAIL === '1') return { status: 'unavailable', reason: 'Stub failure requested.', attempts: 1 };
    const message = JSON.parse(user), { transcript } = message.answer, hit = habitHits(transcript, 'en').hits[0];
    const quote = process.env.STUB_BAD_QUOTE === '1' ? 'we will triple revenue' : hit?.quote ?? transcript.split(/\s+/).slice(0, 4).join(' ');
    let move = process.env.STUB_MOVE ?? (hit ? 'challenge' : 'follow_up');
    const allowed = message.allowed_moves;
    if (allowed && !allowed.includes(move) && process.env.STUB_IGNORE_GATE !== '1') move = allowed[0];
    const question = move === 'wrap_up' ? 'Stub: that answers it. Thank you.' : `You said "${quote}". Say it again without that.`;
    return { status: 'model_reply', reply: { move, quote: move === 'wrap_up' ? '' : quote, question, ...(message.choose_need ? { need: process.env.STUB_NEED ?? 'date' } : {}) },
      model: STUB, provider_request_id: `stub-${Date.now()}`, attempts: 1 };
  },
  async analyze() { await wait(); return { status: 'model_observation', observation: 'Stub observation.', suggested_exercise: 'Stub exercise.', model: STUB, provider_request_id: 'stub' }; },
  async describeScreen({ goal, text, purpose }) {
    await wait();
    if (process.env.STUB_FAIL === '1') return { status: 'unavailable', reason: 'Stub failure requested.' };
    const words = text.split(/\s+/).filter(Boolean).length;
    return { status: 'model_observation', summary: `Stub card: a ${purpose.replace('_', ' ')} note of ${words} words.`,
      observation: goal ? `Stub: this is linked to "${goal.title}".` : 'Stub: no goal was selected.',
      next_step: 'Stub: say your main ask in one sentence.', model: STUB, provider_request_id: `stub-${Date.now()}`, attempts: 1 };
  }
};

// STUB_SPEECH_MP3=<file>: spoken replies stream that file in 1 KiB chunks (first after 300 ms), through the speech route
// and the live socket, so playback can be checked without a speech provider. Off by default (the Mac's own voice).
if (process.env.STUB_SPEECH_MP3) {
  const mp3 = readFileSync(process.env.STUB_SPEECH_MP3);
  Object.assign(models, createSpeechModel({ env: { SPEECH_PROVIDER: 'wit', WIT_TTS_TOKEN: 'stub' }, fetchImpl: async () => new Response(new ReadableStream({
    async start(c) { await new Promise(r => setTimeout(r, 300)); for (let i = 0; i < mp3.length; i += 1024) { c.enqueue(mp3.subarray(i, i + 1024)); await new Promise(r => setTimeout(r, 40)); } c.close(); } }),
    { headers: { 'content-type': 'audio/mpeg' } }) }));
}
const server = createApp(store, { ...(live ? {} : { models }), baseUrl: `http://127.0.0.1:${port}` });
server.listen(port, '127.0.0.1', () => console.log(JSON.stringify({ listening: `http://127.0.0.1:${port}`, token_file: tokenFile, database: join(dir, 'stub.sqlite'), models: live ? 'live (paid Meta and Baseten calls)' : STUB })));
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => server.close(() => { store.close(); process.exit(0); }));
