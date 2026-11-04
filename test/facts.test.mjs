// Recomputes every value in FACTS.md from code, the HTTP handler or the eval. No network, no paid calls.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, mkdtempSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
import { Store, digest } from '../src/store.mjs';
import { createApp, captureParams } from '../src/server.mjs';
import { MAX_AUDIO_BYTES, MAX_AUDIO_MS, TRANSCRIBE_MODEL, ANALYSIS_MODEL, LANGUAGES, LEXICON, inspectWav, measure, createModelClients } from '../src/capture.mjs';
import { runEval, parseItem, goldSpans, CORPUS_URL } from '../src/evaluate.mjs';
import { measurePauses } from '../src/pauses.mjs';
import { adjudicationCandidates, adjudicateCapture, buildAdjudication, verifyLabels, createAdjudicationModel } from '../src/adjudicate.mjs';
import { MAX_SCREEN_TEXT_CHARS, MAX_SCREEN_TEXT_BYTES, createScreenModel } from '../src/screen-context.mjs';
import { createVoiceModel, safeQuestion, VOICE_TIMEOUT_MS, VOICE_EFFORT, ROUND_WINDOW_MS } from '../src/voice.mjs';
import { runVoiceEval } from '../src/voice-eval.mjs';
import { createSpeechModel, SPEECH_PROVIDERS } from '../src/speech.mjs';
import { RECORDING_RATE_LIMIT } from '../src/server.mjs';
import { CAMERA_FIELDS, CAMERA_METHOD } from '../src/camera-metrics.mjs';
import { NEEDS, NEED_METHOD, ANSWER_CAP, allowedMoves, gateReason } from '../src/counterpart.mjs';
import { runCounterpartEval } from '../src/counterpart-eval.mjs';
import { loadHeldout, rescore, applyRules } from '../src/heldout.mjs';
import { summarize as summarizeSemantic, loadSet as loadSemanticSet } from '../scripts/eval-semantic.mjs';
import { MODEL_BUDGET_MS, ADAPTER_DEADLINE_MS, MIN_START_MS } from '../src/budget.mjs';
import { MEDIA_CAP_BYTES, MEDIA_DOWNLOAD_LIMIT } from '../src/media.mjs';
import { BASIS_MAX_SOURCES, BASIS_WINDOW_DAYS, DUE_MAX_DAYS, DRILL_HABITS, checkDueAt } from '../src/drills.mjs';

const read = path => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const MiB = 1024 * 1024;

