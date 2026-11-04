// Fictional follow-up scenarios keep semantic assessments separate from habit-count drills.
import { randomUUID } from 'node:crypto';
import { ApiError, digest } from './store.mjs';
import { practiceFreshness, createPracticeRecord, mutatePracticeRecord } from './practice.mjs';
export const PRACTICE_EXERCISES_PATH='/v1/practice-exercises';
const KIND='practice-exercises', ID=/^[A-Za-z0-9_-]{1,64}$/;
const now=()=>new Date().toISOString();
const object=x=>x!==null&&typeof x==='object'&&!Array.isArray(x);
const text=(x,max)=>typeof x==='string'&&x.trim().length>0&&x.length<=max;
const fail=(code,message,status=409)=>{throw new ApiError(status,code,message);};
const find=(store,user,kind,id)=>{try{return store.get(user,kind,id);}catch(e){if(e.status===404)return null;throw e;}};
const normalized=s=>s.trim().replace(/\s+/g,' ').toLowerCase();
function fields(body,allowed){if(!object(body)||Object.keys(body).some(k=>!allowed.includes(k)))fail('invalid_body','Use only documented fields.',400);}
function appendEvent(store,user,e,action){store.put(user,'practice-exercise-events',{id:randomUUID(),version:1,exercise_id:e.id,exercise_version:e.version,action,occurred_at:now()});}
function save(store,user,e,action){store.put(user,KIND,e);appendEvent(store,user,e,action);return e;}
function sameLink(round,e){return Boolean(round&&e.activation&&round.id===e.activation.round_id&&round.request_version===e.activation.request_version&&round.goal_id===e.goal_id&&round.practice_exercise?.id===e.id&&round.practice_exercise.content_version===e.content_version&&round.practice_exercise.basis_digest===digest(JSON.stringify(e.basis)));}

