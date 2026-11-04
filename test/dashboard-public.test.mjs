import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { createDashboard, publicLimits, publicLimitsFromEnv, DEFAULT_PUBLIC_LIMITS, PUBLIC_LIMIT_ENV } from '../src/dashboard-gateway.mjs';
// The tests set their own limits; the hosted values come from the deploy environment and are not in the repository.
const LIMITS = { readLimit: 15, readTotal: 150, mediaLimit: 4, mediaTotal: 11 };
const { readLimit: PUBLIC_READ_LIMIT, mediaLimit: PUBLIC_MEDIA_LIMIT, mediaTotal: PUBLIC_MEDIA_TOTAL } = LIMITS;
const password='a-long-local-test-access-code', token='test-upstream-credential-public';
const listen=s=>new Promise(r=>s.listen(0,'127.0.0.1',r));
const close=s=>new Promise(r=>s.close(r));
const audio=Buffer.from('RIFF0000WAVEfmt sample audio');
// A fake upstream that answers every allowlisted read with recognisable data and audio for a media file.
function upstream(calls) {
  return async (url, init) => {
    calls.push({ url: String(url), ...init });
    const route = new URL(url).pathname;
    if (/^\/v1\/media\/[^/]+$/.test(route)) return new Response(audio, { headers: { 'Content-Type': 'audio/wav' } });
    return Response.json({ route, goals: [{ id: 'goal-1', title: 'Speak clearly' }], settings: { version: 1, keep_recordings: true }, media: [{ id: 'file-1' }], snapshot_revision: 'r1', as_of: new Date().toISOString() });
  };
}
async function harness(t, options = {}) {
  const reservation = createServer(); await listen(reservation); const port = reservation.address().port; await close(reservation);
  const origin = `http://127.0.0.1:${port}`, calls = [];
  const server = createDashboard({ origin, upstream: 'https://api.example.test', token, password, secure: false, publicRead: true, allowRecordingChanges: false, failureDelayMs: 0, publicLimits: LIMITS, fetchImpl: upstream(calls), ...options });
  await new Promise(r => server.listen(port, '127.0.0.1', r)); t.after(() => close(server));
  let cookie = '', csrf = '';
  const request = async (route, opts = {}) => {
    const res = await fetch(origin + route, { ...opts, headers: { ...(cookie ? { Cookie: cookie } : {}), Origin: origin, ...opts.headers } });
    const raw = Buffer.from(await res.arrayBuffer()), text = raw.toString(); let data; try { data = JSON.parse(text); } catch { data = text; }
    return { status: res.status, headers: res.headers, data, text, raw };
  };
  const login = async () => { const r = await request('/app-api/login', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ password }) }); assert.equal(r.status, 200); cookie = r.headers.get('set-cookie').split(';')[0]; csrf = r.data.csrf; return r; };
  const writeHeaders = (extra = {}) => ({ 'X-CSRF-Token': csrf, 'Idempotency-Key': 'test-change-0001', 'Content-Type': 'application/json', ...extra });
  return { request, login, calls, origin, writeHeaders };
}
const noKey = (r, label) => { assert.ok(!r.text.includes(token), `${label}: no connector key in the body`); for (const [, v] of r.headers) assert.ok(!v.includes(token), `${label}: no connector key in a header`); };
// Every read the dashboard UI makes, with the upstream path it maps to.
const reads = [
  ['/app-api/overview', '/v1/overview'], ['/app-api/context', '/v1/context'], ['/app-api/goals/goal-1', '/v1/goals/goal-1/context'],
  ['/app-api/practice-rounds/round-1', '/v1/practice-rounds/round-1'], ['/app-api/settings', '/v1/settings'], ['/app-api/media', '/v1/media'],
];

test('public read: a visitor without a session reads every dashboard route, proxied with the server-side key',async t=>{
  const h=await harness(t);
  const session=await h.request('/app-api/session');assert.equal(session.status,200);
  assert.deepEqual(session.data,{csrf:'',demo:false,can_change_recordings:false,public_read:true});assert.equal(session.headers.get('set-cookie'),null);
  for(const [route,target] of reads){
    const r=await h.request(route);assert.equal(r.status,200,route);assert.equal(r.data.route,target,route);
    assert.equal(r.headers.get('cache-control'),'no-store',route);noKey(r,route);
  }
  assert.ok(h.calls.every(c=>c.headers.Authorization===`Bearer ${token}`&&c.method==='GET'));assert.equal(h.calls.length,reads.length);
  const conversations=await h.request('/app-api/conversations');assert.equal(conversations.status,200);assert.equal(conversations.data.coverage,'not_connected');
  for(const page of ['/app/','/app/goals','/app/conversations','/app/recordings']){const r=await h.request(page);assert.equal(r.status,200,page);assert.match(r.headers.get('content-security-policy'),/default-src 'self'/);noKey(r,page);}
});

