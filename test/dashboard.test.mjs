import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createDashboard } from '../src/dashboard-gateway.mjs';
import { Store } from '../src/store.mjs';
import { createApp } from '../src/server.mjs';
const password='a-long-local-test-access-code', token='test-upstream-credential';
const listen=s=>new Promise(r=>s.listen(0,'127.0.0.1',r));
const close=s=>new Promise(r=>s.close(r));
async function harness(t, options={}) {
  const reservation=createServer();await listen(reservation);const port=reservation.address().port;await close(reservation);
  const origin=`http://127.0.0.1:${port}`,calls=[];
  const server=createDashboard({origin,upstream:'https://api.example.test',token,password,secure:false,allowRecordingChanges:true,fetchImpl:async(url,init)=>{calls.push({url:String(url),...init});return Response.json({goals:[],as_of:new Date().toISOString()});},...options});
  await new Promise(r=>server.listen(port,'127.0.0.1',r));t.after(()=>close(server));
  let cookie='',csrf='';
  const request=async(route,opts={})=>{const res=await fetch(origin+route,{...opts,headers:{Cookie:cookie,Origin:origin,...opts.headers}});const text=await res.text();let data;try{data=JSON.parse(text);}catch{data=text;}return {status:res.status,headers:res.headers,data,text};};
  const login=async()=>{const r=await request('/app-api/login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({password})});assert.equal(r.status,200);cookie=r.headers.get('set-cookie').split(';')[0];csrf=r.data.csrf;return r;};
  return {request,login,calls,origin,writeHeaders:()=>({'X-CSRF-Token':csrf,'Idempotency-Key':'test-change-0001','Content-Type':'application/json'}),cookie:()=>cookie};
}
test('dashboard denies anonymous private data and creates opaque HTTP-only sessions',async t=>{
  const h=await harness(t);assert.equal((await h.request('/app-api/context')).status,401);
  const login=await h.login();assert.match(login.headers.get('set-cookie'),/HttpOnly; SameSite=Strict/);assert.ok(!h.cookie().includes(token));
  const r=await h.request('/app-api/context');assert.equal(r.status,200);assert.equal(r.headers.get('cache-control'),'no-store');assert.equal(h.calls[0].headers.Authorization,`Bearer ${token}`);assert.ok(!r.text.includes(token));
  const html=await h.request('/app/');assert.match(html.headers.get('content-security-policy'),/frame-ancestors 'none'/);assert.ok(!html.text.includes(token));
});
test('dashboard rejects cross-site writes, missing CSRF and arbitrary proxy routes',async t=>{
  const h=await harness(t);await h.login();
  for(const route of ['/app-api/voice-rounds','/app-api/../v1/context','/app-api/context?user=bob','/app-api/media/%2e%2e%2fcontext','/app/.env'])assert.notEqual((await h.request(route)).status,200);
  assert.equal((await h.request('/app-api/settings',{method:'PATCH',headers:h.writeHeaders(),body:JSON.stringify({expected_version:1,keep_recordings:false})})).status,200);
  assert.equal((await h.request('/app-api/settings',{method:'PATCH',headers:{...h.writeHeaders(),Origin:'https://evil.test'},body:'{}'})).status,403);
  assert.equal((await h.request('/app-api/settings',{method:'PATCH',body:'{}'})).status,403);
  assert.equal(h.calls.length,1);
});
test('settings writes allow only versioned recording fields and require idempotency',async t=>{
  const h=await harness(t);await h.login();
  for(const body of [{keep_recordings:true},{expected_version:1,keep_recordings:true,user_id:'bob'},{expected_version:1,keep_recordings:'yes'}])assert.equal((await h.request('/app-api/settings',{method:'PATCH',headers:h.writeHeaders(),body:JSON.stringify(body)})).status,400);
  assert.equal((await h.request('/app-api/media/a',{method:'DELETE',headers:{...h.writeHeaders(),'Idempotency-Key':'short'}})).status,400);assert.equal(h.calls.length,0);
});
test('sessions expire and logout revokes the session',async t=>{
  let now=1000;const h=await harness(t,{now:()=>now,sessionMs:1000});await h.login();now=2001;assert.equal((await h.request('/app-api/context')).status,401);
  await h.login();assert.equal((await h.request('/app-api/logout',{method:'POST',headers:h.writeHeaders()})).status,200);assert.equal((await h.request('/app-api/context')).status,401);
});
test('failed login is throttled without exposing credential values',async t=>{
  const h=await harness(t);for(let i=0;i<5;i++)assert.equal((await h.request('/app-api/login',{method:'POST',headers:{'Content-Type':'application/json'},body:'{"password":"bad"}'})).status,401);
  const r=await h.request('/app-api/login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({password})});assert.equal(r.status,429);assert.ok(!r.text.includes(password));
});
test('upstream errors are sanitized and request time is bounded',async t=>{
  const bad=await harness(t,{fetchImpl:async()=>new Response(`secret ${token}`,{status:401})});await bad.login();const r=await bad.request('/app-api/context');assert.equal(r.status,502);assert.ok(!r.text.includes(token));
  const slow=await harness(t,{timeoutMs:20,fetchImpl:async(_,init)=>new Promise((resolve,reject)=>init.signal.addEventListener('abort',()=>reject(new Error('slow'))))});await slow.login();assert.equal((await slow.request('/app-api/context')).status,504);
});
test('redirects are forbidden and unexpected upstream content is refused',async t=>{
  const h=await harness(t,{fetchImpl:async(_,init)=>{assert.equal(init.redirect,'error');return new Response('<script>unsafe</script>',{headers:{'Content-Type':'text/html'}});}});await h.login();assert.equal((await h.request('/app-api/context')).status,502);
});
test('full Muse conversation history is explicitly unavailable',async t=>{
  const h=await harness(t);await h.login();const r=await h.request('/app-api/conversations');assert.equal(r.data.coverage,'not_connected');assert.deepEqual(r.data.conversations,[]);assert.equal(h.calls.length,0);
});
test('insecure remote origins and upstream URLs are rejected',()=>{
  const base={origin:'https://practice.example',upstream:'https://api.example',token,password};
  assert.throws(()=>createDashboard({...base,origin:'http://practice.example',secure:false}));assert.throws(()=>createDashboard({...base,upstream:'http://api.example'}));assert.throws(()=>createDashboard({...base,password:'short'}));
});
test('real local API contract preserves account ownership, fresh updates and settings conflicts',async t=>{
  const dir=await mkdtemp(path.join(tmpdir(),'dashboard-contract-')),store=new Store(path.join(dir,'test.sqlite'));
  store.addToken(token,'alice');store.addToken('bob-test-token','bob');
  store.put('alice','goals',{id:'alice-goal',version:1,title:'Speak clearly',target:'Lead with one point'});store.put('bob','goals',{id:'bob-goal',version:1,title:'Private to Bob',target:'Never returned to Alice'});
  const upstream=createApp(store);await listen(upstream);
  t.after(async()=>{await close(upstream);store.close();await rm(dir,{recursive:true,force:true});});
  const h=await harness(t,{upstream:`http://127.0.0.1:${upstream.address().port}`,fetchImpl:fetch});await h.login();
  let r=await h.request('/app-api/context');assert.deepEqual(r.data.goals.map(g=>g.id),['alice-goal']);
  assert.equal((await h.request('/app-api/goals/bob-goal')).status,404);assert.equal((await h.request('/app-api/media/bob-file')).status,404);
  store.put('alice','goals',{id:'alice-goal',version:2,title:'Updated on another device',target:'Lead with one point'});r=await h.request('/app-api/context');assert.equal(r.data.goals[0].version,2);
  const settings=(await h.request('/app-api/settings')).data.settings;
  r=await h.request('/app-api/settings',{method:'PATCH',headers:h.writeHeaders(),body:JSON.stringify({expected_version:settings.version,keep_recordings:true})});assert.equal(r.status,200);
  r=await h.request('/app-api/settings',{method:'PATCH',headers:{...h.writeHeaders(),'Idempotency-Key':'test-change-0002'},body:JSON.stringify({expected_version:settings.version,keep_recordings:false})});assert.equal(r.status,409);
  store.revoke(token);assert.equal((await h.request('/app-api/context')).status,502);
});

test('recording changes are disabled by default on a live connection',async t=>{const h=await harness(t,{allowRecordingChanges:false});await h.login();assert.equal((await h.request('/app-api/media/a',{method:'DELETE',headers:h.writeHeaders()})).status,403);assert.equal(h.calls.length,0);});

test('practice requests are readable only through the narrow authenticated GET route',async t=>{
 const h=await harness(t);assert.equal((await h.request('/app-api/practice-rounds/round-1')).status,401);await h.login();
 assert.equal((await h.request('/app-api/practice-rounds/round-1')).status,200);assert.equal(h.calls[0].url,'https://api.example.test/v1/practice-rounds/round-1');
 for(const method of ['POST','PATCH','DELETE'])assert.equal((await h.request('/app-api/practice-rounds/round-1',{method,headers:h.writeHeaders(),body:method==='DELETE'?undefined:'{}'})).status,404);
 assert.equal((await h.request('/app-api/practice-rounds/'+'x'.repeat(65))).status,404);assert.equal(h.calls.length,1);
});

test('one origin serves the public landing and private app with distinct security policies',async t=>{
 const h=await harness(t,{landingRoot:path.resolve('site'),allowRecordingChanges:false});
 const home=await h.request('/');assert.equal(home.status,200);assert.match(home.text,/Practise on your watch/);assert.match(home.text,/href="\/app\/"/);assert.match(home.text,/src="\/motion-init.js"/);
 assert.ok(!home.text.includes(token));assert.equal(h.calls.length,0);
 assert.match(home.headers.get('content-security-policy'),/fonts.googleapis.com/);
 const app=await h.request('/app/');assert.equal(app.status,200);assert.match(app.text,/Your practice/);
 assert.doesNotMatch(app.headers.get('content-security-policy'),/googleapis|unsafe-inline/);
 assert.equal((await h.request('/app-api/context')).status,401);
 await h.login();assert.equal((await h.request('/app-api/context')).status,200);
 assert.equal((await h.request('/app-api/settings',{method:'PATCH',headers:h.writeHeaders(),body:'{}'})).status,403);
});
test('combined public routing allows only site assets and never exposes account or repository files',async t=>{
 const h=await harness(t,{landingRoot:path.resolve('site')});
 for(const name of ['main.js','motion-init.js','styles.css','assets/watch-ready.png'])assert.equal((await h.request('/'+name)).status,200);
 assert.match((await h.request('/assets/watch-ready.png')).headers.get('content-type'),/image\/png/);
 for(const name of ['.env','.git/config','.data/dashboard-production-code.txt','assets/','src/landing-assets.json','build/dashboard/index.html'])assert.equal((await h.request('/'+name)).status,404);
 const head=await h.request('/',{method:'HEAD'});assert.equal(head.status,200);assert.equal(head.text,'');
 assert.equal(h.calls.length,0);
});
test('one dashboard asset list: the build, the hosting app and the gateway all read it, and the gateway serves each',async t=>{
 const { readFile } = await import('node:fs/promises');
 const list=JSON.parse(await readFile(new URL('../web/dashboard-assets.json',import.meta.url),'utf8'));
 assert.ok(list.includes('index.html')&&list.includes('practice-view.js'));
 for(const [file,needle] of [['scripts/dashboard-build.mjs',"web/dashboard-assets.json"],['deploy/dashboard_app.py',"'dashboard-assets.json'"],['src/dashboard-gateway.mjs',"'../web/dashboard-assets.json'"]]){
  const source=await readFile(new URL(`../${file}`,import.meta.url),'utf8');assert.ok(source.includes(needle),`${file} reads the shared list`);
  assert.ok(!source.includes("'practice-view.js'"),`${file} keeps no copy of the list`);
 }
 const h=await harness(t);
 for(const name of list){const r=await h.request(name==='index.html'?'/app/':`/app/${name}`);assert.equal(r.status,200,name);assert.ok(r.headers.get('content-type'),name);}
 assert.equal((await h.request('/app/dashboard-assets.json')).status,404);
});
