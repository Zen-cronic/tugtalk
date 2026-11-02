// Headless voice-round client: sends one spoken answer (a WAV file, or text rendered by macOS `say`) to
// POST /v1/voice-rounds, as the Mac does when the key is released, and prints the reply and the timings.
// Lets anyone test the round end to end without a microphone. Defaults to the local stub server (npm run stub).
//
//   node scripts/voice-client.mjs --token-file <path> --say "So, um, I think I could maybe lead the launch."
//   node scripts/voice-client.mjs --token-file <path> --wav answer.wav --goal <goal-id> --onset-ms 900
//
// Options:
//   --base URL             API base URL (default http://127.0.0.1:4319, the stub server)
//   --token-file PATH      file holding the Bearer key (or VOICE_TOKEN_FILE). The key is never printed.
//   --wav PATH | --say TEXT  the answer; --say renders 24 kHz mono 16-bit WAV with say and afconvert (macOS)
//   --voice NAME           voice for --say (default Samantha)
//   --goal ID, --screen-context ID, --language en|fr
//   --onset-ms N           pretend the question finished N ms before the key went down (sends X-Prompt-Ended-At)
//   --realtime             hold for the clip's length before sending, as a person speaking would
//   --key KEY              Idempotency-Key (default: a new random one); --repeat sends the same request twice
//   --create-goal "Title|Target"  create a goal first and use it
//   --speech FILE          then fetch the spoken reply, save it to FILE, and print time to first byte and total
//   --live                 stream the clip over WS /v1/voice-rounds/live in real time (80 ms frames), as the Mac does
//                          while the key is held, and print release to transcript, reply, first audio byte and saved.
//                          With --speech FILE the spoken audio that arrives on the socket is saved there.
//   --json                 print one JSON line instead of the summary
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const args = process.argv.slice(2);
const flag = name => args.includes(`--${name}`);
const option = (name, fallback = null) => { const i = args.indexOf(`--${name}`); return i >= 0 && i + 1 < args.length ? args[i + 1] : fallback; };
const fail = message => { console.error(message); process.exit(2); };

const base = option('base', 'http://127.0.0.1:4319').replace(/\/$/, '');
const tokenFile = option('token-file', process.env.VOICE_TOKEN_FILE);
if (!tokenFile) fail('Give --token-file (npm run stub prints its token_file path).');
const token = readFileSync(tokenFile, 'utf8').trim();
if (!token) fail('The token file is empty.');
const auth = { Authorization: `Bearer ${token}` };

function renderSay(text, voice) {
  const dir = mkdtempSync(join(tmpdir(), 'voice-client-'));
  try {
    execFileSync('say', ['-v', voice, '-o', join(dir, 'a.aiff'), text]);
    execFileSync('afconvert', ['-f', 'WAVE', '-d', 'LEI16@24000', '-c', '1', join(dir, 'a.aiff'), join(dir, 'a.wav')]);
    return readFileSync(join(dir, 'a.wav'));
  } finally { rmSync(dir, { recursive: true, force: true }); }
}
// afconvert may add chunks before "data"; read the duration from the header instead of assuming 44 bytes.
function durationMs(wav) {
  let offset = 12, rate = 24000;
  while (offset + 8 <= wav.length) {
    const id = wav.toString('ascii', offset, offset + 4), size = wav.readUInt32LE(offset + 4);
    if (id === 'fmt ') rate = wav.readUInt32LE(offset + 12);
    if (id === 'data') return Math.round(Math.min(size, wav.length - offset - 8) / (rate * 2) * 1000);
    offset += 8 + size + (size % 2);
  }
  return null;
}

const wavPath = option('wav'), sayText = option('say');
if (!wavPath === !sayText) fail('Give exactly one of --wav PATH or --say TEXT.');
const audio = wavPath ? readFileSync(wavPath) : renderSay(sayText, option('voice', 'Samantha'));
const clipMs = durationMs(audio);

let goal = option('goal');
const created = option('create-goal');
if (created) {
  const [title, target = title] = created.split('|');
  const r = await fetch(`${base}/v1/goals`, { method: 'POST', headers: { ...auth, 'Content-Type': 'application/json', 'Idempotency-Key': `goal-${randomBytes(8).toString('hex')}` }, body: JSON.stringify({ title, target }) });
  const data = await r.json();
  if (!r.ok) fail(`Creating the goal failed: HTTP ${r.status} ${data.error}`);
  goal = data.record.id;
}

