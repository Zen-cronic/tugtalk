"""Minimal ASGI bridge. A response is released only after storage commits.

No framework dependency. Node executes the same tested API handler as local HTTP.
The Modal function must have max_containers=1; the lock serializes database access within it.
A recording worker releases the lock during its slow model calls (see scripts/handle-request.mjs),
so reads are not queued behind inference.
"""
import asyncio
import base64
import json
import os
import re

JSON_LIMIT = 16384
AUDIO_LIMIT = 8 * 1024 * 1024  # matches src/capture.mjs MAX_AUDIO_BYTES
FORWARDED = ('authorization', 'content-type', 'idempotency-key',
             'x-goal-id', 'x-language', 'x-capture-device', 'x-occurred-at')


def create_bridge(volume, *, worker_path='/app/scripts/handle-request.mjs', database_path='/data/connector.sqlite'):
    lock = asyncio.Lock()

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
        recording = scope['method'] == 'POST' and scope['path'] == '/v1/recordings'
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
        deadline = loop.time() + (150 if recording else 20)
        remaining = lambda: max(0.1, deadline - loop.time())
        await asyncio.wait_for(lock.acquire(), timeout=remaining())
        held = True
        process = None
        try:
            await volume.reload.aio()
            process = await asyncio.create_subprocess_exec(
                'node', worker_path,
                stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
                env={**os.environ, 'DB_PATH': database_path}, limit=32 * 1024 * 1024)
            process.stdin.write(json.dumps(envelope).encode() + b'\n')
            await process.stdin.drain()
            response = None
            while response is None:
                line = await asyncio.wait_for(process.stdout.readline(), timeout=remaining())
                if not line:
                    raise RuntimeError('Node handler exited without a response')
                message = json.loads(line)
                if message.get('phase') == 'release':
                    # Worker closed the database; persist startup writes, then let other requests in.
                    await volume.commit.aio()
                    lock.release(); held = False
                elif message.get('phase') == 'acquire':
                    await asyncio.wait_for(lock.acquire(), timeout=remaining())
                    held = True
                    await volume.reload.aio()
                    process.stdin.write(b'go\n')
                    await process.stdin.drain()
                elif 'response' in message:
                    response = message['response']
            await asyncio.wait_for(process.wait(), timeout=remaining())
            if process.returncode:
                raise RuntimeError('Node handler failed')
            # Node has checkpointed WAL and closed every DB handle. Commit before acknowledging writes.
            await volume.commit.aio()
        except (Exception, asyncio.CancelledError) as exc:
            if process is not None and process.returncode is None:
                process.kill()
                await process.wait()
            if isinstance(exc, asyncio.CancelledError):
                raise
            return await respond(send, 503, {'error': 'storage_or_worker_unavailable',
                                           'message': 'Retry the identical request with the same Idempotency-Key; no success is claimed.'})
        finally:
            if held:
                lock.release()
        await send({'type': 'http.response.start', 'status': response['status'],
                    'headers': [(k.lower().encode(), str(v).encode()) for k, v in response['headers'].items()]})
        await send({'type': 'http.response.body', 'body': base64.b64decode(response['body_b64'])})
    return app
