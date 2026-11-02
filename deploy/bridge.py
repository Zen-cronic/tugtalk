"""Minimal ASGI bridge. A write is answered only after storage commits.

No framework dependency. One long-lived Node worker (scripts/handle-request.mjs) runs the same tested API handler
as local HTTP for every request, over one database connection that stays open, so no request pays for a process
start or a database open.
The Modal function must have max_containers=1. This container is then the only writer of the volume, so the
volume is never reloaded while it runs, and the lock below serializes database access within it.
It accepts several inputs at once (@modal.concurrent), all on this one event loop.
A recording, screen-context or voice-round request releases the lock during its slow model calls, so reads and
ordinary writes are not queued behind inference.
Model routes take a second lock for their whole run, so only one such request runs at a time: a retry that arrives
while the first attempt is still running waits and then replays its receipt instead of paying for inference twice,
and the hourly counts stay exact. A model request whose client has stopped waiting still runs to the end, so the
retry finds its receipt.
Commits: every request except a GET is committed before it is answered, and a commit that failed is retried before
any later answer, so nothing is acknowledged that is not stored. Reads skip the commit.
Model routes get a time budget (budget_ms) that ends before the adapter's deadline, so they finish, or save a
partial result, while the client is still waiting.
The spoken reply streams: its audio is passed on chunk by chunk as the speech provider sends it. It is not committed
before its answer (its only write is an audit row, which goes out with the next commit), and it does not wait for the
model lock: it calls no paid model.
Live voice rounds are a WebSocket (WS /v1/voice-rounds/live, src/live-voice.mjs): one per hold, carried to the same
worker. The client's PCM frames are passed on as they arrive; the worker's events and spoken audio go back as they
happen, even while the round is being committed; a "saved" event follows only once the commit succeeded.
"""
import asyncio
import base64
import itertools
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
# Time kept back from a model route's budget for the write, the commit and the response.
COMMIT_RESERVE = 10
# How long past its deadline a request may keep the worker before the worker counts as stuck and is restarted.
GRACE = 25
MODEL_ROUTES = ('/v1/recordings', '/v1/screen-contexts', '/v1/voice-rounds')
# Routes whose body is a WAV upload (the audio limit, and a Bearer credential before buffering it).
AUDIO_ROUTES = ('/v1/recordings', '/v1/voice-rounds')
# A spoken reply calls a speech model but has no body. Its audio is streamed to the client.
SPEECH_ROUTE = re.compile(r'/v1/voice-rounds/[A-Za-z0-9-]{1,64}/speech')
# Re-measuring a session may re-transcribe its kept recording (src/remeasure.mjs), so it is a model route too.
REMEASURE_ROUTE = re.compile(r'/v1/sessions/[A-Za-z0-9-]{1,64}/remeasure')
# Timing log: one line per request with the route shape (ids replaced), the status and each phase in ms.
# Never the body, headers, query or ids.
ROUTE_ID = re.compile(r'(/v1/(?:goals|sessions|exercises|check-ins|screen-contexts|voice-rounds|media))/(?!live$)[^/]+')
# Live voice rounds over a WebSocket.
LIVE_ROUTE = '/v1/voice-rounds/live'
LIVE_START_TIMEOUT = 10   # the start frame must arrive this soon after the socket opens
LIVE_FRAME_LIMIT = 64 * 1024   # one PCM frame (the Mac sends about 4 KiB every 85 ms)
LIVE_DRAIN = 30   # after the answer, how long the spoken audio may keep the socket open
BUSY = {'error': 'storage_or_worker_unavailable',
        'message': 'Retry the identical request with the same Idempotency-Key; no success is claimed.'}


def route_label(method, path):
    return method + ' ' + ROUTE_ID.sub(r'\1/{id}', path)


def server_timing(phases):
    return ', '.join(f'{name};dur={ms:.1f}' for name, ms in phases.items())


class Timing:
    """Phase durations for one request, in ms. A phase that repeats (two lock waits) is summed."""
    def __init__(self):
        self.began = time.perf_counter()
        self.phases = {}

    def add(self, name, ms):
        self.phases[name] = self.phases.get(name, 0.0) + ms

    def phase(self, name):
        timing = self
        class Phase:
            def __enter__(self): self.t = time.perf_counter()
            def __exit__(self, *exc): timing.add(name, (time.perf_counter() - self.t) * 1000)
        return Phase()

    def header(self):
        return server_timing({**self.phases, 'total': (time.perf_counter() - self.began) * 1000})

    def log(self, scope, status):
        self.add('total', (time.perf_counter() - self.began) * 1000)
        line = {'timing': {k: round(v, 1) for k, v in self.phases.items()},
                'route': route_label(scope['method'], scope['path']), 'status': status}
        print(json.dumps(line), file=sys.stdout, flush=True)


