// Long-lived request worker for the hosting adapter (deploy/bridge.py). One Node process serves many requests,
// each tagged with an id, over one database connection that stays open, so a request pays neither a process
// start nor a database open. Line protocol, one JSON object per line:
//   adapter -> worker  {"id", "envelope", "budget_ms"?}   start a request; the adapter holds the database lock for it
//                      {"id", "go": true}                 the lock is granted again after this request's "acquire"
//   worker -> adapter  {"ready": true, "dirty"}           once, after the bootstrap token and seed rows are written
//                      {"id", "phase": "persist", "dirty": true} commit closed database under lock; wait for go
//                      {"id", "phase": "release"}         done with the database for now (slow model calls follow)
//                      {"id", "phase": "acquire"}         needs the database again; waits for "go"
//                      {"id", "head": {status, headers}}  streamed responses only (envelope.stream): the headers,
//                      {"id", "chunk": base64}            then each body chunk as the handler writes it
//                      {"id", "response", "dirty", "aborted"?, "timing"}  the final response (for a stream, the rest)
//                      {"id", "failed": true}             the request failed; no success may be claimed
// Live voice rounds (envelope.live: the start frame of WS /v1/voice-rounds/live, src/live-voice.mjs) add:
//   adapter -> worker  {"id", "audio": base64}              one PCM frame from the client
//                      {"id", "end": true}                  the key was released
//                      {"id", "cancel": true}               the client's socket closed
//   worker -> adapter  {"id", "event": {...}}               a JSON event for the client (sent as it happens, lock or not)
//                      {"id", "audio_out": base64}          spoken-reply audio for the client
//                      {"id", "closed": true}               nothing more will be sent for this id
// and the final {"id", "response", "dirty"} once the round is written, before its audio may have finished.
// A request touches the database only while the adapter holds the lock for it: from the envelope (or "go") to its
// next "release" or final message. "dirty" means the adapter must commit the volume before answering; every request
// except a GET or a spoken reply is dirty. Before a dirty response the WAL is checkpointed into the main file and the database is closed,
// so the commit holds one complete file and no open handle (measured on Modal, Nov 2: a commit took 2.5-3.0 s with the
// database open, against 0.5-0.9 s closed). It is reopened when the next request is granted the lock, in a few ms.
// SQLite's own fsyncs are off here (synchronous=OFF): on the volume mount they cost 0.5-1.5 s per write and persist
// nothing, because durability comes from the volume commit, which runs only while the file is closed and complete.
// If the container dies before a commit, the write is lost either way, and the volume keeps its last committed copy.
// Only ids, phases and timings cross this channel besides the response itself; nothing is logged.
import { Readable } from 'node:stream';
import { createInterface } from 'node:readline';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { Store } from '../src/store.mjs';
import { createHandler } from '../src/server.mjs';
import { SPEECH_PATH, createSpeechModel } from '../src/speech.mjs';
import { createLiveRound, createRealtimeModel } from '../src/live-voice.mjs';
import { createModelClients } from '../src/capture.mjs';
import { createVoiceModel } from '../src/voice.mjs';
import { createBudget, MODEL_BUDGET_MS } from '../src/budget.mjs';
import { failOrphanedReservations } from '../src/practice.mjs';

const MAX_LINE = 12 * 1024 * 1024; // base64 of an 8 MiB recording plus the envelope
const emit = message => new Promise(resolve => process.stdout.write(JSON.stringify(message) + '\n', resolve));
const fatal = error => { console.error('Worker failed:', error?.name ?? 'Error'); process.exit(1); };

const dbPath = process.env.DB_PATH;
if (!dbPath) fatal(new Error('DB_PATH is required'));
mkdirSync(dirname(dbPath), { recursive: true, mode: 0o700 });
const store = new Store(dbPath);
const noSync = () => store.db.exec('PRAGMA synchronous=OFF');
noSync();
const changes = () => store.db.prepare('SELECT total_changes() AS n').get().n;
const checkpoint = () => store.db.exec('PRAGMA wal_checkpoint(TRUNCATE)');
// Closed while a commit may run; reopened, still under the lock, before the next request uses it.
let closed = false;
const since = t => Math.round((performance.now() - t) * 10) / 10;
const closeForCommit = () => {
  if (closed) return {};
  let t = performance.now(); checkpoint(); const cp = since(t);
  t = performance.now(); store.close(); closed = true;
  return { checkpoint: cp, close: since(t) };
};
let reopened = null;
const reopen = () => { if (closed) { const t = performance.now(); store.reopen(); noSync(); closed = false; reopened = since(t); } };

const hash = process.env.CONNECTOR_TOKEN_HASH;
if (hash) {
  if (!/^[a-f0-9]{64}$/.test(hash)) fatal(new Error('Invalid bootstrap token hash'));
  store.db.prepare('INSERT OR IGNORE INTO tokens(hash,user_id,scopes) VALUES(?,?,?)').run(hash, 'synthetic-operator', JSON.stringify(['read', 'write']));
  store.seed('synthetic-operator');
}
// A practice reservation left by a worker that was killed (for example after its reservation commit failed) would
// otherwise block that round until a manual recovery; no request is in flight yet, so it is failed now.
failOrphanedReservations(store);
const bootDirty = changes() > 0;
if (bootDirty) closeForCommit();

