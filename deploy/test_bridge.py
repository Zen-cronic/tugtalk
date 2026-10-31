import asyncio
import base64
import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from bridge import create_bridge

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

if __name__ == '__main__': unittest.main()
