// Recomputes every value in FACTS.md from code, the HTTP handler or the eval. No network, no paid calls.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
import { Store } from '../src/store.mjs';
import { createApp, captureParams } from '../src/server.mjs';
import { MAX_AUDIO_BYTES, MAX_AUDIO_MS, TRANSCRIBE_MODEL, ANALYSIS_MODEL, LANGUAGES, inspectWav, measure, createModelClients } from '../src/capture.mjs';
import { runEval } from '../src/evaluate.mjs';
import { MAX_SCREEN_TEXT_CHARS, MAX_SCREEN_TEXT_BYTES } from '../src/screen-context.mjs';

const read = path => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const MiB = 1024 * 1024;

function wav(seconds, { rate = 24000, channels = 1 } = {}) {
  const samples = Math.round(seconds * rate), data = Buffer.alloc(samples * 2 * channels);
  for (let i = 0; i < samples * channels; i++) data.writeInt16LE(Math.round(Math.sin(i / 7) * 3000 + (i % 13) * 11), i * 2);
  const h = Buffer.alloc(44);
  h.write('RIFF', 0); h.writeUInt32LE(36 + data.length, 4); h.write('WAVE', 8); h.write('fmt ', 12); h.writeUInt32LE(16, 16);
  h.writeUInt16LE(1, 20); h.writeUInt16LE(channels, 22); h.writeUInt32LE(rate, 24); h.writeUInt32LE(rate * 2 * channels, 28); h.writeUInt16LE(2 * channels, 32); h.writeUInt16LE(16, 34);
  h.write('data', 36); h.writeUInt32LE(data.length, 40);
  return Buffer.concat([h, data]);
}
const accepts = buffer => { try { inspectWav(buffer); return true; } catch { return false; } };
// The values a capture header accepts, read from the handler's own validation: each listed value passes, an unknown one fails.
function acceptedValues(header) {
  let message;
  try { captureParams({ [header]: 'not-a-value' }); } catch (error) { message = error.message; }
  const values = message.match(/must be one of: (.+)\.$/)[1].split(', ');
  for (const value of values) assert.doesNotThrow(() => captureParams({ [header]: value }), `${header}: ${value}`);
  return values.join(', ');
}
// Counts this repo's Node tests by running them: every other test file through `node --test`, plus this one.
async function runNodeTests() {
  const here = new URL('./', import.meta.url);
  const files = readdirSync(here).filter(f => f.endsWith('.test.mjs') && f !== 'facts.test.mjs').map(f => fileURLToPath(new URL(f, here)));
  const env = { ...process.env }; delete env.NODE_TEST_CONTEXT;
  const { stdout } = await promisify(execFile)(process.execPath, ['--test', '--test-reporter=tap', ...files], { env, maxBuffer: 16 * 1024 * 1024 });
  const count = name => Number(stdout.match(new RegExp(`^# ${name} (\\d+)$`, 'm'))[1]);
  assert.equal(count('fail'), 0, 'the other test files pass');
  return count('tests') + 1;
}

