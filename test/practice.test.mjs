import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Store } from '../src/store.mjs';
import { createApp } from '../src/server.mjs';
import { createPractice, changePractice, getPractice, claimPractice, failPractice, finishPractice, selectedPractice, validateAssessment, UNAVAILABLE_QUESTION } from '../src/practice.mjs';
import { voiceParams, handleVoiceRound } from '../src/voice.mjs';
import { createLiveRound, wavFromPcm } from '../src/live-voice.mjs';
import { checkBasis, recordDrillResult, basisFreshness } from '../src/drills.mjs';

const transcript='I cannot promise Friday until security approves; I will ask them today.';
const objective={id:'delivery',text:'Explain the delivery commitment and its dependency.'};
const evidence={start:0,end:transcript.length,quote:transcript};
const sampleAssessment=(status='addressed')=>({objectives:[{id:'delivery',status,evidence:[evidence],missing:status==='addressed'?'':'A commitment is still missing.'}],next_question:'What will you ask security today?'});
const body=(goal='goal-a',extra={})=>({goal_id:goal,expected_goal_version:1,request_text:'When can you deliver, and what does it depend on?',objectives:[objective],confirmed:true,...extra});
const audio=wavFromPcm(Buffer.alloc(24000*2));
const phases={async release(){},async acquire(){}};
async function fixture(fn) {
 const dir=mkdtempSync(join(tmpdir(),'practice-'));const store=new Store(join(dir,'state.sqlite'));let seq=0;
 for(const id of ['goal-a','goal-b'])store.put('alice','goals',{id,version:1,title:'Delivery',target:'Answer the actual request',updated_at:new Date().toISOString()});
 store.addToken('test-token','alice');
 const create=(goal='goal-a',extra={})=>createPractice(store,'alice',body(goal,extra),`create-${++seq}`).record;
 const change=(r,action,extra={})=>{const {goal_id,...rest}=extra;return changePractice(store,'alice',r.id,{expected_version:r.version,action,...rest},`change-${++seq}`).record;};
 const params=(goal='goal-a',extra={})=>voiceParams({'x-goal-id':goal,...extra});
 let calls=0,asrs=0;const prompts=[];
 const models={async transcribe(){asrs++;return {transcript,turns:[],model:'stub',provider_session_id:'stub'};},async voiceReply(input){calls++;prompts.push(input);return {status:'model_reply',reply:{move:'follow_up',quote:transcript,question:'What will you ask security today?',assessment:sampleAssessment()},model:'stub-spark',attempts:1};}};
 const send=(key='answer-001',p=params(),m=models,ph=phases)=>handleVoiceRound(store,m,'alice',{params:p,audio},key,'request',ph);
 try{await fn({store,create,change,params,models,send,prompts,counts:()=>({calls,asrs})});}finally{store.close();rmSync(dir,{recursive:true,force:true});}
}

