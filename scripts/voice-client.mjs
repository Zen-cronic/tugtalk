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

const keyDown = new Date();
const onset = option('onset-ms');
if (flag('realtime') && clipMs) await new Promise(r => setTimeout(r, clipMs));
const headers = { ...auth, 'Content-Type': 'audio/wav', 'Idempotency-Key': option('key', `voice-${randomBytes(8).toString('hex')}`), 'X-Occurred-At': keyDown.toISOString(),
  ...(goal ? { 'X-Goal-Id': goal } : {}), ...(option('screen-context') ? { 'X-Screen-Context-Id': option('screen-context') } : {}),
  ...(option('language') ? { 'X-Language': option('language') } : {}),
  ...(onset !== null ? { 'X-Prompt-Ended-At': new Date(keyDown.getTime() - Number(onset)).toISOString() } : {}) };

async function send() {
  const released = performance.now();
  const r = await fetch(`${base}/v1/voice-rounds`, { method: 'POST', headers, body: audio });
  const data = await r.json();
  return { status: r.status, client_ms: Math.round(performance.now() - released), request_id: r.headers.get('x-request-id'), data };
}

const runs = [await send()];
if (flag('repeat')) runs.push(await send());
for (const run of runs) {
  if (flag('json')) { console.log(JSON.stringify({ status: run.status, client_ms: run.client_ms, clip_ms: clipMs, goal_id: goal, ...run.data })); continue; }
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

const speechFile = option('speech');
const last = runs.at(-1);
if (speechFile && last.status === 200) {
  const start = performance.now();
  const r = await fetch(`${base}/v1/voice-rounds/${last.data.round_id}/speech`, { method: 'POST', headers: auth });
  if (!r.ok) { const e = await r.json().catch(() => ({})); console.log(`speech:   HTTP ${r.status} ${e.error ?? ''}`); }
  else {
    const chunks = []; let first = null;
    for await (const chunk of r.body) { first ??= Math.round(performance.now() - start); chunks.push(Buffer.from(chunk)); }
    writeFileSync(speechFile, Buffer.concat(chunks));
    const timing = { provider: r.headers.get('x-speech-provider'), voice: r.headers.get('x-speech-voice'), type: r.headers.get('content-type'),
      first_byte_ms: first, total_ms: Math.round(performance.now() - start), bytes: chunks.reduce((n, c) => n + c.length, 0), file: speechFile };
    console.log(flag('json') ? JSON.stringify({ speech: timing }) : `speech:   ${timing.provider} ${timing.voice}, first byte ${timing.first_byte_ms} ms, total ${timing.total_ms} ms, ${timing.bytes} bytes -> ${speechFile}`);
  }
}