test('public read: audio plays and downloads without a session, under per-client and total limits',async t=>{
  let now=1000;const h=await harness(t,{trustProxy:true,now:()=>now});
  const get=(client,id='file-1')=>h.request(`/app-api/media/${id}`,{headers:{'X-Forwarded-For':client}});
  const r=await get('203.0.113.1');assert.equal(r.status,200);assert.match(r.headers.get('content-type'),/^audio\/wav/);assert.equal(r.headers.get('content-disposition'),'inline');
  assert.deepEqual(r.raw,audio);noKey(r,'audio');
  for(let i=1;i<PUBLIC_MEDIA_LIMIT;i++)assert.equal((await get('203.0.113.1')).status,200);
  const limited=await get('203.0.113.1');assert.equal(limited.status,429,'one client is limited');noKey(limited,'limited');
  assert.equal((await get('203.0.113.2')).status,200,'another client still plays audio');
  assert.equal((await h.request('/app-api/media',{headers:{'X-Forwarded-For':'203.0.113.1'}})).status,200,'the media list is not a download');
  // Across all visitors, audio stops at the total, below the account's own upstream download limit.
  for(let c=3;h.calls.filter(x=>/\/v1\/media\/./.test(x.url)).length<PUBLIC_MEDIA_TOTAL;c++)await get(`203.0.113.${c}`);
  assert.equal((await get('198.51.100.50')).status,429,'the total is shared by every visitor');
  const owner=await h.login();assert.equal(owner.status,200);assert.equal((await h.request('/app-api/media/file-1')).status,200,'a signed-in session is not counted');
  now+=60*60*1000+1;assert.equal((await h.request('/app-api/media/file-1',{headers:{Cookie:'','X-Forwarded-For':'203.0.113.1'}})).status,200,'the limit resets after its window');
});

test('public read: each client gets a bounded number of reads a minute',async t=>{
  let now=1000;const h=await harness(t,{trustProxy:true,now:()=>now});
  const get=client=>h.request('/app-api/overview',{headers:{'X-Forwarded-For':client}});
  for(let i=0;i<PUBLIC_READ_LIMIT;i++)assert.equal((await get('192.0.2.10')).status,200);
  const r=await get('192.0.2.10');assert.equal(r.status,429);assert.equal(h.calls.length,PUBLIC_READ_LIMIT,'a limited read never reaches the upstream');
  assert.equal((await get('192.0.2.11')).status,200,'other clients are unaffected');
  now+=61*1000;assert.equal((await get('192.0.2.10')).status,200);
});

test('public read: every write without a session is refused before the upstream',async t=>{
  const h=await harness(t,{allowRecordingChanges:true});
  const body=JSON.stringify({expected_version:1,keep_recordings:false});
  const attempts=[['PATCH','/app-api/settings',body],['DELETE','/app-api/media/file-1'],['POST','/app-api/settings',body],['PUT','/app-api/settings',body],
    ['POST','/app-api/practice-rounds/round-1','{}'],['PATCH','/app-api/practice-rounds/round-1','{}'],['DELETE','/app-api/practice-rounds/round-1'],['POST','/app-api/logout'],['DELETE','/app-api/overview']];
  for(const [method,route,b] of attempts){
    for(const headers of [{'Content-Type':'application/json','Idempotency-Key':'test-change-0001'},{'Content-Type':'application/json','Idempotency-Key':'test-change-0001','X-CSRF-Token':'guess'}]){
      const r=await h.request(route,{method,headers,body:b});assert.ok([401,403].includes(r.status),`${method} ${route}: ${r.status}`);noKey(r,route);
    }
    assert.equal((await h.request(route,{method,headers:{Origin:'https://evil.test','Content-Type':'application/json'},body:b})).status,403,`${method} ${route} cross-origin`);
  }
  assert.equal((await h.request('/app-api/media/file-1',{method:'HEAD'})).status,401,'HEAD is not a public read');
  assert.equal(h.calls.length,0);
});

test('public read: the owner still signs in, and gains nothing a signed-in session lacked',async t=>{
  const h=await harness(t);
  const login=await h.login();assert.equal(login.data.public_read,true);assert.equal(login.data.can_change_recordings,false);noKey(login,'login');
  const session=await h.request('/app-api/session');assert.equal(session.status,200);assert.ok(session.data.csrf.length>10);
  assert.equal((await h.request('/app-api/settings',{method:'PATCH',headers:h.writeHeaders(),body:JSON.stringify({expected_version:1,keep_recordings:false})})).status,403,'recording changes stay off');
  assert.equal((await h.request('/app-api/media/file-1',{method:'DELETE',headers:h.writeHeaders()})).status,403);
  assert.equal((await h.request('/app-api/settings',{method:'PATCH',headers:{...h.writeHeaders(),'X-CSRF-Token':'wrong'},body:'{}'})).status,403,'CSRF still checked');
  assert.equal((await h.request('/app-api/logout',{method:'POST',headers:h.writeHeaders()})).status,200);
  assert.equal(h.calls.filter(c=>c.method!=='GET').length,0);
});

