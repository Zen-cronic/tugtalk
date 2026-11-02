// Long-lived request worker for the hosting adapter (deploy/bridge.py). One Node process serves many requests,
// each tagged with an id, over one database connection that stays open, so a request pays neither a process
// start nor a database open. Line protocol, one JSON object per line:
//   adapter -> worker  {"id", "envelope", "budget_ms"?}   start a request; the adapter holds the database lock for it
//                      {"id", "go": true}                 the lock is granted again after this request's "acquire"
//   worker -> adapter  {"ready": true, "dirty"}           once, after the bootstrap token and seed rows are written
//                      {"id", "phase": "release"}         done with the database for now (slow model calls follow)
//                      {"id", "phase": "acquire"}         needs the database again; waits for "go"
//                      {"id", "head": {status, headers}}  streamed responses only (envelope.stream): the headers,
//                      {"id", "chunk": base64}            then each body chunk as the handler writes it
//                      {"id", "response", "dirty", "aborted"?, "timing"}  the final response (for a stream, the rest)
//                      {"id", "failed": true}             the request failed; no success may be claimed
// A request touches the database only while the adapter holds the lock for it: from the envelope (or "go") to its
// next "release" or final message. "dirty" means the adapter must commit the volume before answering; every request
// except a GET is dirty. Before a dirty response the WAL is checkpointed into the main file, so the commit holds a
// complete database. Only ids, phases and timings cross this channel besides the response itself; nothing is logged.
import { Readable } from 'node:stream';
import { createInterface } from 'node:readline';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { Store } from '../src/store.mjs';
import { createHandler } from '../src/server.mjs';

const MAX_LINE = 12 * 1024 * 1024; // base64 of an 8 MiB recording plus the envelope
const emit = message => new Promise(resolve => process.stdout.write(JSON.stringify(message) + '\n', resolve));
const fatal = error => { console.error('Worker failed:', error?.name ?? 'Error'); process.exit(1); };

const dbPath = process.env.DB_PATH;
if (!dbPath) fatal(new Error('DB_PATH is required'));
mkdirSync(dirname(dbPath), { recursive: true, mode: 0o700 });
const store = new Store(dbPath);
const changes = () => store.db.prepare('SELECT total_changes() AS n').get().n;
const checkpoint = () => store.db.exec('PRAGMA wal_checkpoint(TRUNCATE)');

const hash = process.env.CONNECTOR_TOKEN_HASH;
if (hash) {
  if (!/^[a-f0-9]{64}$/.test(hash)) fatal(new Error('Invalid bootstrap token hash'));
  store.db.prepare('INSERT OR IGNORE INTO tokens(hash,user_id,scopes) VALUES(?,?,?)').run(hash, 'synthetic-operator', JSON.stringify(['read', 'write']));
  store.seed('synthetic-operator');
}
const bootDirty = changes() > 0;
if (bootDirty) checkpoint();

const granted = new Map(); // id -> resolve, for a request waiting on "go"

async function serve(id, envelope, budgetMs) {
  const started = performance.now();
  const stream = envelope.stream === true;
  const dirty = envelope.method !== 'GET';
  let headSent = false, output, aborted = false;
  const phases = {
    async release() { await emit({ id, phase: 'release' }); },
    async acquire() {
      const go = new Promise(resolve => granted.set(id, resolve));
      await emit({ id, phase: 'acquire' });
      await go;
    }
  };
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
    if (dirty) checkpoint();
    await emit({ id, response: output, dirty, ...(aborted ? { aborted: true } : {}), timing: { handler: Math.round((performance.now() - started) * 10) / 10 } });
  } catch (error) {
    console.error('Request failed in worker:', error?.name ?? 'Error');
    await emit({ id, failed: true, dirty });
  }
}

const lines = createInterface({ input: process.stdin, crlfDelay: Infinity });
lines.on('line', line => {
  if (line.length > MAX_LINE) fatal(new Error('Adapter input exceeds 12 MiB'));
  let message;
  try { message = JSON.parse(line); } catch (error) { fatal(error); }
  if (message.go) { const resolve = granted.get(message.id); granted.delete(message.id); resolve?.(); return; }
  if (message.envelope) serve(message.id, message.envelope, message.budget_ms);
});
lines.on('close', () => { try { checkpoint(); store.close(); } catch {} process.exit(0); });
await emit({ ready: true, dirty: bootDirty });
