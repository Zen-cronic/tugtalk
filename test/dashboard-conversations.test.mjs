import {test} from 'node:test';
import assert from 'node:assert/strict';
import {groupVoiceAnswers,gateOutcome,practiceRecords} from '../web/practice-view.js';
const spar=(id,at,reason)=>({id,source:'voice_round',occurred_at:at,transcript:'An answer.',gate:{reason}});
test('spoken answers stay single answers, newest first, and never gain a device or a conversation',()=>{
 const {spoken,rounds}=groupVoiceAnswers([spar('a','2026-11-04T10:00:00Z','open'),spar('b','2026-11-04T11:00:00Z','measured_close'),{id:'s',source:'capture',occurred_at:'2026-11-04T12:00:00Z'}],{});
 assert.deepEqual(spoken.map(r=>r.id),['b','a']);assert.deepEqual(rounds,[]);
 for(const r of spoken){assert.equal(r.capture_device,undefined);assert.equal(r.conversation_id,undefined);}
});
test('confirmed-practice answers group under their own round in answer order; unknown rounds stay single',()=>{
 const linked=(id,at,round,answer)=>({...spar(id,at),gate:undefined,practice:{round_id:round,answer}});
 const records=[linked('x2','2026-11-04T10:05:00Z','r1',2),linked('x1','2026-11-04T10:00:00Z','r1',1),linked('y1','2026-11-04T11:00:00Z','r2',1),linked('z1','2026-11-04T12:00:00Z','gone',1)];
 const {spoken,rounds}=groupVoiceAnswers(records,{practice_rounds:[{id:'r1'},{id:'r2'},{id:'unused'}]});
 assert.deepEqual(rounds.map(g=>[g.round.id,g.answers.map(a=>a.id)]),[['r2',['y1']],['r1',['x1','x2']]]);
 assert.deepEqual(spoken.map(r=>r.id),['z1']);
});
test('only the three gate reasons get an outcome label',()=>{
 assert.equal(gateOutcome('measured_close'),'This answer closed the round');assert.equal(gateOutcome('answer_cap'),'Reached the answer limit');assert.equal(gateOutcome('open'),'Round continued');
 for(const reason of [undefined,null,'','coerced','toString'])assert.equal(gateOutcome(reason),null);
});
test('a stale practice answer keeps no AI reply when grouped',()=>{
 const voice={id:'v',source:'voice_round',occurred_at:'2026-11-04T10:00:00Z',reply:{question:'OLD'},practice:{round_id:'r',request_version:1,answer:1}};
 const overview={practice_rounds:[{id:'r',request_version:1,state:'stale',freshness:{status:'stale'}}]};
 const {rounds}=groupVoiceAnswers(practiceRecords({voice_rounds:[voice]},overview),overview);assert.equal(rounds[0].answers[0].reply,null);
});
