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

test('watch connector key: the build carries it readable, and the docs say to rotate it and keep testing internal', () => {
  const docs = readFileSync(`${root}docs/watch-sparring.md`, 'utf8');
  assert.match(docs, /read that key from the app's Info\.plist/);
  assert.match(docs, /the key is rotated after the demo period, and this build is never opened to external testing/);
  for (const file of ['App.xcconfig', 'Secrets.example.xcconfig'])
    assert.match(readFileSync(`${watch}Config/${file}`, 'utf8'), /rotate (it|the key)\s*(\/\/ )?after the demo period/, file);
});

// The watch app's own bundle ID (the TestFlight wrapper keeps the shorter `…commscoach.watch`).
const watchAppID = projectYml.match(/\n  CommsCoachWatch:[\s\S]*?PRODUCT_BUNDLE_IDENTIFIER: (\S+)/)[1];

test('watch bundle IDs: every simulator launch in the docs starts the watch app, not the wrapper or an older ID', () => {
  assert.equal(watchAppID, 'com.kaungzinhein.commscoach.watch.watchkitapp');
  assert.ok(readFileSync(`${root}docs/watch-sparring.md`, 'utf8').includes(`simctl launch booted ${watchAppID}`), 'the guide launches the watch app');
  for (const doc of ['docs/watch-sparring.md', 'apps/mac/README.md']) {
    let text; try { text = readFileSync(`${root}${doc}`, 'utf8'); } catch { continue; }
    for (const [, id] of text.matchAll(/simctl (?:launch|terminate) \S+ (\S+)/g)) assert.equal(id, watchAppID, `${doc}: ${id}`);
    assert.doesNotMatch(text, /com\.zencronic\.commscoach/, doc);
  }
});

test('watch Info.plist: project.yml is its one source, so the committed file holds only keys project.yml declares', () => {
  const plist = readFileSync(`${watch}CommsCoachWatch/Info.plist`, 'utf8');
  const keys = [...plist.matchAll(/^\t<key>([^<]+)<\/key>/gm)].map(m => m[1]).sort();
  const info = projectYml.match(/\n    info:\n      path: CommsCoachWatch\/Info\.plist\n      properties:\n([\s\S]*?)\n    settings:/)[1];
  const declared = [...info.matchAll(/^        (\w+):/gm)].map(m => m[1]);
  // The keys XcodeGen writes into every generated Info.plist.
  const generated = ['CFBundleDevelopmentRegion', 'CFBundleExecutable', 'CFBundleIdentifier', 'CFBundleInfoDictionaryVersion', 'CFBundleName', 'CFBundlePackageType'];
  assert.deepEqual(keys, [...declared, ...generated].sort());
  for (const key of ['CFBundleDisplayName', 'CFBundleVersion', 'CFBundleShortVersionString', 'CoachAPIToken']) {
    const value = info.match(new RegExp(`^        ${key}: (.+)$`, 'm'))[1];
    assert.match(plist, new RegExp(`<key>${key}</key>\\n\\t<string>${value.replace(/[$()]/g, '\\$&')}</string>`), key);
  }
});

const iconScript = `${watch}Tools/render-icon.swift`;

test('watch icon script: its palette is the app theme\'s, so the icon cannot drift from the in-app Tug', () => {
  const theme = readFileSync(`${watch}CommsCoachWatch/Theme.swift`, 'utf8'), script = readFileSync(iconScript, 'utf8');
  for (const name of ['field', 'ink', 'tugBody', 'tugRim', 'tugInner']) {
    const hex = source => source.match(new RegExp(`let ${name} = Color\\(hex: (0x[0-9A-Fa-f]{6})\\)`))?.[1];
    assert.ok(hex(theme), `Theme.swift defines ${name}`);
    assert.equal(hex(script), hex(theme), name);
  }
});

test('watch icon script: without an output path it prints its usage and exits 64 instead of crashing', { skip: process.platform !== 'darwin' && 'needs swift on macOS' }, () => {
  const r = spawnSync('swift', [iconScript], { encoding: 'utf8', timeout: 120_000 });
  assert.equal(r.status, 64, r.stderr);
  assert.match(r.stderr, /^usage: swift apps\/watch\/Tools\/render-icon\.swift <output\.png>/);
  assert.doesNotMatch(readFileSync(iconScript, 'utf8'), /ctx\.fill\(/, 'no fill under the opaque Canvas');
});
