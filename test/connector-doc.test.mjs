// Pins the exact bytes of the connector document Muse reads. A wording change must update these hashes on purpose.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Store } from '../src/store.mjs';
import { createApp, connectorDocument } from '../src/server.mjs';

const sha256 = value => createHash('sha256').update(value).digest('hex');
const PINNED = {
  'https://example--web.us-east.modal.run': { bytes: 12530, sha256: '44c270532759bb9ce1be58e09ccee43c833bfbfae6b5ce2e715e42ff6e24ebfc' },
  'http://127.0.0.1:4318': { bytes: 12497, sha256: '950f9dfb9944d75887c4eceb62b1081c26c8a2e63a457e8af5c11de81c947477' }
};

test('connector document: exact bytes pinned, served unchanged at /connector.md and /', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'connector-doc-'));
  const store = new Store(join(dir, 'doc.sqlite'));
  try {
    for (const [baseUrl, pin] of Object.entries(PINNED)) {
      const doc = connectorDocument(baseUrl);
      assert.equal(Buffer.byteLength(doc), pin.bytes, baseUrl);
      assert.equal(sha256(doc), pin.sha256, baseUrl);
      const server = createApp(store, { baseUrl }); await new Promise(r => server.listen(0, '127.0.0.1', r));
      try {
        for (const path of ['/connector.md', '/']) {
          const r = await fetch(`http://127.0.0.1:${server.address().port}${path}`);
          assert.equal(r.headers.get('content-type'), 'text/plain; charset=utf-8');
          assert.equal(await r.text(), doc, `${baseUrl}${path}`);
        }
      } finally { await new Promise(r => server.close(r)); }
    }
  } finally { store.close(); rmSync(dir, { recursive: true, force: true }); }
});

test('the TugTalk icon is served as a PNG at /favicon.ico and /icon.png, without authentication', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'icon-'));
  const store = new Store(join(dir, 'icon.sqlite'));
  try {
    const server = createApp(store, { baseUrl: 'http://127.0.0.1:4318' }); await new Promise(r => server.listen(0, '127.0.0.1', r));
    try {
      for (const path of ['/favicon.ico', '/icon.png']) {
        const r = await fetch(`http://127.0.0.1:${server.address().port}${path}`);
        assert.equal(r.status, 200);
        assert.equal(r.headers.get('content-type'), 'image/png');
        const bytes = Buffer.from(await r.arrayBuffer());
        assert.equal(bytes.subarray(1, 4).toString('ascii'), 'PNG');
      }
    } finally { await new Promise(r => server.close(r)); }
  } finally { store.close(); rmSync(dir, { recursive: true, force: true }); }
});
