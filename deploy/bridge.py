"""Minimal ASGI bridge. A response is released only after storage commits.

No framework dependency. Node executes the same tested API handler as local HTTP.
The Modal function must have max_containers=1; the lock serializes requests within it.
"""
import asyncio
import base64
import json
import os
import re


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
        body = bytearray()
        while True:
            event = await receive()
            if event['type'] == 'http.disconnect':
                return
            body.extend(event.get('body', b''))
            if len(body) > 16384:
                return await respond(send, 413, {'error': 'too_large', 'message': 'Maximum JSON request size is 16 KiB.'})
            if not event.get('more_body', False):
                break
        headers = {k.decode('latin1').lower(): v.decode('latin1') for k, v in scope['headers']}
        # Modal's reverse proxy may rewrite Host; published URL is deployment configuration.
        host = os.environ.get('CONNECTOR_PUBLIC_HOST', headers.get('host', ''))
        if not re.fullmatch(r'[a-z0-9-]+(?:\.[a-z0-9-]+)?\.modal\.run', host):
            return await respond(send, 400, {'error': 'invalid_host'})
        # Only headers used by our API are passed on. Authorization stays in process memory.
        selected = {k: headers[k] for k in ('authorization', 'content-type', 'idempotency-key') if k in headers}
        envelope = {'method': scope['method'], 'path': scope['path'], 'headers': selected,
                    'base_url': 'https://' + host, 'body_b64': base64.b64encode(body).decode()}
        async with lock:
            process = None
            try:
                await volume.reload.aio()
                process = await asyncio.create_subprocess_exec(
                    'node', worker_path,
                    stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
                    env={**os.environ, 'DB_PATH': database_path})
                output, _ = await asyncio.wait_for(process.communicate(json.dumps(envelope).encode()), timeout=20)
                if process.returncode:
                    raise RuntimeError('Node handler failed')
                response = json.loads(output)
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
        await send({'type': 'http.response.start', 'status': response['status'],
                    'headers': [(k.lower().encode(), str(v).encode()) for k, v in response['headers'].items()]})
        await send({'type': 'http.response.body', 'body': base64.b64decode(response['body_b64'])})
    return app
