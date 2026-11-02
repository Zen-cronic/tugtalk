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
  'https://example--web.us-east.modal.run': { bytes: 4993, sha256: '69796091504a2b2421e72b1d264255e5cc7ad1d6388854e55c7b974ecfdf04eb' },
  'http://127.0.0.1:4318': { bytes: 4960, sha256: 'ea98ad2b9519ca7e418be18974278ed0108358f994b057fb9df768cd217a30ca' }
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