const speechFile = option('speech');
const keyDown = new Date();
const onset = option('onset-ms');
if (flag('realtime') && clipMs) await new Promise(r => setTimeout(r, clipMs));
const headers = { ...auth, 'Content-Type': 'audio/wav', 'Idempotency-Key': option('key', `voice-${randomBytes(8).toString('hex')}`), 'X-Occurred-At': keyDown.toISOString(),
  ...(goal ? { 'X-Goal-Id': goal } : {}), ...(option('screen-context') ? { 'X-Screen-Context-Id': option('screen-context') } : {}),
  ...(option('language') ? { 'X-Language': option('language') } : {}),
  ...(onset !== null ? { 'X-Prompt-Ended-At': new Date(keyDown.getTime() - Number(onset)).toISOString() } : {}) };

// The samples of a 24 kHz mono 16-bit WAV (the format --say renders and the Mac records).
function pcmOf(wav) {
  let offset = 12;
  while (offset + 8 <= wav.length) {
    const id = wav.toString('ascii', offset, offset + 4), size = wav.readUInt32LE(offset + 4);
    if (id === 'fmt ' && (wav.readUInt16LE(offset + 10) !== 1 || wav.readUInt32LE(offset + 12) !== 24000)) fail('--live needs 24 kHz mono 16-bit WAV.');
    if (id === 'data') return wav.subarray(offset + 8, offset + 8 + Math.min(size, wav.length - offset - 8));
    offset += 8 + size + (size % 2);
  }
  fail('No data chunk in the WAV.');
}

// One hold over the live socket. Times are from the release (the "end" frame), as the Mac measures them.
async function live() {
  const url = base.replace(/^http/, 'ws') + '/v1/voice-rounds/live';
  const pcm = pcmOf(audio), FRAME = 3840; // 80 ms
  const ws = new WebSocket(url, { headers: auth });
  ws.binaryType = 'arraybuffer';
  const t = {}, out = { events: [] }, speech = [];
  let released = null;
  const since = () => (released === null ? null : Math.round(performance.now() - released));
  const opened = performance.now();
  const closed = new Promise(resolve => {
    ws.onclose = e => { t.closed = since(); out.close = e.code; resolve(); };
    ws.onerror = () => { out.error = 'socket error'; };
  });
  ws.onmessage = e => {
    if (typeof e.data !== 'string') { t.first_audio ??= since(); speech.push(Buffer.from(e.data)); return; }
    const m = JSON.parse(e.data);
    out.events.push(m.type);
    if (m.type === 'ready') t.ready_after_open = Math.round(performance.now() - opened);
    if (m.type === 'partial') { t.first_partial_in_hold ??= Math.round(performance.now() - opened); out.partial = m.text; }
    if (m.type === 'transcript') { t.transcript = since(); out.transcript = m.text; out.transcription = m.transcription; out.server_asr_ms = m.asr_ms; }
    if (m.type === 'reply') { t.reply = since(); out.reply = m.reply; out.round_id = m.round_id; out.server_latency = m.latency_ms; out.metrics = m.metrics; }
    if (m.type === 'speech_start') { t.speech_start = since(); out.speech = { provider: m.provider, voice: m.voice, type: m.content_type, server_release_to_speech_ms: m.release_to_speech_ms }; }
    if (m.type === 'speech_unavailable') out.speech = { unavailable: m.error };
    if (m.type === 'saved') { t.saved = since(); out.saved = { round_id: m.round_id, receipt_id: m.receipt_id, replayed: m.replayed }; }
    if (m.type === 'error') { out.error = `${m.status} ${m.error}: ${m.message}`; t.error = since(); }
  };
  await new Promise((resolve, reject) => { ws.onopen = resolve; setTimeout(() => reject(new Error('socket did not open')), 10_000); }).catch(e => fail(e.message));
  t.open = Math.round(performance.now() - opened);
  ws.send(JSON.stringify({ type: 'start', idempotency_key: option('key', `live-${randomBytes(8).toString('hex')}`), language: option('language', 'en'),
    occurred_at: keyDown.toISOString(), ...(goal ? { goal_id: goal } : {}), ...(option('screen-context') ? { screen_context_id: option('screen-context') } : {}),
    ...(onset !== null ? { prompt_ended_at: new Date(keyDown.getTime() - Number(onset)).toISOString() } : {}) }));
  // Real time: frame i goes out at i * 80 ms after the first, as a microphone would deliver it.
  const first = performance.now();
  for (let i = 0; i * FRAME < pcm.length; i++) {
    const due = first + i * 80;
    if (due > performance.now()) await new Promise(r => setTimeout(r, due - performance.now()));
    if (ws.readyState !== WebSocket.OPEN) break;
    ws.send(pcm.subarray(i * FRAME, (i + 1) * FRAME));
  }
  await new Promise(r => setTimeout(r, Math.max(0, first + (pcm.length / 48) - performance.now())));
  released = performance.now();
  if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ type: 'end' }));
  const timer = setTimeout(() => { out.error ??= 'no close within 60 s'; ws.close(); }, 60_000);
  await closed; clearTimeout(timer);
  if (speechFile && speech.length) writeFileSync(speechFile, Buffer.concat(speech));
  return { ms_after_release: t, clip_ms: clipMs, speech_bytes: speech.reduce((n, b) => n + b.length, 0), ...out };
}

