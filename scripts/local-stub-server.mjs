// Local server with stub models, for developing capture clients without paid calls.
// Creates a throwaway database and a local-only token in a temporary directory (or STUB_DIR).
// The token file path is printed; the token itself is not. Nothing here touches .data/.
import { mkdtempSync, writeFileSync, mkdirSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Store } from '../src/store.mjs';
import { createApp } from '../src/server.mjs';

const dir = process.env.STUB_DIR ?? mkdtempSync(join(tmpdir(), 'comms-coach-stub-'));
mkdirSync(dir, { recursive: true, mode: 0o700 });
const port = Number(process.env.PORT ?? 4319);
const store = new Store(join(dir, 'stub.sqlite'));
const token = randomBytes(32).toString('base64url');
store.addToken(token, 'local-stub'); store.seed('local-stub');
const tokenFile = join(dir, 'local-token.txt');
writeFileSync(tokenFile, token, { mode: 0o600 });

const STUB = 'stub (local, no model call)';
const delay = Number(process.env.STUB_DELAY_MS ?? 1500);
const wait = () => new Promise(r => setTimeout(r, delay));
const models = {
  async transcribe() { await wait(); return { transcript: 'Um, the main point is we ship first.', turns: [], audio_duration_ms: 3000, model: STUB, provider_session_id: 'stub' }; },
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

const server = createApp(store, { models, baseUrl: `http://127.0.0.1:${port}` });
server.listen(port, '127.0.0.1', () => console.log(JSON.stringify({ listening: `http://127.0.0.1:${port}`, token_file: tokenFile, database: join(dir, 'stub.sqlite'), models: STUB })));
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => server.close(() => { store.close(); process.exit(0); }));