class Worker:
    """The long-lived Node process. Each request gets an id and its own queue of messages from the worker."""
    def __init__(self, path, database_path):
        self.path, self.database_path = path, database_path
        self.process, self.queues, self.ids = None, {}, itertools.count(1)
        self.sinks = {}   # live rounds: events, audio and "closed" go straight to the client, not through the queue
        self.starts = 0

    @property
    def alive(self):
        return self.process is not None and self.process.returncode is None

    async def start(self):
        """Starts the process and waits for its ready line. Returns whether its bootstrap wrote to the database."""
        self.starts += 1
        process = await asyncio.create_subprocess_exec(
            'node', self.path,
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
            env={**os.environ, 'DB_PATH': self.database_path}, limit=32 * 1024 * 1024)
        try:
            ready = json.loads(await asyncio.wait_for(process.stdout.readline(), timeout=READ_DEADLINE) or b'{}')
            if not ready.get('ready'):
                raise RuntimeError('Node worker did not start')
        except (Exception, asyncio.CancelledError):
            await self.kill(process)
            raise
        # A fresh queue table per process: when this process ends, only its own requests are failed.
        self.process, self.queues = process, {}
        asyncio.get_running_loop().create_task(self.read(process, self.queues))
        return bool(ready.get('dirty'))

    async def read(self, process, queues):
        try:
            while True:
                line = await process.stdout.readline()
                if not line:
                    break
                message = json.loads(line)
                sink = self.sinks.get(message.get('id'))
                if sink is not None and ('event' in message or 'audio_out' in message or 'closed' in message):
                    sink(message)
                    continue
                queue = queues.get(message.get('id'))
                if queue is not None:
                    queue.put_nowait(message)
        except Exception:
            pass
        finally:
            # The process is gone: every request still waiting on it fails, and none claims success.
            try:
                await self.kill(process)
            except Exception:
                pass
            for queue in queues.values():
                queue.put_nowait({'failed': True, 'exited': True})
            for sink in list(self.sinks.values()):
                sink({'closed': True, 'exited': True})

    def open(self):
        rid, queue = f'r{next(self.ids)}', asyncio.Queue()
        self.queues[rid] = queue
        return rid, queue

    def close(self, rid):
        self.queues.pop(rid, None)

    async def send(self, message):
        self.process.stdin.write(json.dumps(message).encode() + b'\n')
        await self.process.stdin.drain()

    async def kill(self, process=None):
        process = process or self.process
        if process is not None and process.returncode is None:
            try:
                process.kill()
            except ProcessLookupError:
                pass
            # Close our end of stdin too; otherwise asyncio may wait forever for the pipe to disconnect.
            process.stdin.close()
            await process.wait()

    async def stop(self):
        """Lets the worker checkpoint and close the database, then exit."""
        if self.alive:
            self.process.stdin.close()
            try:
                await asyncio.wait_for(self.process.wait(), timeout=5)
            except TimeoutError:
                await self.kill()


