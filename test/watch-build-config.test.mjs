// The watch app's build settings: the checks that keep a TestFlight archive from shipping a broken or stale build.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const watch = `${root}apps/watch/`;
const projectYml = readFileSync(`${watch}project.yml`, 'utf8');

const runKeyCheck = env => spawnSync('/bin/sh', [`${watch}Tools/check-release-key.sh`], { env: { PATH: process.env.PATH, ...env }, encoding: 'utf8' });

test('watch Release build: an empty or placeholder connector key stops the build; Debug and a set key pass', () => {
  for (const key of ['', '   ', 'paste-synthetic-key-here', ' paste-synthetic-key-here ']) {
    const r = runKeyCheck({ CONFIGURATION: 'Release', COACH_API_TOKEN: key });
    assert.equal(r.status, 1, `Release with ${JSON.stringify(key)} must fail`);
    assert.match(r.stdout, /^error: COACH_API_TOKEN is empty or the example placeholder/);
  }
  assert.equal(runKeyCheck({ CONFIGURATION: 'Release' }).status, 1, 'an unset key fails too');
  assert.equal(runKeyCheck({ CONFIGURATION: 'Debug', COACH_API_TOKEN: '' }).status, 0, 'simulator runs need no key');
  const ok = runKeyCheck({ CONFIGURATION: 'Release', COACH_API_TOKEN: 'not-a-real-key-for-the-check' });
  assert.equal(ok.status, 0);
  assert.doesNotMatch(ok.stdout + ok.stderr, /not-a-real-key/, 'the key is never printed');
});

test('watch Release build: the key check is a build phase of the watch app target', () => {
  const target = projectYml.slice(projectYml.indexOf('\n  CommsCoachWatch:\n'));
  assert.match(target, /preBuildScripts:\n\s+# [^\n]*\n\s+- name: Check the connector key \(Release\)\n\s+script: '\/bin\/sh "\$\{SCRIPT_INPUT_FILE_0\}"'\n\s+inputFiles:\n\s+- \$\(SRCROOT\)\/Tools\/check-release-key\.sh/);
});
