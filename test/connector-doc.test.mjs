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
  'https://example--web.us-east.modal.run': { bytes: 9650, sha256: 'b223b32ab71e3a5f36869081245cb845f396dfc823de0d882f4562498521b9a7' },
  'http://127.0.0.1:4318': { bytes: 9617, sha256: '8ac2a2273ac3e816bca5d5844cc2f2b5f93f34991556f8f14cbad6860984cdba' }
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
