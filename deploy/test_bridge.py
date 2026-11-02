import asyncio
import base64
import hashlib
import json
import os
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

if __name__ == '__main__': unittest.main()