function wav(seconds, { rate = 24000, channels = 1, bits = 16, code = 1 } = {}) {
  const samples = Math.round(seconds * rate), data = Buffer.alloc(samples * 2 * channels);
  for (let i = 0; i < samples * channels; i++) data.writeInt16LE(Math.round(Math.sin(i / 7) * 3000 + (i % 13) * 11), i * 2);
  const h = Buffer.alloc(44);
  h.write('RIFF', 0); h.writeUInt32LE(36 + data.length, 4); h.write('WAVE', 8); h.write('fmt ', 12); h.writeUInt32LE(16, 16);
  h.writeUInt16LE(code, 20); h.writeUInt16LE(channels, 22); h.writeUInt32LE(rate, 24); h.writeUInt32LE(rate * 2 * channels, 28); h.writeUInt16LE(2 * channels, 32); h.writeUInt16LE(bits, 34);
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
  const calls = { transcribe: 0, analyze: 0, voiceReply: 0 };
  const models = {
    async voiceReply() { calls.voiceReply++; return { status: 'model_reply', reply: { move: calls.move ?? 'challenge', quote: calls.badQuote ? 'we will triple revenue' : 'I think', question: 'Why do you think so?', ...(calls.need ? { need: calls.need } : {}) }, model: ANALYSIS_MODEL, provider_request_id: 'fake', attempts: 1 }; },
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
      'audio-min-seconds': () => {
        // The shortest length, in tenths of a second, that inspectWav accepts.
        const shortest = [...Array(20).keys()].map(i => (i + 1) / 10).find(seconds => accepts(wav(seconds)));
        return `${shortest} s`;
      },
      'audio-format': () => {
        // Probe each header field on its own; the value is what inspectWav accepts.
        const rates = [8000, 11025, 16000, 22050, 24000, 32000, 44100, 48000].filter(rate => accepts(wav(1, { rate })));
        const channels = [1, 2].filter(n => accepts(wav(1, { channels: n })));
        const bits = [8, 16, 24, 32].filter(n => accepts(wav(1, { bits: n })));
        const pcm = accepts(wav(1)) && !accepts(wav(1, { code: 3 }));
        assert.equal(accepts(Buffer.concat([Buffer.from('RIFX'), wav(1).subarray(4)])), false, 'not RIFF/WAVE');
        return `${channels.length === 1 && channels[0] === 1 ? 'mono' : channels.join('/') + ' channels'} ${bits.join('/')}-bit ${pcm ? 'PCM' : 'any encoding'} WAV, ${rates.map(r => r / 1000).join(' or ')} kHz`;
      },
      'json-max-bytes': async () => {
        // Binary search for the largest body that is not refused as too large. Every probe fails validation, so none saves.
        const tooLarge = async bytes => {
          const body = JSON.stringify({ title: 'x', target: '' }); const padded = body.replace('""', `"${'y'.repeat(bytes - body.length)}"`);
          assert.equal(Buffer.byteLength(padded), bytes);
          return (await fetch(base + '/v1/goals', { method: 'POST', headers: { ...auth, 'Content-Type': 'application/json', 'Idempotency-Key': `facts-json-${bytes}` }, body: padded })).status === 413;
        };
        let low = 1024, high = 64 * 1024; // low is accepted, high is refused (a larger body can reset the socket mid-upload)
        assert.equal(await tooLarge(low), false); assert.equal(await tooLarge(high), true);
        while (high - low > 1) { const mid = Math.floor((low + high) / 2); if (await tooLarge(mid)) high = mid; else low = mid; }
        return low % 1024 === 0 ? `${low / 1024} KiB` : `${low} bytes`;
      },
      'idempotency-key': async () => {
        // On a body that fails validation, a refused key is idempotency_required and an accepted one gets as far as the
        // body. Binary search finds each edge of the accepted range from a length inside it (32), then the lengths on
        // either side of each edge are checked, about 20 requests instead of one per length.
        const keyAccepted = async length => (await (await fetch(base + '/v1/goals', { method: 'POST', headers: { ...auth, 'Content-Type': 'application/json', 'Idempotency-Key': 'k'.repeat(length) }, body: '{}' })).json()).error !== 'idempotency_required';
        const inside = 32;
        assert.equal(await keyAccepted(inside), true); assert.equal(await keyAccepted(1), false); assert.equal(await keyAccepted(1024), false);
        const edge = async (accepted, refused) => { while (Math.abs(refused - accepted) > 1) { const mid = Math.floor((accepted + refused) / 2); if (await keyAccepted(mid)) accepted = mid; else refused = mid; } return accepted; };
        const min = await edge(inside, 1), max = await edge(inside, 1024);
        for (const [length, ok] of [[min - 2, false], [min - 1, false], [min, true], [min + 1, true], [max - 1, true], [max, true], [max + 1, false], [max + 2, false]])
          assert.equal(await keyAccepted(length), ok, `length ${length}`);
        return `${min}–${max} characters`;
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
      'analysis-effort': async () => {
        // The hosted value from deploy/modal_app.py, sent through both request paths (fake fetch).
        const hosted = modal.match(/'ANALYSIS_EFFORT': '([a-z]+)'/)[1];
        const sent = [];
        const answer = content => async (url, init) => { sent.push(JSON.parse(init.body).reasoning_effort); return chat(content); };
        const env = { BASETEN_API_KEY: 'k', ANALYSIS_EFFORT: hosted };
        await createModelClients({ env, fetchImpl: answer('{"observation":"o","suggested_exercise":"e"}') }).analyze({ goal: null, transcript: 't', metrics: measure('t', 1000, 'en'), language: 'en' });
        await createScreenModel({ env, fetchImpl: answer('{"summary":"s","observation":"o","next_step":"n"}') }).describeScreen({ goal: null, text: 't', language: 'en', purpose: 'reading', app_name: null });
        assert.deepEqual(sent, [hosted, hosted]);
        return `${sent[0]} on the watch observation and the screen card; ${VOICE_EFFORT} on voice replies`;
      },
      'contract-version': () => {
        const version = spec.info.version.replace(/\./g, '\\.');
        assert.match(connector, new RegExp(`Contract version ${version}`));
        for (const doc of ['docs/capture.md', 'docs/voice.md']) assert.match(read(doc), new RegExp(`^# .*\\(contract ${version}\\)$`, 'm'), `${doc} names the same contract`);
        return spec.info.version;
      },
      'assistant-routes': async () => {
        // The connector's "Allowed paths" line, one method per comma-separated entry (a bare path repeats the last method).
        const line = connector.split('\n').find(l => l.startsWith('Allowed paths: '));
        let method; const listed = [];
        for (const entry of line.slice('Allowed paths: '.length).replace(/\. No other hosts.*$/, '').split(/[;,] /)) {
          const m = entry.trim().match(/^(?:(GET|POST|PATCH) )?(\/v1\/\S+)$/); method = m[1] ?? method; listed.push(`${method} ${m[2]}`);
        }
        const documented = Object.entries(spec.paths).flatMap(([path, ops]) => Object.keys(ops).map(op => `${op.toUpperCase()} ${path}`));
        assert.deepEqual([...listed].sort(), [...documented].sort(), 'OpenAPI and the connector list the same routes');
        const goal = store.list('facts-user', 'goals')[0].id, session = store.list('facts-user', 'sessions')[0].id;
        const served = async route => {
          const [verb, path] = route.split(' ');
          const r = await fetch(base + path.replace('{id}', path.startsWith('/v1/goals') ? goal : session), { method: verb,
            headers: { ...auth, ...(verb === 'GET' ? {} : { 'Content-Type': 'application/json', 'Idempotency-Key': `facts-route-${verb}-${path.length}` }) }, ...(verb === 'GET' ? {} : { body: '{}' }) });
          return (await r.text()).includes('Route not found.') ? false : true;
        };
        for (const route of listed) assert.equal(await served(route), true, `${route} is served`);
        assert.equal(await served('GET /v1/no-such-route'), false, 'an unknown route is refused');
        assert.equal(listed.includes('POST /v1/recordings'), false); assert.equal(await served('POST /v1/recordings'), true, 'a device route is served but not listed');
        const count = verb => listed.filter(r => r.startsWith(verb + ' ')).length;
        return `${listed.length}: ${count('GET')} GET, ${count('POST')} POST, ${count('PATCH')} PATCH; the same in /openapi.json and /connector.md, each served by the router; device routes not listed`;
      },
      'languages': () => acceptedValues('x-language'),
      'devices': () => acceptedValues('x-capture-device'),
      'lexicons': () => Object.keys(LANGUAGES).map(l => measure('x', 1000, l).method).join(', '),
      'filler-forms': () => {
        for (const word of ['are', 'her', 'aha']) assert.equal(measure(`${word} done`, 1000, 'en').filler_count, 0, word);
        return ['ah', 'er', 'eh', 'oh', 'hmm'].filter(word => measure(`${word}, done`, 1000, 'en').fillers.uh === 1).join(', ');
      },
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
      'keep-recordings-default': async () => {
        // A fresh account: the setting reads off, and a capture then writes no file.
        store.addToken('facts-keep-default', 'facts-default-user');
        const headers = { Authorization: 'Bearer facts-keep-default' };
        const settings = (await (await fetch(base + '/v1/settings', { headers })).json()).settings;
        const r = await fetch(base + '/v1/recordings', { method: 'POST', headers: { ...headers, 'Content-Type': 'audio/wav', 'Idempotency-Key': 'facts-keep-default-1' }, body: wav(1) });
        assert.equal(r.status, 200); assert.equal('media' in (await r.json()).record, false);
        assert.equal(existsSync(join(dir, 'media', 'facts-default-user')), false, 'no media folder for this account');
        assert.equal(settings.label, 'Keep my recordings');
        return settings.keep_recordings === false ? 'off' : 'on';
      },
      'keep-recordings-kept': async () => {
        store.addToken('facts-keep-on', 'facts-keep-user');
        const headers = { Authorization: 'Bearer facts-keep-on' };
        const patch = await fetch(base + '/v1/settings', { method: 'PATCH', headers: { ...headers, 'Content-Type': 'application/json', 'Idempotency-Key': 'facts-keep-on-1' }, body: JSON.stringify({ expected_version: 1, keep_recordings: true }) });
        assert.equal(patch.status, 200);
        const audio = wav(1.1);
        const { record } = await (await fetch(base + '/v1/recordings', { method: 'POST', headers: { ...headers, 'Content-Type': 'audio/wav', 'Idempotency-Key': 'facts-keep-on-2' }, body: audio })).json();
        assert.deepEqual(readFileSync(join(dir, 'media', 'facts-keep-user', `${record.id}.wav`)), audio);
        const download = Buffer.from(await (await fetch(base + `/v1/media/${record.id}`, { headers })).arrayBuffer());
        assert.deepEqual(download, audio);
        assert.equal((await fetch(base + `/v1/media/${record.id}`, { headers: auth })).status, 404, 'not another account');
        return record.media.kept && record.media.sha256 === digest(audio) ? 'the uploaded WAV, byte for byte, with its SHA-256 on the record' : 'something else';
      },
      'media-cap': () => `${MEDIA_CAP_BYTES / 1e6} MB`,
      'media-download-limit': () => String(MEDIA_DOWNLOAD_LIMIT.requests),
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
      'screen-sent-fields': () => {
        // The payload's own fields (4-space indent: not the nested Redaction struct's), and what the route accepts.
        const payload = read('apps/mac/Sources/ScreenContextCore/Payload.swift');
        const fields = [...payload.matchAll(/^    public let (\w+): /gm)].map(m => m[1]);
        const accepted = JSON.parse(read('src/screen-context.mjs').match(/^const FIELDS = (\[.+\]);$/m)[1].replace(/'/g, '"'));
        assert.deepEqual(fields, accepted, 'the Mac sends exactly the fields the route accepts');
        const flow = read('apps/mac/TugTalk/CaptureFlow.swift');
        assert.match(flow, /ScreenContextPayload\.make\(redacted: result\.redacted, appName: front\.name,/);
        const named = /FrontApp\(name: app\?\.localizedName /.test(flow) && !/Redactor[^\n]*front\.name|front\.name[^\n]*redact/i.test(flow);
        return `${fields.join(', ')}; app_name is the front app's name as macOS reports it, ${named ? 'not redacted' : 'redacted'}; ${fields.some(f => /title/.test(f)) ? 'a window title' : 'no window title'}`;
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
      'recording-rate-limit': async () => {
        // A separate account, so the count starts at zero: post until the route refuses, then check the refusal cost nothing.
        store.addToken('facts-rec-rate', 'facts-rec-user');
        const post = i => fetch(base + '/v1/recordings', { method: 'POST', headers: { Authorization: 'Bearer facts-rec-rate', 'Content-Type': 'audio/wav', 'Idempotency-Key': `facts-rec-${i}` }, body: wav(0.6) });
        let saved = 0, status;
        while ((status = (await post(saved)).status) === 200 && saved < 100) saved++;
        assert.equal(status, 429);
        const before = calls.transcribe + calls.analyze;
        assert.equal((await post(saved + 1)).status, 429); assert.equal(calls.transcribe + calls.analyze, before, 'refused before any model call');
        assert.equal(saved, RECORDING_RATE_LIMIT.requests);
        return String(saved);
      },
      'model-budget': () => {
        const bridge = read('deploy/bridge.py');
        assert.equal(Number(bridge.match(/^MODEL_DEADLINE = (\d+)$/m)[1]) * 1000, ADAPTER_DEADLINE_MS, 'the budget is set against the adapter deadline');
        assert.match(bridge, /start\['budget_ms'\] = /, 'the adapter passes what is left of the deadline');
        const starts = Object.values(MIN_START_MS);
        return `${MODEL_BUDGET_MS / 1000} s, ${(ADAPTER_DEADLINE_MS - MODEL_BUDGET_MS) / 1000} s under the ${ADAPTER_DEADLINE_MS / 1000} s deadline; a step needs ${Math.min(...starts) / 1000}–${Math.max(...starts) / 1000} s left to start`;
      },
      'seed-sessions': () => {
        const seeded = store.list('facts-user', 'sessions').filter(x => x.source === 'synthetic_fixture');
        assert.ok(seeded.every(x => x.measurement_status === 'simulated'));
        return `${seeded.length}, simulated, ${seeded.map(x => x.occurred_at.slice(0, 10)).sort().join(' and ')}`;
      },
      'measured-improvement': async () => {
        const overview = await (await fetch(base + '/v1/overview', { headers: auth })).json();
        const values = [overview.totals.measured_improvement, ...overview.goals.map(g => g.progress.measured_improvement)];
        assert.ok(overview.goals.length > 0, 'the seeded goals are in the overview');
        return values.every(v => v === null) ? 'none (null)' : JSON.stringify(values);
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
        return `${inputs} at once; one model-calling request at a time`;
      },
      'hosting': () => {
        assert.match(modal, /max_containers=1\b/);
        return `1 container, ${modal.match(/memory=(\d+)/)[1]} MB, ${modal.match(/timeout=(\d+)/)[1]} s timeout`;
      },
      'hosting-worker': () => {
        const bridge = read('deploy/bridge.py'), tests = read('deploy/test_bridge.py');
        assert.doesNotMatch(bridge, /volume\.reload/, 'the adapter never reloads the volume');
        assert.match(bridge, /if not worker\.alive:/, 'a worker is started only when none is running');
        for (const name of ['test_one_worker_serves_every_request_reads_skip_the_commit_and_nothing_reloads', 'test_commit_failure_never_reports_success_and_retry_is_idempotent'])
          assert.match(tests, new RegExp(`def ${name}\\(`));
        return 'one long-lived Node process; writes commit before the answer, reads skip the commit; no volume reload';
      },
      'keep-warm': () => {
        assert.match(modal, /min_containers=1 if keep_warm else 0/);
        assert.match(modal, /keep_warm = os\.environ\.get\('KEEP_WARM', ''\) == '1'/);
        return `off by default, KEEP_WARM=1 keeps 1 container; idle containers stay up ${modal.match(/^SCALEDOWN_SECONDS = (\d+)$/m)[1]} s`;
      },
      'watch-target': () => `watchOS ${read('apps/watch/project.yml').match(/watchOS: "([\d.]+)"/)[1]}`,
      'mac-target': () => `macOS ${read('apps/mac/project.yml').match(/macOS: "([\d.]+)"/)[1]}`,

      // Measurement by Meta's models
      ...measurementChecks(evalResult),
      ...voiceChecks(base, store, dbPath, calls),
      ...await speechChecks(),
      ...liveVoiceChecks(),
      ...hostedChecks(),
      ...cameraChecks(base),
      ...drillChecks(base, store),
      ...counterpartChecks(base, store, calls),
      ...await replayChecks()
    };

    const facts = parseFacts();
    assert.ok(facts.length >= 20, 'FACTS.md table parsed');
    assert.deepEqual(facts.map(f => f.id).sort(), Object.keys(checks).sort(), 'every claim has exactly one check');
    for (const fact of facts) assert.equal(await checks[fact.id](), fact.value, `FACTS.md ${fact.id}: ${fact.claim}`);
  } finally { await new Promise(r => server.close(r)); store.close(); rmSync(dir, { recursive: true, force: true }); }
});

const chat = content => new Response(JSON.stringify({ id: 'fake', choices: [{ message: { content } }] }), { status: 200 });
function measurementChecks(evalResult) {
  const a = evalResult.systems.adjudicated_scripted, adj = evalResult.adjudication;
  return {
    'pause-source': async () => {
      let sent;
      const fetchImpl = async (url, init) => { sent = JSON.parse(await init.body.get('request').text());
        return new Response(JSON.stringify({ transcript: 'one two', audioDurationMs: 3000, turns: [{ turnId: 0, startMs: 100, endMs: 1000 }, { turnId: 1, startMs: 1600, endMs: 2900 }] }), { status: 200 }); };
      const t = await createModelClients({ env: { MODEL_API_KEY: 'k' }, fetchImpl }).transcribe(wav(1), { language: 'en', sessionId: 's' });
      const p = measure(t.transcript, t.audio_duration_ms, 'en', t.turns).pauses;
      assert.equal(p.status, 'measured'); assert.equal(p.longest_pause_ms, 600);
      return `${sent.mode} turn gaps, ${p.method}`;
    },
    'pause-thresholds': () => {
      const gap = g => measurePauses([{ start_ms: 0, end_ms: 500 }, { start_ms: 500 + g, end_ms: 3000 }], 3000, 4);
      const first = key => [...Array(2001).keys()].find(g => gap(g)[key] === 1);
      return `${first('pause_count')} ms, ${first('long_pause_count')} ms`;
    },
    'observation-inputs': async () => {
      let sent;
      const fetchImpl = async (url, init) => { sent = JSON.parse(JSON.parse(init.body).messages[1].content); return chat('{"observation":"o","suggested_exercise":"e"}'); };
      await createModelClients({ env: { BASETEN_API_KEY: 'k' }, fetchImpl }).analyze({ goal: null, transcript: 'Um, what kind of report?', metrics: measure('Um, what kind of report?', 3000, 'en', [{ start_ms: 0, end_ms: 900 }, { start_ms: 2000, end_ms: 2900 }]), language: 'en' });
      return Object.keys(sent.measured).join(', ');
    },
    'adjudication-model': async () => {
      let sent;
      const fetchImpl = async (url, init) => { sent = JSON.parse(init.body); return chat('{"labels":[]}'); };
      await adjudicateCapture({ models: createAdjudicationModel({ env: { BASETEN_API_KEY: 'k' }, fetchImpl }), transcript: 'I mean it.', language: 'en' });
      return `${sent.model}, temperature ${sent.temperature}`;
    },
    'adjudication-calls': async () => {
      const count = async (transcript, replies) => {
        let calls = 0;
        const fetchImpl = async () => chat(replies[calls++] ?? replies.at(-1));
        await adjudicateCapture({ models: createAdjudicationModel({ env: { BASETEN_API_KEY: 'k' }, fetchImpl }), transcript, language: 'en' });
        return calls;
      };
      const good = '{"labels":[{"id":"c1","quote":"I mean","label":"content","reason":"r"}]}';
      return `${await count('I mean it.', [good])} with ambiguous hits, ${await count('I mean it.', ['No.', 'Still no.'])} if the reply is unusable, ${await count('Um, uh, the report.', [good])} without`;
    },
    'always-habit': () => Object.keys(LEXICON).map(language => {
      const never = Object.values(LEXICON[language]).flat().filter(phrase => !adjudicationCandidates(`${phrase}.`, language).candidates.length);
      return `${never.join(', ')} (${language})`;
    }).join('; '),
    'adjudication-quote-check': () => {
      const { candidates } = adjudicationCandidates('What kind of report?', 'en');
      const accepted = quote => verifyLabels(candidates, [{ id: 'c1', quote, label: 'content', reason: 'r' }]).results[0].verified;
      assert.equal(accepted('kind of'), true);
      return accepted('Kind of') || accepted('kind of report') ? 'yes' : 'no';
    },
    'adjudication-never-adds': () => {
      const items = JSON.parse(readFileSync(CORPUS_URL, 'utf8')).items.map(i => ({ ...i, ...parseItem(i.text) }));
      const raises = items.some(item => {
        const { candidates } = adjudicationCandidates(item.transcript, item.language);
        const labels = [...candidates.map(c => ({ id: c.id, quote: c.quote, label: 'habit', reason: 'r' })), { id: 'c99', quote: 'like', label: 'habit', reason: 'r' }, { id: `c${candidates.length + 1}`, quote: 'x', label: 'habit', reason: 'r' }];
        const r = buildAdjudication(item.transcript, item.language, { status: 'model_labels', labels });
        return Object.keys(r.lexicon_count).some(c => r.adjudicated_count[c] > r.lexicon_count[c]);
      });
      return raises ? 'yes' : 'no';
    },
    'eval-adjudicated-scripted': () => { assert.match(adj.label, /not live model runs/); return `${a.overall.precision} / ${a.overall.recall}`; },
    'eval-scripted-checks': () => `${adj.labels.rejected} of ${adj.candidates} rejected, ${adj.accepted_labels_against_gold.wrong} wrong accepted`,
    'eval-live-calls': () => `${adj.live_plan.calls}, at most ${adj.live_plan.max_calls_with_retries} with retries`,
    ...liveChecks(evalResult),
    ...heldoutChecks(),
    ...semanticChecks()
  };
}


// The one live adjudication run (eval/live-results.json). It is stale if the corpus changed after it ran.
function liveChecks(evalResult) {
  const live = JSON.parse(read('eval/live-results.json'));
  const fixed = x => x.toFixed(3);
  const stale = () => { assert.equal(live.corpus_sha256, evalResult.corpus_sha256, 'the live run used the current corpus'); assert.match(live.ran_at, /^2026-11-02T/); };
  return {
    'eval-adjudicated-live': () => { stale(); const o = live.systems.adjudicated_live.overall; return `${fixed(o.precision)} / ${fixed(o.recall)} / ${fixed(o.f1)}`; },
    'eval-live-vs-lexicon': () => {
      const m = live.systems.measure, a = live.systems.adjudicated_live;
      assert.equal(m.overall.f1, evalResult.systems.measure.overall.f1, 'the live file carries the current lexicon numbers');
      return `F1 ${fixed(m.overall.f1)}; hedge recall ${fixed(a.by_category.hedges.recall)} against ${fixed(m.by_category.hedges.recall)}`;
    },
    'eval-live-attempts': () => `${live.items.length} calls, ${live.items.reduce((n, i) => n + i.attempts - 1, 0)} retries`,
    'eval-live-labels': () => {
      const corpus = new Map(JSON.parse(readFileSync(CORPUS_URL, 'utf8')).items.map(i => [i.id, i]));
      let labels = 0, verified = 0, traps = 0, habits = 0;
      for (const item of live.items) {
        const source = corpus.get(item.id), { transcript } = parseItem(source.text), gold = goldSpans(source.text);
        const { candidates } = adjudicationCandidates(transcript, source.language);
        for (const label of item.labels) {
          labels++; if (label.verified) verified++;
          if (!label.verified || label.label !== 'content') continue;
          const c = candidates.find(x => x.id === label.id);
          if (gold.some(g => g.start < c.end && c.start < g.end)) habits++; else traps++;
        }
      }
      return `${verified} of ${labels}; ${traps} on traps, ${habits} on real habits`;
    }
  };
}

// The one held-out live run (eval/heldout-live-results.json), rescored from its stored labels.
function heldoutChecks() {
  const live = JSON.parse(read('eval/heldout-live-results.json')), { set, sha256 } = loadHeldout();
  const fixed = x => x.toFixed(3);
  assert.equal(live.heldout_sha256, sha256, 'the held-out run used the current set'); assert.match(live.ran_at, /^2026-11-04T/);
  const score = rescore(set.transcripts, live.items), rules = applyRules(score);
  return {
    'eval-heldout-model-only': () => { const m = score.classes.model_only; return `${fixed(m.model_only.precision)} / ${fixed(m.model_only.recall)} / ${fixed(m.model_only.f1)} against ${fixed(m.count_all.f1)}`; },
    'eval-heldout-hedges': () => `${fixed(rules.rule2_hedges_leave_adjudication.lexicon_recall)} against ${fixed(rules.rule2_hedges_leave_adjudication.adjudication_recall)}; rule 1 ${rules.rule1_model_only_ships.pass ? 'passes' : 'fails'}, rule 2 ${rules.rule2_hedges_leave_adjudication.fires ? 'fires' : 'does not fire'}`,
    'eval-heldout-calls': () => `${live.items.length} calls, ${live.items.reduce((n, i) => n + i.attempts - 1, 0)} retries`
  };
}

// The semantic assessment eval (eval/SEMANTIC.md): its summary recomputed from the saved records.
function semanticChecks() {
  const saved = JSON.parse(read('eval/semantic-results.json')), set = loadSemanticSet();
  const s = summarizeSemantic(saved.records, set);
  assert.deepEqual(s, saved.summary, 'the saved summary matches its records'); assert.match(saved.started_at, /^2026-11-04T/);
  const pct = x => `${Math.round(x * 100)}%`, [r1, r2] = [s.run1.final, s.run2.final];
  return {
    'eval-semantic-set': () => `${s.items} answers, ${s.objectives} objectives: ${s.gold.addressed} addressed, ${s.gold.partial} partial, ${s.gold.not_addressed} not addressed`,
    'eval-semantic-accuracy': () => `${r1.right} / ${r1.objectives} (${pct(r1.accuracy)}); repeat ${r2.right} / ${r2.objectives} (${pct(r2.accuracy)})`,
    'eval-semantic-false-addressed': () => `${r1.false_addressed.count} / ${r1.false_addressed.of} (${pct(r1.false_addressed.rate)}); repeat ${r2.false_addressed.count} / ${r2.false_addressed.of} (${pct(r2.false_addressed.rate)}); ${r1.false_addressed.gold_not_addressed + r2.false_addressed.gold_not_addressed} not addressed`,
    'eval-semantic-partial': () => `${r1.per_gold_class.partial.right} of ${r1.per_gold_class.partial.n}; repeat ${r2.per_gold_class.partial.right} of ${r2.per_gold_class.partial.n}`
  };
}

// POST /v1/voice-rounds on the same running handler, plus its reply client against a fake fetch.
function voiceChecks(base, store, dbPath, calls) {
  const post = (audio, key, token = 'facts-secret') => fetch(base + '/v1/voice-rounds', { method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'audio/wav', 'Idempotency-Key': key }, body: audio });
  const enc = new TextEncoder();
  const stream = text => new Response(new ReadableStream({ start(c) { c.enqueue(enc.encode(`data: ${JSON.stringify({ choices: [{ delta: { content: text }, finish_reason: 'stop' }] })}\n\ndata: [DONE]\n\n`)); c.close(); } }), { status: 200 });
  return {
    'voice-model': async () => {
      let sent;
      const fetchImpl = async (url, init) => { sent = JSON.parse(init.body); return stream('{"move":"follow_up","quote":"","question":"And then?"}'); };
      const r = await createVoiceModel({ env: { BASETEN_API_KEY: 'k' }, fetchImpl }).voiceReply({ system: 's', user: 'u' });
      assert.equal(r.status, 'model_reply');
      return `${sent.model}, ${sent.reasoning_effort}, ${sent.stream ? 'streamed' : 'plain'}, ${sent.max_tokens} max tokens`;
    },
    'voice-attempts': async () => {
      const count = async respond => { let n = 0; await createVoiceModel({ env: { BASETEN_API_KEY: 'k' }, fetchImpl: async () => { n++; return respond(); } }).voiceReply({ system: 's', user: 'u' }); return n; };
      assert.equal(await count(() => new Response('{}', { status: 403 })), 1, 'a 4xx is not retried');
      const usable = await count(() => stream('{"move":"follow_up","quote":"","question":"And then?"}')), unusable = await count(() => stream('no json'));
      return `${usable}, ${unusable === usable + 1 ? 'a second only after an unusable reply' : `${unusable} after an unusable reply`}; ${VOICE_TIMEOUT_MS / 1000} s each`;
    },
    'voice-quote-check': async () => {
      calls.badQuote = true;
      try {
        const data = await (await post(wav(1.2), 'facts-voice-quote')).json();
        assert.equal(data.reply.quote, '');
        return data.reply.quote_verified ? 'yes' : 'no';
      } finally { calls.badQuote = false; }
    },
    'voice-eval': () => {
      const r = runVoiceEval();
      assert.deepEqual(r, JSON.parse(read('eval/voice-results.json')), 'committed results are current');
      assert.match(r.label, /not live model runs/);
      return `${r.counts.quotes_accepted} of ${r.counts.quotes_offered} accepted, ${r.counts.quotes_rejected} rejected; ${r.baseline.replies_with_unsaid_words} without the check, ${r.checked.replies_with_unsaid_words} with it`;
    },
    'voice-question-words': () => `${safeQuestion(Array(40).fill('word').join(' ') + '?', 'x', 'follow_up', 'en').question.split(' ').length} words`,
    'voice-stored': async () => {
      const audio = wav(2.2);
      const data = await (await post(audio, 'facts-voice-stored')).json();
      const record = store.get('facts-user', 'voice-rounds', data.round_id);
      store.db.exec('PRAGMA wal_checkpoint(TRUNCATE)');
      assert.equal(readFileSync(dbPath).includes(audio.subarray(1000, 1064)), false, 'audio bytes are not stored');
      assert.equal(record.audio_retained, false);
      const kept = ['transcript', 'metrics', 'reply'].filter(k => k in record && record[k] !== null);
      return `${kept.slice(0, -1).join(', ')} and ${kept.at(-1)}; ${record.audio_retained ? 'the audio too' : 'not the audio'}`;
    },
    'voice-retry-no-rebill': async () => {
      const before = { ...calls }, audio = wav(1.7);
      const first = await (await post(audio, 'facts-voice-retry')).json(), second = await (await post(audio, 'facts-voice-retry')).json();
      assert.equal(second.replayed, true); assert.equal(second.round_id, first.round_id);
      return calls.transcribe - before.transcribe === 1 && calls.voiceReply - before.voiceReply === 1 ? 'no' : 'yes';
    },
    'voice-rate-limit': async () => {
      store.addToken('facts-voice-rate', 'facts-voice-user');
      const audio = wav(0.6);
      let saved = 0, status;
      while ((status = (await post(audio, `facts-voice-rate-${saved}`, 'facts-voice-rate')).status) === 200 && saved < 200) saved++;
      assert.equal(status, 429);
      const before = calls.voiceReply + calls.transcribe;
      assert.equal((await post(audio, 'facts-voice-rate-extra', 'facts-voice-rate')).status, 429);
      assert.equal(calls.voiceReply + calls.transcribe, before, 'refused before any model call');
      return String(saved);
    }
  };
}

// The speech route on its own server, with a fake provider that streams three chunks.
async function speechChecks() {
  const dir = mkdtempSync(join(tmpdir(), 'facts-speech-')), dbPath = join(dir, 'speech.sqlite');
  const store = new Store(dbPath);
  store.addToken('speech-secret', 'speech-user');
  store.put('speech-user', 'voice-rounds', { id: 'r1', version: 1, language: 'en', occurred_at: '2026-11-02T15:00:00Z', created_at: '2026-11-02T15:00:00Z', deleted: false,
    transcript: 't', metrics: {}, reply: { move: 'follow_up', question: 'Stored question?', quote: '', quote_verified: false } });
  const audio = [Buffer.from('RIFFfake-wav-'), Buffer.alloc(3000, 9), Buffer.from('-end')];
  const sent = [];
  const fetchImpl = async (url, init) => { sent.push(JSON.parse(init.body));
    return new Response(new ReadableStream({ start(c) { for (const a of audio) c.enqueue(a); c.close(); } }), { status: 200, headers: { 'content-type': 'audio/wav' } }); };
  const run = async env => {
    const server = createApp(store, { models: createSpeechModel({ env, fetchImpl }) }); await new Promise(r => server.listen(0, '127.0.0.1', r));
    try {
      const r = await fetch(`http://127.0.0.1:${server.address().port}/v1/voice-rounds/r1/speech`, { method: 'POST', headers: { Authorization: 'Bearer speech-secret', 'Content-Type': 'application/json' }, body: JSON.stringify({ text: 'Client text.' }) });
      return { status: r.status, headers: r.headers, body: Buffer.from(await r.arrayBuffer()) };
    } finally { await new Promise(r => server.close(r)); }
  };
  try {
    const none = await run({});
    const spoken = await run({ SPEECH_PROVIDER: 'wit', WIT_TTS_TOKEN: 't' });
    assert.deepEqual(spoken.body, Buffer.concat(audio));
    store.db.exec('PRAGMA wal_checkpoint(TRUNCATE)');
    const stored = readFileSync(dbPath).includes(audio[1].subarray(0, 64));
    const worker = read('scripts/handle-request.mjs'), bridge = read('deploy/bridge.py');
    assert.match(worker, /emit\(\{ id, chunk: /, 'the worker passes each written chunk on');
    assert.match(bridge, /if speech:\n\s+envelope\['stream'\] = True/, 'the adapter asks for a stream on the speech route only');
    assert.match(read('deploy/test_bridge.py'), /def test_speech_audio_streams_through_the_adapter_before_the_worker_finishes\(/);
    const mms = read('deploy/mms_tts_app.py');
    return {
      'speech-providers': () => { assert.equal(createSpeechModel({ env: { SPEECH_PROVIDER: 'other' } }).speechReady(), false); return Object.keys(SPEECH_PROVIDERS).sort().join(', '); },
      'speech-wit': async () => {
        let seen;
        const w = createSpeechModel({ env: { SPEECH_PROVIDER: 'wit', WIT_TTS_TOKEN: 't' }, fetchImpl: async (url, init) => { seen = init; return new Response('x'); } });
        await w.synthesize('Hi?', { language: 'en' });
        return `${JSON.parse(seen.body).voice}, ${seen.headers.Accept}, ${['en', 'fr'].filter(l => w.speechSupports(l)).join(', ')} only`;
      },
      'speech-unconfigured': () => { assert.equal(sent.length, 1, 'only the configured request reached the provider'); return `${none.status} ${JSON.parse(none.body).error}, no provider call`; },
      'speech-text': () => sent[0].q === 'Stored question?' && !JSON.stringify(sent).includes('Client text') ? 'the stored reply.question only' : 'client text',
      'speech-stored': () => stored ? 'yes' : 'no',
      'speech-hosted': () => `${spoken.headers.get('transfer-encoding') === 'chunked' ? 'streamed' : 'not streamed'} locally and through the hosting adapter`,
      'mms-licence': () => {
        const models = [...mms.match(/^MODELS = \{(.+)\}$/m)[1].matchAll(/'(facebook\/[a-z-]+)'/g)].map(m => m[1]);
        return `${models.join(', ')}; ${mms.match(/licensed (CC-BY-NC-4\.0)/)[1]}`;
      }
    };
  } finally { store.close(); rmSync(dir, { recursive: true, force: true }); }
}

// The one live voice-round latency run (eval/voice-live-latency.json), and the copy rule it decides.
function liveVoiceChecks() {
  const live = JSON.parse(read('eval/voice-live-latency.json'));
  const pct = (xs, p) => { const s = [...xs].sort((a, b) => a - b), k = (s.length - 1) * p, f = Math.floor(k), c = Math.min(f + 1, s.length - 1); return Math.round(s[f] + (s[c] - s[f]) * (k - f)); };
  const step = key => live.rounds.map(r => r.latency_ms[key]);
  const offered = live.rounds.filter(r => r.reply_checks.quote_offered);
  return {
    'voice-live-latency': () => { assert.match(live.ran_at, /^2026-11-02T/); const t = step('total'); return `${pct(t, 0.5)} / ${pct(t, 0.9)} / ${Math.max(...t)} ms over ${t.length} rounds`; },
    'voice-live-steps': () => `ASR ${pct(step('asr'), 0.5)} / ${Math.max(...step('asr'))} ms; reply ${pct(step('model'), 0.5)} / ${Math.max(...step('model'))} ms`,
    'voice-live-quotes': () => `${offered.filter(r => r.reply.quote_verified).length} of ${offered.length} (${live.rounds.length - offered.length} round offered none)`,
    'voice-wording': () => {
      const t = step('total');
      return t.length >= 10 && pct(t, 0.5) <= 2000 && Math.max(...t) <= 3500 ? 'real-time' : 'voice reply, not real-time';
    },
    'speech-wit-live': () => { const s = live.speech_route_sample; return `first byte ${s.first_byte_ms} ms, total ${s.total_ms} ms, ${s.content_type}`; }
  };
}

// The hosted before-and-after timings (docs/hosted-latency.json), recomputed from the recorded samples.
function hostedChecks() {
  const h = JSON.parse(read('docs/hosted-latency.json'));
  const median = xs => { const s = [...xs].sort((a, b) => a - b); return s.length % 2 ? s[(s.length - 1) / 2] : (s[s.length / 2 - 1] + s[s.length / 2]) / 2; };
  const fresh = h.after.voice_rounds.filter(r => !r.replayed), replay = h.after.voice_rounds.filter(r => r.replayed);
  const v = h.voice_latency, live = v.live_rounds;
  return {
    'hosted-health': () => {
      assert.equal(h.before.warm_health_ms.length, h.after.warm_health_ms.length);
      return `${median(h.before.warm_health_ms)} ms before, ${median(h.after.warm_health_ms)} ms after (${h.after.warm_health_ms.length} requests each)`;
    },
    'hosted-voice': () => {
      assert.ok(fresh.every(r => r.status === 200));
      const outside = r => r.release_to_reply_ms - r.latency_ms.total;
      return `${h.before.voice_round.release_to_reply_ms} ms before; ${fresh.map(r => r.release_to_reply_ms).join(' and ')} ms after (${fresh.length} rounds); `
        + `outside the handler ${outside(h.before.voice_round)} ms before, ${fresh.map(outside).join(' and ')} ms after`;
    },
    'hosted-speech': () => {
      assert.ok(h.after.speech.every(s => s.voice === 'wit$Rebecca' && s.content_type === 'audio/mpeg'));
      return `${h.before.speech_first_byte_ms} ms before; ${h.after.speech.map(s => s.first_byte_ms).join(' and ')} ms after`;
    },
    'hosted-replay': () => {
      assert.equal(replay.length, 1); assert.equal(replay[0].status, 200);
      assert.equal(replay[0].server_timing.handler < 100, true, 'the replay made no model call');
      return `none, ${replay[0].release_to_reply_ms} ms`;
    },
    'hosted-voice-before': () => `${v.before.release_to_reply_ms} ms and ${v.before.release_to_first_word_ms} ms`,
    'hosted-live-voice': () => {
      const reply = live.map(r => r.release_to_reply_ms), audio = live.map(r => r.release_to_first_audio_ms);
      return `reply ${median(reply)} / ${Math.max(...reply)} ms; first audio byte ${median(audio)} / ${Math.max(...audio)} ms (${live.length} rounds)`;
    },
    'hosted-live-transcript': () => {
      const t = live.map(r => r.release_to_transcript_ms);
      return `${median(t)} / ${Math.max(...t)} ms; Meta realtime in ${live.filter(r => r.transcription === 'realtime').length} of ${live.length}`;
    },
    'hosted-live-steps': () => {
      const model = live.map(r => r.server.model), gap = live.map(r => r.server.release_to_speech - r.server.release_to_reply);
      return `model ${median(model)} / ${Math.max(...model)} ms; reply to audio ${median(gap)} / ${Math.max(...gap)} ms`;
    },
    'hosted-speech-prefetch': () => {
      const s = v.wav_round.speech_after_receipt;
      assert.equal(s.voice, 'wit$Rebecca'); assert.equal('commit' in s.server_timing, false, 'the speech request was not committed');
      return `${s.first_byte_ms} ms, server ${s.server_timing.total} ms (made while the round was saved; no commit)`;
    }
  };
}

// "Faced the camera": the header's fields over HTTP, the Mac's cone read from its source, and the committed synthetic eval.
function cameraChecks(base) {
  const post = (key, header) => fetch(base + '/v1/voice-rounds', { method: 'POST', body: wav(1.4),
    headers: { Authorization: 'Bearer facts-secret', 'Content-Type': 'audio/wav', 'Idempotency-Key': key, 'X-Camera-Metrics': header } });
  return {
    'camera-header': async () => {
      const ok = await (await post('facts-camera-1', '{"faced_camera_pct":62,"frames":148,"longest_look_away_ms":4100,"looked_away_count":3}')).json();
      const fields = Object.keys(ok.metrics.camera).filter(k => k !== 'method');
      assert.deepEqual(fields.sort(), Object.keys(CAMERA_FIELDS).sort());
      assert.equal(ok.metrics.camera.method, CAMERA_METHOD);
      assert.equal((await post('facts-camera-2', '{"faced_camera_pct":62,"frames":148,"longest_look_away_ms":4100,"looked_away_count":3,"image":"AAAA"}')).status, 400);
      return `${fields.length} integers (${Object.keys(CAMERA_FIELDS).join(', ')}); any other field is refused`;
    },
    'camera-cone': () => {
      const swift = read('apps/mac/Sources/ScreenContextCore/CameraMeter.swift');
      const [, yaw, pitch] = swift.match(/init\(maxYaw: Double = (\d+), maxPitch: Double = (\d+)\)/);
      const minAway = swift.match(/minLookAway: Double = ([\d.]+)/)[1];
      const synthetic = JSON.parse(read('eval/camera-synthetic.json'));
      assert.deepEqual(synthetic.rule, { max_pitch_deg: Number(pitch), max_yaw_deg: Number(yaw) }, 'the eval ran the shipped cone');
      return `head turn ≤ ${yaw}° and tilt ≤ ${pitch}°; look-aways counted from ${Number(minAway).toFixed(1)} s`;
    },
    'camera-synthetic': () => {
      const r = JSON.parse(read('eval/camera-synthetic.json'));
      const runs = r.scenarios.length * r.seeds, right = r.scenarios.reduce((n, s) => n + s.count_matches, 0);
      assert.equal(right / runs, r.count_match_rate);
      assert.match(r.note, /not Vision's accuracy on a real face/);
      return `${r.scenarios.length} scenarios × ${r.seeds} seeds: look-away count right in ${right} of ${runs}; worst share error ${r.worst_pct_error} points`;
    }
  };
}

// Drills set by the assistant: the basis recount, the measured check-in and the one-open rule over HTTP, and the
// apps' source read for who writes exercises. Uses its own account, so the rate-limit checks above are unaffected.
function walk(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap(e => e.isDirectory() ? (['build', 'DerivedData', '.build'].some(x => e.name.startsWith(x)) ? [] : walk(join(dir, e.name))) : [join(dir, e.name)]);
}
function drillChecks(base, store) {
  store.addToken('facts-drill', 'facts-drill-user');
  const headers = (key, extra = {}) => ({ Authorization: 'Bearer facts-drill', 'Idempotency-Key': key, ...extra });
  const json = async (path, body, key) => { const r = await fetch(base + path, { method: 'POST', headers: headers(key, { 'Content-Type': 'application/json' }), body: JSON.stringify(body) }); return { status: r.status, data: await r.json() }; };
  const capture = async (key, extra) => (await (await fetch(base + '/v1/recordings', { method: 'POST', body: wav(1.4), headers: headers(key, { 'Content-Type': 'audio/wav', 'X-Capture-Device': 'watch', ...extra }) })).json()).record;
  let setup, n = 0;
  const ready = async () => setup ??= (async () => {
    const goal = (await json('/v1/goals', { title: 'Drill facts', target: 'Fewer hedges' }, 'facts-drill-goal')).data.record.id;
    const sources = [await capture('facts-drill-s1'), await capture('facts-drill-s2')];
    const truth = sources.reduce((n, s) => n + s.metrics.hedge_count, 0);
    const exercise = body => json('/v1/exercises', { goal_id: goal, title: 'Answer without hedges', instructions: 'One sentence.', ...body }, `facts-drill-ex-${++n}`);
    return { goal, sources, truth, exercise };
  })();
  return {
    'drill-basis-check': async () => {
      const { sources, truth, exercise } = await ready();
      const wrong = await exercise({ basis: { habit: 'hedge', source_ids: sources.map(s => s.id), claimed_count: truth + 1 } });
      assert.equal(wrong.status, 422); assert.equal(wrong.data.error, 'basis_mismatch'); assert.equal(wrong.data.recomputed.count, truth);
      return `no: ${wrong.status} ${wrong.data.error}, with the count code measured`;
    },
    'drill-basis-sources': () => `1–${BASIS_MAX_SOURCES} measured captures or voice rounds from the last ${BASIS_WINDOW_DAYS} days; fixtures and hidden sessions refused; habits ${DRILL_HABITS.join(', ')}`,
    'drill-one-open': async () => {
      const { sources, truth, exercise } = await ready();
      const basis = { habit: 'hedge', source_ids: sources.map(s => s.id), claimed_count: truth };
      // Set drills on the same goal until the server refuses one.
      let saved = 0, refused;
      while (saved < 5) {
        const r = await exercise({ basis });
        if (r.status !== 200) { refused = r; break; }
        assert.equal(r.data.record.set_via, 'connector'); saved++;
      }
      assert.ok(refused, `the server refused none of ${saved} drills on one goal`);
      assert.equal(refused.status, 409); assert.equal(refused.data.error, 'drill_open');
      return String(saved);
    },
    'drill-measured-checkin': async () => {
      const { goal, sources, truth, exercise } = await ready();
      // The open drill drill-one-open saved, or a new one when this row is checked first.
      const open = store.list('facts-drill-user', 'exercises').find(e => e.basis && e.goal_id === goal)
        ?? (await exercise({ basis: { habit: 'hedge', source_ids: sources.map(s => s.id), claimed_count: truth } })).data.record;
      const session = await capture('facts-drill-c1', { 'X-Goal-Id': goal, 'X-Exercise-Id': open.id });
      const again = await capture('facts-drill-c2', { 'X-Goal-Id': goal, 'X-Exercise-Id': open.id });
      const checkIns = store.list('facts-drill-user', 'check-ins');
      assert.equal(checkIns.length, 1); assert.equal(again.drill.reason, 'already_recorded');
      const c = checkIns[0];
      assert.equal(c.id, session.drill.check_in_id); assert.match(c.feedback, /One measured result, not a trend\.$/); assert.doesNotMatch(c.feedback, /improv/i);
      return `one check-in per drill, evidence_type ${c.evidence_type}: the capture's ${c.measured.habit} count beside the basis count`;
    },
    'drill-due': () => {
      const now = Date.now();
      assert.doesNotThrow(() => checkDueAt(new Date(now + 60_000).toISOString(), now));
      assert.throws(() => checkDueAt(new Date(now + DUE_MAX_DAYS * 86_400_000 + 60_000).toISOString(), now));
      return `optional; at most ${DUE_MAX_DAYS} days ahead, no minimum lead time`;
    },
    'drill-set-by': () => {
      const files = walk(fileURLToPath(new URL('../apps/', import.meta.url))).filter(f => /\.(swift|m|mjs|js|py)$/.test(f));
      assert.ok(files.length > 10, 'app sources found');
      const callers = files.filter(f => readFileSync(f, 'utf8').includes('v1/exercises'));
      return `the assistant, through the connector; ${callers.length} app source files call POST /v1/exercises`;
    }
  };
}

// The other person's need and the move gate, over HTTP on the same handler (a separate account), plus the committed eval.
function counterpartChecks(base, store, calls) {
  store.addToken('facts-need', 'facts-need-user');
  let n = 0;
  const post = headers => fetch(base + '/v1/voice-rounds', { method: 'POST', body: wav(1 + (n++) / 20),
    headers: { Authorization: 'Bearer facts-need', 'Content-Type': 'audio/wav', 'Idempotency-Key': `facts-need-${n}`, ...headers } }).then(r => r.json());
  return {
    'counterpart-needs': async () => {
      store.put('facts-need-user', 'screen-contexts', { id: 'need-card', version: 1, purpose: 'meeting_prep', app_name: 'Notes', occurred_at: '2026-11-02T14:00:00.000Z', deleted: false,
        analysis: { summary: 'Asking for a launch date.', observation: 'o', next_step: 'n' } });
      calls.need = 'date';
      try {
        const first = await post({ 'X-Screen-Context-Id': 'need-card' });
        assert.equal(first.counterpart.need, 'date'); assert.equal(first.counterpart.answer, 1);
      } finally { delete calls.need; }
      return `${NEEDS.join(', ')}; fixed English and French word patterns, ${NEED_METHOD}`;
    },
    'counterpart-move-gate': async () => {
      for (const need of [null, 'date']) for (const met of [false, true]) for (const hedges of [0, 1, 3]) for (let answer = 1; answer <= 6; answer++) {
        const input = { need, needMet: met, hedges, answerIndex: answer }, closes = answer >= 2 && hedges === 0 && (need ? met : true);
        assert.deepEqual([allowedMoves(input), gateReason(input)], closes ? [['wrap_up'], 'measured_close'] : answer >= ANSWER_CAP ? [['wrap_up'], 'answer_cap'] : [['follow_up', 'challenge'], 'open']);
      }
      calls.move = 'wrap_up';
      try {
        store.addToken('facts-need-2', 'facts-need-user-2');
        const r = await fetch(base + '/v1/voice-rounds', { method: 'POST', body: wav(1.3), headers: { Authorization: 'Bearer facts-need-2', 'Content-Type': 'audio/wav', 'Idempotency-Key': 'facts-gate-1' } }).then(x => x.json());
        assert.deepEqual([r.reply.move, r.gate.coerced, r.gate.reason], ['follow_up', true, 'open'], 'a model wrap-up on answer 1 is replaced');
      } finally { delete calls.move; }
      return `code: from answer 2, once the answer meets the need with no hedges (no hedges, when there is no need); at answer ${ANSWER_CAP} at the latest`;
    },
    'counterpart-code-only': async () => {
      store.addToken('facts-need-3', 'facts-need-user-3');
      const before = calls.voiceReply;
      const r = await fetch(base + '/v1/voice-rounds', { method: 'POST', body: wav(1.1), headers: { Authorization: 'Bearer facts-need-3', 'Content-Type': 'audio/wav', 'Idempotency-Key': 'facts-code-1', 'X-Reply-Mode': 'code' } }).then(x => x.json());
      assert.equal(r.model, null); assert.equal(r.reply.quote, 'I think'); assert.equal(r.reply_mode, 'code');
      return String(calls.voiceReply - before);
    },
    'counterpart-need-stored': async () => {
      store.addToken('facts-need-4', 'facts-need-user-4');
      const r = await fetch(base + '/v1/voice-rounds', { method: 'POST', body: wav(1.15), headers: { Authorization: 'Bearer facts-need-4', 'Content-Type': 'audio/wav', 'Idempotency-Key': 'facts-stored-1', 'X-Counterpart-Need': 'owner' } }).then(x => x.json());
      assert.equal(r.counterpart.need, 'owner');
      const record = store.get('facts-need-user-4', 'voice-rounds', r.round_id);
      assert.equal(JSON.stringify(record).includes('owner'), false);
      return `${'need' in record ? 'yes' : 'no'}; the round keeps gate (${Object.keys(record.gate).join(', ')})`;
    },
    'voice-practice-round': async () => {
      store.addToken('facts-need-5', 'facts-need-user-5');
      const send = (key, extra = {}) => fetch(base + '/v1/voice-rounds', { method: 'POST', body: wav(1 + key.length / 50), headers: { Authorization: 'Bearer facts-need-5', 'Content-Type': 'audio/wav', 'Idempotency-Key': key, ...extra } }).then(x => x.json());
      const answers = [];
      for (const key of ['facts-round-a', 'facts-round-bb', 'facts-round-ccc', 'facts-round-dddd']) answers.push(await send(key));
      const after = await send('facts-round-eeeee');
      // The fake transcript always has a hedge, so the round runs to the cap and code ends it there.
      assert.deepEqual(answers.map(a => [a.counterpart.answer, a.reply.move]), [[1, 'challenge'], [2, 'challenge'], [3, 'challenge'], [4, 'wrap_up']]);
      assert.equal(after.counterpart.answer, 1);
      assert.equal((await send('facts-round-ffffff')).counterpart.answer, 2);
      // A device ends the round without a wrap-up (the watch's End round, the Mac's bubble closed).
      const end = await fetch(base + '/v1/voice-rounds/end', { method: 'POST', body: '{}', headers: { Authorization: 'Bearer facts-need-5', 'Content-Type': 'application/json', 'Idempotency-Key': 'facts-round-end-1' } });
      assert.equal(end.status, 200);
      assert.equal((await send('facts-round-ggggggg')).counterpart.answer, 1);
      return `after the newest wrap-up or round end in the last ${ROUND_WINDOW_MS / 60_000} minutes`;
    },
    'counterpart-eval': async () => {
      const r = await runCounterpartEval();
      assert.deepEqual(r, JSON.parse(read('eval/counterpart-results.json')), 'committed results are current');
      assert.match(r.label, /not live model runs/);
      return `${r.counts.outside_gate} of ${r.counts.cases}; ${r.baseline.replies_outside_gate_spoken} without the gate, ${r.gated.replies_outside_gate_spoken} with it`;
    }
  };
}

// The hands check: the request sent to Meta, the clip limits on all three sides, and code's count on saved SAM output.
async function replayChecks() {
  const replay = await import('../src/replay.mjs');
  const fixture = name => readFileSync(new URL(`./fixtures/sam/${name}`, import.meta.url));
  const truth = JSON.parse(fixture('synthetic-truth.json').toString());
  const has = (ranges, i) => ranges.some(([a, b]) => i >= a && i < b);
  return {
    'replay-method': () => {
      const box = (x1, y1, x2, y2) => ({ x1, y1, x2, y2 });
      assert.equal(replay.overlaps(box(0, 0, 10, 10), box(5, 5, 15, 15)), true);
      assert.equal(replay.overlaps(box(0, 0, 10, 10), box(10, 0, 20, 10)), false, 'touching edges do not count');
      return `${replay.REPLAY_METHOD}: ${replay.REPLAY_CONCEPTS.length} requests (${replay.REPLAY_CONCEPTS.join(', ')}); in hand = a phone or paper box sharing area with a hand box in the same frame, counted per frame`;
    },
    'replay-store-false': () => {
      const body = replay.samRequestBody('data:video/mp4;base64,AAAA', 'phone');
      assert.equal(body.model, 'sam-3.1');
      const inline = /^data:video\/mp4;base64,/.test(body.input[0].content[1].video_url), upload = JSON.stringify(body).includes('file_id');
      assert.match(read('test/replay.test.mjs'), /never keeps the clip, even with Keep my recordings on/);
      return `the clip ${inline ? 'inline (data URL)' : 'by reference'} with store ${body.store} and ${upload ? 'a file upload' : 'no file upload'}; only the seconds are kept, never the clip, even with Keep my recordings on`;
    },
    'replay-clip': () => {
      const swift = read('apps/mac/Sources/ScreenContextCore/ReplayClip.swift');
      assert.equal(Number(swift.match(/static let fps: Int32 = (\d+)/)[1]), replay.REPLAY_FPS);
      assert.equal(Number(swift.match(/static let maxFrames = (\d+)/)[1]), replay.REPLAY_MAX_FRAMES);
      assert.match(swift, /static let maxBytes = 1024 \* 1024/);
      assert.equal(replay.REPLAY_MAX_BYTES, MiB);
      assert.match(read('deploy/bridge.py'), /^VIDEO_LIMIT = 1 \* 1024 \* 1024/m);
      assert.doesNotMatch(swift, /AVMediaType\.audio|mediaType: \.audio/, 'the writer has no audio input');
      return `${replay.REPLAY_FPS} frames a second, at most ${replay.REPLAY_MAX_FRAMES} frames (${replay.REPLAY_MAX_FRAMES / replay.REPLAY_FPS} s), at most 1 MiB, no audio`;
    },
    'replay-no-lock': () => {
      const bridge = read('deploy/bridge.py'), tests = read('deploy/test_bridge.py');
      assert.match(bridge, /drive\(envelope, model_call and not \(speech or replay\),/);
      assert.match(tests, /def test_a_live_hold_takes_the_model_lock_without_waiting_while_a_replay_runs\(/);
      const limit = Number(tests.match(/assertLessEqual\(wait_ms, (\d+),/)[1]);
      return `never takes the model lock; a live hold started during a check waits at most ${limit / 1000} s for it (adapter test)`;
    },
    'replay-saved-output': async () => {
      const hand = replay.parseBoxes(fixture('hand.txt').toString()), phone = replay.parseBoxes(fixture('phone.txt').toString()), paper = replay.parseBoxes(fixture('paper.txt').toString());
      const frames = Array.from({ length: truth.frames }, (_, i) => i);
      const handsRight = frames.filter(i => (hand.get(i)?.length ?? 0) === Number(has(truth.visible.left_hand, i)) + Number(has(truth.visible.right_hand, i))).length;
      const found = (map, ranges) => frames.filter(i => has(ranges, i) && map.get(i)?.length).length;
      const total = ranges => frames.filter(i => has(ranges, i)).length;
      const outputs = { hand: fixture('real_hand.txt').toString(), phone: fixture('real_phone.txt').toString(), paper: '' };
      const real = await replay.runReplay(fixture('real_clip.mp4'), { segments: replay.parseSegments('0-100'), segment: async (u, c) => ({ ok: true, text: outputs[c], frames_processed: 100 }) });
      const realTruth = 7; // frames 0-39 and 70-99 (test/fixtures/sam/README.md)
      return `synthetic clip: hands right on ${handsRight} of ${truth.frames} frames, paper on ${found(paper, truth.visible.paper)} of ${total(truth.visible.paper)}, phone on ${found(phone, truth.visible.phone)} of ${total(truth.visible.phone)}; `
        + `CC0 photo clip: phone in hand ${real.replay.seconds.phone_in_hand} s of ${realTruth} s`;
    }
  };
}
