// One isolated request. Line protocol with the hosting adapter (deploy/bridge.py):
//   stdin  line 1: request envelope JSON
//   stdout {"phase":"release"}  database checkpointed and closed; the adapter may serve other requests
//   stdout {"phase":"acquire"}  worker needs the database again; it waits for stdin line "go"
//   stdout {"response":{...}}   final response; database checkpointed and closed
// The adapter persists the closed database before releasing the response.
import { Readable } from 'node:stream';
import { createInterface } from 'node:readline';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { Store } from '../src/store.mjs';
import { createHandler } from '../src/server.mjs';

const lines = createInterface({ input: process.stdin, crlfDelay: Infinity })[Symbol.asyncIterator]();
const emit = message => new Promise(resolve => process.stdout.write(JSON.stringify(message) + '\n', resolve));
let store;
try {
  const first = await lines.next();
  if (first.done) throw new Error('Missing request envelope');
  if (first.value.length > 12 * 1024 * 1024) throw new Error('Adapter input exceeds 12 MiB'); // base64 of an 8 MiB recording plus envelope
  const envelope = JSON.parse(first.value);
  const dbPath = process.env.DB_PATH;
  if (!dbPath) throw new Error('DB_PATH is required');
  mkdirSync(dirname(dbPath), { recursive: true, mode: 0o700 });
  store = new Store(dbPath);
  const checkpointAndClose = () => { store.db.exec('PRAGMA wal_checkpoint(TRUNCATE)'); store.close(); };
  const phases = {
    async release() { checkpointAndClose(); await emit({ phase: 'release' }); },
    async acquire() {
      await emit({ phase: 'acquire' });
      const go = await lines.next();
      if (go.done || go.value.trim() !== 'go') throw new Error('Database lock was not granted');
      store.reopen();
    }
  };
  const hash = process.env.CONNECTOR_TOKEN_HASH;
  if (hash) {
    if (!/^[a-f0-9]{64}$/.test(hash)) throw new Error('Invalid bootstrap token hash');
    store.db.prepare('INSERT OR IGNORE INTO tokens(hash,user_id,scopes) VALUES(?,?,?)').run(hash, 'synthetic-operator', JSON.stringify(['read', 'write']));
    store.seed('synthetic-operator');
  }
  const req = Readable.from([Buffer.from(envelope.body_b64 ?? '', 'base64')]);
  Object.assign(req, { method: envelope.method, url: envelope.path, headers: envelope.headers ?? {} });
  let output;
  const res = { writeHead(status, headers) { this.status = status; this.headers = headers; }, end(body) { output = { status: this.status, headers: this.headers, body_b64: Buffer.from(body).toString('base64') }; } };
  await createHandler(store, { baseUrl: envelope.base_url, phases })(req, res);
  if (!output) throw new Error('Handler did not produce a response');
  checkpointAndClose();
  // Emit only the response. Never log request headers or the input envelope.
  await emit({ response: output });
  process.exit(0);
} catch (err) {
  try { store?.close(); } catch {}
  console.error('Adapter failed:', err.name);
  process.exit(1);
}
