// The README's first line and the landing page's headline are the same sentence, and the eval number follows it.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const read = path => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');

test('README: the first line is the landing headline, and the eval number comes next', () => {
  const lines = read('README.md').split('\n').filter(l => l.trim() && !l.startsWith('# '));
  const headline = read('site/index.html').match(/<h1>([^<]+)<\/h1>/)[1].trim();
  assert.equal(lines[0], headline);
  assert.match(lines[1], /^\*\*Measured habit counts: precision /);
});
