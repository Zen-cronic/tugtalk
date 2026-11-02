// The hosting worker (scripts/handle-request.mjs) on its own: one process for many requests, and after every write the
// database file alone is complete and closed, so the adapter's volume commit holds the whole database. No network.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { mkdtempSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';

test('worker: one process serves many requests; a write leaves one complete, closed database file; a read is not committed', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'worker-test-'));
  const dbPath = join(dir, 'connector.sqlite');
  const token = 'worker-test-token';
  const env = { ...process.env, DB_PATH: dbPath, CONNECTOR_TOKEN_HASH: createHash('sha256').update(token).digest('hex') };
  delete env.MODEL_API_KEY; delete env.BASETEN_API_KEY;
  const child = spawn(process.execPath, [fileURLToPath(new URL('../scripts/handle-request.mjs', import.meta.url))], { env, stdio: ['pipe', 'pipe', 'ignore'] });
  const lines = createInterface({ input: child.stdout })[Symbol.asyncIterator]();
  const next = async () => JSON.parse((await lines.next()).value);
  const request = async (id, method, path, body, key = `worker-${id}`) => {
    const headers = { authorization: `Bearer ${token}`, ...(body ? { 'content-type': 'application/json', 'idempotency-key': key } : {}) };
    child.stdin.write(JSON.stringify({ id, envelope: { method, path, headers, base_url: 'https://x--web.us-east.modal.run', body_b64: Buffer.from(body ? JSON.stringify(body) : '').toString('base64') } }) + '\n');
    const message = await next();
    assert.equal(message.id, id);
    return { ...message, data: JSON.parse(Buffer.from(message.response.body_b64, 'base64')) };
  };
  // What a volume commit would see right now: the main file only, opened by someone else.
  const committed = () => {
    const db = new DatabaseSync(dbPath, { readOnly: true });
    try { return { integrity: db.prepare('PRAGMA integrity_check').get().integrity_check, goals: db.prepare("SELECT COUNT(*) AS n FROM records WHERE kind='goals'").get().n }; }
    finally { db.close(); }
  };
  try {
    const ready = await next();
    assert.deepEqual(ready, { ready: true, dirty: true }, 'the bootstrap token and seed rows were written');
    assert.equal(existsSync(dbPath + '-wal'), false, 'closed after the bootstrap, so the first commit holds one file');
    const read = await request('r1', 'GET', '/v1/overview');
    assert.equal(read.response.status, 200); assert.equal(read.dirty, false, 'a read is not committed');
    assert.ok(read.timing.reopen >= 0, 'the database was reopened for the first request');
    const write = await request('r2', 'POST', '/v1/goals', { title: 'Pause first', target: 'Wait a beat' });
    assert.equal(write.response.status, 200); assert.equal(write.dirty, true);
    assert.ok(write.timing.checkpoint >= 0 && write.timing.close >= 0, 'checkpointed and closed before answering');
    assert.equal(existsSync(dbPath + '-wal'), false);
    assert.deepEqual(committed(), { integrity: 'ok', goals: 1 }, 'the file alone holds the new goal');
    const after = await request('r3', 'GET', '/v1/overview');
    assert.equal(after.data.goals.length, 1, 'the next request reads it on the reopened database');
    const replay = await request('r4', 'POST', '/v1/goals', { title: 'Pause first', target: 'Wait a beat' }, 'worker-r2');
    assert.equal(replay.data.replayed, true); assert.equal(replay.data.receipt_id, write.data.receipt_id);
    assert.deepEqual(committed(), { integrity: 'ok', goals: 1 }, 'an exact retry adds nothing');
    for (let i = 0; i < 5; i++) assert.equal((await request(`h${i}`, 'GET', '/health')).response.status, 200);
    assert.equal(child.exitCode, null, 'nine requests, still the same process');
  } finally { child.kill(); rmSync(dir, { recursive: true, force: true }); }
});