test('public read keeps exact host checks and the proxy allowlist',async t=>{
  const h=await harness(t);
  for(const route of ['/app-api/voice-rounds','/app-api/../v1/context','/app-api/context?user=bob','/app-api/media/%2e%2e%2fcontext','/app-api/v1/overview'])assert.notEqual((await h.request(route)).status,200,route);
  assert.equal(h.calls.length,0);
  const { request } = await import('node:http');
  const status=await new Promise((resolve,reject)=>{const req=request(h.origin+'/app-api/overview',{headers:{Host:'evil.test'}},res=>{res.resume();resolve(res.statusCode);});req.on('error',reject);req.end();});
  assert.equal(status,400);assert.equal(h.calls.length,0);
});

test('with public read off, every route still needs a sign-in, exactly as before',async t=>{
  const h=await harness(t,{publicRead:false});
  for(const route of ['/app-api/session','/app-api/conversations','/app-api/media/file-1',...reads.map(([r])=>r)]){const r=await h.request(route);assert.equal(r.status,401,route);noKey(r,route);}
  assert.equal(h.calls.length,0);
  const login=await h.login();assert.equal(login.data.public_read,false);
  assert.equal((await h.request('/app-api/overview')).status,200);
  const session=await h.request('/app-api/session');assert.equal(session.data.public_read,false);
});

test('public read against the real local API: real records and a kept recording, still under the account download limit',async t=>{
  const { mkdtemp, rm } = await import('node:fs/promises'), { tmpdir } = await import('node:os'), path = await import('node:path');
  const { Store } = await import('../src/store.mjs'), { createApp } = await import('../src/server.mjs'), { MEDIA_DOWNLOAD_LIMIT } = await import('../src/media.mjs');
  const dir=await mkdtemp(path.join(tmpdir(),'dashboard-public-')),store=new Store(path.join(dir,'test.sqlite'));
  store.addToken(token,'alice');store.addToken('bob-test-token','bob');store.seed('alice');store.put('alice','goals',{id:'alice-goal',version:1,title:'Speak clearly',target:'Lead with one point'});
  store.put('bob','goals',{id:'bob-goal',version:1,title:'Private to Bob',target:'Never returned'});
  const transcript='Um, we ship it today.';
  const models={async transcribe(){return {transcript,turns:[{turn_id:0,start_ms:0,end_ms:900,transcript}],audio_duration_ms:1000,model:'muse-voice-transcribe-1.0',provider_session_id:'fake'};},
    async analyze(){return {status:'model_observation',observation:'One filler.',suggested_exercise:'Answer once.',model:'fake',provider_request_id:'fake'};},
    async voiceReply(){return {status:'model_reply',reply:{move:'follow_up',quote:'we ship it',question:'Why today?'},model:'fake',provider_request_id:'fake',attempts:1};}};
  const api=createApp(store,{models});await listen(api);const base=`http://127.0.0.1:${api.address().port}`;
  t.after(async()=>{await close(api);store.close();await rm(dir,{recursive:true,force:true});});
  const direct=(method,route,init={})=>fetch(base+route,{method,...init,headers:{Authorization:`Bearer ${token}`,'Idempotency-Key':`direct-${Math.random().toString(36).slice(2)}`,...init.headers}});
  const settings=(await (await direct('GET','/v1/settings')).json()).settings;
  assert.equal((await direct('PATCH','/v1/settings',{headers:{'Content-Type':'application/json'},body:JSON.stringify({expected_version:settings.version,keep_recordings:true})})).status,200);
  const wav=Buffer.alloc(44+32000);wav.write('RIFF',0);wav.writeUInt32LE(36+32000,4);wav.write('WAVE',8);wav.write('fmt ',12);wav.writeUInt32LE(16,16);wav.writeUInt16LE(1,20);wav.writeUInt16LE(1,22);wav.writeUInt32LE(16000,24);wav.writeUInt32LE(32000,28);wav.writeUInt16LE(2,32);wav.writeUInt16LE(16,34);wav.write('data',36);wav.writeUInt32LE(32000,40);
  for(let i=0;i<16000;i++)wav.writeInt16LE(Math.round(Math.sin(i/7)*3000),44+i*2);
  const saved=await direct('POST','/v1/recordings',{headers:{'Content-Type':'audio/wav','X-Capture-Device':'watch'},body:wav});assert.equal(saved.status,200);const id=(await saved.json()).record.id;
  const h=await harness(t,{upstream:base,fetchImpl:fetch});
  const context=await h.request('/app-api/context');assert.equal(context.status,200);assert.ok(context.data.goals.length>0);assert.ok(!context.data.goals.some(g=>g.id==='bob-goal'));
  assert.ok(JSON.stringify(context.data).includes(transcript),'the saved capture is visible');noKey(context,'context');
  for(const route of ['/app-api/overview','/app-api/settings','/app-api/session']){const r=await h.request(route);assert.equal(r.status,200,route);noKey(r,route);}
  const media=await h.request('/app-api/media');assert.deepEqual(media.data.media.map(m=>m.id),[id]);
  const download=await h.request(`/app-api/media/${id}`);assert.equal(download.status,200);assert.deepEqual(download.raw,wav);noKey(download,'download');
  assert.equal((await h.request('/app-api/goals/bob-goal')).status,404,'another account stays out of reach');
  assert.equal((await h.request(`/app-api/media/${id}`,{method:'DELETE',headers:{'Idempotency-Key':'test-change-0001'}})).status,401);
  assert.equal((await direct('GET',`/v1/media/${id}`)).status,200,'a visitor delete changed nothing');
  // The account's own download limit still applies behind the public limits.
  for(let i=2;i<MEDIA_DOWNLOAD_LIMIT.requests;i++)await direct('GET',`/v1/media/${id}`);
  const limited=await h.request(`/app-api/media/${id}`);assert.equal(limited.status,429);noKey(limited,'limited');
});

