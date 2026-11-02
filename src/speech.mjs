// Spoken replies: POST /v1/voice-rounds/{round_id}/speech turns a stored round's reply.question into audio with a
// Meta voice and pipes it back as it arrives. Meta's Model API has no text-to-speech model, so the provider is one
// of two other Meta voices, chosen by env SPEECH_PROVIDER:
//   wit  Wit.ai text-to-speech (the service behind Meta's Voice SDK), needs WIT_TTS_TOKEN; WIT_TTS_VOICE optional.
//        English voices only (en_US, en_CA, en_GB), so a French round gets 503 and the Mac's own voice.
//   mms  Meta MMS-TTS (facebook/mms-tts-eng, facebook/mms-tts-fra), self-hosted (deploy/mms_tts_app.py);
//        needs MMS_TTS_URL and MMS_TTS_TOKEN.
// Unset or unconfigured: 503 speech_unconfigured, and the Mac speaks the question with an on-device Apple voice.
// Only text this server produced (the checked question in the stored round) is sent; the client sends no text.
// Audio is never stored, and neither text nor audio is logged.
import { ApiError } from './store.mjs';

export const SPEECH_PATH = /^\/v1\/voice-rounds\/([A-Za-z0-9-]{1,64})\/speech$/;
export const SPEECH_RATE_LIMIT = { requests: 60, windowMs: 60 * 60 * 1000 };
export const SPEECH_TIMEOUT_MS = 20_000;
export const MAX_SPEECH_CHARS = 300;
export const WIT_DEFAULT_VOICE = 'wit$Rebecca';
const AUDIO_TYPES = ['audio/wav', 'audio/x-wav', 'audio/mpeg', 'audio/pcm'];

// Each provider builds one HTTP request. wit was checked live on Nov 2: voice names carry a "wit$" prefix
// (GET /voices), WAV arrives in one burst once synthesis ends, and MP3 streams (first byte in about 0.4 s against
// about 3 s for WAV), so wit asks for MP3. The mms request matches deploy/tts_asgi.py.
export const SPEECH_PROVIDERS = {
  wit: {
    model: 'wit.ai synthesize',
    configured: env => Boolean(env.WIT_TTS_TOKEN),
    languages: ['en'],
    voice: env => env.WIT_TTS_VOICE || WIT_DEFAULT_VOICE,
    request: (text, language, env) => ({
      url: 'https://api.wit.ai/synthesize?v=20240304',
      init: { method: 'POST', headers: { Authorization: `Bearer ${env.WIT_TTS_TOKEN}`, 'Content-Type': 'application/json', Accept: 'audio/mpeg' },
        body: JSON.stringify({ q: text, voice: env.WIT_TTS_VOICE || WIT_DEFAULT_VOICE }) } })
  },
  mms: {
    model: 'facebook/mms-tts',
    configured: env => Boolean(env.MMS_TTS_URL && env.MMS_TTS_TOKEN),
    languages: ['en', 'fr'],
    voice: (env, language = 'en') => `facebook/mms-tts-${language === 'fr' ? 'fra' : 'eng'}`,
    request: (text, language, env) => ({
      url: `${env.MMS_TTS_URL.replace(/\/$/, '')}/synthesize`,
      init: { method: 'POST', headers: { Authorization: `Bearer ${env.MMS_TTS_TOKEN}`, 'Content-Type': 'application/json', Accept: 'audio/wav' },
        body: JSON.stringify({ text, language }) } })
  }
};

export function createSpeechModel({ env = process.env, fetchImpl = fetch } = {}) {
  const provider = SPEECH_PROVIDERS[env.SPEECH_PROVIDER];
  return {
    speechReady: () => Boolean(provider?.configured(env)),
    speechProvider: () => (provider ? env.SPEECH_PROVIDER : null),
    speechSupports: language => Boolean(provider?.languages.includes(language)),
    speechVoice: language => provider?.voice(env, language) ?? null,
    // Returns the provider's fetch Response; its body is the audio stream.
    async synthesize(text, { language = 'en', signal } = {}) {
      const { url, init } = provider.request(text, language, env);
      return fetchImpl(url, { ...init, signal });
    }
  };
}

// Writes the response itself (it streams), so it returns nothing. Errors before the first byte are thrown as an
// ApiError for the handler's usual JSON error; a failure after the first byte ends the response early.
export async function handleSpeech(store, models, user, roundId, { res, requestId, phases, audit }) {
  if (typeof models.synthesize !== 'function' || (models.speechReady && !models.speechReady()))
    throw new ApiError(503, 'speech_unconfigured', 'Spoken replies are not configured on this deployment; speak the question on the device.');
  const round = store.get(user, 'voice-rounds', roundId);
  if (round.deleted) throw new ApiError(404, 'not_found', 'Record not found.');
  const text = String(round.reply?.question ?? '').slice(0, MAX_SPEECH_CHARS);
  if (!text.trim()) throw new ApiError(404, 'not_found', 'This round has no question to speak.');
  if (models.speechSupports && !models.speechSupports(round.language))
    throw new ApiError(503, 'speech_unconfigured', `No ${round.language} voice is configured; speak the question on the device.`);
  // The same hourly budget as voice rounds, counted on its own: one spoken reply per round at that pace.
  if (store.recentRequestsMatching(user, 'POST', '/v1/voice-rounds/%/speech', [200, 502], SPEECH_RATE_LIMIT.windowMs) >= SPEECH_RATE_LIMIT.requests)
    throw new ApiError(429, 'rate_limited', `At most ${SPEECH_RATE_LIMIT.requests} spoken replies per hour.`);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), SPEECH_TIMEOUT_MS);
  // The client hanging up stops the provider stream too.
  res.on?.('close', () => { if (!res.writableEnded) controller.abort(); });
  let reacquired = false;
  const acquire = async () => { if (!reacquired) { reacquired = true; await phases.acquire(); } };
  await phases.release();
  try {
    let upstream;
    try { upstream = await models.synthesize(text, { language: round.language, signal: controller.signal }); }
    catch (error) { throw new ApiError(502, 'speech_failed', error.name === 'AbortError' ? 'Speech timed out.' : 'Speech request failed.'); }
    const type = (upstream.headers.get('content-type') ?? '').split(';')[0].trim().toLowerCase();
    if (!upstream.ok || !upstream.body || (type && !AUDIO_TYPES.includes(type))) {
      await upstream.body?.cancel().catch(() => {});
      throw new ApiError(502, 'speech_failed', upstream.ok ? 'Speech returned something other than audio.' : `Speech returned HTTP ${upstream.status}.`);
    }
    res.writeHead(200, { 'Content-Type': type === 'audio/x-wav' || !type ? 'audio/wav' : type, 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff',
      'X-Request-Id': requestId, 'X-Speech-Provider': models.speechProvider?.() ?? 'custom', 'X-Speech-Voice': models.speechVoice?.(round.language) ?? 'unknown' });
    let failed = null;
    try { for await (const chunk of upstream.body) res.write(chunk); }
    catch (error) { failed = error; }
    await acquire();
    // The audit row records route and status; its hash is of a fixed label, never of the audio or the text.
    audit(200, `speech ${round.id} ${failed ? 'cut short' : 'complete'}`);
    if (failed) res.destroy?.(failed); else res.end();
  } finally {
    clearTimeout(timer);
    await acquire();
  }
}