const granted = new Map(); // id -> resolve, for a request waiting on "go"
// Waits for the adapter's "go" for this request.
const waitForGo = async (id, message) => {
  const go = new Promise(resolve => granted.set(id, resolve));
  await emit(message);
  await go;
};
// The database phases of one request, the same for HTTP and live rounds. persist closes the database so the adapter
// can commit it (a practice reservation, or a saved answer) and returns once that commit succeeded.
const lockPhases = id => ({
  async persist() { closeForCommit(); await waitForGo(id, { id, phase: 'persist', dirty: true }); },
  async release() { await emit({ id, phase: 'release' }); },
  async acquire() { await waitForGo(id, { id, phase: 'acquire' }); }
});

async function serve(id, envelope, budgetMs) {
  const started = performance.now();
  const opened = reopened; reopened = null;
  const stream = envelope.stream === true;
  // The spoken reply's only write is its audit row, so it is not committed before its answer either: the row goes out
  // with the next committed write, as a read's does.
  const dirty = envelope.method !== 'GET' && !SPEECH_PATH.test(envelope.path ?? '');
  let headSent = false, output, aborted = false;
  const phases = lockPhases(id);
  const req = Readable.from([Buffer.from(envelope.body_b64 ?? '', 'base64')]);
  Object.assign(req, { method: envelope.method, url: envelope.path, headers: envelope.headers ?? {}, budgetMs: Number.isFinite(budgetMs) ? budgetMs : undefined });
  const chunks = [];
  const body = () => Buffer.concat(chunks).toString('base64');
  const res = {
    writeHead(status, headers) { this.status = status; this.headers = headers; },
    // A streamed response goes out chunk by chunk; any other is collected and sent whole after the commit.
    write(chunk) {
      if (!stream) { chunks.push(Buffer.from(chunk)); return true; }
      if (!headSent) { headSent = true; emit({ id, head: { status: this.status, headers: this.headers } }); }
      emit({ id, chunk: Buffer.from(chunk).toString('base64') });
      return true;
    },
    on() {}, get writableEnded() { return output !== undefined; },
    // A stream cut short upstream: the adapter ends the response early (or answers 503 if nothing was sent).
    destroy() { aborted = true; output ??= { status: this.status, headers: this.headers, body_b64: body() }; },
    end(last) { if (last !== undefined) chunks.push(Buffer.from(last)); output = { status: this.status, headers: this.headers, body_b64: body() }; }
  };
  try {
    await createHandler(store, { baseUrl: envelope.base_url, phases })(req, res);
    if (!output) throw new Error('Handler did not produce a response');
    const handler = since(started);
    const closing = dirty ? closeForCommit() : {};
    await emit({ id, response: output, dirty, ...(aborted ? { aborted: true } : {}), timing: { handler, ...closing, ...(opened !== null ? { reopen: opened } : {}) } });
  } catch (error) {
    console.error('Request failed in worker:', error?.name ?? 'Error');
    try { if (dirty) closeForCommit(); } catch {}
    await emit({ id, failed: true, dirty });
  }
}

// Live rounds in progress, by id.
const sessions = new Map();
const liveModels = { ...createModelClients(), ...createVoiceModel(), ...createSpeechModel(), ...createRealtimeModel() };

async function live(id, envelope, budgetMs) {
  const started = performance.now();
  const opened = reopened; reopened = null;
  const phases = lockPhases(id);
  const budget = createBudget({ totalMs: Math.min(MODEL_BUDGET_MS, Number.isFinite(budgetMs) ? budgetMs : Infinity) });
  let result;
  try {
    const session = createLiveRound({ store, models: liveModels, token: envelope.headers?.authorization, start: envelope.live, phases, budget,
      emit: event => emit({ id, event }), emitAudio: chunk => emit({ id, audio_out: Buffer.from(chunk).toString('base64') }) });
    sessions.set(id, session);
    result = await session.done;
    const closing = result.dirty ? closeForCommit() : {};
    await emit({ id, response: { status: result.status, headers: { 'Content-Type': 'application/json' }, body_b64: Buffer.from(JSON.stringify(result.body)).toString('base64') },
      dirty: result.dirty, timing: { handler: since(started), ...closing, ...(opened !== null ? { reopen: opened } : {}) } });
  } catch (error) {
    console.error('Live round failed in worker:', error?.name ?? 'Error');
    try { closeForCommit(); } catch {}
    await emit({ id, failed: true, dirty: true });
  }
  try { await result?.speechDone; } catch {}
  sessions.delete(id);
  await emit({ id, closed: true });
}

const lines = createInterface({ input: process.stdin, crlfDelay: Infinity });
lines.on('line', line => {
  if (line.length > MAX_LINE) fatal(new Error('Adapter input exceeds 12 MiB'));
  let message;
  try { message = JSON.parse(line); } catch (error) { fatal(error); }
  // Both messages grant the database lock, so this is where a database closed for a commit is reopened.
  if (message.go) { const resolve = granted.get(message.id); granted.delete(message.id); reopen(); resolve?.(); return; }
  if (message.audio) { sessions.get(message.id)?.audio(Buffer.from(message.audio, 'base64')); return; }
  if (message.end) { sessions.get(message.id)?.end({ camera: message.camera }); return; }
  if (message.cancel) { sessions.get(message.id)?.cancel(); return; }
  if (message.envelope?.live) { reopen(); live(message.id, message.envelope, message.budget_ms); return; }
  if (message.envelope) { reopen(); serve(message.id, message.envelope, message.budget_ms); }
});
lines.on('close', () => { try { closeForCommit(); } catch {} process.exit(0); });
await emit({ ready: true, dirty: bootDirty });