// Original source only. Never reads the target, preventing dependency recursion through activation.
export function exerciseBasisReasons(store,user,e){
 const b=e.basis,source=find(store,user,'practice-rounds',b.round_id),voice=find(store,user,'voice-rounds',b.voice_id),goal=find(store,user,'goals',e.goal_id);
 const reasons=[];
 if(!goal||goal.deleted||goal.version!==e.goal_version)reasons.push('goal_changed');
 // The basis is the assessed objective and answer. A later end or revision of the source round does not change them;
 // while the source keeps the assessed request, its sources, latest answer and assessment must still match.
 const sameRequest=Boolean(source&&source.request_version===b.request_version);
 // Refuse chains before calling practiceFreshness: a corrupt cycle cannot recurse.
 if(!source||source.practice_exercise||source.goal_id!==e.goal_id||(sameRequest&&source.state==='disputed'))reasons.push('source_round_changed');
 else if(sameRequest&&practiceFreshness(store,user,source).status!=='current')reasons.push('source_round_stale');
 if(!voice||voice.deleted||voice.version!==b.voice_version||voice.goal_id!==e.goal_id||voice.practice?.round_id!==b.round_id||voice.practice?.request_version!==b.request_version||(sameRequest&&source.answer_sources.at(-1)?.id!==b.voice_id))reasons.push('source_answer_changed');
 if(!source||!voice?.practice?.assessment||digest(JSON.stringify(voice.practice.assessment))!==b.assessment_digest||(sameRequest&&digest(JSON.stringify(source.assessment))!==b.assessment_digest))reasons.push('source_assessment_changed');
 return reasons;
}
// Called by A's target freshness: state/content + original basis, never the target result.
export function exerciseDependencyCurrent(store,user,round){
 const link=round.practice_exercise,e=find(store,user,KIND,link.id);
 return Boolean(e&&sameLink(round,e)&&!e.superseded&&e.state!=='disputed'&&(e.state!=='skipped'||round.state==='ended')&&exerciseBasisReasons(store,user,e).length===0);
}
export function exerciseFreshness(store,user,e){
 const reasons=exerciseBasisReasons(store,user,e);
 if(e.superseded)reasons.push('superseded');
 if(e.state==='disputed')reasons.push('disputed');
 if(e.activation){
  const target=find(store,user,'practice-rounds',e.activation.round_id);
  if(!sameLink(target,e))reasons.push('target_revised_or_missing');
  else {
   if(target.state==='disputed')reasons.push('target_disputed');
   if(practiceFreshness(store,user,target).status!=='current')reasons.push('target_stale');
   if(e.result){
    const answer=find(store,user,'voice-rounds',e.result.voice_id);
    // Pinned to the assessed answer: a later lifecycle write on the target (such as end) changes its version, not the result.
    if(!answer||answer.deleted||answer.version!==e.result.voice_version||answer.goal_id!==e.goal_id||target.answer_sources.at(-1)?.id!==e.result.voice_id||target.request_version!==e.result.request_version||answer.practice?.round_id!==target.id||answer.practice?.request_version!==target.request_version)reasons.push('result_changed');
   }
  }
 }
 return {status:reasons.length?'stale':'current',reasons:[...new Set(reasons)]};
}
export function projectExercise(store,user,e){
 const freshness=exerciseFreshness(store,user,e),unusable=freshness.status!=='current'||e.state==='disputed';
 return {...e,...(unusable?{title:null,request_text:null,objective:null,result:null,latest_attempt:null,basis:{...e.basis,source_outcome:null}}:{}),
  persisted_state:e.state,state:unusable&&!['skipped','disputed'].includes(e.state)?'stale':e.state,freshness,evidence_type:'model_assessment',
  assessment_scope:'One model-assessed practice attempt, not measured improvement or demonstrated learning transfer.'};
}
export const getPracticeExercise=(store,user,id)=>projectExercise(store,user,store.get(user,KIND,id));
export const practiceExerciseViews=(store,user,goalId)=>store.list(user,KIND).filter(e=>!goalId||e.goal_id===goalId).map(e=>projectExercise(store,user,e));
export function createPracticeExercise(store,user,body,key){
 fields(body,['goal_id','expected_goal_version','title','request_text','scenario_type','purpose','basis']);
 if(!text(body.goal_id,64)||!ID.test(body.goal_id)||!Number.isInteger(body.expected_goal_version)||!text(body.title,160)||!text(body.request_text,2000)||body.scenario_type!=='fictional_practice'||!['address_gap','transfer'].includes(body.purpose))fail('invalid_body','Provide a goal/version, title, fictional request and supported purpose.',400);
 fields(body.basis,['round_id','round_version','request_version','voice_id','voice_version','objective_id']);
 for(const field of ['round_id','voice_id','objective_id'])if(!text(body.basis[field],64)||!ID.test(body.basis[field]))fail('invalid_body','Invalid basis identifier.',400);
 for(const field of ['round_version','request_version','voice_version'])if(!Number.isInteger(body.basis[field])||body.basis[field]<1)fail('invalid_body','Invalid basis version.',400);
 return store.mutate(user,'POST',PRACTICE_EXERCISES_PATH,body,key,()=>{
  const goal=store.get(user,'goals',body.goal_id),source=store.get(user,'practice-rounds',body.basis.round_id);
  if(goal.version!==body.expected_goal_version)fail('version_conflict','Re-read the goal.');
  if(source.practice_exercise)fail('exercise_chain_unsupported','Use an ordinary practice round as the source; exercise chains are not supported.');
  const objective=source.objectives.find(o=>o.id===body.basis.objective_id),outcome=source.assessment?.objectives.find(o=>o.id===body.basis.objective_id);
  const e={...body,id:randomUUID(),version:1,content_version:1,goal_version:goal.version,state:'proposed',superseded:false,
   objective,activation:null,result:null,latest_attempt:null,created_via:'connector',created_at:now(),updated_at:now(),
   basis:{...body.basis,assessment_digest:digest(JSON.stringify(source.assessment)),source_outcome:outcome?.status??null}};
  delete e.expected_goal_version;
  // At proposal time the cited source must be exactly as read: terminal, idle and at the cited versions.
  const asCited=source.version===body.basis.round_version&&source.request_version===body.basis.request_version&&!source.pending&&['addressed','capped','ended'].includes(source.state);
  if(!asCited||exerciseBasisReasons(store,user,e).length)fail('exercise_basis_stale','The cited source must be a current terminal round and its latest answer on this goal.');
  if(!objective||source.assessment?.status!=='assessed'||!outcome||!(body.purpose==='transfer'?outcome.status==='addressed':['partial','not_addressed'].includes(outcome.status)))fail('exercise_basis_unclear','This outcome cannot support that purpose. Clarify the request or choose the matching purpose.');
  if(normalized(body.request_text)===normalized(source.request_text))fail('scenario_unchanged','Propose a different fictional scenario; an exact copy is not a follow-up.',400);
  if(store.list(user,KIND).some(x=>x.goal_id===e.goal_id&&['proposed','active'].includes(x.state)))fail('practice_exercise_open','This goal already has a proposed or active practice exercise.');
  return save(store,user,e,'propose');
 });
}
export function changePracticeExercise(store,user,id,body,key){
 fields(body,['expected_version','action','confirmed','expected_goal_version','content_version','expected_target_round_version']);
 if(!Number.isInteger(body.expected_version)||body.expected_version<1||!['activate','skip','dispute'].includes(body.action))fail('invalid_body','Provide expected_version and a supported action.',400);
 const allowed=body.action==='activate'?['expected_version','action','confirmed','expected_goal_version','content_version']:['expected_version','action','expected_target_round_version'];
 fields(body,allowed);
 return store.mutate(user,'PATCH',`${PRACTICE_EXERCISES_PATH}/${id}`,body,key,()=>{
  let e=store.get(user,KIND,id);
  if(e.version!==body.expected_version)fail('version_conflict','Re-read the practice exercise.');
  if(body.action==='activate'){
   if(e.state!=='proposed')fail('exercise_transition','Only a proposed exercise can be activated. Create a new proposal for another attempt.');
   if(body.confirmed!==true||body.content_version!==e.content_version||body.expected_goal_version!==e.goal_version)fail('confirmation_required','Confirm this exact exercise content and current goal version.');
   if(exerciseFreshness(store,user,e).status!=='current')fail('exercise_stale','The source changed. Dismiss this proposal and create a fresh one.');
   const target=createPracticeRecord(store,user,{goal_id:e.goal_id,expected_goal_version:e.goal_version,request_text:e.request_text,objectives:[e.objective],confirmed:true,sources:[]},
    {practice_exercise:{id:e.id,content_version:e.content_version,basis_digest:digest(JSON.stringify(e.basis))}});
   e={...e,state:'active',activation:{round_id:target.id,request_version:target.request_version,content_version:e.content_version}};
  }else{
   const permitted=body.action==='skip'?['proposed','active']:['proposed','active','assessed_addressed','attempted'];
   if(!permitted.includes(e.state))fail('exercise_transition','This lifecycle transition is not allowed.');
   const target=e.activation?find(store,user,'practice-rounds',e.activation.round_id):null;
   // A revision detaches the exercise. It may still be dismissed, but cannot touch ordinary practice.
   if(sameLink(target,e)){
    if(!Number.isInteger(body.expected_target_round_version)||target.version!==body.expected_target_round_version)fail('version_conflict','Re-read the linked target round before ending or disputing it.');
    mutatePracticeRecord(store,user,target.id,{expected_version:target.version,action:body.action==='skip'?'end':'dispute'},{notifyExercise:false});
   }
   e={...e,state:body.action==='skip'?'skipped':'disputed'};
  }
  e={...e,version:e.version+1,updated_at:now()};save(store,user,e,body.action);return projectExercise(store,user,e);
 });
}
// Runs inside the same transaction as an A lifecycle/answer write. Never calls a route or opens a transaction.
export function practiceExerciseChanged(store,user,before,after,action,voice=null){
 const link=before.practice_exercise;if(!link)return;
 let e=find(store,user,KIND,link.id);if(!e||!sameLink(before,e)||action==='recover'||['skipped','disputed'].includes(e.state))return;
 if(action==='revise')e={...e,superseded:true};
 else if(action==='dispute')e={...e,state:'disputed'};
 else if(e.state==='active'){
  const source=voice??(after.answer_sources.at(-1)?find(store,user,'voice-rounds',after.answer_sources.at(-1).id):null);
  const attempt=source?{voice_id:source.id,voice_version:source.version,round_id:after.id,round_version:after.version,request_version:after.request_version}:null;
  // Ended before any answer is a skip, not an attempt.
  const state=after.state==='addressed'?'assessed_addressed':after.state==='ended'&&after.answer_count===0?'skipped':['capped','ended'].includes(after.state)?'attempted':'active';
  e={...e,state,latest_attempt:attempt??e.latest_attempt,result:state==='active'?null:attempt?{...attempt,evidence_type:'model_assessment',assessment:after.assessment}:null};
 }else return;
 save(store,user,{...e,version:e.version+1,updated_at:now()},`round_${action}`);
}
