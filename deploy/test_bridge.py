import asyncio
import base64
import hashlib
import json
import os
import re
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from bridge import create_bridge, FORWARDED

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

class BridgeTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.volume = Volume()
        self.env = patch.dict(os.environ, {'CONNECTOR_TOKEN_HASH': hashlib.sha256(b'local-test-only').hexdigest()})
        self.env.start()
        self.app = create_bridge(self.volume, worker_path=str(ROOT/'scripts/handle-request.mjs'), database_path=self.temp.name+'/state.sqlite')
        self.sequence = 0

    async def asyncTearDown(self):
        self.env.stop(); self.temp.cleanup()

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

    async def test_full_loop_survives_separate_processes(self):
        status, context = await self.call('GET','/v1/context')
        self.assertEqual(status,200); self.assertEqual(len(context['sessions']),2)
        self.assertEqual(self.volume.events,['reload','commit','response'])
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

    async def test_commit_failure_never_reports_success_and_retry_is_idempotent(self):
        self.volume.fail = True
        body = {'title':'Retry safely','target':'A single goal'}
        self.assertEqual((await self.call('POST','/v1/goals',body,key='commit-failure'))[0],503)
        self.volume.fail = False
        status, data = await self.call('POST','/v1/goals',body,key='commit-failure')
        self.assertEqual(status,200); self.assertTrue(data['replayed'])
        context = (await self.call('GET','/v1/context'))[1]
        self.assertEqual(len(context['goals']),1)

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
        fake = Path(self.temp.name) / 'fake-worker.mjs'
        fake.write_text("""
import { createInterface } from 'node:readline';
const lines = createInterface({ input: process.stdin })[Symbol.asyncIterator]();
const env = JSON.parse((await lines.next()).value);
const out = m => process.stdout.write(JSON.stringify(m) + '\\n');
if (env.path === '/v1/recordings') {
  out({ phase: 'release' });
  await new Promise(r => setTimeout(r, 1500));
  out({ phase: 'acquire' });
  if ((await lines.next()).value !== 'go') process.exit(1);
}
out({ response: { status: 200, headers: { 'content-type': 'application/json' }, body_b64: Buffer.from(JSON.stringify({ path: env.path })).toString('base64') } });
process.exit(0);
""")
        app = create_bridge(self.volume, worker_path=str(fake), database_path=self.temp.name + '/fake.sqlite')
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
        fake = Path(self.temp.name) / 'slow-worker.mjs'
        fake.write_text("""
import { createInterface } from 'node:readline';
const lines = createInterface({ input: process.stdin })[Symbol.asyncIterator]();
const env = JSON.parse((await lines.next()).value);
out({ phase: 'release' });
await new Promise(r => setTimeout(r, 1000));
out({ phase: 'acquire' });
if ((await lines.next()).value !== 'go') process.exit(1);
out({ response: { status: 200, headers: { 'content-type': 'application/json' }, body_b64: Buffer.from(JSON.stringify({ path: env.path })).toString('base64') } });
process.exit(0);
function out(m) { process.stdout.write(JSON.stringify(m) + '\\n'); }
""")
        app = create_bridge(self.volume, worker_path=str(fake), database_path=self.temp.name + '/slow.sqlite')
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
            # A valid round on a deployment without a reply model stops before any paid transcription.
            status, body = await self.raw('/v1/voice-rounds', wav, audio + [(b'idempotency-key', b'voice-bridge-3'), (b'x-language', b'fr'),
                                                                              (b'x-occurred-at', b'2026-11-02T15:00:01Z'), (b'x-prompt-ended-at', b'2026-11-02T15:00:00Z')])
            self.assertEqual(status, 503); self.assertEqual(body['error'], 'reply_unconfigured')
        for header in ('x-screen-context-id', 'x-prompt-ended-at'):
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
        fake = Path(self.temp.name) / 'voice-worker.mjs'
        fake.write_text("""
import { createInterface } from 'node:readline';
const lines = createInterface({ input: process.stdin })[Symbol.asyncIterator]();
const env = JSON.parse((await lines.next()).value);
const out = m => process.stdout.write(JSON.stringify(m) + '\\n');
if (env.path === '/v1/voice-rounds') {
  out({ phase: 'release' });
  await new Promise(r => setTimeout(r, 1000));
  out({ phase: 'acquire' });
  if ((await lines.next()).value !== 'go') process.exit(1);
}
const size = Buffer.from(env.body_b64, 'base64').length;
out({ response: { status: 200, headers: { 'content-type': 'application/json' }, body_b64: Buffer.from(JSON.stringify({ path: env.path, size, prompt: env.headers['x-prompt-ended-at'] ?? null })).toString('base64') } });
process.exit(0);
""")
        app = create_bridge(self.volume, worker_path=str(fake), database_path=self.temp.name + '/voice.sqlite')
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
                outer = self
                class Op(Operation):
                    async def aio(self): note(self.name); await asyncio.sleep(0.01)
                self.reload = Op(self, 'reload'); self.commit = Op(self, 'commit')
        fake = Path(self.temp.name) / 'logging-worker.mjs'
        fake.write_text("""
import { createInterface } from 'node:readline';
import { appendFileSync } from 'node:fs';
const lines = createInterface({ input: process.stdin })[Symbol.asyncIterator]();
const env = JSON.parse((await lines.next()).value);
const id = env.headers['idempotency-key'];
const note = s => appendFileSync(process.env.TIMELINE, s + ' ' + id + '\\n');
const out = m => process.stdout.write(JSON.stringify(m) + '\\n');
const pause = ms => new Promise(r => setTimeout(r, ms));
note('db-open'); await pause(30);
if (env.path === '/v1/recordings') {
  note('db-close'); out({ phase: 'release' });
  note('model-start'); await pause(400); note('model-end');
  out({ phase: 'acquire' });
  if ((await lines.next()).value !== 'go') process.exit(1);
  note('db-open'); await pause(30);
}
note('db-close');
out({ response: { status: 200, headers: { 'content-type': 'application/json' }, body_b64: Buffer.from('{}').toString('base64') } });
process.exit(0);
""")
        with patch.dict(os.environ, {'TIMELINE': str(log)}):
            app = create_bridge(LoggingVolume(), worker_path=str(fake), database_path=self.temp.name + '/log.sqlite')
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
        holder, in_model = None, None
        for event in events:
            name, _, key = event.partition(' ')
            if name == 'db-open':
                self.assertIsNone(holder, f'two workers had the database open: {events}'); holder = key
            elif name == 'db-close':
                self.assertEqual(holder, key); holder = 'closed'
            elif name == 'commit':
                self.assertEqual(holder, 'closed', 'commit only after the worker closed the database'); holder = None
            elif name == 'reload':
                self.assertIsNone(holder, 'reload only while no worker has the database open')
            elif name == 'model-start':
                self.assertIsNone(in_model, 'requests that call a model run one at a time'); in_model = key
            elif name == 'model-end':
                in_model = None
        self.assertIsNone(holder)
        # Reads were served while a capture was in its model calls, not queued behind it.
        first_model = events.index(next(e for e in events if e.startswith('model-start')))
        last_model = len(events) - 1 - events[::-1].index(next(e for e in reversed(events) if e.startswith('model-end')))
        self.assertTrue(any(e.startswith('db-open read-') for e in events[first_model:last_model]))
        self.assertEqual(sum(e.startswith('model-start') for e in events), 3, 'each capture runs its own worker; Node replays the retry')

    async def test_a_request_that_cannot_get_the_lock_in_time_gets_a_503(self):
        fake = Path(self.temp.name) / 'hold-worker.mjs'
        fake.write_text("""
await new Promise(r => setTimeout(r, 800));
process.stdout.write(JSON.stringify({ response: { status: 200, headers: {}, body_b64: '' } }) + '\\n');
process.exit(0);
""")
        app = create_bridge(self.volume, worker_path=str(fake), database_path=self.temp.name + '/hold.sqlite')
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

if __name__ == '__main__': unittest.main()