test('public read: the limits come from DASHBOARD_PUBLIC_* variables, validated, with conservative defaults',async t=>{
  assert.deepEqual(publicLimitsFromEnv({}),DEFAULT_PUBLIC_LIMITS,'unset variables keep the defaults');
  assert.deepEqual(Object.values(PUBLIC_LIMIT_ENV),['DASHBOARD_PUBLIC_READ_LIMIT','DASHBOARD_PUBLIC_READ_TOTAL','DASHBOARD_PUBLIC_MEDIA_LIMIT','DASHBOARD_PUBLIC_MEDIA_TOTAL']);
  assert.deepEqual(publicLimitsFromEnv({DASHBOARD_PUBLIC_READ_LIMIT:'7',DASHBOARD_PUBLIC_READ_TOTAL:'70',DASHBOARD_PUBLIC_MEDIA_LIMIT:'2',DASHBOARD_PUBLIC_MEDIA_TOTAL:'9'}),{readLimit:7,readTotal:70,mediaLimit:2,mediaTotal:9});
  assert.deepEqual(publicLimitsFromEnv({DASHBOARD_PUBLIC_MEDIA_LIMIT:'3',DASHBOARD_PUBLIC_READ_TOTAL:''}),{...DEFAULT_PUBLIC_LIMITS,mediaLimit:3},'an empty variable keeps its default');
  for(const bad of ['0','-5','1.5','12abc',' 12','1e3','abc','9999999999'])assert.throws(()=>publicLimitsFromEnv({DASHBOARD_PUBLIC_READ_LIMIT:bad}),/DASHBOARD_PUBLIC_READ_LIMIT must be a positive whole number/,bad);
  assert.throws(()=>publicLimitsFromEnv({DASHBOARD_PUBLIC_MEDIA_LIMIT:'50',DASHBOARD_PUBLIC_MEDIA_TOTAL:'10'}),/cannot exceed its total/);
  for(const bad of [0,-1,2.5,'5',NaN])assert.throws(()=>publicLimits({readLimit:bad}),/positive whole number/,String(bad));
  // The gateway refuses a bad configuration at startup instead of running with no limit.
  assert.throws(()=>createDashboard({origin:'http://127.0.0.1:1',upstream:'https://api.example.test',token,password,secure:false,publicRead:true,publicLimits:{mediaTotal:0}}),/positive whole number/);
  // With no limits given the gateway uses the defaults: a client's audio stops at the default per-client limit.
  let now=1000;const h=await harness(t,{trustProxy:true,now:()=>now,publicLimits:undefined});
  for(let i=0;i<DEFAULT_PUBLIC_LIMITS.mediaLimit;i++)assert.equal((await h.request('/app-api/media/file-1',{headers:{'X-Forwarded-For':'192.0.2.40'}})).status,200);
  assert.equal((await h.request('/app-api/media/file-1',{headers:{'X-Forwarded-For':'192.0.2.40'}})).status,429);
});
