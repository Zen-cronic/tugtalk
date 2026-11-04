import { createServer } from 'node:http';
import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import landingAssetNames from './landing-assets.json' with { type: 'json' };
const landingAssets = new Set(landingAssetNames);

const hash = value => createHash('sha256').update(value).digest();
const same = (a, b) => timingSafeEqual(hash(a), hash(b));
const id = '[A-Za-z0-9_-]{1,100}';
const routes = [
  ['GET', /^\/overview$/, () => '/v1/overview'],
  ['GET', /^\/context$/, () => '/v1/context'],
  ['GET', new RegExp(`^/goals/(${id})$`), m => `/v1/goals/${m[1]}/context`],
  ['GET', /^\/practice-rounds\/([A-Za-z0-9_-]{1,64})$/, m => `/v1/practice-rounds/${m[1]}`],
  ['GET', /^\/settings$/, () => '/v1/settings'],
  ['PATCH', /^\/settings$/, () => '/v1/settings'],
  ['GET', /^\/media$/, () => '/v1/media'],
  ['GET', new RegExp(`^/media/(${id})$`), m => `/v1/media/${m[1]}`],
  ['DELETE', new RegExp(`^/media/(${id})$`), m => `/v1/media/${m[1]}`],
];
const mime = { '.png': 'image/png', '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.svg': 'image/svg+xml', '.ttf': 'font/ttf' };
const assets = new Set(['index.html', 'app.js', 'practice-view.js', 'styles.css', 'icon.svg', 'Anybody.ttf', 'HankenGrotesk.ttf', 'AzeretMono.ttf']);
class Failure extends Error { constructor(status, message) { super(message); this.status = status; } }
async function bytes(stream, max) {
  const chunks = []; let n = 0;
  for await (const part of stream) { n += part.length; if (n > max) throw new Failure(413, 'This request is too large.'); chunks.push(Buffer.from(part)); }
  return Buffer.concat(chunks);
}
async function jsonBody(req) {
  if (!(req.headers['content-type'] ?? '').startsWith('application/json')) throw new Failure(415, 'Use a JSON request.');
  try { return JSON.parse((await bytes(req, 16384)).toString()); } catch (e) { if (e.status) throw e; throw new Failure(400, 'The request could not be read.'); }
}
function cookieValue(req, name) {
  return (req.headers.cookie ?? '').split(';').map(v => v.trim()).find(v => v.startsWith(`${name}=`))?.slice(name.length + 1) ?? '';
}
export function createDashboard({ origin, upstream, token, password, secure = true, webRoot = fileURLToPath(new URL('../web/', import.meta.url)), landingRoot = null, fetchImpl = fetch, now = Date.now, demo = false, allowRecordingChanges = false, sessionMs = 8 * 60 * 60 * 1000, timeoutMs = 10000 }) {
  const publicURL = new URL(origin), apiURL = new URL(upstream);
  if (!['http:', 'https:'].includes(publicURL.protocol) || (!secure && !['127.0.0.1', 'localhost', '[::1]'].includes(publicURL.hostname))) throw new Error('Insecure cookies are allowed only on loopback.');
  if (secure && publicURL.protocol !== 'https:') throw new Error('HTTPS is required.');
  if (apiURL.protocol !== 'https:' && !(apiURL.protocol === 'http:' && ['127.0.0.1', 'localhost', '[::1]'].includes(apiURL.hostname))) throw new Error('The API must use HTTPS or loopback.');
  if (publicURL.username || publicURL.password || apiURL.username || apiURL.password || !token || typeof password !== 'string' || password.length < 20) throw new Error('Server credentials and a long access code are required.');
  const passwordHash = hash(password), sessions = new Map(), attempts = new Map();
  const cookieName = secure ? '__Host-comms-session' : 'comms-session';
  const cookie = (value, age) => `${cookieName}=${value}; HttpOnly; SameSite=Strict; Path=/; Max-Age=${age}${secure ? '; Secure' : ''}`;
  const server = createServer(async (req, res) => {
    const headers = { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer', 'Content-Security-Policy': "default-src 'self'; script-src 'self'; style-src 'self'; font-src 'self'; img-src 'self'; connect-src 'self'; media-src 'self' blob:; frame-ancestors 'none'; base-uri 'none'; form-action 'self'", 'Permissions-Policy': 'camera=(), microphone=(), geolocation=()' };
    const send = (status, body, extra = {}) => { res.writeHead(status, { ...headers, 'Content-Type': 'application/json', ...extra }); res.end(JSON.stringify(body)); };
    try {
      if (req.headers.host !== publicURL.host) throw new Failure(400, 'Unexpected host.');
      if (req.url.includes('\\') || /%2f|%5c|%2e/i.test(req.url)) throw new Failure(400, 'Invalid path.');
      const url = new URL(req.url, origin), route = url.pathname;
      if (route.startsWith('/app-api/') && url.search) throw new Failure(400, 'Unexpected query parameters.');
      const writing = !['GET', 'HEAD'].includes(req.method);
      if (writing && req.headers.origin !== publicURL.origin) throw new Failure(403, 'Reload this page before making a change.');
      const t = now();
      for (const [key, value] of sessions) if (value.expires <= t) sessions.delete(key);
      for (const [key, value] of attempts) if (value.until <= t) attempts.delete(key);
      if (route === '/app-api/login' && req.method === 'POST') {
        const key = req.socket.remoteAddress ?? 'unknown';
        const bucket = attempts.get(key) ?? { count: 0, until: t + 15 * 60 * 1000 };
        if (bucket.count >= 5 || attempts.size >= 2048) throw new Failure(429, 'Too many sign-in attempts. Try again in 15 minutes.');
        bucket.count++; attempts.set(key, bucket);
        const body = await jsonBody(req);
        if (typeof body?.password !== 'string' || !timingSafeEqual(hash(body.password), passwordHash)) throw new Failure(401, 'That access code did not work.');
        if (sessions.size >= 256) throw new Failure(503, 'Sign-in is busy. Try again later.');
        sessions.delete(cookieValue(req, cookieName));
        const sessionID = randomBytes(32).toString('hex'), csrf = randomBytes(24).toString('hex');
        sessions.set(sessionID, { csrf, expires: t + sessionMs });
        return send(200, { csrf, demo, can_change_recordings: allowRecordingChanges }, { 'Set-Cookie': cookie(sessionID, Math.floor(sessionMs / 1000)) });
      }
      if (route.startsWith('/app-api/')) {
        const sessionID = cookieValue(req, cookieName), session = sessions.get(sessionID);
        if (!session) throw new Failure(401, 'Sign in to see your practice.');
        if (writing && !same(String(req.headers['x-csrf-token'] ?? ''), session.csrf)) throw new Failure(403, 'Reload this page before making a change.');
        if (route === '/app-api/session' && req.method === 'GET') return send(200, { csrf: session.csrf, demo, can_change_recordings: allowRecordingChanges });
        if (route === '/app-api/logout' && req.method === 'POST') { sessions.delete(sessionID); return send(200, { signed_out: true }, { 'Set-Cookie': cookie('', 0) }); }
        if (route === '/app-api/conversations' && req.method === 'GET') return send(200, { conversations: [], coverage: 'not_connected', as_of: new Date(t).toISOString() });
        if (writing && !allowRecordingChanges) throw new Failure(403, 'Recording changes are disabled for this connection.');
        const suffix = route.slice('/app-api'.length);
        const found = routes.map(([method, regex, target]) => ({ method, match: suffix.match(regex), target })).find(r => r.method === req.method && r.match);
        if (!found) throw new Failure(404, 'This action is not available.');
        const proxyHeaders = { Authorization: `Bearer ${token}` }; let body;
        if (writing) {
          const key = req.headers['idempotency-key'];
          if (typeof key !== 'string' || !/^[A-Za-z0-9_-]{8,128}$/.test(key)) throw new Failure(400, 'A change identifier is required.');
          proxyHeaders['Idempotency-Key'] = key;
          if (req.method === 'PATCH') {
            body = await jsonBody(req);
            if (!body || Array.isArray(body) || Object.keys(body).some(k => !['expected_version', 'keep_recordings', 'delete_kept_recordings'].includes(k)) || !Number.isInteger(body.expected_version) || body.expected_version < 1 || typeof body.keep_recordings !== 'boolean' || ('delete_kept_recordings' in body && typeof body.delete_kept_recordings !== 'boolean')) throw new Failure(400, 'The recording settings are not valid.');
            proxyHeaders['Content-Type'] = 'application/json'; body = JSON.stringify(body);
          }
        }
        const controller = new AbortController(), timer = setTimeout(() => controller.abort(), timeoutMs);
        let response, data;
        try {
          response = await fetchImpl(new URL(found.target(found.match), apiURL), { method: req.method, headers: proxyHeaders, body, redirect: 'error', cache: 'no-store', signal: controller.signal });
          data = await bytes(response.body, suffix.startsWith('/media/') ? 16 * 1024 * 1024 : 4 * 1024 * 1024);
        } catch (e) { if (e.status === 413) throw e; throw new Failure(controller.signal.aborted ? 504 : 502, 'Your practice service is unavailable. Try refreshing in a moment.'); }
        finally { clearTimeout(timer); }
        if (!response.ok) {
          const messages = { 401: 'The practice connection needs to be renewed.', 403: 'This connection cannot make that change.', 404: 'This item is no longer available.', 409: 'This record changed on another device. Refresh, then try again.', 429: 'Please wait before trying again.' };
          return send(response.status === 401 ? 502 : response.status, { error: messages[response.status] ?? 'The practice service could not complete that request.' });
        }
        const type = response.headers.get('content-type') ?? 'application/json';
        if (!type.startsWith('application/json') && !type.startsWith('audio/')) throw new Failure(502, 'The practice service returned an unexpected response.');
        res.writeHead(response.status, { ...headers, 'Content-Type': type, ...(type.startsWith('audio/') ? { 'Content-Disposition': 'inline' } : {}) }); res.end(data); return;
      }
      if (req.method !== 'GET' && req.method !== 'HEAD') throw new Failure(405, 'This action is not available.');
      if (landingRoot && !route.startsWith('/app/') && route !== '/app') {
        const publicFile = route === '/' ? 'index.html' : route.slice(1);
        if (!landingAssets.has(publicFile)) throw new Failure(404, 'Page not found.');
        const data = await readFile(path.join(landingRoot, publicFile));
        const publicPolicy = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src 'self' https://fonts.gstatic.com; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'";
        res.writeHead(200, { ...headers, 'Content-Security-Policy': publicPolicy, 'Content-Type': mime[path.extname(publicFile)] });
        res.end(req.method === 'HEAD' ? undefined : data); return;
      }
      const file = route === '/' || route === '/app' || route === '/app/' ? 'index.html' : route.startsWith('/app/') ? route.slice(5) : '';
      if (!assets.has(file)) throw new Failure(404, 'Page not found.');
      const data = await readFile(path.join(webRoot, file));
      res.writeHead(200, { ...headers, 'Content-Type': mime[path.extname(file)] }); res.end(req.method === 'HEAD' ? undefined : data);
    } catch (e) { if (!res.headersSent) send(e.status ?? 500, { error: e.status ? e.message : 'Something went wrong. Please try again.' }); else res.end(); }
  });
  return server;
}
