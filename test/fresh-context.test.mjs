import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {Store} from '../src/store.mjs';
import {createApp} from '../src/server.mjs';
import {createFreshReader} from '../src/fresh-client.mjs';

test('two goal clients update independently; overview refreshes and preserves ownership',async()=>{
 const dir=mkdtempSync(join(tmpdir(),'fresh-goals-')); const store=new Store(join(dir,'state.sqlite'));
 store.addToken('test-a','alice');store.addToken('test-b','bob');store.seed('alice');
 const server=createApp(store);await new Promise(r=>server.listen(0,'127.0.0.1',r));
 const base=`http://127.0.0.1:${server.address().port}`;
 const reader=createFreshReader({baseUrl:base,token:'test-a'});let seq=0;
 const write=async(method,path,body)=>{
   const r=await fetch(base+path,{method,headers:{Authorization:'Bearer test-a','Content-Type':'application/json','Idempotency-Key':`fresh-test-${++seq}`},body:JSON.stringify(body)});
   return {status:r.status,data:await r.json()};
 };
 try {
   const a=(await write('POST','/v1/goals',{title:'Listening',target:'Wait'})).data.record;
   const b=(await write('POST','/v1/goals',{title:'Clarity',target:'Be concise'})).data.record;
   const ea=(await write('POST','/v1/exercises',{goal_id:a.id,title:'A practice',instructions:'Wait'})).data.record;
   const eb=(await write('POST','/v1/exercises',{goal_id:b.id,title:'B practice',instructions:'Be concise'})).data.record;
   const initial=await reader.overview();assert.equal(initial.totals.pending_exercises,2);
   await write('POST','/v1/check-ins',{goal_id:a.id,exercise_id:ea.id,status:'completed',feedback:'A only'});
   await write('POST','/v1/check-ins',{goal_id:b.id,exercise_id:eb.id,status:'skipped',feedback:'B only'});
   await write('PATCH',`/v1/goals/${a.id}`,{expected_version:1,target:'Listen fully'});
   assert.equal((await write('PATCH',`/v1/goals/${a.id}`,{expected_version:1,target:'Stale overwrite'})).status,409);
   const fresh=await reader.overview();assert.notEqual(fresh.snapshot_revision,initial.snapshot_revision);assert.notEqual(fresh.request_id,initial.request_id);
   assert.equal(fresh.totals.self_reported_completions,1);assert.equal(fresh.totals.skipped_exercises,1);assert.equal(fresh.totals.pending_exercises,0);
   const af=await reader.goal(a.id), bf=await reader.goal(b.id);
   assert.equal(af.goal.version,2);assert.equal(bf.goal.version,1);
   assert.deepEqual(af.check_ins.map(c=>c.feedback),['A only']);assert.deepEqual(bf.check_ins.map(c=>c.feedback),['B only']);
   assert.equal(af.goal.progress.self_reported_completions,1);assert.equal(bf.goal.progress.self_reported_completions,0);
   const r=await fetch(base+`/v1/goals/${a.id}/context`,{headers:{Authorization:'Bearer test-b'}});assert.equal(r.status,404);
   const noCache=await fetch(base+'/v1/overview',{headers:{Authorization:'Bearer test-a'}});assert.equal(noCache.headers.get('cache-control'),'no-store');
   store.revoke('test-a');await assert.rejects(reader.overview(),/unavailable/);
 } finally {await new Promise(r=>server.close(r));store.close();rmSync(dir,{recursive:true,force:true});}
});

test('reader rejects stale or absent metadata and does not fall back after a failed refresh',async()=>{
 let fail=false;let stale=false;
 const reader=createFreshReader({baseUrl:'https://example.test',token:'local-only',fetchImpl:async(url,options)=>{
   assert.equal(options.cache,'no-store');
   if(fail)throw new Error('network unavailable');
   return new Response(JSON.stringify({as_of:new Date(Date.now()-(stale?60000:0)).toISOString(),snapshot_revision:'revision',request_id:'request'}),{headers:{'X-Request-Id':'request'}});
 }});
 await reader.overview();fail=true;await assert.rejects(reader.overview(),/network unavailable/);
 fail=false;stale=true;await assert.rejects(reader.overview(),/stale/);
});
