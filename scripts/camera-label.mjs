// Hand labels for the "faced the camera" accuracy check: watch a recorded clip and say, second by second, whether
// the head faced the camera. Writes the labels file `camera-eval score` reads. Nothing is sent anywhere.
//   node scripts/camera-label.mjs --seconds 60 --out labels.json [--clip "Nov 3 test"]
// At each prompt, scrub the clip to that second and answer:
//   y = faced the camera, n = did not, Enter = same as the last answer, s = skip (unsure), b = back one second,
//   q = save and stop.
import { createInterface } from 'node:readline';
import { writeFileSync } from 'node:fs';
import { stdin, stdout, argv, exit } from 'node:process';

const arg = name => { const i = argv.indexOf(name); return i > 0 ? argv[i + 1] : undefined; };
const seconds = Number(arg('--seconds') ?? 60), out = arg('--out'), clip = arg('--clip') ?? 'hand-labelled clip';
if (!out || !Number.isInteger(seconds) || seconds < 1 || seconds > 600) {
  console.error('Usage: node scripts/camera-label.mjs --seconds 60 --out labels.json [--clip name]');
  exit(2);
}

function applyAnswer(labels, i, answer) {
  const a = answer.trim().toLowerCase();
  if (a === 'q') return { labels, i, done: true };
  if (a === 'b') return { labels, i: Math.max(0, i - 1), done: false };
  const next = [...labels];
  if (a === 'y') next[i] = true;
  else if (a === 'n') next[i] = false;
  else if (a === 's') next[i] = null;
  else if (a === '') next[i] = [...next.slice(0, i)].reverse().find(v => v !== null && v !== undefined) ?? null;
  else return { labels, i, done: false, error: 'Type y, n, Enter, s, b or q.' };
  return { labels: next, i: i + 1, done: i + 1 >= next.length };
}

const rl = createInterface({ input: stdin, terminal: false });
let state = { labels: Array(seconds).fill(null), i: 0, done: false };
const ask = () => {
  const s = state.i, mark = state.labels[s] === null ? '' : ` (now ${state.labels[s] ? 'y' : 'n'})`;
  stdout.write(`${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')} faced the camera?${mark} [y/n/Enter/s/b/q] `);
};
console.log(`Labelling ${seconds} s. Faced the camera = head pointed at the lens (not where the eyes looked).`);
ask();
// Reading line by line works the same from a keyboard and from a file of answers.
for await (const answer of rl) {
  state = applyAnswer(state.labels, state.i, answer);
  if (state.error) console.log(state.error);
  if (state.done) break;
  ask();
}
rl.close();
stdout.write('\n');
writeFileSync(out, JSON.stringify({ clip, seconds: state.labels }, null, 2) + '\n');
const labelled = state.labels.filter(v => v !== null);
console.log(`Saved ${out}: ${labelled.length} seconds labelled, faced the camera in ${labelled.filter(Boolean).length}.`);
