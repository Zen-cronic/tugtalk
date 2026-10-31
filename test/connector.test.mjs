import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync,rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Store } from '../src/store.mjs';
import { createApp } from '../src/server.mjs';

test('authenticated coaching loop, correction, persistence and access boundaries', async t=>{
  const dir=mkdtempSync(join(tmpdir(),'coaching-test-')); const path=join(dir,'test.sqlite');
  const store=new Store(path); store.addToken('alice-secret','alice'); store.addToken('bob-secret','bob'); store.addToken('reader-secret','alice',['read']);store.seed('alice');store.seed('bob');
  const server=createApp(store); await new Promise(r=>server.listen(0,'127.0.0.1',r));
  const base=`http://127.0.0.1:${server.address().port}`;
  let next=0;
  const call=async(method,path,body,token='alice-secret',key=`test-key-${++next}`)=>{
    const response=await fetch(base+path,{method,headers:{Authorization:`Bearer ${token}`,'Content-Type':'application/json','Idempotency-Key':key},...(body!==undefined?{body:JSON.stringify(body)}:{})});
    return {status:response.status,data:await response.json()};
  };
  try {
    await t.test('denies missing credentials and private access to docs is unnecessary',async()=>{
      assert.equal((await call('GET','/v1/context',undefined,'')).status,401);
      const spec=await (await fetch(base+'/openapi.json')).json(); assert.equal(spec.openapi,'3.1.0');
    });
    let goal,exercise,receipt;
    await t.test('creates goal and exercise but no completion or measured improvement',async()=>{
      const g=await call('POST','/v1/goals',{title:'Pause before answering',target:'Pause before responding to a question'});assert.equal(g.status,200);goal=g.data.record;
      const e=await call('POST','/v1/exercises',{goal_id:goal.id,title:'One deliberate pause',instructions:'Wait for the question to finish, pause, then answer.'});assert.equal(e.status,200);exercise=e.data.record;
      const ctx=(await call('GET','/v1/context')).data; assert.equal(ctx.check_ins.length,0);assert.equal(ctx.progress.measured_improvement,null);
    });
    await t.test('completion is self-report; exact retry replays receipt without duplicate',async()=>{
      const body={goal_id:goal.id,exercise_id:exercise.id,status:'completed',feedback:'I tried one pause.'};
      const a=await call('POST','/v1/check-ins',body,'alice-secret','completion-once');assert.equal(a.status,200);receipt=a.data.receipt_id;assert.equal(a.data.record.evidence_type,'self_reported');
      const b=await call('POST','/v1/check-ins',body,'alice-secret','completion-once'); assert.equal(b.data.receipt_id,receipt);assert.equal(b.data.replayed,true);
      assert.equal((await call('POST','/v1/check-ins',body)).status,409);
      assert.equal((await call('POST','/v1/check-ins',{...body,feedback:'different'},'alice-secret','completion-once')).status,409);
      assert.equal((await call('GET','/v1/context')).data.progress.self_reported_completions,1);
    });
    await t.test('validates schemas, scopes, ownership and references',async()=>{
      assert.equal((await call('POST','/v1/goals',{title:'bad',target:'test',user_id:'bob'})).status,400);
      assert.equal((await call('POST','/v1/goals',{title:'test',target:'test'},'reader-secret')).status,403);
      assert.equal((await call('POST','/v1/exercises',{goal_id:goal.id,title:'wrong account',instructions:'test'},'bob-secret')).status,404);
      assert.equal((await call('GET','/v1/context',undefined,'bob-secret')).data.goals.length,0);
      assert.equal((await call('GET','/v1/receipts',undefined,'bob-secret')).data.receipts.length,0);
    });
    await t.test('corrects evidence and goal, rejects stale update, hides deleted session',async()=>{
      const a=await call('PATCH','/v1/sessions/session-after',{expected_version:1,transcript:'Correction: the speaker interrupted before the question ended.',pause_before_answer_ms:80,correction_reason:'Fixture attribution corrected.'});assert.equal(a.status,200);assert.equal(a.data.record.version,2);
      assert.equal((await call('PATCH','/v1/sessions/session-after',{expected_version:1,deleted:true,correction_reason:'stale'})).status,409);
      assert.equal((await call('PATCH',`/v1/goals/${goal.id}`,{expected_version:1,target:'Listen to the entire question before answering'})).status,200);
      const ctx=(await call('GET','/v1/context')).data;assert.equal(ctx.sessions.find(s=>s.id==='session-after').pause_before_answer_ms,80);assert.equal(ctx.goals[0].version,2);
      assert.equal((await call('PATCH','/v1/sessions/session-after',{expected_version:2,deleted:true,correction_reason:'Remove fixture from active evidence'})).status,200);
      assert.equal((await call('GET','/v1/context')).data.sessions.length,1);
    });
    await t.test('audit proves requests and revocation stops subsequent access',async()=>{
      const rows=store.db.prepare('SELECT * FROM requests').all();assert.ok(rows.some(r=>r.path==='/v1/check-ins'&&r.status===200));assert.ok(rows.every(r=>!JSON.stringify(r).includes('secret')));
      store.revoke('alice-secret');assert.equal((await call('GET','/v1/context')).status,401);
    });
  } finally { await new Promise(r=>server.close(r));store.close(); }
  const reopened=new Store(path);assert.equal(reopened.context('alice').progress.self_reported_completions,1);assert.equal(reopened.context('alice').goals[0].version,2);reopened.close();rmSync(dir,{recursive:true,force:true});
});
