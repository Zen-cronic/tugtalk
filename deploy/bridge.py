"""Minimal ASGI bridge. A response is released only after storage commits.

No framework dependency. Node executes the same tested API handler as local HTTP.
The Modal function must have max_containers=1; the lock serializes database access within it.
It accepts several inputs at once (@modal.concurrent), all on this one event loop.
A recording, screen-context or voice-round worker releases the lock during its slow model calls
(see scripts/handle-request.mjs), so reads and ordinary writes are not queued behind inference.
Model routes take a second lock for their whole run, so only one such request runs at a time:
a retry that arrives while the first attempt is still running waits and then replays its receipt
instead of paying for inference twice, and the hourly screen-context count stays exact.
Only the holder of the database lock has the database open; it reloads the volume before the
worker opens it and commits after the worker closes it, before handing the lock on.
"""
import asyncio
import base64
import json
import os
import re
import sys
import time

JSON_LIMIT = 16384
AUDIO_LIMIT = 8 * 1024 * 1024  # matches src/capture.mjs MAX_AUDIO_BYTES
FORWARDED = ('authorization', 'content-type', 'idempotency-key',
             'x-goal-id', 'x-language', 'x-capture-device', 'x-occurred-at',
             'x-screen-context-id', 'x-prompt-ended-at')
# Requests that call a model get the long deadline; everything else must finish quickly.
READ_DEADLINE = 20
MODEL_DEADLINE = 150
MODEL_ROUTES = ('/v1/recordings', '/v1/screen-contexts', '/v1/voice-rounds')
# Routes whose body is a WAV upload (the audio limit, and a Bearer credential before buffering it).
AUDIO_ROUTES = ('/v1/recordings', '/v1/voice-rounds')
# A spoken reply calls a speech model but has no body. The adapter returns it whole, not streamed.
SPEECH_ROUTE = re.compile(r'/v1/voice-rounds/[A-Za-z0-9-]{1,64}/speech')
# Timing log: one line per request with the route shape (ids replaced), the status and each phase in ms.
# Never the body, headers, query or ids.
ROUTE_ID = re.compile(r'/[A-Za-z0-9-]{8,64}(?=/|$)')


def route_label(method, path):
    return method + ' ' + ROUTE_ID.sub('/{id}', path)


def server_timing(phases):
    return ', '.join(f'{name};dur={ms:.1f}' for name, ms in phases.items())


BUSY = {'error': 'storage_or_worker_unavailable',
        'message': 'Retry the identical request with the same Idempotency-Key; no success is claimed.'}


class Timing:
    """Phase durations for one request, in ms. A phase that repeats (two commits) is summed."""
    def __init__(self):
        self.began = time.perf_counter()
        self.phases = {}

    def add(self, name, seconds):
        self.phases[name] = self.phases.get(name, 0.0) + seconds * 1000

    def start(self, name):
        return (name, time.perf_counter())

    def stop(self, started):
        self.add(started[0], time.perf_counter() - started[1])

    def phase(self, name):
        timing = self
        class Phase:
            def __enter__(self): self.t = time.perf_counter()
            def __exit__(self, *exc): timing.add(name, time.perf_counter() - self.t)
        return Phase()

    def log(self, scope, status):
        self.add('total', time.perf_counter() - self.began)
        line = {'timing': {k: round(v, 1) for k, v in self.phases.items()},
                'route': route_label(scope['method'], scope['path']), 'status': status}
        print(json.dumps(line), file=sys.stdout, flush=True)


