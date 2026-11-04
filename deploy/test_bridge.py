import asyncio
import base64
import contextlib
import io
import hashlib
import json
import os
import re
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch
from bridge import create_bridge, FORWARDED, REMEASURE_ROUTE, REPLAY_ROUTE, VIDEO_LIMIT, route_label

ROOT = Path(__file__).resolve().parents[1]

class Operation:
    def __init__(self, owner, name): self.owner, self.name = owner, name
    async def aio(self):
        self.owner.events.append(self.name)
        if self.name == 'commit' and self.owner.fail: raise RuntimeError('simulated storage failure')

class Volume:
    def __init__(self):
        self.events = []; self.fail = False
        self.reload = Operation(self, 'reload'); self.commit = Operation(self, 'commit')

# The adapter's side of scripts/handle-request.mjs, for fake workers: each test supplies handle(id, env, message).
FAKE_WORKER = """
import { createInterface } from 'node:readline';
import { appendFileSync } from 'node:fs';
const out = m => process.stdout.write(JSON.stringify(m) + '\\n');
const pause = ms => new Promise(r => setTimeout(r, ms));
const granted = new Map();
const release = id => out({ id, phase: 'release' });
const acquire = id => new Promise(r => { granted.set(id, r); out({ id, phase: 'acquire' }); });
const respond = (id, status, body, dirty = true) => out({ id, dirty,
  response: { status, headers: { 'content-type': 'application/json' }, body_b64: Buffer.from(JSON.stringify(body)).toString('base64') } });
createInterface({ input: process.stdin }).on('line', line => {
  const m = JSON.parse(line);
  if (m.go) { const r = granted.get(m.id); granted.delete(m.id); r?.(); return; }
  handle(m.id, m.envelope, m).catch(() => process.exit(1));
});
out({ ready: true, dirty: false });
"""

# The real API handler with stub models behind the adapter's line protocol, for "Keep my recordings": no model call,
# but every file and row is written by the code that runs in production.
KEEP_WORKER = """
import { createInterface } from 'node:readline';
import { Readable } from 'node:stream';
import { Store } from 'ROOT/src/store.mjs';
import { createHandler } from 'ROOT/src/server.mjs';
const out = m => process.stdout.write(JSON.stringify(m) + '\\n');
const store = new Store(process.env.DB_PATH);
store.db.prepare('INSERT OR IGNORE INTO tokens(hash,user_id,scopes) VALUES(?,?,?)').run(process.env.CONNECTOR_TOKEN_HASH, 'synthetic-operator', JSON.stringify(['read', 'write']));
const models = { async transcribe() { return { transcript: 'Um, we ship it today.', turns: [], audio_duration_ms: 2000, model: 'stub', provider_session_id: 'stub' }; },
  async analyze() { return { status: 'unavailable', reason: 'stub' }; } };
const granted = new Map();
createInterface({ input: process.stdin }).on('line', async line => {
  const m = JSON.parse(line);
  if (m.go) { const r = granted.get(m.id); granted.delete(m.id); r?.(); return; }
  const env = m.envelope, chunks = [];
  const phases = { async release() { out({ id: m.id, phase: 'release' }); },
    async acquire() { await new Promise(r => { granted.set(m.id, r); out({ id: m.id, phase: 'acquire' }); }); } };
  const req = Object.assign(Readable.from([Buffer.from(env.body_b64, 'base64')]), { method: env.method, url: env.path, headers: env.headers });
  const res = { writeHead(status, headers) { this.status = status; this.headers = headers; }, write(c) { chunks.push(Buffer.from(c)); }, on() {},
    end(last) { if (last !== undefined) chunks.push(Buffer.from(last));
      out({ id: m.id, dirty: env.method !== 'GET', response: { status: this.status, headers: this.headers, body_b64: Buffer.concat(chunks).toString('base64') } }); } };
  await createHandler(store, { baseUrl: env.base_url, models, phases })(req, res);
});
out({ ready: true, dirty: true });
"""


class BridgeTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.volume = Volume()
        self.env = patch.dict(os.environ, {'CONNECTOR_TOKEN_HASH': hashlib.sha256(b'local-test-only').hexdigest()})
        self.env.start()
        self.apps = []
        self.app = self.bridge(self.volume, worker_path=str(ROOT/'scripts/handle-request.mjs'), database_path=self.temp.name+'/state.sqlite')
        self.sequence = 0

    async def asyncTearDown(self):
        for app in self.apps:
            await app.worker.kill()
        self.env.stop(); self.temp.cleanup()

    def bridge(self, volume, **options):
        app = create_bridge(volume, **options)
        self.apps.append(app)
        return app

    def fake(self, name, handle):
        path = Path(self.temp.name) / name
        path.write_text(FAKE_WORKER + 'async function handle(id, env, m) {\n' + handle + '\n}\n')
        return str(path)

    async def call(self, method, path, body=None, key=None, auth=True):
        self.sequence += 1
        headers = [(b'host', b'example--web.us-east.modal.run'), (b'content-type', b'application/json'),
                   (b'idempotency-key', (key or f'test-request-{self.sequence}').encode())]
        if auth: headers.append((b'authorization', b'Bearer local-test-only'))
        sent = []
        async def receive(): return {'type': 'http.request', 'body': json.dumps(body).encode() if body is not None else b''}
        async def send(event):
            if event['type'] == 'http.response.start': self.volume.events.append('response')
            sent.append(event)
        await self.app({'type':'http','method':method,'path':path,'headers':headers}, receive, send)
        raw = sent[1]['body']
        try: data = json.loads(raw)
        except ValueError: data = raw.decode()
        return sent[0]['status'], data

    async def test_semantic_reservation_is_committed_before_go_and_failure_never_grants_go(self):
        for should_fail in (False, True):
            self.volume.fail = should_fail
            self.volume.events.clear()
            log = Path(self.temp.name) / f'persist-{should_fail}.txt'
            app = self.bridge(self.volume, worker_path=self.fake(f'persist-{should_fail}.mjs', f"""
                const go = new Promise(r => granted.set(id, r));
                out({{id, phase:'persist', dirty:true}});
                await go;
                appendFileSync({json.dumps(str(log))}, 'paid-work-could-start');
                respond(id,200,{{saved:true}});
            """))
            old = self.app
            self.app = app
            try:
                status, data = await self.call('POST', '/v1/voice-rounds', {})
                self.assertEqual(status, 503 if should_fail else 200)
                self.assertEqual(log.exists(), not should_fail, 'failed persist never acknowledges go')
                self.assertEqual(self.volume.events[0], 'commit')
                self.assertEqual(self.volume.events[-1], 'response')
            finally:
                self.app = old
        self.volume.fail = False
        self.assertIn('x-practice-round-id', FORWARDED)
        self.assertIn('x-practice-round-version', FORWARDED)
        self.assertEqual(route_label('GET','/v1/practice-rounds/private-id'),'GET /v1/practice-rounds/{id}')
        self.assertEqual(route_label('GET','/v1/practice-exercises/private-id'),'GET /v1/practice-exercises/{id}')

    async def test_a_failed_reservation_commit_leaves_the_round_usable_on_the_next_request(self):
        # The real worker. The reservation is written, its commit fails, and the worker is killed before any model call.
        data = bytes(48000)
        wav = (b'RIFF' + (36 + len(data)).to_bytes(4, 'little') + b'WAVEfmt ' + (16).to_bytes(4, 'little')
               + (1).to_bytes(2, 'little') + (1).to_bytes(2, 'little') + (24000).to_bytes(4, 'little')
               + (48000).to_bytes(4, 'little') + (2).to_bytes(2, 'little') + (16).to_bytes(2, 'little')
               + b'data' + len(data).to_bytes(4, 'little') + data)
        # A reply model only looks configured; no transcription key, so no provider can be called.
        keys = {'BASETEN_API_KEY': 'not-a-real-key', 'MODEL_API_KEY': '', 'MMS_TTS_TOKEN': '', 'WIT_TTS_TOKEN': '', 'REPLAY_ENABLED': ''}
        with patch.dict(os.environ, keys):
            status, data = await self.call('POST', '/v1/goals', {'title': 'Deliver', 'target': 'Answer the request'})
            goal = data['record']
            status, data = await self.call('POST', '/v1/practice-rounds', {'goal_id': goal['id'], 'expected_goal_version': 1, 'confirmed': True,
                'request_text': 'When can you deliver?', 'objectives': [{'id': 'date', 'text': 'Give a date.'}]})
            self.assertEqual(status, 200); round_id = data['record']['id']
            answer = lambda key: self.raw('/v1/voice-rounds', wav, [(b'content-type', b'audio/wav'), (b'idempotency-key', key), (b'x-goal-id', goal['id'].encode())])
            self.volume.fail = True
            status, _ = await answer(b'reserve-then-fail')
            self.assertEqual(status, 503)
            self.volume.fail = False
            status, view = await self.call('GET', '/v1/practice-rounds/' + round_id)
            self.assertEqual(status, 200)
            self.assertIsNone(view['pending'], 'the next worker failed the reservation the killed one left')
            self.assertEqual((view['state'], view['version']), ('open', 1))
            self.assertEqual(self.app.worker.starts, 2)
            # The next answer is claimed (no turn_in_progress) and stops only at the missing transcription key.
            status, body = await answer(b'next-answer-key')
            self.assertEqual((status, body['error']), (503, 'transcription_unconfigured'))

    async def test_full_loop_runs_on_one_long_lived_worker(self):
        status, context = await self.call('GET','/v1/context')
        self.assertEqual(status,200); self.assertEqual(len(context['sessions']),2)
        self.assertEqual(self.volume.events,['commit','response'], 'the bootstrap token and seed rows are committed before the first answer')
        status, data = await self.call('POST','/v1/goals',{'title':'Pause','target':'Wait for the question'})
        self.assertEqual(status,200); goal = data['record']
        status, data = await self.call('POST','/v1/exercises',{'goal_id':goal['id'],'title':'One pause','instructions':'Wait, pause, answer'})
        self.assertEqual(status,200); exercise = data['record']
        body = {'goal_id':goal['id'],'exercise_id':exercise['id'],'status':'completed','feedback':'I tried it'}
        status, first = await self.call('POST','/v1/check-ins',body,key='completion-once')
        self.assertEqual(status,200)
        status, retry = await self.call('POST','/v1/check-ins',body,key='completion-once')
        self.assertEqual(retry['receipt_id'],first['receipt_id']); self.assertTrue(retry['replayed'])
        self.assertEqual((await self.call('POST','/v1/check-ins',body))[0],409)
        status, data = await self.call('PATCH','/v1/sessions/session-after',{'expected_version':1,'transcript':'The speaker interrupted.','pause_before_answer_ms':80,'correction_reason':'Fixture correction'})
        self.assertEqual(status,200); self.assertEqual(data['record']['version'],2)
        self.assertEqual((await self.call('PATCH','/v1/sessions/session-after',{'expected_version':1,'deleted':True,'correction_reason':'Stale'}))[0],409)
        status, data = await self.call('PATCH','/v1/goals/'+goal['id'],{'expected_version':1,'target':'Listen to the entire question'})
        self.assertEqual(status,200)
        status, context = await self.call('GET','/v1/context')
        self.assertEqual(context['goals'][0]['version'],2)
        self.assertEqual(context['progress']['self_reported_completions'],1)
        self.assertIsNone(context['progress']['measured_improvement'])
        self.assertIn('80ms',(await self.call('GET','/v1/files/evidence.txt'))[1])
        self.assertEqual((await self.call('GET','/v1/context',auth=False))[0],401)
        self.assertEqual(self.app.worker.starts, 1, 'every request ran on the same Node process')
        self.assertNotIn('reload', self.volume.events)

    async def test_one_worker_serves_every_request_reads_skip_the_commit_and_nothing_reloads(self):
        await self.call('GET', '/health')
        self.volume.events.clear()
        for _ in range(5):
            self.assertEqual((await self.call('GET', '/health'))[0], 200)
            self.assertEqual((await self.call('GET', '/v1/overview'))[0], 200)
        self.assertEqual(self.volume.events, ['response'] * 10, 'reads are answered without a reload or a commit')
        self.volume.events.clear()
        self.assertEqual((await self.call('POST', '/v1/goals', {'title': 'Pace', 'target': 'Slow down'}))[0], 200)
        self.assertEqual(self.volume.events, ['commit', 'response'], 'a write is committed before it is answered')
        self.assertEqual(self.app.worker.starts, 1)

    async def test_a_round_end_is_a_quick_committed_write_and_a_retry_replays_it(self):
        await self.call('GET', '/health')
        self.volume.events.clear()
        status, first = await self.call('POST', '/v1/voice-rounds/end', {}, key='round-end-once')
        self.assertEqual(status, 200); self.assertFalse(first['replayed'])
        self.assertEqual(self.volume.events, ['commit', 'response'], 'committed before it is answered')
        status, retry = await self.call('POST', '/v1/voice-rounds/end', {}, key='round-end-once')
        self.assertTrue(retry['replayed']); self.assertEqual(retry['record']['ended_at'], first['record']['ended_at'])
        self.assertEqual(route_label('POST', '/v1/voice-rounds/end'), 'POST /v1/voice-rounds/end', 'a route name, not an id')
        self.assertEqual(route_label('WS', '/v1/voice-rounds/live'), 'WS /v1/voice-rounds/live')

    async def test_commit_failure_never_reports_success_and_retry_is_idempotent(self):
        self.volume.fail = True
        body = {'title':'Retry safely','target':'A single goal'}
        self.assertEqual((await self.call('POST','/v1/goals',body,key='commit-failure'))[0],503)
        # While storage keeps failing, even a read is refused: nothing uncommitted is shown as stored.
        self.assertEqual((await self.call('GET','/v1/context'))[0],503)
        self.volume.fail = False
        self.volume.events.clear()
        status, context = await self.call('GET','/v1/context')
        self.assertEqual(self.volume.events,['commit','response'], 'the failed commit is retried before the next answer')
        self.assertEqual(len(context['goals']),1)
        status, data = await self.call('POST','/v1/goals',body,key='commit-failure')
        self.assertEqual(status,200); self.assertTrue(data['replayed'])
        self.assertEqual(len((await self.call('GET','/v1/context'))[1]['goals']),1)

    async def raw(self, path, body, headers):
        sent = []
        async def receive(): return {'type': 'http.request', 'body': body}
        async def send(event): sent.append(event)
        base = [(b'host', b'example--web.us-east.modal.run'), (b'authorization', b'Bearer local-test-only')]
        await self.app({'type': 'http', 'method': 'POST', 'path': path, 'headers': base + headers}, receive, send)
        return sent[0]['status'], json.loads(sent[1]['body'])

    async def test_recording_route_accepts_audio_beyond_json_limit_and_forwards_capture_headers(self):
        # 2 s of 24 kHz mono silence: larger than the 16 KiB JSON cap, valid WAV.
        data = bytes(96000)
        wav = (b'RIFF' + (36 + len(data)).to_bytes(4, 'little') + b'WAVEfmt ' + (16).to_bytes(4, 'little')
               + (1).to_bytes(2, 'little') + (1).to_bytes(2, 'little') + (24000).to_bytes(4, 'little')
               + (48000).to_bytes(4, 'little') + (2).to_bytes(2, 'little') + (16).to_bytes(2, 'little')
               + b'data' + len(data).to_bytes(4, 'little') + data)
        os.environ.pop('MODEL_API_KEY', None)  # restored by the setUp patch.dict on teardown
        status, body = await self.raw('/v1/recordings', wav, [(b'content-type', b'audio/wav'), (b'idempotency-key', b'bridge-audio-1'), (b'x-language', b'de')])
        self.assertEqual(status, 400); self.assertIn('X-Language', body['message'])  # capture header reached Node
        # A capture naming a drill: X-Exercise-Id reaches Node, which checks it before any model call.
        status, body = await self.raw('/v1/recordings', wav, [(b'content-type', b'audio/wav'), (b'idempotency-key', b'bridge-audio-3'), (b'x-exercise-id', b'not an id')])
        self.assertEqual(status, 400); self.assertIn('X-Exercise-Id', body['message'])
        self.assertIn('x-exercise-id', FORWARDED)
        # The watch adds consent, attribution and context headers for French; the adapter drops them (allow-list) and the request proceeds.
        status, body = await self.raw('/v1/recordings', wav, [(b'content-type', b'audio/wav'), (b'idempotency-key', b'bridge-audio-2'), (b'x-language', b'fr'),
                                                              (b'x-consent-basis', b'self_only'), (b'x-attribution', b'self_declared'), (b'x-context', b'everyday')])
        self.assertEqual(status, 503); self.assertEqual(body['error'], 'transcription_unconfigured')
        for header in ('x-consent-basis', 'x-attribution', 'x-context'):
            self.assertNotIn(header, FORWARDED)
        sent = []
        async def receive(): return {'type': 'http.request', 'body': wav}
        async def send(event): sent.append(event)
        await self.app({'type': 'http', 'method': 'POST', 'path': '/v1/recordings', 'headers': [(b'host', b'example--web.us-east.modal.run'), (b'content-type', b'audio/wav')]}, receive, send)
        self.assertEqual(sent[0]['status'], 401)  # anonymous audio rejected before buffering or spawning Node
        status, body = await self.raw('/v1/goals', b'x' * 20000, [(b'content-type', b'application/json'), (b'idempotency-key', b'too-large-json')])
        self.assertEqual(status, 413)

    async def test_reads_are_served_while_a_recording_is_in_model_calls(self):
        # A fake worker that follows the release/acquire protocol with a slow "inference" step.
        app = self.bridge(self.volume, worker_path=self.fake('fake-worker.mjs', """
if (env.path === '/v1/recordings') {
  release(id);
  await pause(1500);
  await acquire(id);
}
respond(id, 200, { path: env.path }, env.method !== 'GET');
"""), database_path=self.temp.name + '/fake.sqlite')
        finished = []
        async def request(path, method):
            sent = []
            async def receive(): return {'type': 'http.request', 'body': b''}
            async def send(event): sent.append(event)
            headers = [(b'host', b'example--web.us-east.modal.run'), (b'authorization', b'Bearer x')]
            await app({'type': 'http', 'method': method, 'path': path, 'headers': headers}, receive, send)
            finished.append((path, sent[0]['status']))
        recording = asyncio.create_task(request('/v1/recordings', 'POST'))
        await asyncio.sleep(0.5)
        await request('/v1/overview', 'GET')
        self.assertEqual(finished, [('/v1/overview', 200)], 'read completed while the recording was still in model calls')
        await recording
        self.assertEqual(finished[-1], ('/v1/recordings', 200))

    async def test_screen_context_gets_the_model_deadline_and_json_limit(self):
        # A fake worker that answers after 1 s, with the read deadline cut to 0.3 s: only model routes may wait that long.
        app = self.bridge(self.volume, worker_path=self.fake('slow-worker.mjs', """
release(id);
await pause(1000);
await acquire(id);
respond(id, 200, { path: env.path });
"""), database_path=self.temp.name + '/slow.sqlite')
        async def request(app, path, body=b'{}'):
            sent = []
            async def receive(): return {'type': 'http.request', 'body': body}
            async def send(event): sent.append(event)
            headers = [(b'host', b'example--web.us-east.modal.run'), (b'authorization', b'Bearer x'), (b'content-type', b'application/json')]
            await app({'type': 'http', 'method': 'POST', 'path': path, 'headers': headers}, receive, send)
            return sent[0]['status']
        with patch('bridge.READ_DEADLINE', 0.3):
            self.assertEqual(await request(app, '/v1/screen-contexts'), 200)
            self.assertEqual(await request(app, '/v1/goals'), 503, 'ordinary writes keep the short deadline')
        self.assertEqual(await request(self.app, '/v1/screen-contexts', b'x' * 20000), 413, 'screen contexts keep the 16 KiB JSON limit')

    async def test_voice_round_route_takes_audio_and_forwards_voice_headers_to_node(self):
        data = bytes(96000)
        wav = (b'RIFF' + (36 + len(data)).to_bytes(4, 'little') + b'WAVEfmt ' + (16).to_bytes(4, 'little')
               + (1).to_bytes(2, 'little') + (1).to_bytes(2, 'little') + (24000).to_bytes(4, 'little')
               + (48000).to_bytes(4, 'little') + (2).to_bytes(2, 'little') + (16).to_bytes(2, 'little')
               + b'data' + len(data).to_bytes(4, 'little') + data)
        with patch.dict(os.environ):
            for name in ('MODEL_API_KEY', 'BASETEN_API_KEY'):
                os.environ.pop(name, None)
            audio = [(b'content-type', b'audio/wav')]
            # Each header reached Node: its own validation message comes back.
            status, body = await self.raw('/v1/voice-rounds', wav, audio + [(b'idempotency-key', b'voice-bridge-1'), (b'x-prompt-ended-at', b'soon')])
            self.assertEqual(status, 400); self.assertIn('X-Prompt-Ended-At', body['message'])
            status, body = await self.raw('/v1/voice-rounds', wav, audio + [(b'idempotency-key', b'voice-bridge-2'), (b'x-screen-context-id', b'no-such-card')])
            self.assertEqual(status, 404)
            status, body = await self.raw('/v1/voice-rounds', wav, audio + [(b'idempotency-key', b'voice-bridge-4'), (b'x-camera-metrics', b'{"frames":1}')])
            self.assertEqual(status, 400); self.assertIn('X-Camera-Metrics', body['message'])
            status, body = await self.raw('/v1/voice-rounds', wav, audio + [(b'idempotency-key', b'voice-bridge-5'), (b'x-reply-mode', b'auto')])
            self.assertEqual(status, 400); self.assertIn('X-Reply-Mode', body['message'])
            # A valid round on a deployment without a reply model stops before any paid transcription.
            status, body = await self.raw('/v1/voice-rounds', wav, audio + [(b'idempotency-key', b'voice-bridge-3'), (b'x-language', b'fr'),
                                                                              (b'x-occurred-at', b'2026-11-02T15:00:01Z'), (b'x-prompt-ended-at', b'2026-11-02T15:00:00Z')])
            self.assertEqual(status, 503); self.assertEqual(body['error'], 'reply_unconfigured')
        for header in ('x-screen-context-id', 'x-prompt-ended-at', 'x-camera-metrics', 'x-counterpart-need', 'x-reply-mode'):
            self.assertIn(header, FORWARDED)
        sent = []
        async def receive(): return {'type': 'http.request', 'body': wav}
        async def send(event): sent.append(event)
        await self.app({'type': 'http', 'method': 'POST', 'path': '/v1/voice-rounds', 'headers': [(b'host', b'example--web.us-east.modal.run'), (b'content-type', b'audio/wav')]}, receive, send)
        self.assertEqual(sent[0]['status'], 401)  # anonymous audio rejected before buffering or spawning Node
        status, body = await self.raw('/v1/voice-rounds', bytes(8 * 1024 * 1024 + 1), [(b'content-type', b'audio/wav'), (b'idempotency-key', b'voice-too-large')])
        self.assertEqual(status, 413); self.assertEqual(body['message'], 'Maximum audio upload is 8 MiB.')

    async def test_voice_round_gets_the_model_deadline_and_releases_the_database_during_model_calls(self):
        # A fake worker that releases the database for 1 s of "transcription and reply", with the read deadline cut to 0.3 s.
        app = self.bridge(self.volume, worker_path=self.fake('voice-worker.mjs', """
if (env.path === '/v1/voice-rounds') {
  release(id);
  await pause(1000);
  await acquire(id);
}
const size = Buffer.from(env.body_b64, 'base64').length;
respond(id, 200, { path: env.path, size, prompt: env.headers['x-prompt-ended-at'] ?? null }, env.method !== 'GET');
"""), database_path=self.temp.name + '/voice.sqlite')
        finished = []
        async def request(method, path, body=b''):
            sent = []
            async def receive(): return {'type': 'http.request', 'body': body}
            async def send(event): sent.append(event)
            headers = [(b'host', b'example--web.us-east.modal.run'), (b'authorization', b'Bearer x'), (b'content-type', b'audio/wav'),
                       (b'x-prompt-ended-at', b'2026-11-02T15:00:00Z')]
            await app({'type': 'http', 'method': method, 'path': path, 'headers': headers}, receive, send)
            finished.append((path, sent[0]['status']))
            return json.loads(sent[1]['body'])
        with patch('bridge.READ_DEADLINE', 0.3):
            voice = asyncio.create_task(request('POST', '/v1/voice-rounds', bytes(200000)))
            await asyncio.sleep(0.4)
            await request('GET', '/v1/overview')
            self.assertEqual(finished, [('/v1/overview', 200)], 'a read was served while the voice round was in model calls')
            body = await voice
        self.assertEqual(finished[-1], ('/v1/voice-rounds', 200), 'the voice round outlived the read deadline')
        self.assertEqual(body, {'path': '/v1/voice-rounds', 'size': 200000, 'prompt': '2026-11-02T15:00:00Z'})

    async def test_hosted_config_runs_several_inputs_in_one_container(self):
        modal_app = (ROOT / 'deploy' / 'modal_app.py').read_text()
        self.assertRegex(modal_app, r'max_containers=1\b')
        self.assertGreater(int(re.search(r'@modal\.concurrent\(max_inputs=(\d+)\)', modal_app).group(1)), 1)

    async def test_concurrent_requests_keep_one_database_holder_and_one_model_call_at_a_time(self):
        # Every volume operation and every worker step goes to one log, in order.
        log = Path(self.temp.name) / 'timeline.log'
        def note(line):
            with open(log, 'a') as f: f.write(line + '\n')
        class LoggingVolume(Volume):
            def __init__(self):
                super().__init__()
                class Op(Operation):
                    async def aio(self): note(self.name); await asyncio.sleep(0.01)
                self.reload = Op(self, 'reload'); self.commit = Op(self, 'commit')
        worker = self.fake('logging-worker.mjs', """
const key = env.headers['idempotency-key'];
const note = s => appendFileSync(process.env.TIMELINE, s + ' ' + key + '\\n');
note('db-open'); await pause(30);
if (env.path === '/v1/recordings') {
  note('db-close'); release(id);
  note('model-start'); await pause(400); note('model-end');
  await acquire(id);
  note('db-open'); await pause(30);
}
note('db-close');
respond(id, 200, {}, env.method !== 'GET');
""")
        with patch.dict(os.environ, {'TIMELINE': str(log)}):
            app = self.bridge(LoggingVolume(), worker_path=worker, database_path=self.temp.name + '/log.sqlite')
            finished = []
            async def request(method, path, key):
                sent = []
                async def receive(): return {'type': 'http.request', 'body': b''}
                async def send(event): sent.append(event)
                headers = [(b'host', b'example--web.us-east.modal.run'), (b'authorization', b'Bearer x'), (b'idempotency-key', key.encode())]
                await app({'type': 'http', 'method': method, 'path': path, 'headers': headers}, receive, send)
                finished.append((key, sent[0]['status']))
            # Two captures with the same key (a client retry while the first is still running), one other capture, reads.
            await asyncio.gather(request('POST', '/v1/recordings', 'capture-a'), request('POST', '/v1/recordings', 'capture-a'),
                                 request('POST', '/v1/recordings', 'capture-b'),
                                 *(request('GET', '/v1/overview', f'read-{i}') for i in range(3)))
        self.assertEqual(sorted(s for _, s in finished), [200] * 6)
        events = log.read_text().split('\n')[:-1]
        holder, in_model, commits = None, None, 0
        for event in events:
            name, _, key = event.partition(' ')
            if name == 'db-open':
                self.assertIn(holder, (None, 'closed'), f'two requests had the database at once: {events}'); holder = key
            elif name == 'db-close':
                self.assertEqual(holder, key); holder = 'closed'
            elif name == 'commit':
                self.assertEqual(holder, 'closed', 'commit only after the request finished with the database'); holder = None; commits += 1
            elif name == 'reload':
                self.fail('the volume is never reloaded while the container runs')
            elif name == 'model-start':
                self.assertIsNone(in_model, 'requests that call a model run one at a time'); in_model = key
            elif name == 'model-end':
                in_model = None
        self.assertIn(holder, (None, 'closed'))
        self.assertEqual(commits, 3, 'the three captures commit; the reads do not')
        # Reads were served while a capture was in its model calls, not queued behind it.
        first_model = events.index(next(e for e in events if e.startswith('model-start')))
        last_model = len(events) - 1 - events[::-1].index(next(e for e in reversed(events) if e.startswith('model-end')))
        self.assertTrue(any(e.startswith('db-open read-') for e in events[first_model:last_model]))
        self.assertEqual(sum(e.startswith('model-start') for e in events), 3, 'each capture ran once in the worker; the real handler replays the retry')
        self.assertEqual(app.worker.starts, 1, 'six requests, one Node process')

    async def test_a_request_that_cannot_get_the_lock_in_time_gets_a_503(self):
        app = self.bridge(self.volume, worker_path=self.fake('hold-worker.mjs', """
await pause(800);
respond(id, 200, {});
"""), database_path=self.temp.name + '/hold.sqlite')
        async def request(method, path):
            sent = []
            async def receive(): return {'type': 'http.request', 'body': b'{}'}
            async def send(event): sent.append(event)
            headers = [(b'host', b'example--web.us-east.modal.run'), (b'authorization', b'Bearer x'), (b'content-type', b'application/json')]
            await app({'type': 'http', 'method': method, 'path': path, 'headers': headers}, receive, send)
            return sent[0]['status'], json.loads(sent[1]['body']) if sent[1]['body'] else None
        with patch('bridge.READ_DEADLINE', 0.3):
            slow = asyncio.create_task(request('POST', '/v1/goals'))
            await asyncio.sleep(0.05)
            status, body = await request('GET', '/v1/overview')
            self.assertEqual(status, 503); self.assertEqual(body['error'], 'storage_or_worker_unavailable')
            await slow

    async def test_speech_audio_streams_through_the_adapter_before_the_worker_finishes(self):
        app = self.bridge(self.volume, worker_path=self.fake('speech-worker.mjs', """
release(id);
out({ id, head: { status: 200, headers: { 'Content-Type': 'audio/mpeg', 'X-Speech-Provider': 'wit' } } });
for (const part of ['first-', 'second-', 'third']) { out({ id, chunk: Buffer.from(part).toString('base64') }); await pause(250); }
await acquire(id);
out({ id, dirty: true, response: { status: 200, headers: {}, body_b64: '' } });
"""), database_path=self.temp.name + '/speech.sqlite')
        began, events = time.perf_counter(), []
        async def receive(): return {'type': 'http.request', 'body': b''}
        async def send(event):
            events.append((round(time.perf_counter() - began, 3), event))
            self.volume.events.append('start' if event['type'] == 'http.response.start' else 'more' if event.get('more_body') else 'end')
        headers = [(b'host', b'example--web.us-east.modal.run'), (b'authorization', b'Bearer x')]
        await app({'type': 'http', 'method': 'POST', 'path': '/v1/voice-rounds/round-1/speech', 'headers': headers}, receive, send)
        start = events[0][1]
        self.assertEqual(start['status'], 200)
        self.assertIn((b'content-type', b'audio/mpeg'), start['headers'])
        self.assertTrue(any(k == b'server-timing' for k, _ in start['headers']))
        body = b''.join(e.get('body', b'') for _, e in events[1:])
        self.assertEqual(body, b'first-second-third')
        first_chunk, last = events[1][0], events[-1][0]
        self.assertLess(first_chunk, last - 0.4, 'the first audio reached the client while the rest was still being made')
        self.assertEqual(self.volume.events, ['start', 'more', 'more', 'more', 'commit', 'end'], 'the stream ends only after the commit')

    async def test_model_routes_get_a_budget_that_ends_before_their_deadline_and_counts_the_wait(self):
        app = self.bridge(self.volume, worker_path=self.fake('budget-worker.mjs', """
if (env.method === 'POST') { release(id); await pause(1000); await acquire(id); }
respond(id, 200, { budget_ms: m.budget_ms ?? null }, env.method !== 'GET');
"""), database_path=self.temp.name + '/budget.sqlite')
        async def request(method, path, key):
            sent = []
            async def receive(): return {'type': 'http.request', 'body': b''}
            async def send(event): sent.append(event)
            headers = [(b'host', b'example--web.us-east.modal.run'), (b'authorization', b'Bearer x'), (b'idempotency-key', key.encode())]
            await app({'type': 'http', 'method': method, 'path': path, 'headers': headers}, receive, send)
            return sent[0]['status'], json.loads(sent[1]['body'])
        with patch('bridge.MODEL_DEADLINE', 4), patch('bridge.COMMIT_RESERVE', 1):
            first, second = await asyncio.gather(request('POST', '/v1/recordings', 'budget-a'), request('POST', '/v1/voice-rounds', 'budget-b'))
            read = await request('GET', '/v1/overview', 'budget-read')
        self.assertEqual((first[0], second[0]), (200, 200))
        self.assertTrue(2800 <= first[1]['budget_ms'] <= 3000, first)
        self.assertTrue(1700 <= second[1]['budget_ms'] <= 2000, f'the wait for the first model call came off the budget: {second}')
        self.assertIsNone(read[1]['budget_ms'], 'reads carry no budget')

    async def test_a_model_request_that_outlives_its_deadline_still_finishes_and_commits(self):
        log = Path(self.temp.name) / 'late.log'
        app = self.bridge(self.volume, worker_path=self.fake('late-worker.mjs', """
release(id);
await pause(800);
await acquire(id);
appendFileSync(process.env.TIMELINE, 'saved\\n');
respond(id, 200, { saved: true });
"""), database_path=self.temp.name + '/late.sqlite')
        sent = []
        async def receive(): return {'type': 'http.request', 'body': b''}
        async def send(event): sent.append(event)
        headers = [(b'host', b'example--web.us-east.modal.run'), (b'authorization', b'Bearer x'), (b'idempotency-key', b'late-1')]
        with patch.dict(os.environ, {'TIMELINE': str(log)}), patch('bridge.MODEL_DEADLINE', 0.3):
            await app({'type': 'http', 'method': 'POST', 'path': '/v1/screen-contexts', 'headers': headers}, receive, send)
            self.assertEqual(sent[0]['status'], 503, 'the client is told no success is claimed')
            self.assertNotIn('commit', self.volume.events)
            await asyncio.sleep(1.0)
        self.assertEqual(log.read_text(), 'saved\n', 'the request finished in the background')
        self.assertIn('commit', self.volume.events, 'and its write was committed, so a retry replays it')

    async def test_a_worker_that_exits_fails_its_requests_and_the_next_request_starts_a_new_one(self):
        app = self.bridge(self.volume, worker_path=self.fake('crash-worker.mjs', """
if (env.path === '/v1/crash') process.exit(3);
respond(id, 200, { ok: true }, false);
"""), database_path=self.temp.name + '/crash.sqlite')
        async def request(path):
            sent = []
            async def receive(): return {'type': 'http.request', 'body': b''}
            async def send(event): sent.append(event)
            await app({'type': 'http', 'method': 'GET', 'path': path, 'headers': [(b'host', b'example--web.us-east.modal.run')]}, receive, send)
            return sent[0]['status']
        self.assertEqual(await request('/v1/crash'), 503)
        self.assertEqual(await request('/health'), 200)
        self.assertEqual(app.worker.starts, 2)

    async def test_lifespan_startup_starts_the_worker_and_commits_its_bootstrap(self):
        events = [{'type': 'lifespan.startup'}, {'type': 'lifespan.shutdown'}]
        sent = []
        async def receive(): return events.pop(0)
        async def send(event): sent.append(event['type'])
        await self.app({'type': 'lifespan'}, receive, send)
        self.assertEqual(sent, ['lifespan.startup.complete', 'lifespan.shutdown.complete'])
        self.assertEqual(self.app.worker.starts, 1)
        self.assertEqual(self.volume.events, ['commit'], 'the bootstrap rows were committed once, at startup')

    async def test_a_kept_recording_is_on_the_volume_before_the_commit_that_precedes_its_answer(self):
        media = Path(self.temp.name) / 'media'
        volume, files_at_commit = Volume(), []
        commit = volume.commit
        class Snapshot:
            async def aio(_):
                files_at_commit.append(sorted(p.name for p in media.rglob('*.wav')))
                await commit.aio()
        volume.commit = Snapshot()
        worker = Path(self.temp.name) / 'keep-worker.mjs'
        worker.write_text(KEEP_WORKER.replace('ROOT', str(ROOT)))
        app = self.bridge(volume, worker_path=str(worker), database_path=self.temp.name + '/keep.sqlite')
        async def request(method, path, body=b'', headers=()):
            sent = []
            async def receive(): return {'type': 'http.request', 'body': body}
            async def send(event):
                if event['type'] == 'http.response.start': volume.events.append('response')
                sent.append(event)
            base = [(b'host', b'example--web.us-east.modal.run'), (b'authorization', b'Bearer local-test-only')]
            await app({'type': 'http', 'method': method, 'path': path, 'headers': base + list(headers)}, receive, send)
            raw = b''.join(e.get('body', b'') for e in sent[1:])
            return sent[0]['status'], raw
        status, _ = await request('PATCH', '/v1/settings', json.dumps({'expected_version': 1, 'keep_recordings': True}).encode(),
                                  [(b'content-type', b'application/json'), (b'idempotency-key', b'keep-on-1')])
        self.assertEqual(status, 200)
        data = bytes(range(256)) * 250
        wav = (b'RIFF' + (36 + len(data)).to_bytes(4, 'little') + b'WAVEfmt ' + (16).to_bytes(4, 'little')
               + (1).to_bytes(2, 'little') + (1).to_bytes(2, 'little') + (16000).to_bytes(4, 'little')
               + (32000).to_bytes(4, 'little') + (2).to_bytes(2, 'little') + (16).to_bytes(2, 'little')
               + b'data' + len(data).to_bytes(4, 'little') + data)
        volume.events.clear()
        status, body = await request('POST', '/v1/recordings', wav, [(b'content-type', b'audio/wav'), (b'idempotency-key', b'keep-capture-1')])
        self.assertEqual(status, 200)
        record = json.loads(body)['record']
        self.assertTrue(record['media']['kept']); self.assertEqual(record['media']['sha256'], hashlib.sha256(wav).hexdigest())
        self.assertEqual(volume.events, ['commit', 'response'], 'the kept recording is committed before it is answered')
        self.assertIn(record['id'] + '.wav', files_at_commit[-1], 'the file was on the volume when the commit ran')
        self.assertEqual((media / 'synthetic-operator' / (record['id'] + '.wav')).read_bytes(), wav)
        # The owner downloads it through the adapter as audio, a read: no commit.
        volume.events.clear()
        status, body = await request('GET', '/v1/media/' + record['id'])
        self.assertEqual(status, 200); self.assertEqual(body, wav); self.assertEqual(volume.events, ['response'])
        # Deleting it is a write: the file is gone by the commit, and the commit precedes the answer.
        volume.events.clear()
        sent = []
        async def receive(): return {'type': 'http.request', 'body': b''}
        async def send(event):
            if event['type'] == 'http.response.start': volume.events.append('response')
            sent.append(event)
        await app({'type': 'http', 'method': 'DELETE', 'path': '/v1/media/' + record['id'], 'headers': [(b'host', b'example--web.us-east.modal.run'), (b'authorization', b'Bearer local-test-only'), (b'idempotency-key', b'keep-delete-1')]}, receive, send)
        self.assertEqual(sent[0]['status'], 200)
        self.assertEqual(volume.events, ['commit', 'response']); self.assertEqual(files_at_commit[-1], [])
        # Re-measuring may re-transcribe a kept recording, so it is a model route; media ids never reach the timing log.
        self.assertIsNotNone(REMEASURE_ROUTE.fullmatch('/v1/sessions/' + record['id'] + '/remeasure'))
        self.assertEqual(route_label('GET', '/v1/media/' + record['id']), 'GET /v1/media/{id}')

    async def test_replay_route_takes_a_clip_up_to_1_mib_after_a_bearer_and_routes_by_exact_path(self):
        app = self.bridge(self.volume, worker_path=self.fake('replay-worker.mjs', """
const size = Buffer.from(env.body_b64, 'base64').length;
respond(id, 200, { path: env.path, size, budget_ms: m.budget_ms ?? null, segments: env.headers['x-replay-segments'] ?? null,
  type: env.headers['content-type'] ?? null });
"""), database_path=self.temp.name + '/replay.sqlite')
        async def post(path, body, auth=True):
            sent = []
            async def receive(): return {'type': 'http.request', 'body': body}
            async def send(event): sent.append(event)
            headers = [(b'host', b'example--web.us-east.modal.run'), (b'content-type', b'video/mp4'), (b'idempotency-key', b'replay-bridge-1'),
                       (b'x-replay-segments', b'0-40,40-100')] + ([(b'authorization', b'Bearer x')] if auth else [])
            await app({'type': 'http', 'method': 'POST', 'path': path, 'headers': headers}, receive, send)
            return sent[0]['status'], json.loads(sent[1]['body'])
        self.assertEqual(VIDEO_LIMIT, 1024 * 1024)
        status, body = await post('/v1/voice-rounds/round-1/replay', bytes(VIDEO_LIMIT))
        self.assertEqual(status, 200); self.assertEqual(body['size'], VIDEO_LIMIT)
        self.assertEqual(body['segments'], '0-40,40-100', 'X-Replay-Segments reaches Node')
        self.assertEqual(body['type'], 'video/mp4')
        self.assertIsNotNone(body['budget_ms'], 'the replay gets a time budget like any model route')
        status, body = await post('/v1/voice-rounds/round-1/replay', bytes(VIDEO_LIMIT + 1))
        self.assertEqual((status, body['message']), (413, 'Maximum replay clip is 1 MiB.'))
        starts = app.worker.starts
        status, _ = await post('/v1/voice-rounds/round-1/replay', bytes(VIDEO_LIMIT), auth=False)
        self.assertEqual(status, 401, 'no Bearer, no buffering of a large body')
        self.assertEqual(app.worker.starts, starts)
        # Exact paths only: anything else keeps the 16 KiB JSON limit.
        for path in ('/v1/voice-rounds/round-1/replay/x', '/v1/voice-rounds/round-1/replayx', '/v1/voice-rounds/a/b/replay', '/v1/voice-rounds//replay',
                     '/v1/voice-rounds/' + 'a' * 65 + '/replay', '/v1/sessions/round-1/replay'):
            self.assertIsNone(REPLAY_ROUTE.fullmatch(path), path)
            self.assertEqual((await post(path, bytes(20000)))[0], 413, path)
        self.assertIsNotNone(REPLAY_ROUTE.fullmatch('/v1/voice-rounds/0b6f-AZ-9/replay'))
        self.assertEqual(route_label('POST', '/v1/voice-rounds/3f2a-round/replay'), 'POST /v1/voice-rounds/{id}/replay', 'the timing log hides the round id')
        self.assertIn('x-replay-segments', FORWARDED)

    async def test_a_replay_never_takes_the_model_lock_and_releases_the_database_during_sam_calls(self):
        app = self.bridge(self.volume, worker_path=self.fake('replay-lock-worker.mjs', """
if (env.path.endsWith('/replay')) { release(id); await pause(800); await acquire(id); respond(id, 200, { ok: 'replay' }); return; }
if (env.path === '/v1/recordings') { release(id); await pause(300); await acquire(id); respond(id, 200, { ok: 'recording' }); return; }
respond(id, 200, { ok: env.path }, env.method !== 'GET');
"""), database_path=self.temp.name + '/replay-lock.sqlite')
        finished = []
        async def request(method, path, body=b''):
            sent = []
            async def receive(): return {'type': 'http.request', 'body': body}
            async def send(event): sent.append(event)
            headers = [(b'host', b'example--web.us-east.modal.run'), (b'authorization', b'Bearer x'), (b'content-type', b'video/mp4'),
                       (b'idempotency-key', path.encode()[-40:].replace(b'/', b'-'))]
            await app({'type': 'http', 'method': method, 'path': path, 'headers': headers}, receive, send)
            finished.append(path)
        replay = asyncio.create_task(request('POST', '/v1/voice-rounds/round-1/replay', bytes(300000)))
        await asyncio.sleep(0.15)
        await request('GET', '/v1/overview')
        await request('POST', '/v1/recordings')
        self.assertEqual(finished, ['/v1/overview', '/v1/recordings'], 'a read and a model request both ran while the replay was in its SAM calls')
        await replay
        self.assertEqual(finished[-1], '/v1/voice-rounds/round-1/replay')

