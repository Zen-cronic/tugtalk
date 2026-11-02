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
// Prefetch: the moment a voice round's checked reply exists, its synthesis starts (prefetchSpeech), alongside the
// write and the commit. The audio is kept in this process's memory for a short while, keyed by the round and its
// account, so the speech request that follows gets the audio already made and the rest as it arrives.
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

// How long prefetched audio is kept, how many rounds at once, and the most audio kept for one round.
export const SPEECH_CACHE = { ttlMs: 120_000, entries: 8, maxBytes: 2 * 1024 * 1024 };

// Opens the provider stream once and keeps its chunks, so any number of readers (the speech route, the live socket)
// can replay what arrived and wait for the rest. The head settles once: { type } for audio, or { error } (an ApiError).
function speechEntry(user, language, open) {
  const entry = { user, language, at: Date.now(), chunks: [], bytes: 0, done: false, error: null, waiters: new Set() };
  const wake = () => { for (const w of entry.waiters) w(); entry.waiters.clear(); };
  const finish = error => { entry.done = true; entry.error = error; wake(); };
  entry.head = (async () => {
    let upstream;
    try { upstream = await open(); }
    catch (error) { const e = new ApiError(502, 'speech_failed', error.name === 'AbortError' || error.name === 'TimeoutError' ? 'Speech timed out.' : 'Speech request failed.'); finish(e); return { error: e }; }
    const type = (upstream.headers.get('content-type') ?? '').split(';')[0].trim().toLowerCase();
    if (!upstream.ok || !upstream.body || (type && !AUDIO_TYPES.includes(type))) {
      await upstream.body?.cancel().catch(() => {});
      const e = new ApiError(502, 'speech_failed', upstream.ok ? 'Speech returned something other than audio.' : `Speech returned HTTP ${upstream.status}.`);
      finish(e); return { error: e };
    }
    (async () => {
      try {
        for await (const chunk of upstream.body) {
          const buffer = Buffer.from(chunk);
          entry.bytes += buffer.length;
          if (entry.bytes > SPEECH_CACHE.maxBytes) throw new Error('Speech is longer than expected.');
          entry.chunks.push(buffer); wake();
        }
        finish(null);
      } catch (error) { await upstream.body.cancel?.().catch(() => {}); finish(error); }
    })();
    return { type: type === 'audio/x-wav' || !type ? 'audio/wav' : type };
  })();
  // Every chunk so far, then each new one; throws if the provider stream broke after its head.
  entry.read = async function* () {
    let i = 0;
    while (true) {
      while (i < entry.chunks.length) yield entry.chunks[i++];
      if (entry.done) { if (entry.error) throw entry.error; return; }
      await new Promise(resolve => entry.waiters.add(resolve));
    }
  };
  return entry;
}

export function createSpeechCache({ ttlMs = SPEECH_CACHE.ttlMs, entries: max = SPEECH_CACHE.entries } = {}) {
  const entries = new Map();
  const sweep = () => {
    const now = Date.now();
    for (const [id, e] of entries) if (now - e.at > ttlMs) entries.delete(id);
    while (entries.size > max) entries.delete(entries.keys().next().value);
  };
  return {
    put(roundId, entry) { entries.set(roundId, entry); sweep(); return entry; },
    // Only the account that made the round gets its audio.
    get(roundId, user) { sweep(); const e = entries.get(roundId); return e && e.user === user ? e : null; },
    delete(roundId) { entries.delete(roundId); },
    get size() { sweep(); return entries.size; }
  };
}
// One cache per process: the hosting worker and the local server each keep their own.
export const speechCache = createSpeechCache();

export function createSpeechModel({ env = process.env, fetchImpl = fetch, cache = speechCache } = {}) {
  const provider = SPEECH_PROVIDERS[env.SPEECH_PROVIDER];
  const model = {
    speechReady: () => Boolean(provider?.configured(env)),
    speechProvider: () => (provider ? env.SPEECH_PROVIDER : null),
    speechSupports: language => Boolean(provider?.languages.includes(language)),
    speechVoice: language => provider?.voice(env, language) ?? null,
    // Returns the provider's fetch Response; its body is the audio stream.
    async synthesize(text, { language = 'en', signal } = {}) {
      const { url, init } = provider.request(text, language, env);
      return fetchImpl(url, { ...init, signal });
    },
    // Starts synthesis for a round's checked question now and keeps the audio in memory; null when this round
    // cannot be voiced here (no provider, or no voice for its language). Bounded by SPEECH_TIMEOUT_MS.
    prefetchSpeech(roundId, user, text, language) {
      const line = String(text ?? '').slice(0, MAX_SPEECH_CHARS);
      if (!model.speechReady() || !model.speechSupports(language) || !line.trim()) return null;
      return cache.put(roundId, speechEntry(user, language, () => model.synthesize(line, { language, signal: AbortSignal.timeout(SPEECH_TIMEOUT_MS) })));
    },
    cachedSpeech: (roundId, user) => cache.get(roundId, user),
    dropSpeech: roundId => cache.delete(roundId)
  };
  return model;
}

// The audio headers for a spoken reply.
export const speechHeaders = (models, language, type, requestId) => ({ 'Content-Type': type, 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff',
  'X-Request-Id': requestId, 'X-Speech-Provider': models.speechProvider?.() ?? 'custom', 'X-Speech-Voice': models.speechVoice?.(language) ?? 'unknown' });

// Writes the response itself (it streams), so it returns nothing. Errors before the first byte are thrown as an
// ApiError for the handler's usual JSON error; a failure after the first byte ends the response early.
// Audio prefetched for this round is served from memory: what was already made goes out at once, then the rest.
// Otherwise the provider is called now. Either way it is the same stream object, read the same way.
// The hosting worker does not commit after this route (scripts/handle-request.mjs): its only write is the audit row,
// which goes out with the next committed write.
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
  let entry = models.cachedSpeech?.(round.id, user) ?? null;
  let controller = null;
  let reacquired = false;
  const acquire = async () => { if (!reacquired) { reacquired = true; await phases.acquire(); } };
  await phases.release();
  let timer;
  try {
    let head = entry ? await entry.head : null;
    // A prefetch that failed before any audio gets one fresh call, like any other request.
    if (!head || head.error) {
      if (entry) models.dropSpeech?.(round.id);
      controller = new AbortController();
      timer = setTimeout(() => controller.abort(), SPEECH_TIMEOUT_MS);
      entry = speechEntry(user, round.language, () => models.synthesize(text, { language: round.language, signal: controller.signal }));
      head = await entry.head;
    }
    if (head.error) throw head.error;
    // The client hanging up stops a call made for it (not a shared prefetch, which other readers may need).
    res.on?.('close', () => { if (!res.writableEnded) controller?.abort(); });
    res.writeHead(200, speechHeaders(models, round.language, head.type, requestId));
    let failed = null;
    try { for await (const chunk of entry.read()) res.write(chunk); }
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