if (flag('live')) {
  const r = await live();
  if (flag('json')) console.log(JSON.stringify(r));
  else console.log([
    `live round ${r.round_id ?? '-'} (${r.transcription ?? 'no transcript'}), close ${r.close}${r.error ? `, error ${r.error}` : ''}`,
    `heard:    ${r.transcript ?? '-'}`,
    `reply:    ${r.reply ? `[${r.reply.move}] ${r.reply.question}` : '-'}`,
    `release to: transcript ${r.ms_after_release.transcript ?? '-'} ms, reply ${r.ms_after_release.reply ?? '-'} ms, first audio byte ${r.ms_after_release.first_audio ?? '-'} ms, saved ${r.ms_after_release.saved ?? '-'} ms`,
    `speech:   ${r.speech ? JSON.stringify(r.speech) : '-'}, ${r.speech_bytes} bytes`
  ].join('\n'));
  process.exit(r.saved ? 0 : 1);
}

async function send() {
  const released = performance.now();
  const r = await fetch(`${base}/v1/voice-rounds`, { method: 'POST', headers, body: audio });
  const data = await r.json();
  return { status: r.status, released, client_ms: Math.round(performance.now() - released), request_id: r.headers.get('x-request-id'), server_timing: r.headers.get('server-timing'), data };
}

const runs = [await send()];
if (flag('repeat')) runs.push(await send());
for (const run of runs) {
  if (flag('json')) { console.log(JSON.stringify({ status: run.status, client_ms: run.client_ms, released: undefined, clip_ms: clipMs, goal_id: goal, server_timing: run.server_timing, ...run.data })); continue; }
  if (run.status !== 200) { console.log(`HTTP ${run.status} ${run.data.error}: ${run.data.message}`); continue; }
  const d = run.data, m = d.metrics, p = m.pauses;
  console.log([
    `round ${d.round_id}${d.replayed ? ' (replayed, no model call)' : ''}${goal ? `, goal ${goal}` : ''}`,
    `heard:    ${d.transcript}`,
    `measured: ${m.word_count} words, ${m.words_per_minute} wpm, ${m.filler_count} fillers, ${m.hedge_count} hedges, ${m.restart_count} restarts, longest pause ${p.longest_pause_ms ?? '-'} ms, onset ≈ ${m.onset_ms_approx ?? '-'} ms`,
    `reply:    [${d.reply.move}] ${d.reply.question}`,
    `quote:    ${d.reply.quote_verified ? `"${d.reply.quote}" (verified)` : 'none kept'}`,
    `latency:  asr ${d.latency_ms.asr} ms, model ${d.latency_ms.model} ms, server ${d.latency_ms.total} ms, release to reply ${run.client_ms} ms (clip ${clipMs} ms)`
  ].join('\n'));
}

const last = runs.at(-1);
if (speechFile && last.status === 200) {
  const start = performance.now();
  const r = await fetch(`${base}/v1/voice-rounds/${last.data.round_id}/speech`, { method: 'POST', headers: auth });
  const headers_ms = Math.round(performance.now() - start);
  if (!r.ok) { const e = await r.json().catch(() => ({})); console.log(`speech:   HTTP ${r.status} ${e.error ?? ''}`); }
  else {
    const chunks = []; let first = null;
    for await (const chunk of r.body) { first ??= Math.round(performance.now() - start); chunks.push(Buffer.from(chunk)); }
    writeFileSync(speechFile, Buffer.concat(chunks));
    const timing = { provider: r.headers.get('x-speech-provider'), voice: r.headers.get('x-speech-voice'), type: r.headers.get('content-type'), server_timing: r.headers.get('server-timing'),
      headers_ms,
      first_byte_ms: first, release_to_first_audio_ms: first === null ? null : Math.round(start + first - last.released), total_ms: Math.round(performance.now() - start), bytes: chunks.reduce((n, c) => n + c.length, 0), file: speechFile };
    console.log(flag('json') ? JSON.stringify({ speech: timing }) : `speech:   ${timing.provider} ${timing.voice}, first byte ${timing.first_byte_ms} ms, total ${timing.total_ms} ms, ${timing.bytes} bytes -> ${speechFile}`);
  }
}
