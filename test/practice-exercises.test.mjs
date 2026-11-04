import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {Store} from '../src/store.mjs';
import {createApp} from '../src/server.mjs';
import {createPractice,changePractice,getPractice,claimPractice,failPractice} from '../src/practice.mjs';
import {createPracticeExercise,changePracticeExercise,getPracticeExercise} from '../src/practice-exercises.mjs';
import {handleVoiceRound,voiceParams} from '../src/voice.mjs';
import {createLiveRound,wavFromPcm} from '../src/live-voice.mjs';
const text='I can deliver on Tuesday if the external approval arrives Monday.';
const audio=wavFromPcm(Buffer.alloc(48000)),phases={async release(){},async acquire(){}};
async function fixture(fn){
 const dir=mkdtempSync(join(tmpdir(),'practice-exercises-')),store=new Store(join(dir,'db.sqlite'));let seq=0,calls=0,outcome='addressed';
 store.addToken('exercise-token','u');
 for(const id of ['goal-a','goal-b'])store.put('u','goals',{id,version:1,title:'Delivery',target:'Explain commitments',updated_at:new Date().toISOString()});
 const models={async transcribe(){calls++;return {transcript:text,turns:[],model:'stub-asr',provider_session_id:'stub'};},async voiceReply(){calls++;return {status:'model_reply',model:'stub-spark',attempts:1,reply:{move:'follow_up',quote:text,question:'What approval is needed?',assessment:{objectives:[{id:'delivery',status:outcome,evidence:outcome==='unclear'?[]:[{start:0,end:text.length,quote:text}],missing:outcome==='addressed'?'':'Explain dependency.'}],next_question:'What approval is needed?'}}};}};
 const key=()=>`exercise-${++seq}`;
 const answer=(goal='goal-a',m=models,k=key(),p=phases)=>handleVoiceRound(store,m,'u',{params:voiceParams({'x-goal-id':goal}),audio},k,'fixture',p);
 const source=async(goal='goal-a',status='addressed')=>{
  outcome=status;const r=createPractice(store,'u',{goal_id:goal,expected_goal_version:1,request_text:'When can you deliver the report?',objectives:[{id:'delivery',text:'Explain delivery commitment and dependency.'}],confirmed:true},key()).record;
  const response=await answer(goal);let round=store.get('u','practice-rounds',r.id);
  if(status!=='addressed')round=changePractice(store,'u',r.id,{action:'end',expected_version:round.version},key()).record;
  return {round,voice:store.get('u','voice-rounds',response.round_id)};
 };
 const payload=({round,voice},extra={})=>({goal_id:round.goal_id,expected_goal_version:1,title:'A different delivery conversation',request_text:'Fictional practice: a customer wants Tuesday delivery before a required external approval. Explain your commitment.',scenario_type:'fictional_practice',purpose:'transfer',basis:{round_id:round.id,round_version:round.version,request_version:round.request_version,voice_id:voice.id,voice_version:voice.version,objective_id:'delivery'},...extra});
 const propose=(s,extra={},k=key())=>createPracticeExercise(store,'u',payload(s,extra),k).record;
 const change=(e,action,extra={},k=key())=>changePracticeExercise(store,'u',e.id,{expected_version:e.version,action,...extra},k).record;
 const activate=(e,k=key())=>change(e,'activate',{confirmed:true,expected_goal_version:1,content_version:1},k);
 const current=e=>store.get('u','practice-exercises',e.id);
 try{await fn({store,models,key,source,payload,propose,change,activate,current,answer,setOutcome:s=>{outcome=s;},calls:()=>calls});}finally{store.close();rmSync(dir,{recursive:true,force:true});}
}

