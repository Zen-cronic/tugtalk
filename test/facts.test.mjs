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
import { MAX_AUDIO_BYTES, MAX_AUDIO_MS, TRANSCRIBE_MODEL, ANALYSIS_MODEL, LANGUAGES, LEXICON, inspectWav, measure, createModelClients } from '../src/capture.mjs';
import { runEval, parseItem, goldSpans, CORPUS_URL } from '../src/evaluate.mjs';
import { measurePauses } from '../src/pauses.mjs';
import { adjudicationCandidates, adjudicateCapture, buildAdjudication, verifyLabels, createAdjudicationModel } from '../src/adjudicate.mjs';
import { MAX_SCREEN_TEXT_CHARS, MAX_SCREEN_TEXT_BYTES } from '../src/screen-context.mjs';
import { createVoiceModel, safeQuestion, VOICE_TIMEOUT_MS } from '../src/voice.mjs';
import { runVoiceEval } from '../src/voice-eval.mjs';
import { createSpeechModel, SPEECH_PROVIDERS } from '../src/speech.mjs';

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
  const calls = { transcribe: 0, analyze: 0, voiceReply: 0 };
  const models = {
    async voiceReply() { calls.voiceReply++; return { status: 'model_reply', reply: { move: 'challenge', quote: calls.badQuote ? 'we will triple revenue' : 'I think', question: 'Why do you think so?' }, model: ANALYSIS_MODEL, provider_request_id: 'fake', attempts: 1 }; },
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
        for (const doc of ['docs/capture.md', 'docs/voice.md']) assert.match(read(doc), new RegExp(`^# .*\\(contract ${version}\\)$`, 'm'), `${doc} names the same contract`);
        return spec.info.version;
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
      ...liveVoiceChecks()
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
    'eval-live-calls': () => `${adj.live_plan.calls}, at most ${adj.live_plan.max_calls_with_retries} with retries`,
    ...liveChecks(evalResult)
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
      assert.equal(await count(() => stream('{"move":"follow_up","quote":"","question":"And then?"}')), 1);
      assert.equal(await count(() => stream('no json')), 2, 'an unusable reply gets one more call');
      return `1, a second only after an unusable reply; ${VOICE_TIMEOUT_MS / 1000} s each`;
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