def create_bridge(volume, *, worker_path='/app/scripts/handle-request.mjs', database_path='/data/connector.sqlite'):
    lock = asyncio.Lock()
    model_lock = asyncio.Lock()

    async def respond(send, status, payload):
        await send({'type': 'http.response.start', 'status': status,
                    'headers': [(b'content-type', b'application/json'), (b'cache-control', b'no-store')]})
        await send({'type': 'http.response.body', 'body': json.dumps(payload).encode()})

    async def app(scope, receive, send):
        if scope['type'] == 'lifespan':
            while True:
                event = await receive()
                if event['type'] == 'lifespan.startup':
                    await send({'type': 'lifespan.startup.complete'})
                elif event['type'] == 'lifespan.shutdown':
                    await send({'type': 'lifespan.shutdown.complete'})
                    return
            return
        if scope['type'] != 'http':
            return
        recording = scope['method'] == 'POST' and scope['path'] in AUDIO_ROUTES
        # A screen context is a small JSON body (JSON limit) but waits on a reasoning model.
        model_call = scope['method'] == 'POST' and (scope['path'] in MODEL_ROUTES or SPEECH_ROUTE.fullmatch(scope['path']) is not None)
        early_headers = {k.decode('latin1').lower(): v.decode('latin1') for k, v in scope['headers']}
        # Only a request that at least presents a Bearer credential may buffer a large audio body.
        # Node still performs the real token check; this keeps anonymous uploads at the JSON limit.
        if recording and not early_headers.get('authorization', '').startswith('Bearer '):
            return await respond(send, 401, {'error': 'unauthorized', 'message': 'A valid connector Bearer token is required.'})
        limit = AUDIO_LIMIT if recording else JSON_LIMIT
        body = bytearray()
        while True:
            event = await receive()
            if event['type'] == 'http.disconnect':
                return
            body.extend(event.get('body', b''))
            if len(body) > limit:
                message = 'Maximum audio upload is 8 MiB.' if recording else 'Maximum JSON request size is 16 KiB.'
                return await respond(send, 413, {'error': 'too_large', 'message': message})
            if not event.get('more_body', False):
                break
        headers = {k.decode('latin1').lower(): v.decode('latin1') for k, v in scope['headers']}
        # Modal's reverse proxy may rewrite Host; published URL is deployment configuration.
        host = os.environ.get('CONNECTOR_PUBLIC_HOST', headers.get('host', ''))
        if not re.fullmatch(r'[a-z0-9-]+(?:\.[a-z0-9-]+)?\.modal\.run', host):
            return await respond(send, 400, {'error': 'invalid_host'})
        # Only headers used by our API are passed on. Authorization stays in process memory.
        selected = {k: headers[k] for k in FORWARDED if k in headers}
        envelope = {'method': scope['method'], 'path': scope['path'], 'headers': selected,
                    'base_url': 'https://' + host, 'body_b64': base64.b64encode(body).decode()}
        loop = asyncio.get_running_loop()
        deadline = loop.time() + (MODEL_DEADLINE if model_call else READ_DEADLINE)
        remaining = lambda: max(0.1, deadline - loop.time())
        timing = Timing()
        if model_call:
            try:
                with timing.phase('model_wait'):
                    await asyncio.wait_for(model_lock.acquire(), timeout=remaining())
            except TimeoutError:
                timing.log(scope, 503)
                return await respond(send, 503, BUSY)
            try:
                response = await run(envelope, remaining, timing)
            finally:
                model_lock.release()
        else:
            response = await run(envelope, remaining, timing)
        if response is None:
            timing.log(scope, 503)
            return await respond(send, 503, BUSY)
        headers = [(k.lower().encode(), str(v).encode()) for k, v in response['headers'].items()]
        headers.append((b'server-timing', server_timing(timing.phases).encode()))
        await send({'type': 'http.response.start', 'status': response['status'], 'headers': headers})
        await send({'type': 'http.response.body', 'body': base64.b64decode(response['body_b64'])})
        timing.log(scope, response['status'])

    # Runs one worker under the database lock. Returns its response, or None when no success can be claimed.
    async def run(envelope, remaining, timing):
        held = False
        process = None
        try:
            # Inside the try: a request that cannot get the lock in time gets a 503, not an unhandled timeout.
            with timing.phase('lock_wait'):
                await asyncio.wait_for(lock.acquire(), timeout=remaining())
            held = True
            with timing.phase('reload'):
                await volume.reload.aio()
            with timing.phase('spawn'):
                process = await asyncio.create_subprocess_exec(
                    'node', worker_path,
                    stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
                    env={**os.environ, 'DB_PATH': database_path}, limit=32 * 1024 * 1024)
            process.stdin.write(json.dumps(envelope).encode() + b'\n')
            await process.stdin.drain()
            response = None
            worker = timing.start('worker')
            while response is None:
                line = await asyncio.wait_for(process.stdout.readline(), timeout=remaining())
                if not line:
                    raise RuntimeError('Node handler exited without a response')
                message = json.loads(line)
                # asyncio.Lock has no owner, so a phase out of order must never release another request's hold.
                if message.get('phase') in ('release', 'acquire') and (message['phase'] == 'release') != held:
                    raise RuntimeError('Worker phase out of order')
                if message.get('phase') == 'release':
                    # Worker closed the database; persist startup writes, then let other requests in.
                    with timing.phase('commit'):
                        await volume.commit.aio()
                    lock.release(); held = False
                elif message.get('phase') == 'acquire':
                    with timing.phase('lock_wait'):
                        await asyncio.wait_for(lock.acquire(), timeout=remaining())
                    held = True
                    with timing.phase('reload'):
                        await volume.reload.aio()
                    process.stdin.write(b'go\n')
                    await process.stdin.drain()
                elif 'response' in message:
                    response = message['response']
            with timing.phase('exit'):
                await asyncio.wait_for(process.wait(), timeout=remaining())
            timing.stop(worker)
            if process.returncode:
                raise RuntimeError('Node handler failed')
            # Node has checkpointed WAL and closed every DB handle. Commit before acknowledging writes.
            with timing.phase('commit'):
                await volume.commit.aio()
        except (Exception, asyncio.CancelledError) as exc:
            if process is not None and process.returncode is None:
                process.kill()
                # Close our end of stdin too; otherwise asyncio may wait forever for the pipe to disconnect.
                process.stdin.close()
                await process.wait()
            if isinstance(exc, asyncio.CancelledError):
                raise
            return None
        finally:
            if held:
                lock.release()
        return response
    return app
