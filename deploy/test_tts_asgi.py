import json
import struct
import unittest
import wave
import io
from tts_asgi import create_tts_app, wav_bytes, MAX_TEXT

TOKEN = 'x' * 40


class TtsAsgiTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.calls = []
        def synthesize(text, language):
            self.calls.append((text, language))
            if text == 'boom':
                raise RuntimeError('secret text boom')
            return [0.0, 0.5, -0.5, 1.5], 16000
        self.app = create_tts_app(synthesize, TOKEN)

    async def call(self, path='/synthesize', body=b'', auth='Bearer ' + TOKEN, method='POST'):
        sent = []
        async def receive(): return {'type': 'http.request', 'body': body}
        async def send(event): sent.append(event)
        headers = [(b'authorization', auth.encode())] if auth else []
        await self.app({'type': 'http', 'method': method, 'path': path, 'headers': headers}, receive, send)
        return sent[0]['status'], dict(sent[0]['headers']), sent[1]['body']

    async def test_synthesizes_wav_with_the_shared_secret(self):
        status, headers, body = await self.call(body=json.dumps({'text': ' Et ensuite ? ', 'language': 'fr'}).encode())
        self.assertEqual(status, 200); self.assertEqual(headers[b'content-type'], b'audio/wav')
        with wave.open(io.BytesIO(body)) as w:
            self.assertEqual((w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()), (1, 2, 16000, 4))
            frames = struct.unpack('<4h', w.readframes(4))
        self.assertEqual(frames, (0, 16384, -16384, 32767), 'samples are clipped to [-1, 1]')
        self.assertEqual(self.calls, [('Et ensuite ?', 'fr')])

    async def test_refuses_without_the_secret_before_reading_or_synthesizing(self):
        for auth in (None, 'Bearer wrong', 'Bearer ' + TOKEN + 'x', TOKEN):
            status, _, _ = await self.call(body=b'{"text":"hi"}', auth=auth)
            self.assertEqual(status, 401, auth)
        self.assertEqual(self.calls, [])
        self.assertEqual((await self.call('/health', method='GET', auth=None))[0], 200)

    async def test_rejects_bad_bodies_and_hides_synthesis_errors(self):
        for body in (b'nope', b'[]', b'{"text":""}', json.dumps({'text': 'a' * (MAX_TEXT + 1)}).encode(), b'{"text":"hi","language":"de"}'):
            self.assertEqual((await self.call(body=body))[0], 400, body[:20])
        self.assertEqual((await self.call(body=b'x' * 5000))[0], 413)
        status, _, body = await self.call(body=b'{"text":"boom"}')
        self.assertEqual(status, 502); self.assertNotIn(b'boom', body)

    def test_requires_a_long_random_secret(self):
        with self.assertRaises(RuntimeError):
            create_tts_app(lambda t, l: ([], 16000), 'short')
        self.assertEqual(wav_bytes([], 16000)[:4], b'RIFF')


if __name__ == '__main__': unittest.main()
