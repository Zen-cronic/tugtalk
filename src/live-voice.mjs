// Live voice rounds: the Mac streams the answer while the key is held, and Meta transcribes it as it arrives.
// The Mac opens one WebSocket per hold to WS /v1/voice-rounds/live (the hosting adapter, deploy/bridge.py, carries it to
// the long-lived worker). Its first frame is a JSON start message with the round's parameters; then binary frames of
// 24 kHz mono 16-bit PCM; then {"type": "end"} on release. The connector key is checked, and every check a WAV round
// makes before a paid call is made, before Meta's socket is opened. Meta's key never leaves the server.
//
// On release the final transcript is usually ready within a few hundred milliseconds, so the reply call starts at
// once. The reply goes back as an event the moment code has checked it, and its spoken audio follows as binary frames
// while the round is written and committed; a "saved" event (the same body as POST /v1/voice-rounds) comes last, after
// the commit. So text and speech arrive before the acknowledgement, and nothing is called saved before it is.
//
// Same round, same rules: the audio is never stored, the round's idempotency fingerprint is the one a WAV upload of
// the same samples has (so the Mac's fallback upload with the same key replays a round that was saved), the hourly
// limit counts it, and it shares the request's time budget. If Meta's socket fails, the server transcribes the same
// audio with the file endpoint instead, so a live round still answers.
import { randomUUID } from 'node:crypto';
import { ApiError } from './store.mjs';
import { TRANSCRIBE_MODEL, LANGUAGES, MAX_AUDIO_BYTES, inspectWav } from './capture.mjs';
import { voiceParams, prepareVoiceRound, replyToAnswer, saveVoiceRound, voiceFingerprint, voiceResponse, VOICE_ROUNDS_PATH } from './voice.mjs';
import { createBudget, MIN_START_MS } from './budget.mjs';
import { parseCameraMetrics } from './camera-metrics.mjs';

export const LIVE_PATH = '/v1/voice-rounds/live';
export const REALTIME_URL = 'wss://api.meta.ai/v1/asr/realtime';
export const PCM_RATE = 24_000;
const BYTES_PER_MS = PCM_RATE * 2 / 1000;
// Meta closes a stream more than 5 s ahead of real time; this stays well inside it.
export const MAX_AHEAD_MS = 3_000;
export const HANDSHAKE_TIMEOUT_MS = 5_000;
// After endStream: how long to wait for the last turn. Without it the round uses the file endpoint on the full audio.
export const FINAL_TIMEOUT_MS = 2_500;
// A hold the client never ends is ended here (the Mac caps a hold at 60 s).
export const MAX_HOLD_MS = 120_000;
export const MAX_LIVE_BYTES = MAX_AUDIO_BYTES - 44;
const KEY = /^[A-Za-z0-9_-]{8,128}$/;

// The WAV a client would upload for these samples: the canonical 44-byte header the Mac writes, then the samples.
export function wavFromPcm(pcm, rate = PCM_RATE) {
  const h = Buffer.alloc(44);
  h.write('RIFF', 0); h.writeUInt32LE(36 + pcm.length, 4); h.write('WAVE', 8); h.write('fmt ', 12); h.writeUInt32LE(16, 16);
  h.writeUInt16LE(1, 20); h.writeUInt16LE(1, 22); h.writeUInt32LE(rate, 24); h.writeUInt32LE(rate * 2, 28); h.writeUInt16LE(2, 32); h.writeUInt16LE(16, 34);
  h.write('data', 36); h.writeUInt32LE(pcm.length, 40);
  return Buffer.concat([h, pcm]);
}