if __name__ == '__main__': unittest.main()


class LiveBridgeTests(BridgeTests):
    """WS /v1/voice-rounds/live through the adapter, with fake workers that play src/live-voice.mjs's side."""

    async def socket(self, app, frames, auth=True, path='/v1/voice-rounds/live', pause=0.0):
        """Plays the client: frames are ('text', str) | ('bytes', bytes) | ('wait', seconds) | ('disconnect',)."""
        incoming = asyncio.Queue()
        await incoming.put({'type': 'websocket.connect'})
        sent = []
        async def feed():
            for frame in frames:
                if frame[0] == 'wait':
                    await asyncio.sleep(frame[1]); continue
                if frame[0] == 'disconnect':
                    await incoming.put({'type': 'websocket.disconnect', 'code': 1001}); continue
                await incoming.put({'type': 'websocket.receive', frame[0]: frame[1]})
        async def receive():
            return await incoming.get()
        async def send(event):
            if event['type'] == 'websocket.send' and 'text' in event and json.loads(event['text']).get('type') == 'saved':
                self.volume.events.append('saved')
            if event['type'] == 'websocket.close':
                await incoming.put({'type': 'websocket.disconnect', 'code': event['code']})
            sent.append(event)
        headers = [(b'host', b'example--web.us-east.modal.run')] + ([(b'authorization', b'Bearer local-test-only')] if auth else [])
        feeder = asyncio.get_running_loop().create_task(feed())
        await asyncio.wait_for(app({'type': 'websocket', 'path': path, 'headers': headers}, receive, send), timeout=10)
        feeder.cancel()
        return sent

    START = ('text', json.dumps({'type': 'start', 'idempotency_key': 'live-bridge-1', 'language': 'en'}))

    async def test_live_refuses_a_socket_without_a_bearer_credential_before_accepting_it(self):
        sent = await self.socket(self.app, [self.START], auth=False)
        self.assertEqual(sent, [{'type': 'websocket.close', 'code': 1008}])
        sent = await self.socket(self.app, [self.START], path='/v1/voice-rounds/other')
        self.assertEqual(sent, [{'type': 'websocket.close', 'code': 1008}])
        self.assertEqual(self.app.worker.starts, 0, 'no worker was started for a refused socket')

    async def test_live_round_streams_events_and_audio_and_says_saved_only_after_the_commit(self):
        record = Path(self.temp.name) / 'worker-saw.jsonl'
        app = self.bridge(self.volume, worker_path=self.fake('live-worker.mjs', f"""
            appendFileSync({json.dumps(str(record))}, JSON.stringify(m) + '\\n');
            if (m.envelope?.live) {{ globalThis.audio = []; await release(id); out({{ id, event: {{ type: 'ready' }} }}); return; }}
            if (m.audio) {{ globalThis.audio.push(m.audio); return; }}
            if (m.end) {{
              out({{ id, event: {{ type: 'reply', round_id: 'round-1', frames: globalThis.audio.length }} }});
              out({{ id, audio_out: Buffer.from('mp3-1').toString('base64') }});
              await acquire(id);
              respond(id, 200, {{ round_id: 'round-1', receipt_id: 'receipt-1' }});
              await pause(30);
              out({{ id, audio_out: Buffer.from('mp3-2').toString('base64') }});
              out({{ id, closed: true }});
            }}
        """))
        camera = {'faced_camera_pct': 62, 'frames': 148, 'longest_look_away_ms': 4100, 'looked_away_count': 3}
        sent = await self.socket(app, [self.START, ('bytes', b'\\x01\\x02' * 1000), ('bytes', b'\\x03\\x04' * 1000), ('text', json.dumps({'type': 'end', 'camera': camera}))])
        self.assertEqual(sent[0], {'type': 'websocket.accept'})
        kinds = [('text', json.loads(e['text'])['type']) if 'text' in e else ('bytes', e['bytes']) if 'bytes' in e else (e['type'], e.get('code')) for e in sent[1:]]
        self.assertEqual(kinds, [('text', 'ready'), ('text', 'reply'), ('bytes', b'mp3-1'), ('text', 'saved'), ('bytes', b'mp3-2'), ('websocket.close', 1000)])
        reply = json.loads(sent[2]['text'])
        self.assertEqual(reply['frames'], 2, 'both PCM frames reached the worker before the release')
        self.assertEqual(self.volume.events, ['commit', 'saved'], 'saved only after the commit')
        saw = [json.loads(line) for line in record.read_text().splitlines()]
        self.assertEqual(saw[0]['envelope']['live']['idempotency_key'], 'live-bridge-1')
        self.assertEqual(saw[0]['envelope']['headers'], {'authorization': 'Bearer local-test-only'}, 'only the credential is passed on')
        self.assertTrue(0 < saw[0]['budget_ms'] < 150_000)
        self.assertEqual([base64.b64decode(m['audio']) for m in saw if 'audio' in m], [b'\\x01\\x02' * 1000, b'\\x03\\x04' * 1000])
        self.assertTrue(any(m.get('end') for m in saw))
        self.assertEqual([m.get('camera') for m in saw if m.get('end')], [camera], 'the camera numbers ride on "end" to the worker')

    async def test_live_semantic_persist_failure_sends_no_reply_or_audio(self):
        self.volume.fail = True
        app = self.bridge(self.volume, worker_path=self.fake('semantic-persist-fail.mjs', """
            if(m.envelope?.live) {
              const go = new Promise(r => granted.set(id,r));
              out({id,phase:'persist',dirty:true}); await go;
              out({id,event:{type:'reply'}}); out({id,audio_out:Buffer.from('audio').toString('base64')});
              respond(id,200,{saved:true}); out({id,closed:true});
            }
        """))
        sent = await self.socket(app,[self.START,('text','{"type":"end"}')])
        events=[json.loads(e['text']) for e in sent if 'text' in e]
        self.assertEqual([e['type'] for e in events],['error'])
        self.assertFalse(any('bytes' in e for e in sent))

    async def test_live_round_whose_commit_fails_is_never_called_saved(self):
        self.volume.fail = True
        app = self.bridge(self.volume, worker_path=self.fake('live-fail-worker.mjs', """
            if (m.envelope?.live) { await release(id); return; }
            if (m.end) { await acquire(id); respond(id, 200, { round_id: 'round-1' }); out({ id, closed: true }); }
        """))
        sent = await self.socket(app, [self.START, ('bytes', b'\\x00' * 4000), ('text', '{"type":"end"}')])
        events = [json.loads(e['text']) for e in sent if 'text' in e]
        self.assertEqual([e['type'] for e in events], ['error'])
        self.assertEqual(events[0]['error'], 'storage_or_worker_unavailable')
        self.assertNotIn('saved', self.volume.events)

    async def test_live_client_that_leaves_before_release_cancels_the_hold(self):
        record = Path(self.temp.name) / 'cancel-saw.jsonl'
        app = self.bridge(self.volume, worker_path=self.fake('live-cancel-worker.mjs', f"""
            appendFileSync({json.dumps(str(record))}, JSON.stringify(m) + '\\n');
            if (m.envelope?.live) {{ await release(id); return; }}
            if (m.cancel) {{ await acquire(id); respond(id, 499, {{ error: 'cancelled' }}, false); out({{ id, closed: true }}); }}
        """))
        sent = await self.socket(app, [self.START, ('bytes', b'\\x00' * 4000), ('wait', 0.05), ('disconnect',)])
        saw = [json.loads(line) for line in record.read_text().splitlines()]
        self.assertTrue(any(m.get('cancel') for m in saw))
        self.assertNotIn('commit', self.volume.events, 'a cancelled hold wrote nothing to commit')

    async def test_live_audio_past_the_frame_or_total_limit_is_a_413_and_never_a_release(self):
        record = Path(self.temp.name) / 'large-saw.jsonl'
        app = self.bridge(self.volume, worker_path=self.fake('live-large-worker.mjs', f"""
            appendFileSync({json.dumps(str(record))}, JSON.stringify(m) + '\\n');
            if (m.envelope?.live) {{ await release(id); return; }}
            if (m.cancel) {{ await acquire(id); respond(id, 499, {{ error: 'cancelled' }}); out({{ id, closed: true }}); }}
            if (m.end) {{ await acquire(id); respond(id, 200, {{ round_id: 'round-1' }}); out({{ id, closed: true }}); }}
        """))
        cases = {'frame': [('bytes', bytes(4000)), ('bytes', bytes(64 * 1024 + 1))],
                 'total': [('bytes', bytes(60_000))] * 4}
        for name, frames in cases.items():
            with self.subTest(name), patch('bridge.AUDIO_LIMIT', 200_000):
                record.write_text('')
                sent = await self.socket(app, [self.START, *frames, ('text', '{"type":"end"}')])
                events = [json.loads(e['text']) for e in sent if 'text' in e]
                self.assertEqual([(e['type'], e.get('status'), e.get('error')) for e in events], [('error', 413, 'audio_too_large')])
                self.assertEqual(sent[-1], {'type': 'websocket.close', 'code': 1009})
                saw = [json.loads(line) for line in record.read_text().splitlines()]
                self.assertTrue(any(m.get('cancel') for m in saw), 'the hold was dropped')
                self.assertFalse(any(m.get('end') for m in saw), 'never sent as a release')
                self.assertEqual(sum(1 for m in saw if 'audio' in m), 1 if name == 'frame' else 3, 'nothing past the limit reached the worker')

    async def test_live_oversized_frame_does_not_hide_a_refusal_the_worker_made_itself(self):
        app = self.bridge(self.volume, worker_path=self.fake('live-large-refused-worker.mjs', """
            if (m.envelope?.live) { await release(id); return; }
            // The worker's own refusal lands after the bridge has seen the oversized frame.
            if (m.cancel) { await acquire(id); respond(id, 429, { error: 'rate_limited', message: 'At most 30 voice rounds per hour.' }, false); out({ id, closed: true }); }
        """))
        sent = await self.socket(app, [self.START, ('bytes', bytes(64 * 1024 + 1)), ('text', '{"type":"end"}')])
        events = [json.loads(e['text']) for e in sent if 'text' in e]
        self.assertEqual([(e['type'], e.get('status'), e.get('error')) for e in events], [('error', 429, 'rate_limited')],
                         'the worker\'s own refusal is shown, not "too much audio"')

    async def test_spoken_reply_does_not_wait_for_a_model_request_and_is_not_committed(self):
        app = self.bridge(self.volume, worker_path=self.fake('speech-lock-worker.mjs', """
            if (env.path === '/v1/voice-rounds') { await release(id); await pause(400); await acquire(id); respond(id, 200, { ok: 'round' }); return; }
            respond(id, 200, { ok: 'speech' }, false);
        """))
        order = []
        async def one(path):
            sent = []
            async def receive(): return {'type': 'http.request', 'body': b''}
            async def send(event): sent.append(event)
            headers = [(b'host', b'example--web.us-east.modal.run'), (b'authorization', b'Bearer local-test-only'), (b'idempotency-key', b'k-12345678'), (b'content-type', b'audio/wav')]
            await app({'type': 'http', 'method': 'POST', 'path': path, 'headers': headers}, receive, send)
            order.append(path)
        round_task = asyncio.get_running_loop().create_task(one('/v1/voice-rounds'))
        await asyncio.sleep(0.1)
        await one('/v1/voice-rounds/round-1/speech')
        self.assertEqual(order, ['/v1/voice-rounds/round-1/speech'], 'the spoken reply answered while the round still held the model lock')
        self.assertEqual(self.volume.events, [], 'and nothing was committed for it')
        await round_task
        self.assertEqual(self.volume.events, ['commit'])

    def live_model_waits(self, log):
        """model_wait of each live round in the adapter's timing log, in ms."""
        lines = [json.loads(l) for l in log.getvalue().splitlines() if l.startswith('{')]
        return [l['timing'].get('model_wait', 0.0) for l in lines if l.get('route') == 'WS /v1/voice-rounds/live']

    LOCK_WORKER = """
            if (m.envelope?.live) { await release(id); out({ id, event: { type: 'ready' } }); return; }
            if (m.end) { await acquire(id); respond(id, 200, { round_id: 'round-2' }); out({ id, closed: true }); return; }
            if (m.envelope?.path) { release(id); await pause(1200); await acquire(id); respond(id, 200, { ok: m.envelope.path }); }
        """

    async def held_during(self, path):
        """Starts a POST to path (a slow model request), opens a live hold 0.2 s later, and returns its model_wait in ms
        and whether the POST was still running when the hold was saved."""
        app = self.bridge(self.volume, worker_path=self.fake('live-lock-' + path.split('/')[-1] + '.mjs', self.LOCK_WORKER))
        done = []
        async def post():
            sent = []
            async def receive(): return {'type': 'http.request', 'body': bytes(200000)}
            async def send(event): sent.append(event)
            headers = [(b'host', b'example--web.us-east.modal.run'), (b'authorization', b'Bearer local-test-only'),
                       (b'content-type', b'video/mp4' if path.endswith('/replay') else b'audio/wav'), (b'idempotency-key', b'lock-test-1')]
            await app({'type': 'http', 'method': 'POST', 'path': path, 'headers': headers}, receive, send)
            done.append(sent[0]['status'])
        log = io.StringIO()
        with contextlib.redirect_stdout(log):
            slow = asyncio.get_running_loop().create_task(post())
            await asyncio.sleep(0.2)
            sent = await self.socket(app, [self.START, ('bytes', b'\x00' * 4000), ('text', '{"type":"end"}')])
            running = not done
            await slow
        self.assertIn('saved', [json.loads(e['text'])['type'] for e in sent if 'text' in e])
        return self.live_model_waits(log)[0], running

    async def test_a_live_hold_takes_the_model_lock_without_waiting_while_a_replay_runs(self):
        wait_ms, running = await self.held_during('/v1/voice-rounds/round-1/replay')
        self.assertTrue(running, 'the replay was still in its SAM calls when the hold was saved')
        self.assertLessEqual(wait_ms, 200, f'the hold waited {wait_ms} ms for the model lock')
        # Negative control: a model route that does hold the lock (a WAV round) makes the same hold wait.
        wait_ms, running = await self.held_during('/v1/voice-rounds')
        self.assertFalse(running, 'the hold could only start after the WAV round finished')
        self.assertGreater(wait_ms, 500, 'the test can see a hold waiting on the lock')


# LiveBridgeTests reuses BridgeTests' setup and helpers; its inherited tests already run once under BridgeTests.
for _name in [n for n in vars(BridgeTests) if n.startswith('test_')]:
    setattr(LiveBridgeTests, _name, None)
