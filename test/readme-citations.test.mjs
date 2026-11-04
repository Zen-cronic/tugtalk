// The README cites code by name, with a GitHub line anchor: [`replyToAnswer`](src/voice.mjs#L293-L302).
// Each cited range must still contain the name in the link text, so a citation cannot silently point at other code.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';

const root = new URL('../', import.meta.url);
const readme = readFileSync(new URL('README.md', root), 'utf8');
const ANCHORED = /\[`([^`]+)`\]\(((?:src|test|deploy|apps|scripts)\/[^)#\s]+)#L(\d+)(?:-L(\d+))?\)/g;

test('README: every anchored code citation names something on the cited lines', () => {
  const cites = [...readme.matchAll(ANCHORED)];
  assert.ok(cites.length >= 40, `expected the README's code citations, found ${cites.length}`);
  const wrong = [];
  for (const [link, name, path, from, to = from] of cites) {
    const file = new URL(path, root);
    if (!existsSync(file)) { wrong.push(`${link}: no such file`); continue; }
    const lines = readFileSync(file, 'utf8').split('\n');
    const a = Number(from), b = Number(to);
    if (a < 1 || b < a || b > lines.length) { wrong.push(`${link}: lines out of range (file has ${lines.length})`); continue; }
    if (!lines.slice(a - 1, b).join('\n').includes(name)) wrong.push(`${link}: "${name}" is not on lines ${a}-${b}`);
  }
  assert.deepEqual(wrong, []);
});

test('README: no source link without a line anchor, and no bare file:line citations', () => {
  const unanchored = [...readme.matchAll(/\]\((src\/[^)\s]+)\)/g)].map(m => m[1]).filter(p => !/#L\d+/.test(p));
  assert.deepEqual(unanchored, [], 'link source files with #L anchors');
  const bare = readme.match(/[\w/.-]+\.(?:mjs|py|swift):\d+/g) ?? [];
  assert.deepEqual(bare, [], 'cite a name with a #L anchor, not file:line');
});