// The start frame carries what a WAV round sends in headers, with the same checks.
export function liveStart(start) {
  if (!start || typeof start !== 'object' || start.type !== 'start') throw new ApiError(400, 'invalid_body', 'The first frame must be {"type": "start", ...}.');
  const key = start.idempotency_key;
  if (typeof key !== 'string' || !KEY.test(key)) throw new ApiError(400, 'idempotency_required', 'Provide idempotency_key: 8–128 letters, digits, underscores or hyphens.');
  const text = v => (v === undefined || v === null ? undefined : String(v));
  // need and reply_mode are X-Counterpart-Need and X-Reply-Mode (src/counterpart.mjs).
  const headers = Object.fromEntries(Object.entries({ 'x-language': text(start.language), 'x-goal-id': text(start.goal_id), 'x-screen-context-id': text(start.screen_context_id),
    'x-prompt-ended-at': text(start.prompt_ended_at), 'x-occurred-at': text(start.occurred_at), 'x-counterpart-need': text(start.need),
    'x-reply-mode': text(start.reply_mode) }).filter(([, v]) => v !== undefined));
  // speech: false when the Mac speaks the reply with its own voice; the server then makes no audio.
  return { key, params: voiceParams(headers), speak: start.speech !== false };
}

// Meta realtime transcription for one hold. send() queues PCM (sent once the handshake is acknowledged, never more than
// MAX_AHEAD_MS ahead of real time); finish() waits for the queue to drain, sends endStream, and resolves with the same
// shape as the file endpoint's result. Fails closed: any error, an unexpected close, or no final turn within
// FINAL_TIMEOUT_MS of endStream makes finish() reject, and the caller falls back to the file path.
// maxAheadMs, finalTimeoutMs and handshakeTimeoutMs are options so tests can run the pacing in milliseconds.
export function createRealtimeModel({ env = process.env, WebSocketImpl = globalThis.WebSocket, url = REALTIME_URL, clock = () => performance.now(),
  maxAheadMs = MAX_AHEAD_MS, finalTimeoutMs = FINAL_TIMEOUT_MS, handshakeTimeoutMs = HANDSHAKE_TIMEOUT_MS } = {}) {
  return {
    realtimeReady: () => Boolean(env.MODEL_API_KEY && WebSocketImpl),
    openRealtime({ language = 'en', sessionId, onPartial = () => {} } = {}) {
      const ws = new WebSocketImpl(`${url}?sessionId=${encodeURIComponent(sessionId)}`);
      ws.binaryType = 'arraybuffer';
      const turns = new Map();
      const queue = [];
      let acked = false, failed = null, finished = false, ended = false, endSent = false, sentBytes = 0, firstSend = null, pumpTimer = null, providerSession = null;
      // receivedBytes: every byte given to send(), queued or sent. finalReceived: the last turn really arrived (not a failure).
      let receivedBytes = 0, finalReceived = false;
      let settleFinal, settleDrained, partial = '';
      const finalSeen = new Promise(r => { settleFinal = r; });
      const final = () => { finalReceived = true; settleFinal(); };
      // Settles once endStream is sent (every queued byte went first), or on failure.
      const drained = new Promise(r => { settleDrained = r; });
      let readyResolve, readyReject;
      const ready = new Promise((resolve, reject) => { readyResolve = resolve; readyReject = reject; });
      ready.catch(() => {});
      const handshakeTimer = setTimeout(() => fail('handshake timed out'), handshakeTimeoutMs);
      function fail(reason) {
        if (failed || finished) return;
        failed = reason; clearTimeout(handshakeTimer); clearTimeout(pumpTimer);
        readyReject(new Error(reason)); settleFinal(); settleDrained();
        try { ws.close(); } catch {}
      }
      const turn = id => { if (!turns.has(id)) turns.set(id, { turn_id: id, start_ms: null, end_ms: null, transcript: null }); return turns.get(id); };
      const text = () => [...turns.values()].sort((a, b) => a.turn_id - b.turn_id).map(t => t.transcript ?? '').concat(partial ? [partial] : []).join(' ').replace(/\s+/g, ' ').trim();
      function pump() {
        clearTimeout(pumpTimer);
        if (!acked || failed) return;
        while (queue.length) {
          const now = clock();
          const ahead = sentBytes / BYTES_PER_MS - (firstSend === null ? 0 : now - firstSend);
          if (ahead > maxAheadMs) { pumpTimer = setTimeout(pump, Math.ceil(ahead - maxAheadMs)); return; }
          const chunk = queue.shift();
          firstSend ??= now;
          try { ws.send(chunk); } catch { fail('send failed'); return; }
          sentBytes += chunk.length;
        }
        if (ended && !endSent) { endSent = true; try { ws.send(JSON.stringify({ type: 'endStream' })); settleDrained(); } catch { fail('send failed'); } }
      }
      ws.onopen = () => {
        try {
          ws.send(JSON.stringify({ authorization: { accessToken: `Bearer ${env.MODEL_API_KEY}` }, audioEncoding: 'PCM_24KHZ', model: TRANSCRIBE_MODEL,
            mode: 'ENDPOINTING', partialMode: 'CUMULATIVE', languageBias: [LANGUAGES[language]], emitAudioProgress: false }));
        } catch { fail('handshake send failed'); }
      };
      ws.onmessage = event => {
        if (typeof event.data !== 'string') return;
        let m; try { m = JSON.parse(event.data); } catch { return; }
        if (!('type' in m)) {
          if (!m.sessionId) return fail('handshake refused');
          acked = true; providerSession = m.sessionId; clearTimeout(handshakeTimer); readyResolve(); pump(); return;
        }
        switch (m.type) {
          case 'speechStart': turn(m.turnId).start_ms = m.audioProcessedMs ?? null; break;
          case 'speechEnd': turn(m.turnId).end_ms = m.audioProcessedMs ?? null; break;
          case 'speechComplete': { const t = turn(m.turnId); t.transcript = String(m.transcript ?? ''); t.end_ms ??= m.audioProcessedMs ?? null; partial = ''; onPartial(text()); break; }
          case 'transcript':
            if (m.final === true && (!m.transcript || !String(m.transcript).trim())) { final(); break; }
            partial = String(m.transcript ?? ''); onPartial(text());
            if (m.final === true) final();
            break;
          case 'error': fail('transcriber error'); break;
          default: break;
        }
      };
      ws.onerror = () => fail('socket error');
      // A normal close after endStream ends the session; any other close before finish() is a failure.
      ws.onclose = event => {
        if (finished || failed) return;
        if (endSent && event.code === 1000) final(); else fail(`closed ${event.code}`);
      };
      return {
        ready,
        get sentBytes() { return sentBytes; },
        get failed() { return failed; },
        send(pcm) { if (failed || finished) return; receivedBytes += pcm.length; queue.push(Buffer.from(pcm)); pump(); },
        // Ends input: the audio still queued behind the pacing goes out first, then endStream, and only then does the
        // wait for the last turn (the final empty transcript or the close) start, at most finalTimeoutMs. A missing
        // last turn is a failure, never a cut-off transcript: the caller transcribes the full audio with the file endpoint.
        async finish() {
          try {
            if (failed) throw new Error(failed);
            await within(ready, handshakeTimeoutMs, 'not acknowledged');
            ended = true; pump();
            // Draining takes at most the queued audio's length (less the pacing lead); the cap only guards a stuck pump.
            await within(drained, Math.ceil((receivedBytes - sentBytes) / BYTES_PER_MS) + finalTimeoutMs, 'audio not drained');
            if (failed) throw new Error(failed);
            await within(finalSeen, finalTimeoutMs, 'no final turn');
            if (failed || !finalReceived) throw new Error(failed ?? 'no final turn');
          } catch (error) {
            fail(error.message);
            throw error;
          }
          finished = true;
          try { ws.close(1000); } catch {}
          const list = [...turns.values()].sort((a, b) => a.turn_id - b.turn_id).filter(t => t.start_ms !== null && t.end_ms !== null);
          return { transcript: text(), turns: list.map(t => ({ ...t, transcript: t.transcript ?? '' })), audio_duration_ms: Math.round(receivedBytes / BYTES_PER_MS) || null,
            model: TRANSCRIBE_MODEL, provider_session_id: providerSession ?? sessionId, mode: 'realtime' };
        },
        close() { finished = true; clearTimeout(handshakeTimer); clearTimeout(pumpTimer); try { ws.close(); } catch {} }
      };
    }
  };
}

