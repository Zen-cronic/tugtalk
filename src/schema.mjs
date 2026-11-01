export const schemas={
  goals:{required:['title','target'],properties:{title:{type:'string',minLength:1,maxLength:160},target:{type:'string',minLength:1,maxLength:1000}}},
  exercises:{required:['goal_id','title','instructions'],properties:{goal_id:{type:'string'},title:{type:'string',minLength:1,maxLength:160},instructions:{type:'string',minLength:1,maxLength:1000}}},
  'check-ins':{required:['goal_id','exercise_id','status','feedback'],properties:{goal_id:{type:'string'},exercise_id:{type:'string'},status:{type:'string',enum:['completed','skipped']},feedback:{type:'string',minLength:1,maxLength:1000}}},
  sessions:{required:['expected_version','correction_reason'],properties:{expected_version:{type:'integer',minimum:1},transcript:{type:'string',minLength:1,maxLength:4000},pause_before_answer_ms:{type:'integer',minimum:0,maximum:10000},deleted:{type:'boolean'},correction_reason:{type:'string',minLength:1,maxLength:1000}}}
};
export function specification(base) {
  const paths={
    '/v1/overview':{get:{operationId:'getFreshGoalsOverview',description:'Required fresh GET every goal-related turn. Current user-scoped goals with per-goal progress, totals, as_of, snapshot_revision and request_id. No cache; on failure do not use prior chat as current.',responses:{200:{description:'Fresh committed all-goals snapshot'}}}},
    '/v1/goals/{id}/context':{get:{operationId:'getFreshGoalContext',description:'Fresh context for the explicit goal ID; exercises and check-ins filtered by goal. linked_sessions are captures tagged with this goal; shared_evidence is unlinked and account-wide. Fetch after overview and again after writes.',parameters:[{name:'id',in:'path',required:true,schema:{type:'string'}}],responses:{200:{description:'Fresh scoped goal context'},404:{description:'Goal absent or not owned'}}}},
    '/v1/context':{get:{operationId:'getCoachingContext',description:'Read all current goals, evidence, exercises, check-ins and progress. Fetch before coaching; do not infer improvement from self-reports.',responses:{200:{description:'Current user-scoped synthetic coaching state'}}}},
    '/v1/receipts':{get:{operationId:'listSavedReceipts',responses:{200:{description:'Confirmed writes for the authenticated user'}}}},
    '/v1/files/evidence.txt':{get:{operationId:'downloadEvidenceText',responses:{200:{description:'Current synthetic evidence text',content:{'text/plain':{schema:{type:'string'}}}}}}}
  };
  const write=(name,schema,method)=>({operationId:name,parameters:[{name:'Idempotency-Key',in:'header',required:true,schema:{type:'string',minLength:8,maxLength:128}},...(method==='patch'?[{name:'id',in:'path',required:true,schema:{type:'string'}}]:[])],requestBody:{required:true,content:{'application/json':{schema:{type:'object',additionalProperties:false,...schema}}}},responses:{200:{description:'Persisted record and receipt'},400:{description:'Invalid request'},401:{description:'Unauthorized'},403:{description:'Missing scope'},404:{description:'Record not found'},409:{description:'Version, completion or idempotency conflict'}}});
  for (const k of ['goals','exercises','check-ins']) paths['/v1/'+k]={post:write('create_'+k.replace('-','_'),schemas[k],'post')};
  paths['/v1/goals/{id}']={patch:write('reviseGoal',{required:['expected_version'],properties:{...schemas.goals.properties,expected_version:{type:'integer',minimum:1}}},'patch')};
  paths['/v1/sessions/{id}']={patch:write('correctSession',schemas.sessions,'patch')};
  return {openapi:'3.1.0',info:{title:'Synthetic Coaching Connector',version:'0.3.0',description:'Private test service. Seeded fixtures are synthetic; POST /v1/recordings stores the transcript of audio a capture device uploads (audio itself is not retained), so it can contain real speech. Writes only persist authorized user actions. Completion means self-reported, not measured improvement.'},servers:[{url:base}],security:[{bearerAuth:[]}],components:{securitySchemes:{bearerAuth:{type:'http',scheme:'bearer'}}},paths};
}