function parseFacts() {
  return read('FACTS.md').split('\n').filter(l => /^\| `[a-z0-9-]+` \|/.test(l))
    .map(l => l.split('|').slice(1, -1).map(c => c.trim())).map(([id, claim, value]) => ({ id: id.replace(/`/g, ''), claim, value }));
}

test('every FACTS.md claim matches the code, the HTTP handler or the eval', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'facts-test-'));
  const dbPath = join(dir, 'facts.sqlite');
  const store = new Store(dbPath);
  store.addToken('facts-secret', 'facts-user'); store.seed('facts-user');
  const calls = { transcribe: 0, analyze: 0 };
  const models = {
    async transcribe() { calls.transcribe++; return { transcript: 'Um, I think we ship it.', turns: [], audio_duration_ms: 2000, model: TRANSCRIBE_MODEL, provider_session_id: 'fake' }; },
    async analyze() { calls.analyze++; return { status: 'model_observation', observation: 'One filler.', suggested_exercise: 'Answer once.', model: ANALYSIS_MODEL, provider_request_id: 'fake' }; },
    async describeScreen() { calls.describe = (calls.describe ?? 0) + 1; return { status: 'model_observation', summary: 'Preparing a 1:1.', observation: 'Lead with the ask.', next_step: 'Say it once.', model: ANALYSIS_MODEL }; }
  };
  const screen = (text, key) => fetch(base + '/v1/screen-contexts', { method: 'POST', headers: { ...auth, 'Content-Type': 'application/json', 'Idempotency-Key': key },
    body: JSON.stringify({ purpose: 'meeting_prep', capture_device: 'mac', text, redaction: { method: 'on-device-v1', counts: {} } }) });
  const server = createApp(store, { models }); await new Promise(r => server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${server.address().port}`;
  const auth = { Authorization: 'Bearer facts-secret' };
  try {
    const evalResult = runEval();
    const m = evalResult.systems.measure, b = evalResult.systems.flat_list_baseline;
    const spec = await (await fetch(base + '/openapi.json')).json();
    const connector = await (await fetch(base + '/connector.md')).text();
    const modal = read('deploy/modal_app.py');

    const checks = {
      'audio-max-bytes': () => {
        const bridge = Number(read('deploy/bridge.py').match(/^AUDIO_LIMIT = (\d+) \* (\d+) \* (\d+)/m).slice(1).reduce((a, x) => a * Number(x), 1));
        assert.equal(bridge, MAX_AUDIO_BYTES, 'bridge and handler limits agree');
        return `${MAX_AUDIO_BYTES / MiB} MiB`;
      },
      'audio-max-seconds': () => { assert.equal(accepts(wav(181, { rate: 16000 })), false); return `${MAX_AUDIO_MS / 1000} s`; },
      'audio-min-seconds': () => { assert.equal(accepts(wav(0.4)), false); assert.equal(accepts(wav(0.5)), true); return '0.5 s'; },
      'audio-format': () => {
        assert.equal(accepts(wav(1, { rate: 16000 })), true); assert.equal(accepts(wav(1, { rate: 24000 })), true);
        assert.equal(accepts(wav(1, { rate: 44100 })), false); assert.equal(accepts(wav(1, { channels: 2 })), false);
        return 'mono 16-bit PCM WAV, 16 or 24 kHz';
      },
      'json-max-bytes': async () => {
        const body = JSON.stringify({ title: 'x', target: 'y'.repeat(16384) });
        const r = await fetch(base + '/v1/goals', { method: 'POST', headers: { ...auth, 'Content-Type': 'application/json', 'Idempotency-Key': 'facts-json-1' }, body });
        assert.equal(r.status, 413);
        return '16 KiB';
      },
      'idempotency-key': async () => {
        const post = key => fetch(base + '/v1/goals', { method: 'POST', headers: { ...auth, 'Content-Type': 'application/json', 'Idempotency-Key': key }, body: JSON.stringify({ title: 'Facts', target: 'Check limits' }) });
        assert.equal((await post('a'.repeat(7))).status, 400);
        assert.equal((await post('a'.repeat(8))).status, 200);
        assert.equal((await post('b'.repeat(129))).status, 400);
        return '8–128 characters';
      },
      'transcribe-model': async () => {
        let sent;
        const fetchImpl = async (url, init) => { sent = JSON.parse(await init.body.get('request').text()); return new Response(JSON.stringify({ transcript: 'hello there' }), { status: 200 }); };
        await createModelClients({ env: { MODEL_API_KEY: 'k' }, fetchImpl }).transcribe(wav(1), { language: 'en', sessionId: 's' });
        assert.equal(sent.model, TRANSCRIBE_MODEL);
        return sent.model;
      },
      'analysis-model': async () => {
        let sent;
        const fetchImpl = async (url, init) => { sent = JSON.parse(init.body); return new Response(JSON.stringify({ choices: [{ message: { content: '{"observation":"o","suggested_exercise":"e"}' } }] }), { status: 200 }); };
        await createModelClients({ env: { BASETEN_API_KEY: 'k' }, fetchImpl }).analyze({ goal: null, transcript: 't', metrics: measure('t', 1000, 'en'), language: 'en' });
        assert.equal(sent.model, ANALYSIS_MODEL);
        return sent.model;
      },
      'analysis-budgets': async () => {
        // The max_tokens actually sent when the first reply runs out of tokens before answering.
        const sent = [];
        const fetchImpl = async (url, init) => { sent.push(JSON.parse(init.body).max_tokens); return new Response(JSON.stringify({ choices: [{ finish_reason: 'length', message: { content: '' } }] }), { status: 200 }); };
        const result = await createModelClients({ env: { BASETEN_API_KEY: 'k' }, fetchImpl }).analyze({ goal: null, transcript: 't', metrics: measure('t', 1000, 'en'), language: 'en' });
        assert.equal(result.status, 'unavailable'); assert.equal(sent.length, 2, 'one retry, then the session is saved without an observation');
        return `${sent[0]}, then ${sent[1]} on retry`;
      },
      'contract-version': () => {
        const version = spec.info.version.replace(/\./g, '\\.');
        assert.match(connector, new RegExp(`Contract version ${version}`));
        assert.match(read('docs/capture.md'), new RegExp(`^# .*\\(contract ${version}\\)$`, 'm'), 'docs/capture.md names the same contract');
        return spec.info.version;
      },
      'languages': () => acceptedValues('x-language'),
      'devices': () => acceptedValues('x-capture-device'),
      'lexicons': () => Object.keys(LANGUAGES).map(l => measure('x', 1000, l).method).join(', '),
      'audio-retained': async () => {
        const audio = wav(2);
        const r = await fetch(base + '/v1/recordings', { method: 'POST', headers: { ...auth, 'Content-Type': 'audio/wav', 'Idempotency-Key': 'facts-capture-1' }, body: audio });
        const data = await r.json();
        assert.equal(r.status, 200);
        store.db.exec('PRAGMA wal_checkpoint(TRUNCATE)');
        const file = readFileSync(dbPath);
        assert.equal(file.includes(audio.subarray(1000, 1064)), false, 'audio bytes are not stored');
        return data.record.audio_retained === false ? 'no' : 'yes';
      },
      'retry-no-rebill': async () => {
        const before = { ...calls }, audio = wav(1.5);
        const send = () => fetch(base + '/v1/recordings', { method: 'POST', headers: { ...auth, 'Content-Type': 'audio/wav', 'Idempotency-Key': 'facts-capture-2' }, body: audio });
        const first = await (await send()).json(), second = await (await send()).json();
        assert.equal(second.replayed, true); assert.equal(second.receipt_id, first.receipt_id);
        return calls.transcribe - before.transcribe === 1 && calls.analyze - before.analyze === 1 ? 'no' : 'yes';
      },
      'screen-text-max': async () => {
        assert.equal((await screen('a'.repeat(MAX_SCREEN_TEXT_CHARS + 1), 'facts-screen-1')).status, 400);
        assert.equal((await screen('€'.repeat(Math.ceil((MAX_SCREEN_TEXT_BYTES + 1) / 3)), 'facts-screen-2')).status, 400);
        return `${MAX_SCREEN_TEXT_CHARS} characters, ${MAX_SCREEN_TEXT_BYTES / 1024} KiB`;
      },
      'screen-text-retained': async () => {
        const text = 'Prep note: ask to lead the launch; mention the beta shipped early. Unique marker 7f3e.';
        const r = await screen(text, 'facts-screen-3'); const data = await r.json();
        assert.equal(r.status, 200);
        store.db.exec('PRAGMA wal_checkpoint(TRUNCATE)');
        assert.equal(readFileSync(dbPath).includes(Buffer.from('Unique marker 7f3e')), false, 'screen text is not stored');
        return data.record.text_retained === false ? 'no' : 'yes';
      },
      'screen-rate-limit': async () => {
        // A separate account, so the count starts at zero: post until the route refuses, then check the refusal cost nothing.
        store.addToken('facts-rate-secret', 'facts-rate-user');
        const post = i => fetch(base + '/v1/screen-contexts', { method: 'POST', headers: { Authorization: 'Bearer facts-rate-secret', 'Content-Type': 'application/json', 'Idempotency-Key': `facts-rate-${i}` },
          body: JSON.stringify({ purpose: 'reading', capture_device: 'mac', text: `Reading note ${i}.`, redaction: { method: 'on-device-v1', counts: {} } }) });
        let saved = 0, status;
        while ((status = (await post(saved)).status) === 200 && saved < 100) saved++;
        assert.equal(status, 429);
        const before = calls.describe;
        assert.equal((await post(saved + 1)).status, 429); assert.equal(calls.describe, before, 'refused before any model call');
        return String(saved);
      },
      'seed-sessions': () => {
        const seeded = store.list('facts-user', 'sessions').filter(x => x.source === 'synthetic_fixture');
        assert.ok(seeded.every(x => x.measurement_status === 'simulated'));
        return `${seeded.length}, simulated, ${seeded.map(x => x.occurred_at.slice(0, 10)).sort().join(' and ')}`;
      },
      'measured-improvement': async () => {
        const overview = await (await fetch(base + '/v1/overview', { headers: auth })).json();
        assert.equal(overview.totals.measured_improvement, null);
        assert.ok(overview.goals.every(g => g.progress.measured_improvement === null));
        return 'none (null)';
      },
      'unauthenticated': async () => String((await fetch(base + '/v1/overview')).status),
      'eval-measure': () => `${m.overall.precision} / ${m.overall.recall}`,
      'eval-baseline': () => `${b.overall.precision} / ${b.overall.recall}`,
      'eval-corpus': () => `${evalResult.counts.items} items, ${evalResult.counts.negative_controls} clean controls`,
      'eval-controls': () => String(m.negative_control.false_counts),
      'node-tests': async () => String(await runNodeTests()),
      'python-tests': () => String((read('deploy/test_bridge.py').match(/^\s*(?:async )?def test_/gm) ?? []).length),
      'hosting-concurrency': () => {
        const inputs = modal.match(/^@modal\.concurrent\(max_inputs=(\d+)\)$/m)[1];
        assert.match(read('deploy/bridge.py'), /^    model_lock = asyncio\.Lock\(\)$/m, 'model routes take their own lock');
        assert.match(read('deploy/test_bridge.py'), /def test_concurrent_requests_keep_one_database_holder_and_one_model_call_at_a_time\(/);
        return `${inputs} at once; one model request at a time`;
      },
      'hosting': () => {
        assert.match(modal, /max_containers=1\b/);
        return `1 container, ${modal.match(/memory=(\d+)/)[1]} MB, ${modal.match(/timeout=(\d+)/)[1]} s timeout`;
      },
      'watch-target': () => `watchOS ${read('apps/watch/project.yml').match(/watchOS: "([\d.]+)"/)[1]}`,
      'mac-target': () => `macOS ${read('apps/mac/project.yml').match(/macOS: "([\d.]+)"/)[1]}`
    };

    const facts = parseFacts();
    assert.ok(facts.length >= 20, 'FACTS.md table parsed');
    assert.deepEqual(facts.map(f => f.id).sort(), Object.keys(checks).sort(), 'every claim has exactly one check');
    for (const fact of facts) assert.equal(await checks[fact.id](), fact.value, `FACTS.md ${fact.id}: ${fact.claim}`);
  } finally { await new Promise(r => server.close(r)); store.close(); rmSync(dir, { recursive: true, force: true }); }
});