test('proposal copies source objective and provenance without model calls or count-drill overload',()=>fixture(async({store,source,propose,calls})=>{
 const s=await source(),before=calls(),e=propose(s);assert.equal(calls(),before);assert.equal(e.state,'proposed');assert.equal(e.created_via,'connector');assert.equal(e.scenario_type,'fictional_practice');assert.deepEqual(e.objective,s.round.objectives[0]);assert.equal(e.basis.source_outcome,'addressed');
 assert.equal(store.list('u','exercises').length,0);assert.equal(store.list('u','check-ins').length,0);assert.equal(store.freshContext('u','goal-a').practice_exercises[0].id,e.id);assert.equal(store.freshContext('u','goal-b').practice_exercises,undefined);
 assert.throws(()=>getPracticeExercise(store,'other',e.id),e=>e.status===404);
}));
test('basis refuses wrong goal/account/version/latest answer, uncertain assessment, wrong purpose and copied scenario',()=>fixture(async({store,source,propose,payload,key})=>{
 const s=await source();
 for(const extra of [{goal_id:'goal-b'},{basis:{...payload(s).basis,round_version:99}},{basis:{...payload(s).basis,voice_version:99}},{basis:{...payload(s).basis,objective_id:'missing'}},{purpose:'address_gap'},{request_text:s.round.request_text}])assert.throws(()=>propose(s,extra));
 assert.throws(()=>createPracticeExercise(store,'other',payload(s),key()),e=>e.status===404);
 const uncertain=await source('goal-b','unclear');assert.throws(()=>propose(uncertain,{purpose:'address_gap'}),e=>e.code==='exercise_basis_unclear');
}));
test('gap purpose accepts partial terminal source and rejects transfer',()=>fixture(async({source,propose})=>{
 const s=await source('goal-a','partial');assert.throws(()=>propose(s),e=>e.code==='exercise_basis_unclear');assert.equal(propose(s,{purpose:'address_gap'}).basis.source_outcome,'partial');
}));
test('exact proposal/activation retries create one target and lifecycle updates do not invalidate themselves',()=>fixture(async({store,source,propose,activate,payload,calls})=>{
 const s=await source(),e=propose(s,{},'propose-exact'),count=calls();const replay=createPracticeExercise(store,'u',payload(s),'propose-exact');assert.equal(replay.replayed,true);assert.equal(replay.record.id,e.id);
 const active=activate(e,'activate-exact');assert.equal(active.state,'active');assert.equal(active.freshness.status,'current');assert.equal(getPractice(store,'u',active.activation.round_id).state,'open');assert.equal(calls(),count);
 const again=changePracticeExercise(store,'u',e.id,{expected_version:1,action:'activate',confirmed:true,expected_goal_version:1,content_version:1},'activate-exact');assert.equal(again.replayed,true);assert.equal(again.record.activation.round_id,active.activation.round_id);assert.equal(store.list('u','practice-rounds').length,2);
 assert.throws(()=>activate(active),e=>e.code==='exercise_transition');
}));
test('one proposed/active per goal and activation races with open A round safely roll back',()=>fixture(async({store,source,propose,activate,key,current})=>{
 const s=await source(),e=propose(s);assert.throws(()=>propose(s),e=>e.code==='practice_exercise_open');
 const other=createPractice(store,'u',{goal_id:'goal-a',expected_goal_version:1,request_text:'Another confirmed request',objectives:[{id:'delivery',text:'Explain a commitment.'}],confirmed:true},key()).record;
 assert.throws(()=>activate(e),e=>e.code==='practice_open');assert.equal(current(e).state,'proposed');assert.equal(store.list('u','practice-rounds').length,2);
 changePractice(store,'u',other.id,{expected_version:1,action:'end'},key());assert.equal(activate(e).state,'active');
}));
test('matching target answer atomically records model-assessed result and never a measured check-in',()=>fixture(async({store,source,propose,activate,answer,current})=>{
 const active=activate(propose(await source()));const response=await answer();const e=current(active);assert.equal(e.state,'assessed_addressed');assert.equal(e.result.voice_id,response.round_id);assert.equal(e.result.evidence_type,'model_assessment');assert.equal(e.result.assessment.status,'assessed');assert.equal(getPracticeExercise(store,'u',e.id).freshness.status,'current');assert.equal(getPractice(store,'u',active.activation.round_id).state,'addressed');assert.equal(store.list('u','check-ins').length,0);
}));
test('cap and explicit end are attempted, unavailable/partial open answers do not complete',()=>fixture(async({store,source,propose,activate,answer,current,setOutcome,key})=>{
 let active=activate(propose(await source()));setOutcome('partial');for(let i=1;i<=4;i++){await answer();assert.equal(current(active).state,i===4?'attempted':'active');}
 assert.equal(current(active).result.assessment.objectives[0].status,'partial');
 const s=await source('goal-b');active=activate(propose(s));const target=store.get('u','practice-rounds',active.activation.round_id);changePractice(store,'u',target.id,{expected_version:target.version,action:'end'},key());assert.equal(current(active).state,'attempted');assert.equal(current(active).result,null);
}));
test('source correction before activation and during inference refuses current semantic completion',()=>fixture(async({store,source,propose,activate,answer,models,current})=>{
 const s=await source(),e=propose(s);store.put('u','voice-rounds',{...s.voice,version:2,deleted:true});assert.throws(()=>activate(e),e=>e.code==='exercise_stale');const hidden=getPracticeExercise(store,'u',e.id);assert.equal(hidden.state,'stale');assert.equal(hidden.request_text,null);assert.equal(hidden.objective,null);
 const second=await source('goal-b'),active=activate(propose(second));const changed={...models,async voiceReply(input){const out=await models.voiceReply(input);store.put('u','voice-rounds',{...second.voice,version:2,deleted:true});return out;}};
 await assert.rejects(answer('goal-b',changed),e=>e.code==='practice_stale');assert.equal(current(active).state,'active');assert.equal(current(active).result,null);assert.equal(getPractice(store,'u',active.activation.round_id).state,'stale');
}));
test('terminal exercise dispute suppresses both exercise result and linked terminal A judgment',()=>fixture(async({store,source,propose,activate,answer,current,change})=>{
 let e=activate(propose(await source()));await answer();e=current(e);const target=store.get('u','practice-rounds',e.activation.round_id);
 assert.throws(()=>change(e,'dispute',{expected_target_round_version:99}),e=>e.code==='version_conflict');const disputed=change(e,'dispute',{expected_target_round_version:target.version});assert.equal(disputed.state,'disputed');assert.equal(disputed.result,null);const projected=getPractice(store,'u',target.id);assert.equal(projected.assessment,null);assert.notEqual(projected.state,'addressed');
 const focused=store.freshContext('u','goal-a');assert.equal(focused.practice_exercises[0].result,null);assert.equal(focused.practice_rounds.find(r=>r.id===target.id).assessment,null);
 assert.throws(()=>activate(current(e)),e=>e.code==='exercise_transition');
}));
test('target answer deletion or correction revokes current completion interpretation',()=>fixture(async({store,source,propose,activate,answer,current})=>{
 const e=activate(propose(await source()));const response=await answer();const v=store.get('u','voice-rounds',response.round_id);store.put('u','voice-rounds',{...v,version:v.version+1,deleted:true});assert.equal(getPracticeExercise(store,'u',e.id).state,'stale');assert.equal(getPracticeExercise(store,'u',e.id).result,null);assert.equal(getPractice(store,'u',e.activation.round_id).assessment,null);assert.equal(current(e).state,'assessed_addressed','history is retained');
}));
test('revising target detaches it; skip/dispute cannot mutate the revised ordinary round',()=>fixture(async({store,source,propose,activate,current,change,key})=>{
 const e=activate(propose(await source()));let target=store.get('u','practice-rounds',e.activation.round_id);
 target=changePractice(store,'u',target.id,{action:'revise',expected_version:target.version,expected_goal_version:1,request_text:'Ordinary revised practice',objectives:[{id:'delivery',text:'Explain your plan.'}],confirmed:true},key()).record;
 assert.equal(target.practice_exercise,undefined);assert.equal(current(e).superseded,true);assert.equal(getPracticeExercise(store,'u',e.id).state,'stale');const before=store.get('u','practice-rounds',target.id);change(current(e),'skip');assert.deepEqual(store.get('u','practice-rounds',target.id),before);
}));
test('skip/dispute refuse pending target, then atomically affect only the exact goal and round',()=>fixture(async({store,source,propose,activate,current,change})=>{
 const a=activate(propose(await source())),b=activate(propose(await source('goal-b')));const beforeB=store.get('u','practice-rounds',b.activation.round_id);
 const reservation=claimPractice(store,'u',voiceParams({'x-goal-id':'goal-a'}),'reserved-b-turn');
 assert.throws(()=>change(a,'skip',{expected_target_round_version:1}),e=>e.code==='turn_in_progress');assert.equal(current(a).state,'active');failPractice(store,'u',reservation);const target=store.get('u','practice-rounds',a.activation.round_id);const skipped=change(current(a),'skip',{expected_target_round_version:target.version});assert.equal(skipped.state,'skipped');assert.equal(skipped.freshness.status,'current');assert.equal(getPracticeExercise(store,'u',a.id).state,'skipped');assert.equal(store.freshContext('u','goal-a').practice_exercises[0].freshness.status,'current');assert.equal(getPractice(store,'u',target.id).state,'ended');assert.equal(current(a).state,'skipped');assert.equal(store.get('u','practice-rounds',target.id).state,'ended');assert.deepEqual(store.get('u','practice-rounds',b.activation.round_id),beforeB);
}));
test('exercise chains and terminal reactivation are refused; separate goals update independently',()=>fixture(async({store,source,propose,activate,answer,current,payload,change})=>{
 const a=activate(propose(await source())),b=activate(propose(await source('goal-b')));await answer('goal-a');assert.equal(current(a).state,'assessed_addressed');assert.equal(current(b).state,'active');const round=store.get('u','practice-rounds',a.activation.round_id),voice=store.get('u','voice-rounds',round.answer_sources.at(-1).id);assert.throws(()=>propose({round,voice}),e=>e.code==='exercise_chain_unsupported');assert.throws(()=>activate(current(a)),e=>e.code==='exercise_transition');
 const target=store.get('u','practice-rounds',b.activation.round_id);const skipped=change(current(b),'skip',{expected_target_round_version:target.version});assert.throws(()=>activate(skipped),e=>e.code==='exercise_transition');
}));
test('live linked exercise result exists before semantic reply and persists with the A receipt',()=>fixture(async({store,source,propose,activate,models,current})=>{
 const e=activate(propose(await source()));let seen=false,persists=0;
 const live=createLiveRound({store,models,token:'exercise-token',start:{type:'start',goal_id:'goal-a',idempotency_key:'exercise-live',speech:false},phases:{...phases,async persist(){persists++;}},emit:event=>{if(event.type==='reply'){seen=true;assert.equal(persists,2);assert.equal(current(e).state,'assessed_addressed');}}});live.audio(Buffer.alloc(48000));live.end();const result=await live.done;assert.equal(result.status,200,JSON.stringify(result.body));assert.equal(seen,true);assert.equal(current(e).result.voice_id,result.body.round_id);
}));
test('connector HTTP exercise operations are authenticated, versioned and projected freshly',()=>fixture(async({store,source,payload})=>{
 const s=await source();const server=createApp(store);await new Promise(r=>server.listen(0,'127.0.0.1',r));const base=`http://127.0.0.1:${server.address().port}`;
 try{let r=await fetch(base+'/v1/practice-exercises',{method:'POST',headers:{Authorization:'Bearer exercise-token','Content-Type':'application/json','Idempotency-Key':'http-exercise'},body:JSON.stringify(payload(s))});assert.equal(r.status,200);const e=(await r.json()).record;r=await fetch(base+`/v1/practice-exercises/${e.id}`,{headers:{Authorization:'Bearer exercise-token'}});assert.equal((await r.json()).state,'proposed');r=await fetch(base+`/v1/practice-exercises/${e.id}`);assert.equal(r.status,401);const activation={expected_version:1,action:'activate',confirmed:true,content_version:1,expected_goal_version:1};const attempts=await Promise.all(['activate-one','activate-two'].map(async k=>{const response=await fetch(base+`/v1/practice-exercises/${e.id}`,{method:'PATCH',headers:{Authorization:'Bearer exercise-token','Content-Type':'application/json','Idempotency-Key':k},body:JSON.stringify(activation)});return {status:response.status,body:await response.json(),key:k};}));assert.deepEqual(attempts.map(x=>x.status).sort(),[200,409]);assert.equal(store.list('u','practice-rounds').length,2);const winner=attempts.find(x=>x.status===200);r=await fetch(base+`/v1/practice-exercises/${e.id}`,{method:'PATCH',headers:{Authorization:'Bearer exercise-token','Content-Type':'application/json','Idempotency-Key':winner.key},body:JSON.stringify(activation)});assert.equal((await r.json()).replayed,true);}
 finally{await new Promise(r=>server.close(r));}
}));
test('ending an addressed or capped target keeps the completed result current',()=>fixture(async({store,source,propose,activate,answer,current,setOutcome,key})=>{
 const done=activate(propose(await source()));await answer();let target=store.get('u','practice-rounds',done.activation.round_id);
 changePractice(store,'u',target.id,{expected_version:target.version,action:'end'},key());
 let view=getPracticeExercise(store,'u',done.id);assert.equal(view.state,'assessed_addressed');assert.equal(view.freshness.status,'current');assert.equal(view.result.voice_id,current(done).result.voice_id);
 const capped=activate(propose(await source('goal-b')));setOutcome('partial');for(let i=0;i<4;i++)await answer('goal-b');
 target=store.get('u','practice-rounds',capped.activation.round_id);assert.equal(target.state,'capped');
 changePractice(store,'u',target.id,{expected_version:target.version,action:'end'},key());
 view=getPracticeExercise(store,'u',capped.id);assert.equal(view.state,'attempted');assert.equal(view.freshness.status,'current');assert.notEqual(view.result,null);
}));
test('ending or revising the source round keeps active and completed exercises and their targets current',()=>fixture(async({store,source,propose,activate,answer,current,key})=>{
 const s=await source();const active=activate(propose(s));
 let src=store.get('u','practice-rounds',s.round.id);changePractice(store,'u',src.id,{expected_version:src.version,action:'end'},key());
 assert.equal(getPracticeExercise(store,'u',active.id).freshness.status,'current');assert.equal(getPractice(store,'u',active.activation.round_id).state,'open');
 await answer();assert.equal(current(active).state,'assessed_addressed');
 src=store.get('u','practice-rounds',s.round.id);changePractice(store,'u',src.id,{action:'revise',expected_version:src.version,expected_goal_version:1,request_text:'A new ordinary request',objectives:[{id:'delivery',text:'Explain it.'}],confirmed:true},key());
 const view=getPracticeExercise(store,'u',active.id);assert.equal(view.freshness.status,'current');assert.notEqual(view.result,null);
 assert.equal(getPractice(store,'u',active.activation.round_id).state,'addressed');
 // A correction of the assessed answer itself still makes the exercise stale.
 store.put('u','voice-rounds',{...s.voice,version:s.voice.version+1,deleted:true});assert.equal(getPracticeExercise(store,'u',active.id).state,'stale');
}));