def create_bridge(volume, *, worker_path='/app/scripts/handle-request.mjs', database_path='/data/connector.sqlite'):
    lock = asyncio.Lock()
    model_lock = asyncio.Lock()
    worker = Worker(worker_path, database_path)
    # A write the worker made that the volume does not hold yet. Cleared only by a successful commit.
    state = {'pending': False}

    async def respond(send, status, payload, timing=None):
        headers = [(b'content-type', b'application/json'), (b'cache-control', b'no-store')]
        if timing is not None:
            headers.append((b'server-timing', timing.header().encode()))
        await send({'type': 'http.response.start', 'status': status, 'headers': headers})
        await send({'type': 'http.response.body', 'body': json.dumps(payload).encode()})

    # Both run with the database lock held.
    async def ensure_worker(timing):
        if not worker.alive:
            with timing.phase('worker_start'):
                dirty = await worker.start()
            state['pending'] = state['pending'] or dirty

    async def settle(timing):
        """Commits any uncommitted write. False when the commit failed: then nothing may be acknowledged."""
        if not state['pending']:
            return True
        try:
            with timing.phase('commit'):
                await volume.commit.aio()
        except Exception:
            return False
        state['pending'] = False
        return True

    async def startup():
        # Start the worker before the first request arrives, so a cold start pays for it once, off the request path.
        timing = Timing()
        async with lock:
            await ensure_worker(timing)
            await settle(timing)

    async def app(scope, receive, send):
        if scope['type'] == 'lifespan':
            while True:
                event = await receive()
                if event['type'] == 'lifespan.startup':
                    try:
                        await startup()
                    except Exception:
                        pass  # the first request starts the worker instead
                    await send({'type': 'lifespan.startup.complete'})
                elif event['type'] == 'lifespan.shutdown':
                    try:
                        async with lock:
                            await worker.stop()
                            await settle(Timing())
                    except Exception:
                        pass
                    await send({'type': 'lifespan.shutdown.complete'})
                    return
            return
        if scope['type'] == 'websocket':
            return await live(scope, receive, send)
        if scope['type'] != 'http':
            return
        recording = scope['method'] == 'POST' and scope['path'] in AUDIO_ROUTES
        speech = scope['method'] == 'POST' and SPEECH_ROUTE.fullmatch(scope['path']) is not None
        # A screen context is a small JSON body (JSON limit) but waits on a reasoning model. The spoken reply gets the
        # long deadline but not the model lock.
        model_call = scope['method'] == 'POST' and (scope['path'] in MODEL_ROUTES or speech or REMEASURE_ROUTE.fullmatch(scope['path']) is not None)
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
        if speech:
            envelope['stream'] = True
        loop = asyncio.get_running_loop()
        limit_s = MODEL_DEADLINE if model_call else READ_DEADLINE
        deadline = loop.time() + limit_s
        remaining = lambda: max(0.1, deadline - loop.time())
        timing = Timing()
        # Streaming: the head and each chunk go straight to the client, unless it has already been answered 503.
        stream = {'started': False, 'closed': False}

        async def on_head(head):
            if stream['closed']:
                return
            stream['started'] = True
            pairs = [(k.lower().encode(), str(v).encode()) for k, v in (head.get('headers') or {}).items()]
            pairs.append((b'server-timing', timing.header().encode()))
            await send({'type': 'http.response.start', 'status': head['status'], 'headers': pairs})

        async def on_chunk(data):
            if stream['started'] and not stream['closed']:
                try:
                    await send({'type': 'http.response.body', 'body': data, 'more_body': True})
                except Exception:
                    stream['closed'] = True

        task = loop.create_task(drive(envelope, model_call and not speech, deadline, deadline + GRACE, timing, on_head, on_chunk))
        try:
            message = await asyncio.wait_for(asyncio.shield(task), timeout=remaining())
        except TimeoutError:
            if stream['started']:
                message = await task
            else:
                # The client gets a 503 now. A model request keeps running, so its retry can replay the receipt.
                stream['closed'] = True
                message = None
        if stream['started']:
            # Audio already went out; end the body. A stream cut short upstream simply ends early.
            last = base64.b64decode(message['response']['body_b64']) if message and not message.get('aborted') else b''
            if not stream['closed']:
                try:
                    await send({'type': 'http.response.body', 'body': last, 'more_body': False})
                except Exception:
                    pass
            return timing.log(scope, 200 if message else 503)
        if message is None or message.get('aborted'):
            await respond(send, 503, BUSY, timing)
            return timing.log(scope, 503)
        response = message['response']
        pairs = [(k.lower().encode(), str(v).encode()) for k, v in (response.get('headers') or {}).items()]
        pairs.append((b'server-timing', timing.header().encode()))
        await send({'type': 'http.response.start', 'status': response['status'], 'headers': pairs})
        await send({'type': 'http.response.body', 'body': base64.b64decode(response['body_b64'])})
        timing.log(scope, response['status'])

    async def drive(envelope, model_call, deadline, hard_deadline, timing, on_head, on_chunk):
        """Runs one request on the worker. Returns its final message, or None when no success can be claimed."""
        loop = asyncio.get_running_loop()
        until = lambda limit: max(0.1, limit - loop.time())
        model_held = held = False
        rid = None
        try:
            # Inside the try: a request that cannot get a lock in time gets a 503, not an unhandled timeout.
            if model_call:
                with timing.phase('model_wait'):
                    await asyncio.wait_for(model_lock.acquire(), timeout=until(deadline))
                model_held = True
            with timing.phase('lock_wait'):
                await asyncio.wait_for(lock.acquire(), timeout=until(deadline))
            held = True
            await ensure_worker(timing)
            rid, queue = worker.open()
            start = {'id': rid, 'envelope': envelope}
            if model_call:
                # The handler's time budget ends before this request's deadline, with room to save and commit.
                start['budget_ms'] = max(0, int((deadline - loop.time() - COMMIT_RESERVE) * 1000))
            await worker.send(start)
            while True:
                try:
                    message = await asyncio.wait_for(queue.get(), timeout=until(hard_deadline))
                except TimeoutError:
                    # Far past the deadline. Holding the database: the worker is stuck, so restart it.
                    if held:
                        await worker.kill()
                    return None
                if message.get('failed'):
                    if held and message.get('dirty'):
                        state['pending'] = True
                    return None
                phase = message.get('phase')
                # asyncio.Lock has no owner, so a phase out of order must never release another request's hold.
                if phase in ('release', 'acquire') and (phase == 'release') != held:
                    raise RuntimeError('Worker phase out of order')
                if phase == 'release':
                    lock.release(); held = False
                elif phase == 'acquire':
                    with timing.phase('lock_wait'):
                        await asyncio.wait_for(lock.acquire(), timeout=until(hard_deadline))
                    held = True
                    await worker.send({'id': rid, 'go': True})
                elif 'head' in message:
                    await on_head(message['head'])
                elif 'chunk' in message:
                    await on_chunk(base64.b64decode(message['chunk']))
                elif 'response' in message:
                    if not held:
                        raise RuntimeError('Worker answered without the database lock')
                    for name, ms in (message.get('timing') or {}).items():
                        if name in ('handler', 'checkpoint', 'close', 'reopen'):
                            timing.add(name, float(ms))
                    if message.get('dirty'):
                        state['pending'] = True
                    # Commit before acknowledging: a failed commit means no success is claimed.
                    return message if await settle(timing) else None
        except (Exception, asyncio.CancelledError) as exc:
            if held:
                # The worker may be mid-request on the database; restart it rather than hand the lock on.
                await worker.kill()
            if isinstance(exc, asyncio.CancelledError):
                raise
            return None
        finally:
            if rid is not None:
                worker.close(rid)
            if held:
                lock.release()
            if model_held:
                model_lock.release()

    async def live(scope, receive, send):
        """One live voice round: one WebSocket per hold. Never answers 'saved' before the commit."""
        event = await receive()
        if event['type'] != 'websocket.connect':
            return
        headers = {k.decode('latin1').lower(): v.decode('latin1') for k, v in scope['headers']}
        host = os.environ.get('CONNECTOR_PUBLIC_HOST', headers.get('host', ''))
        # Refused before the socket is accepted (the client sees HTTP 403): wrong path or host, or no Bearer credential.
        # Node checks the credential itself before any provider is called.
        if (scope['path'] != LIVE_ROUTE or not re.fullmatch(r'[a-z0-9-]+(?:\.[a-z0-9-]+)?\.modal\.run', host)
                or not headers.get('authorization', '').startswith('Bearer ')):
            await send({'type': 'websocket.close', 'code': 1008})
            return
        await send({'type': 'websocket.accept'})
        loop = asyncio.get_running_loop()
        timing = Timing()
        out = asyncio.Queue()   # ('text', str) | ('bytes', bytes) | ('close', code)
        session = {'client_gone': False, 'closed': asyncio.Event(), 'status': None}

        async def sender():
            while True:
                kind, value = await out.get()
                try:
                    if kind == 'close':
                        await send({'type': 'websocket.close', 'code': value})
                        return
                    await send({'type': 'websocket.send', kind: value})
                except Exception:
                    session['client_gone'] = True
                    return

        def text(payload):
            out.put_nowait(('text', json.dumps(payload)))

        def finish(code, label_status):
            session['status'] = label_status
            out.put_nowait(('close', code))

        sending = loop.create_task(sender())
        deadline = loop.time() + MODEL_DEADLINE
        until = lambda limit: max(0.1, limit - loop.time())
        try:
            first = await asyncio.wait_for(receive(), timeout=LIVE_START_TIMEOUT)
            start = json.loads(first.get('text') or 'null') if first['type'] == 'websocket.receive' else None
            if not isinstance(start, dict) or start.get('type') != 'start':
                raise ValueError('no start frame')
        except (Exception, asyncio.CancelledError):
            text({'type': 'error', 'status': 400, 'error': 'invalid_body', 'message': 'The first frame must be {"type": "start", ...}.'})
            finish(1008, 400)
            await sending
            return timing.log({'method': 'WS', 'path': LIVE_ROUTE}, 400)

        envelope = {'method': 'POST', 'path': LIVE_ROUTE, 'headers': {'authorization': headers['authorization']},
                    'base_url': 'https://' + host, 'body_b64': '', 'live': start}
        model_held = held = False
        rid = None
        pump = None

        def sink(message):
            if 'event' in message:
                text(message['event'])
            elif 'audio_out' in message:
                out.put_nowait(('bytes', base64.b64decode(message['audio_out'])))
            elif 'closed' in message:
                session['closed'].set()

        async def pump_client():
            """Client frames to the worker: PCM, then "end". A closed socket cancels a hold that was not released."""
            total = 0
            try:
                while True:
                    event = await receive()
                    if event['type'] == 'websocket.disconnect':
                        break
                    data = event.get('bytes')
                    if data is not None:
                        total += len(data)
                        if len(data) > LIVE_FRAME_LIMIT or total > AUDIO_LIMIT:
                            await worker.send({'id': rid, 'end': True})
                            continue
                        await worker.send({'id': rid, 'audio': base64.b64encode(data).decode()})
                    elif event.get('text'):
                        try:
                            kind = json.loads(event['text']).get('type')
                        except Exception:
                            kind = None
                        if kind == 'end':
                            await worker.send({'id': rid, 'end': True})
            except Exception:
                pass
            session['client_gone'] = True
            try:
                await worker.send({'id': rid, 'cancel': True})
            except Exception:
                pass

        try:
            with timing.phase('model_wait'):
                await asyncio.wait_for(model_lock.acquire(), timeout=until(deadline))
            model_held = True
            with timing.phase('lock_wait'):
                await asyncio.wait_for(lock.acquire(), timeout=until(deadline))
            held = True
            await ensure_worker(timing)
            rid, queue = worker.open()
            worker.sinks[rid] = sink
            await worker.send({'id': rid, 'envelope': envelope,
                               'budget_ms': max(0, int((deadline - loop.time() - COMMIT_RESERVE) * 1000))})
            pump = loop.create_task(pump_client())
            message = None
            while True:
                try:
                    message = await asyncio.wait_for(queue.get(), timeout=until(deadline + GRACE))
                except TimeoutError:
                    if held:
                        await worker.kill()
                    message = None
                    break
                if message.get('failed'):
                    if held and message.get('dirty'):
                        state['pending'] = True
                    message = None
                    break
                phase = message.get('phase')
                if phase in ('release', 'acquire') and (phase == 'release') != held:
                    raise RuntimeError('Worker phase out of order')
                if phase == 'release':
                    lock.release(); held = False
                elif phase == 'acquire':
                    with timing.phase('lock_wait'):
                        await asyncio.wait_for(lock.acquire(), timeout=until(deadline + GRACE))
                    held = True
                    await worker.send({'id': rid, 'go': True})
                elif 'response' in message:
                    if not held:
                        raise RuntimeError('Worker answered without the database lock')
                    for name, ms in (message.get('timing') or {}).items():
                        if name in ('handler', 'checkpoint', 'close', 'reopen'):
                            timing.add(name, float(ms))
                    if message.get('dirty'):
                        state['pending'] = True
                    if not await settle(timing):
                        message = None
                    break
            if held:
                lock.release(); held = False
            if model_held:
                model_lock.release(); model_held = False
            if message is None:
                text({'type': 'error', 'status': 503, **BUSY})
                finish(1011, 503)
            else:
                response = message['response']
                body = json.loads(base64.b64decode(response['body_b64']) or b'{}')
                status = response['status']
                text({'type': 'saved', **body} if status == 200 else {'type': 'error', 'status': status, **body})
                # The spoken audio may still be streaming; the socket closes once it is done or the client leaves.
                try:
                    await asyncio.wait_for(session['closed'].wait(), timeout=LIVE_DRAIN)
                except TimeoutError:
                    pass
                finish(1000 if status == 200 else 1008, status)
        except (Exception, asyncio.CancelledError) as exc:
            if held:
                await worker.kill()
            if not session['status']:
                text({'type': 'error', 'status': 503, **BUSY})
                finish(1011, 503)
            if isinstance(exc, asyncio.CancelledError):
                raise
        finally:
            if rid is not None:
                worker.close(rid)
                worker.sinks.pop(rid, None)
            if held:
                lock.release()
            if model_held:
                model_lock.release()
            if pump is not None and not pump.done():
                pump.cancel()
        try:
            await asyncio.wait_for(sending, timeout=5)
        except (Exception, asyncio.CancelledError):
            sending.cancel()
        timing.log({'method': 'WS', 'path': LIVE_ROUTE}, session['status'] or 503)

    app.worker = worker
    return app