// Resolves with the promise, or rejects with Error(reason) after ms.
function within(promise, ms, reason) {
  let timer;
  return Promise.race([promise, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(reason)), ms); })]).finally(() => clearTimeout(timer));
}

// One live round. emit(event) sends a JSON event to the client and emitAudio(buffer) a binary frame. The caller feeds
// audio(), end() and cancel(), and awaits done: { status, body, dirty, speechDone } once the round is written (or refused).
// phases: as for HTTP model routes, the database is held from the start until the checks are done, released for the
// hold and the provider calls, and acquired again for the write. Never throws.
export function createLiveRound({ store, models, token, start, requestId = randomUUID(), phases, budget = createBudget(), emit = () => {}, emitAudio = () => {} }) {
  const chunks = [];
  let bytes = 0, ended = false, cancelled = false, audioStopped = false, transcriber = null, released = false, user = null, lastPartial = '';
  let endHold, endCamera;
  const holdEnded = new Promise(r => { endHold = r; });
  const capTimer = setTimeout(() => { ended = true; endHold('capped'); }, MAX_HOLD_MS);
  const audit = (path, status, label) => { try { store.audit(requestId, user, 'POST', path, status, label); } catch {} };
  const errorBody = e => ({ error: e.code ?? 'internal_error', message: e instanceof ApiError ? e.message : 'Request failed.', request_id: requestId });

  const done = (async () => {
    let params, key, context, speak;
    // Checks, with the database held. Nothing has been sent anywhere yet.
    try {
      user = store.authenticate(String(token ?? '').replace(/^Bearer /, ''), 'write');
      ({ params, key, speak } = liveStart(start));
      context = prepareVoiceRound(store, models, user, params);
      if (typeof models.transcribe !== 'function') throw new ApiError(503, 'transcription_unconfigured', 'Transcription is not configured on this deployment.');
      if (!budget.allows(MIN_START_MS.reply + 2_000)) throw new ApiError(503, 'time_budget', 'Not enough time left for this round.');
    } catch (error) {
      clearTimeout(capTimer);
      audit(LIVE_PATH, error.status ?? 500, 'live refused');
      return { status: error.status ?? 500, body: errorBody(error), dirty: false };
    }
    await phases.release(); released = true;
    const acquire = async () => { if (released) { released = false; await phases.acquire(); } };
    try {
      if (models.realtimeReady?.()) {
        transcriber = models.openRealtime({ language: params.language, sessionId: requestId, onPartial: text => {
          if (text !== lastPartial && !cancelled) { lastPartial = text; emit({ type: 'partial', text }); }
        } });
        for (const c of chunks) transcriber.send(c);
      }
      emit({ type: 'ready', transcription: transcriber ? 'realtime' : 'file' });
      const why = await holdEnded;
      clearTimeout(capTimer);
      if (why === 'cancelled') {
        transcriber?.close();
        await acquire();
        // Audio that reached the transcriber is billed, so the hold counts toward the hourly limit.
        if (transcriber?.sentBytes) audit(VOICE_ROUNDS_PATH, 499, 'live cancelled');
        return { status: 499, body: { error: 'cancelled', message: 'The hold ended before release.', request_id: requestId }, dirty: false };
      }
      const releasedAt = performance.now();
      // "Faced the camera" numbers come with the end message, since they are known only at release. The answer is never
      // refused for them: numbers that fail the check are dropped, and the client is told.
      if (endCamera !== undefined) {
        try { const camera = parseCameraMetrics(endCamera); if (camera) params = { ...params, camera }; }
        catch (error) { emit({ type: 'camera_ignored', message: error.message }); }
      }
      const audio = wavFromPcm(Buffer.concat(chunks));
      const wav = inspectWav(audio);
      let transcription = null, mode = 'realtime';
      if (transcriber) {
        try { transcription = await transcriber.finish(); } catch { transcription = null; }
        if (!transcription?.transcript?.trim()) transcription = null;
      }
      if (!transcription) {
        // The file endpoint on the same audio: slower, but the round still answers.
        mode = transcriber ? 'file_fallback' : 'file';
        if (!budget.allows(MIN_START_MS.transcription)) throw new ApiError(503, 'time_budget', 'Not enough time left to transcribe.');
        transcription = { ...(await models.transcribe(audio, { language: params.language, sessionId: requestId, budget })), mode };
      }
      const asrMs = Math.round(performance.now() - releasedAt);
      emit({ type: 'transcript', text: transcription.transcript, transcription: mode, asr_ms: asrMs });
      const answer = await replyToAnswer(models, context, transcription, wav.durationMs, params, budget);
      if (!answer.checked) throw new ApiError(502, 'reply_failed', answer.result?.reason ?? 'Reply failed.');
      const roundId = randomUUID();
      const replyMs = Math.round(performance.now() - releasedAt);
      emit({ type: 'reply', round_id: roundId, transcript: transcription.transcript, metrics: answer.metrics, reply: answer.checked.reply,
        model: answer.result.model ?? null, provider_request_id: answer.result.provider_request_id ?? null,
        latency_ms: { asr: asrMs, model: answer.modelMs, release_to_reply: replyMs }, transcription: mode,
        gate: answer.gate, reply_mode: params.replyMode ?? 'model', counterpart: answer.counterpart });
      // The spoken reply starts now, alongside the write and the commit.
      const entry = speak ? models.prefetchSpeech?.(roundId, user, answer.checked.reply.question, params.language) ?? null : null;
      const speechDone = (async () => {
        if (!entry) { emit({ type: 'speech_unavailable', error: speak ? 'speech_unconfigured' : 'not_requested' }); return; }
        const head = await entry.head;
        if (head.error) { emit({ type: 'speech_unavailable', error: head.error.code ?? 'speech_failed' }); return; }
        emit({ type: 'speech_start', content_type: head.type, provider: models.speechProvider?.() ?? 'custom', voice: models.speechVoice?.(params.language) ?? 'unknown',
          release_to_speech_ms: Math.round(performance.now() - releasedAt) });
        try { for await (const chunk of entry.read()) { if (audioStopped) return; emitAudio(chunk); } emit({ type: 'speech_end' }); }
        catch { emit({ type: 'speech_end', cut_short: true }); }
      })();
      await acquire();
      const receipt = saveVoiceRound(store, user, { params, fingerprintBody: voiceFingerprint(params, audio), key, roundId, transcription, metrics: answer.metrics,
        result: answer.result, checked: answer.checked, gate: answer.gate, live: true, audio, latency: { asr: asrMs, model: answer.modelMs, total: replyMs } });
      audit(VOICE_ROUNDS_PATH, 200, 'live saved');
      return { status: 200, body: voiceResponse(receipt, receipt.record.id === roundId ? answer.counterpart : null), dirty: true, speechDone };
    } catch (error) {
      transcriber?.close();
      await acquire();
      const status = error instanceof ApiError ? error.status : 500;
      audit(VOICE_ROUNDS_PATH, status, 'live failed');
      return { status, body: errorBody(error), dirty: true };
    }
  })();

  return {
    done,
    audio(buffer) {
      if (ended || cancelled) return;
      if (bytes + buffer.length > MAX_LIVE_BYTES) { ended = true; endHold('capped'); return; }
      bytes += buffer.length; chunks.push(Buffer.from(buffer));
      transcriber?.send(buffer);
    },
    // extra.camera: the hold's camera numbers from the end message (src/camera-metrics.mjs), if any.
    end(extra = {}) { if (!ended && !cancelled) { ended = true; endCamera = extra?.camera; endHold('released'); } },
    // The client went away. Before release, the round is dropped; after it, the round is still saved (so a retry with
    // the same key replays it) and only the audio stops.
    cancel() { audioStopped = true; if (!ended && !cancelled) { cancelled = true; endHold('cancelled'); } }
  };
}
