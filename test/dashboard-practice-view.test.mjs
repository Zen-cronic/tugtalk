import {test} from 'node:test';
import assert from 'node:assert/strict';
import {renderPracticeRounds,drillBasisStatus,practiceRecords,readyDrills,readStablePractice} from '../web/practice-view.js';
const round={id:'round-1',version:2,request_version:1,goal_id:'a',state:'open',persisted_state:'open',freshness:{status:'current'},request_text:'When can you deliver?',answer_count:1,objectives:[{id:'delivery',text:'Explain the delivery commitment.'}],assessment:{status:'assessed',objectives:[{id:'delivery',status:'partial',evidence:[{start:0,end:6,quote:'Friday'}],missing:'The dependency is still missing.'}]},current_question:'What does Friday depend on?'};
test('practice view uses actual goal-scoped objective results and escapes supplied text',()=>{
 const html=renderPracticeRounds({practice_rounds:[round,{...round,id:'other',goal_id:'b',request_text:'PRIVATE_OTHER_GOAL'}]},'a');
 assert.match(html,/AI: partly addressed/);assert.match(html,/Friday/);assert.match(html,/AI judgment, not a measurement/);assert.ok(!html.includes('PRIVATE_OTHER_GOAL'));
 const escaped=renderPracticeRounds({practice_rounds:[{...round,request_text:'<img onerror=alert(1)>'}]},'a');assert.ok(!escaped.includes('<img'));assert.match(escaped,/&lt;img/);
});
test('stale, disputed, unknown freshness and failed refresh hide request and assessment evidence',()=>{
 for(const variant of [{state:'stale'},{state:'disputed'},{freshness:{status:'stale'}},{freshness:{status:'unknown'}}]){
  const html=renderPracticeRounds({practice_rounds:[{...round,...variant}]},'a');assert.ok(!html.includes('When can you deliver?'));assert.ok(!html.includes('Friday'));assert.ok(!html.includes('AI: partly addressed'));
 }
 const html=renderPracticeRounds({practice_rounds:[round]},'a',{fresh:false});assert.match(html,/fresh read succeeds/);assert.ok(!html.includes('Friday'));
});
test('pending and unavailable assessments abstain; capped and ended states do not imply success',()=>{
 for(const variant of [{pending:{since:'2026-11-03T20:00:00Z'}},{assessment:{...round.assessment,status:'unavailable'}}]){
  const html=renderPracticeRounds({practice_rounds:[{...round,...variant}]},'a');assert.ok(!html.includes('AI: partly addressed'));assert.match(html,/Not assessed/);
 }
 assert.match(renderPracticeRounds({practice_rounds:[{...round,state:'capped'}]},'a'),/without confirming/);
 assert.match(renderPracticeRounds({practice_rounds:[{...round,state:'ended'}]},'a'),/without a success claim/);
 assert.match(renderPracticeRounds({practice_rounds:[{...round,state:'addressed'}]},'a'),/not proof/);
});
test('open round precedes history and stale drill basis is not treated as current',()=>{
 const html=renderPracticeRounds({practice_rounds:[{...round,id:'closed',state:'ended',persisted_state:'ended',mutation_order:9},{...round,id:'open',mutation_order:1}]},'a');
 assert.ok(html.indexOf('Record open')<html.indexOf('Record closed'));
 assert.equal(drillBasisStatus({exercise_basis_status:[{exercise_id:'e',status:'stale'}]},'e'),'stale');assert.equal(drillBasisStatus({},'e'),'unknown');
 assert.equal(renderPracticeRounds({},'a'),'');
 assert.deepEqual(readyDrills([{id:'e'},{id:'fresh'}],[],{exercise_basis_status:[{exercise_id:'e',status:'stale'}]}).map(e=>e.id),['fresh']);
 const records=practiceRecords({voice_rounds:[{id:'watch',source:'voice_round',capture_device:'watch'},{id:'unknown',source:'voice_round'}]});assert.equal(records[0].capture_device,'watch');assert.equal(records[1].capture_device,undefined);
});

test('snapshot read retries a source correction and refuses continuously changing revisions',async()=>{
 let index=0;const replies=[{snapshot_revision:'before'},{goals:[{version:1}]},{snapshot_revision:'after'},{snapshot_revision:'after'},{goals:[{version:2}]},{snapshot_revision:'after'}];
 const snapshot=await readStablePractice(async()=>replies[index++]);assert.equal(snapshot.context.goals[0].version,2);assert.equal(index,6);
 let revision=0;await assert.rejects(readStablePractice(async route=>route==='context'?{goals:[]}:{snapshot_revision:String(++revision)}),/changed while loading/);
});
