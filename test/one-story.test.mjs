// The README's first line and the landing page's headline are the same sentence; the eval line is kept in the README.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const read = path => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');

test('README: the first line is the landing headline, and the eval line is still in the README', () => {
  const lines = read('README.md').split('\n').filter(l => l.trim() && !l.startsWith('# '));
  const headline = read('site/index.html').match(/<h1>([^<]+)<\/h1>/)[1].trim();
  assert.equal(lines[0], headline);
  assert.ok(lines.some(l => /^\*\*Measured habit counts: precision /.test(l)), 'README keeps the eval line');
});