test('confirmed briefs validate ownership, source versions, objective IDs, and one open round per goal',()=>fixture(({store,create})=>{
 const r=create();assert.equal(r.state,'open');assert.throws(()=>create(),e=>e.code==='practice_open');assert.equal(create('goal-b').goal_id,'goal-b');
 for(const extra of [{confirmed:false},{objectives:[objective,objective]},{sources:[{kind:'sessions',id:'missing',version:1}]}])assert.throws(()=>create('goal-a',extra));
 assert.throws(()=>getPractice(store,'bob',r.id),e=>e.status===404);
}));
test('lifecycle revises older closed rounds without selector confusion and forbids two open rounds',()=>fixture(({store,create,change,params})=>{
 let old=create();old=change(old,'end');let newer=create();newer=change(newer,'end');
 old=change(old,'revise',body());assert.equal(selectedPractice(store,'alice',params()).id,old.id);assert.equal(old.request_version,2);
 assert.throws(()=>change(newer,'revise',body()),e=>e.code==='practice_open');
 const disputed=change(old,'dispute');assert.equal(disputed.request_version,2);assert.equal(disputed.state,'disputed');assert.equal(disputed.assessment,null);
}));
test('per-objective shape/evidence validation abstains without inventing semantic proof',()=>{
 assert.equal(validateAssessment(sampleAssessment(),[objective],transcript).objectives[0].status,'addressed');
 for(const raw of [null,{}, {objectives:[]}, {...sampleAssessment(),objectives:[{...sampleAssessment().objectives[0],evidence:[{start:0,end:2,quote:'XX'}]}]}, {...sampleAssessment(),objectives:[...sampleAssessment().objectives,...sampleAssessment().objectives]}, {...sampleAssessment(),objectives:[...sampleAssessment().objectives,{id:'extra'}]}]){
  const a=validateAssessment(raw,[objective],transcript);assert.ok(a.objectives.every(o=>o.status==='unclear'));
 }
 const emoji='🙂 yes'; const a=validateAssessment({objectives:[{id:'delivery',status:'partial',evidence:[{start:3,end:6,quote:'yes'}],missing:'Need date'}],next_question:'When can you deliver?'},[objective],emoji);
 assert.equal(a.objectives[0].status,'partial');
});
test('semantic WAV saves goal state, separates model judgment, resets legacy need and replays after replacement',()=>fixture(async({store,create,change,send,counts,prompts})=>{
 const r=create();const response=await send();assert.equal(response.practice.state,'addressed');assert.equal(response.counterpart.answer,1);assert.equal(response.counterpart.need,null);assert.equal(response.counterpart.need_met,null);assert.equal(response.gate.reason,'model_assessed_addressed');assert.match(response.reply.question,/My assessment/);assert.doesNotMatch(response.reply.question,/\?/);
 assert.equal(getPractice(store,'alice',r.id).version,2);assert.equal(getPractice(store,'alice',r.id).assessment.evidence_type,'model_assessment');
 create();const replay=await send();assert.equal(replay.replayed,true);assert.equal(replay.round_id,response.round_id);assert.deepEqual(counts(),{calls:1,asrs:1});
 assert.match(prompts[0].system,/unrelated number/);assert.equal(JSON.parse(prompts[0].user).confirmed_request,body().request_text);
 assert.equal(store.freshContext('alice','goal-b').practice_rounds,undefined);
}));
test('partial, unrelated and negated fixture judgments never close by keyword; unavailable fallback stays explicit',()=>fixture(async({store,create,params,models,send})=>{
 const r=create();let n=0;
 const stub={...models,async voiceReply(){n++;return n===4?{status:'unavailable',attempts:1}:{status:'model_reply',reply:{move:'wrap_up',question:'Done?',assessment:sampleAssessment(n===1?'partial':n===2?'not_addressed':'unclear')},attempts:1};}};
 for(let i=1;i<=4;i++){
  const out=await send(`answer-${i}`,params('goal-a',{'x-counterpart-need':'date'}),stub);assert.notEqual(out.gate.reason,'measured_close');
  assert.equal(out.practice.state,i===4?'capped':'open');assert.equal(out.counterpart.need_met,null);assert.equal(out.counterpart.answer,1);assert.equal(out.practice.answer,i);
  if(i===4){assert.match(out.reply.question,/couldn't assess/);assert.match(out.reply.question,/round is over/);assert.equal(out.practice.assessment.status,'unavailable');}
 }
 assert.equal(getPractice(store,'alice',r.id).state,'capped');
}));
test('reservation survives store reopen; concurrent answers and reused failed keys spend nothing',()=>fixture(async({store,create,params,send,counts})=>{
 const r=create(), p=params();const reservation=claimPractice(store,'alice',p,'pending-key');store.close();store.reopen();
 await assert.rejects(send('other-key'),e=>e.code==='turn_in_progress');await assert.rejects(send('pending-key'),e=>e.code==='turn_in_progress');assert.deepEqual(counts(),{calls:0,asrs:0});
 assert.throws(()=>store.replay('alice','POST','/v1/recordings',{},'pending-key'),e=>e.code==='idempotency_conflict');
 assert.throws(()=>changePractice(store,'alice',r.id,{action:'end',expected_version:1},'end-key-1'),e=>e.code==='turn_in_progress');
 failPractice(store,'alice',reservation);await assert.rejects(send('pending-key'),e=>e.code==='attempt_consumed');
}));
test('recovery invalidates nonce and old late result; new revision clears old answer dependencies',()=>fixture(async({store,create,change,params,send,models})=>{
 const r=create();const reservation=claimPractice(store,'alice',params(),'abandoned-key');const raw=store.get('alice','practice-rounds',r.id);raw.pending.since=new Date(Date.now()-301000).toISOString();store.put('alice','practice-rounds',raw);
 const recovered=change(raw,'recover');assert.equal(recovered.reservation_epoch,1);assert.equal(recovered.pending,null);assert.throws(()=>finishPractice(store,'alice',reservation,{id:'late',version:1,reply:{question:'late'}},validateAssessment(sampleAssessment(),[objective],transcript),{}),e=>e.code==='reservation_expired');failPractice(store,'alice',reservation);assert.equal(store.get('alice','practice-rounds',r.id).version,recovered.version);
 const out=await send('fresh-key');let current=store.get('alice','practice-rounds',r.id);const voice=store.get('alice','voice-rounds',out.round_id);store.put('alice','voice-rounds',{...voice,version:2,deleted:true});assert.equal(getPractice(store,'alice',r.id).state,'stale');
 current=change(current,'revise',body());assert.deepEqual(current.answer_sources,[]);assert.equal(getPractice(store,'alice',r.id).state,'open');
}));
test('stale goal/source blocks inference and suppresses current assessment; count drills cannot use it',()=>fixture(async({store,create,send,params,counts})=>{
 store.put('alice','screen-contexts',{id:'screen-a',version:1,goal_id:'goal-a',deleted:false,occurred_at:new Date().toISOString()});const r=create('goal-a',{sources:[{kind:'screen-contexts',id:'screen-a',version:1}]});
 const response=await send();const b=checkBasis(store,'alice','goal-a',{habit:'hedge',source_ids:[response.round_id],claimed_count:response.metrics.hedge_count});
 store.put('alice','screen-contexts',{id:'screen-a',version:2,goal_id:'goal-a',deleted:true});
 const view=getPractice(store,'alice',r.id);assert.equal(view.state,'stale');assert.equal(view.request_text,null);assert.equal(view.assessment,null);assert.equal(basisFreshness(store,'alice',b).status,'stale');
 assert.throws(()=>checkBasis(store,'alice','goal-a',{habit:'hedge',source_ids:[response.round_id],claimed_count:response.metrics.hedge_count}),e=>e.code==='basis_source_invalid');
 await assert.rejects(send('later-key'),e=>e.code==='practice_stale');assert.deepEqual(counts(),{calls:1,asrs:1});
 store.put('alice','exercises',{id:'exercise-a',version:1,goal_id:'goal-a',basis:b});
 assert.equal(recordDrillResult(store,'alice',{id:'new-capture',metrics:{hedge_count:0}},'exercise-a').reason,'basis_stale');
}));
test('fresh snapshot revision changes after reservation/source mutation and independent goals remain isolated',()=>fixture(async({store,create,params,send,models})=>{
 const a=create(),b=create('goal-b');const initial=store.freshContext('alice');const reservation=claimPractice(store,'alice',params(),'reserved-a');
 assert.notEqual(store.freshContext('alice').snapshot_revision,initial.snapshot_revision);const out=await send('answer-b',params('goal-b'));assert.equal(out.practice.round_id,b.id);assert.equal(getPractice(store,'alice',a.id).answer_count,0);
 failPractice(store,'alice',reservation);const old=store.freshContext('alice').snapshot_revision;store.put('alice','goals',{...store.get('alice','goals','goal-a'),version:2});assert.notEqual(store.freshContext('alice').snapshot_revision,old);
}));
test('closed/stale/code-only explicit or implicit rounds refuse before ASR; legacy goal remains supported',()=>fixture(async({store,create,change,params,send,counts})=>{
 let r=create();await assert.rejects(send('code-key',params('goal-a',{'x-reply-mode':'code'})),e=>e.code==='semantic_model_required');
 await assert.rejects(send('version-key',params('goal-a',{'x-practice-round-id':r.id,'x-practice-round-version':'2'})),e=>e.code==='version_conflict');
 change(r,'end');await assert.rejects(send('closed-key'),e=>e.code==='practice_closed');assert.deepEqual(counts(),{calls:0,asrs:0});
 const legacy=await send('legacy-key',params('goal-b'));assert.equal(legacy.practice,undefined);
}));
test('failed transcription consumes semantic attempt but does not fabricate an answer',()=>fixture(async({store,create,send,models,counts})=>{
 const r=create();await assert.rejects(send('failed-key',undefined,{...models,async transcribe(){throw new Error('failed');}}));
 await assert.rejects(send('failed-key'),e=>e.code==='attempt_consumed');assert.equal(getPractice(store,'alice',r.id).answer_count,0);
 const fallback=await send('fallback-key',undefined,{...models,async voiceReply(){return {status:'unavailable',attempts:1};}});assert.equal(fallback.reply.question,UNAVAILABLE_QUESTION);assert.equal(fallback.practice.state,'open');
}));
test('source mutation during model call refuses application; no speech is prefetched',()=>fixture(async({store,create,send,models})=>{
 const r=create();let speech=0;const changed={...models,async voiceReply(input){const result=await models.voiceReply(input);store.put('alice','goals',{...store.get('alice','goals','goal-a'),version:2});return result;},prefetchSpeech(){speech++;}};
 await assert.rejects(send('change-key',undefined,changed),e=>e.code==='practice_stale');assert.equal(speech,0);assert.equal(getPractice(store,'alice',r.id).answer_count,0);
}));
test('durability failure before inference spends nothing; after assessment emits no semantic speech',()=>fixture(async({store,create,send,models,counts})=>{
 create();await assert.rejects(send('persist-fail',undefined,models,{...phases,async persist(){throw new Error('commit failed');}}));assert.deepEqual(counts(),{calls:0,asrs:0});
}));
test('live semantic turn commits before reply, same-key WAV replays, and durability failure suppresses output',()=>fixture(async({store,create,params,models,send})=>{
 create();let persisted=0;const events=[];
 const live=createLiveRound({store,models,token:'test-token',start:{type:'start',idempotency_key:'live-key-1',goal_id:'goal-a',speech:false},phases:{...phases,async persist(){persisted++;}},emit:e=>{if(e.type==='reply')assert.equal(persisted,2);events.push(e);}});
 live.audio(Buffer.alloc(24000*2));live.end();const result=await live.done;assert.equal(result.status,200,JSON.stringify(result.body));assert.equal(result.body.counterpart.need,null);assert.equal(events.find(e=>e.type==='reply').practice.state,'addressed');
 const replay=await send('live-key-1');assert.equal(replay.replayed,true);
 create();let commits=0,speech=0;const seen=[];
 const failed=createLiveRound({store,models:{...models,prefetchSpeech(){speech++;}},token:'test-token',start:{type:'start',idempotency_key:'live-key-2',goal_id:'goal-a'},phases:{...phases,async persist(){if(++commits===2)throw new Error('commit failed');}},emit:e=>seen.push(e)});
 failed.audio(Buffer.alloc(24000*2));failed.end();assert.equal((await failed.done).status,500);assert.equal(seen.some(e=>e.type==='reply'),false);assert.equal(speech,0);
}));
test('authenticated HTTP practice routes expose current state in fresh context with version conflicts',()=>fixture(async({store})=>{
 const server=createApp(store);await new Promise(r=>server.listen(0,'127.0.0.1',r));const base=`http://127.0.0.1:${server.address().port}`;
 const request=async(method,path,b)=>{const r=await fetch(base+path,{method,headers:{Authorization:'Bearer test-token','Content-Type':'application/json','Idempotency-Key':'http-key-1'},...(b?{body:JSON.stringify(b)}:{})});return {status:r.status,body:await r.json()};};
 try{const r=await request('POST','/v1/practice-rounds',body());assert.equal(r.status,200);assert.equal((await request('GET',`/v1/practice-rounds/${r.body.record.id}`)).body.state,'open');const overview=await request('GET','/v1/overview');assert.equal(overview.body.practice_rounds.length,1);}
 finally{await new Promise(r=>server.close(r));}
}));
test('fresh context computes practice freshness once per practice round, with byte-identical output',()=>fixture(async({store,create,send,params,models})=>{
 const partial={...models,async voiceReply(){return {status:'model_reply',reply:{move:'follow_up',quote:'',question:'And then?',assessment:sampleAssessment('partial')},attempts:1};}};
 const a=create();for(const key of ['memo-a1','memo-a2'])await send(key,params('goal-a'),partial);
 const b=create('goal-b');const answer=await send('memo-b1',params('goal-b'));
 store.put('alice','exercises',{id:'drill-memo',version:1,goal_id:'goal-b',basis:checkBasis(store,'alice','goal-b',{habit:'hedge',source_ids:[answer.round_id],claimed_count:answer.metrics.hedge_count})});
 // One round goes stale (its goal changes), so both current and hidden projections are covered.
 store.put('alice','goals',{...store.get('alice','goals','goal-b'),version:2});
 assert.equal(getPractice(store,'alice',b.id).state,'stale');assert.equal(getPractice(store,'alice',a.id).answer_count,2);
 const views=()=>{const strip=({as_of,...rest})=>rest;return JSON.stringify([strip(store.freshContext('alice')),strip(store.freshContext('alice','goal-a')),strip(store.freshContext('alice','goal-b')),strip(store.context('alice'))]);};
 let sets=0,gets=0;const counting=store.freshnessMemo.bind(store);
 store.freshnessMemo=()=>{const m=counting();return {get:k=>{gets++;return m.get(k);},set:(k,v)=>{sets++;m.set(k,v);}};};
 const memoized=views();
 assert.ok(sets<=2*4,'at most one computation per practice round per read');assert.ok(gets>sets,'later checks are lookups');
 store.freshnessMemo=()=>({get(){},set(){}});
 assert.equal(memoized,views(),'the memo changes no byte of any view');
}));
test('a deleted practice voice round is refused as deleted, not as practice_stale',()=>fixture(async({store,create,send})=>{
 create();const out=await send('deleted-basis');const voice=store.get('alice','voice-rounds',out.round_id);
 store.put('alice','voice-rounds',{...voice,version:2,deleted:true});
 assert.throws(()=>checkBasis(store,'alice','goal-a',{habit:'hedge',source_ids:[out.round_id],claimed_count:0}),e=>e.code==='basis_source_invalid'&&e.details.refused[0].reason==='deleted');
 assert.throws(()=>checkBasis(store,'alice','goal-a',{habit:'hedge',source_ids:['missing-round'],claimed_count:0}),e=>e.details.refused[0].reason==='not_found');
}));
