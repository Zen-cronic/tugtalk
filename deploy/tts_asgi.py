"""Minimal ASGI app for the self-hosted Meta MMS-TTS voice. No framework dependency, so it is testable without
torch or Modal (deploy/test_tts_asgi.py); deploy/mms_tts_app.py wires it to the real models on Modal.

POST /synthesize  Authorization: Bearer <MMS_TTS_TOKEN>  {"text": str (<= 300 chars), "language": "en" | "fr"}
  200 audio/wav (mono 16-bit PCM at the model's rate), 400 bad body, 401 bad token, 413 too large, 502 synthesis failed.
GET /health       200 {"status": "ok"}

Only the main backend holds the shared secret. Text and audio are never logged or stored.
"""
import hmac
import io
import json
import wave

MAX_BODY = 4096
MAX_TEXT = 300
LANGUAGES = ('en', 'fr')


def wav_bytes(samples, rate):
    """Float samples in [-1, 1] to a mono 16-bit PCM WAV."""
    pcm = bytearray()
    for x in samples:
        v = max(-1.0, min(1.0, float(x)))
        pcm += int(round(v * 32767)).to_bytes(2, 'little', signed=True)
    out = io.BytesIO()
    with wave.open(out, 'wb') as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(int(rate)); w.writeframes(bytes(pcm))
    return out.getvalue()


def create_tts_app(synthesize, token):
    """synthesize(text, language) -> (float samples, sample rate). token: the shared secret (str)."""
    if not token or len(token) < 32:
        raise RuntimeError('MMS_TTS_TOKEN must be set to a random secret of at least 32 characters')
    expected = ('Bearer ' + token).encode()

    async def respond(send, status, body, content_type=b'application/json'):
        if isinstance(body, dict):
            body = json.dumps(body).encode()
        await send({'type': 'http.response.start', 'status': status,
                    'headers': [(b'content-type', content_type), (b'cache-control', b'no-store')]})
        await send({'type': 'http.response.body', 'body': body})

    async def app(scope, receive, send):
        if scope['type'] == 'lifespan':
            while True:
                event = await receive()
                if event['type'] == 'lifespan.startup':
                    await send({'type': 'lifespan.startup.complete'})
                elif event['type'] == 'lifespan.shutdown':
                    await send({'type': 'lifespan.shutdown.complete'})
                    return
        if scope['type'] != 'http':
            return
        if scope['method'] == 'GET' and scope['path'] == '/health':
            return await respond(send, 200, {'status': 'ok'})
        if scope['method'] != 'POST' or scope['path'] != '/synthesize':
            return await respond(send, 404, {'error': 'not_found'})
        headers = dict((k.lower(), v) for k, v in scope['headers'])
        # Constant-time comparison; the check runs before the body is read.
        if not hmac.compare_digest(headers.get(b'authorization', b''), expected):
            return await respond(send, 401, {'error': 'unauthorized'})
        body = bytearray()
        while True:
            event = await receive()
            if event['type'] == 'http.disconnect':
                return
            body.extend(event.get('body', b''))
            if len(body) > MAX_BODY:
                return await respond(send, 413, {'error': 'too_large'})
            if not event.get('more_body', False):
                break
        try:
            data = json.loads(body)
        except ValueError:
            return await respond(send, 400, {'error': 'invalid_json'})
        text = data.get('text') if isinstance(data, dict) else None
        language = data.get('language', 'en') if isinstance(data, dict) else None
        if not isinstance(text, str) or not text.strip() or len(text) > MAX_TEXT or language not in LANGUAGES:
            return await respond(send, 400, {'error': 'invalid_body', 'message': f'Send text (1-{MAX_TEXT} characters) and language en or fr.'})
        try:
            samples, rate = synthesize(text.strip(), language)
            audio = wav_bytes(samples, rate)
        except Exception:
            # The exception may carry the text; report only that synthesis failed.
            return await respond(send, 502, {'error': 'synthesis_failed'})
        return await respond(send, 200, audio, b'audio/wav')

    return app
