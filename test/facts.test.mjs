// Recomputes every value in FACTS.md from code, the HTTP handler or the eval. No network, no paid calls.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Store } from '../src/store.mjs';
import { createApp } from '../src/server.mjs';
import { MAX_AUDIO_BYTES, MAX_AUDIO_MS, TRANSCRIBE_MODEL, ANALYSIS_MODEL, ANALYSIS_BUDGETS, LANGUAGES, DEVICES, inspectWav, measure, createModelClients } from '../src/capture.mjs';
import { runEval, parseItem, CORPUS_URL } from '../src/evaluate.mjs';
import { measurePauses } from '../src/pauses.mjs';
import { adjudicationCandidates, adjudicateCapture, buildAdjudication, verifyLabels, createAdjudicationModel } from '../src/adjudicate.mjs';
import { LEXICON } from '../src/capture.mjs';
import { SCREEN_RATE_LIMIT, MAX_SCREEN_TEXT_CHARS, MAX_SCREEN_TEXT_BYTES } from '../src/screen-context.mjs';

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
      'analysis-budgets': () => `${ANALYSIS_BUDGETS[0]}, then ${ANALYSIS_BUDGETS[1]} on retry`,
      'contract-version': () => { assert.match(connector, new RegExp(`Contract version ${spec.info.version.replace(/\./g, '\\.')}`)); return spec.info.version; },
      'languages': () => Object.keys(LANGUAGES).join(', '),
      'devices': () => DEVICES.join(', '),
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
      'screen-rate-limit': () => String(SCREEN_RATE_LIMIT.requests),
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
      'node-tests': () => String(readdirSync(new URL('./', import.meta.url)).filter(f => f.endsWith('.test.mjs'))
        .reduce((n, f) => n + (read(`test/${f}`).match(/^test\(|\bt\.test\(/gm) ?? []).length, 0)),
      'python-tests': () => String((read('deploy/test_bridge.py').match(/^\s*(?:async )?def test_/gm) ?? []).length),
      'hosting': () => {
        assert.match(modal, /max_containers=1\b/);
        return `1 container, ${modal.match(/memory=(\d+)/)[1]} MB, ${modal.match(/timeout=(\d+)/)[1]} s timeout`;
      },
      'watch-target': () => `watchOS ${read('apps/watch/project.yml').match(/watchOS: "([\d.]+)"/)[1]}`,
      'mac-target': () => `macOS ${read('apps/mac/project.yml').match(/macOS: "([\d.]+)"/)[1]}`,

      // Measurement by Meta's models
      ...measurementChecks(evalResult)
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
      await adjudicateCapture({ models: createAdjudicationModel({ env: { BASETEN_API_KEY: 'k' }, fetchImpl }), transcript: 'What kind of report?', language: 'en' });
      return `${sent.model}, temperature ${sent.temperature}`;
    },
    'adjudication-calls': async () => {
      const count = async (transcript, replies) => {
        let calls = 0;
        const fetchImpl = async () => chat(replies[calls++] ?? replies.at(-1));
        await adjudicateCapture({ models: createAdjudicationModel({ env: { BASETEN_API_KEY: 'k' }, fetchImpl }), transcript, language: 'en' });
        return calls;
      };
      const good = '{"labels":[{"id":"c1","quote":"kind of","label":"content","reason":"r"}]}';
      return `${await count('What kind of report?', [good])} with ambiguous hits, ${await count('What kind of report?', ['No.', 'Still no.'])} if the reply is unusable, ${await count('Um, uh, the report.', [good])} without`;
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
    'eval-live-calls': () => `${adj.live_plan.calls}, at most ${adj.live_plan.max_calls_with_retries} with retries`
  };
}

