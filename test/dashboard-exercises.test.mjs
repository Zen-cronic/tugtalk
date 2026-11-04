import {test} from 'node:test';
import assert from 'node:assert/strict';
import {renderPracticeExercises} from '../web/practice-view.js';
const exercise={id:'exercise-1',version:1,content_version:1,goal_id:'goal-a',goal_version:1,title:'A fictional handoff',request_text:'Tell a fictional teammate when to expect the draft.',scenario_type:'fictional_practice',purpose:'address_gap',objective:{id:'delivery',text:'Explain the delivery commitment.'},state:'proposed',persisted_state:'proposed',freshness:{status:'current'},superseded:false,created_via:'connector',updated_at:'2026-11-03T20:00:00Z'};
const assessment={evidence_type:'model_assessment',assessment:{status:'assessed',objectives:[{id:'delivery',status:'addressed',evidence:[{start:0,end:6,quote:'Friday'}],missing:''}]}};
test('conversation exercise view separates fictional proposed practice from count drills and assistant authorship',()=>{
 const html=renderPracticeExercises({practice_exercises:[exercise,{...exercise,goal_id:'other',title:'OTHER_ACCOUNT_GOAL'}]},'goal-a');
 assert.match(html,/Fictional practice scenario/);assert.match(html,/has not been started/);assert.match(html,/Separate from drills that count fillers or restarts/);assert.match(html,/creator not identified/);assert.ok(!html.includes('Muse'));assert.ok(!html.includes('OTHER_ACCOUNT_GOAL'));assert.ok(!/<button|<form/.test(html));
 const escaped=renderPracticeExercises({practice_exercises:[{...exercise,title:'<img src=x onerror=alert(1)>'}]},'goal-a');assert.ok(!escaped.includes('<img'));assert.match(escaped,/&lt;img/);
});
test('stale, disputed, superseded, unknown and failed reads hide all scenario and result content',()=>{
 for(const variant of [{state:'stale'},{state:'disputed'},{freshness:{status:'stale'}},{freshness:{status:'unknown'}},{superseded:true},{state:'invented'},{scenario_type:'real_event'}]){
  const html=renderPracticeExercises({practice_exercises:[{...exercise,result:assessment,...variant}]},'goal-a');assert.ok(!html.includes(exercise.title));assert.ok(!html.includes(exercise.request_text));assert.ok(!html.includes(exercise.objective.text));assert.ok(!html.includes('Friday'));
 }
 const disputed=renderPracticeExercises({practice_exercises:[{...exercise,state:'disputed',freshness:{status:'stale'},result:assessment}]},'goal-a');assert.match(disputed,/Result disputed/);assert.ok(!disputed.includes('Friday'));
 const skipped=renderPracticeExercises({practice_exercises:[{...exercise,state:'skipped',freshness:{status:'stale'}}]},'goal-a');assert.match(skipped,/Skipped/);assert.ok(!skipped.includes(exercise.request_text));
 const html=renderPracticeExercises({practice_exercises:[{...exercise,result:assessment}]},'goal-a',{fresh:false});assert.match(html,/Refresh to see the latest practice/);assert.ok(!html.includes(exercise.request_text));
});
test('active is not complete and assessed/attempted results are AI judgments without closed scenario instructions',()=>{
 assert.match(renderPracticeExercises({practice_exercises:[{...exercise,state:'active'}]},'goal-a'),/not a completed result/);
 const result=renderPracticeExercises({practice_exercises:[{...exercise,state:'assessed_addressed',result:assessment}]},'goal-a');assert.match(result,/AI thinks you covered this point/);assert.match(result,/Words cited by the AI/);assert.match(result,/not measured learning/);assert.ok(!result.includes(exercise.request_text));
 const attempted=renderPracticeExercises({practice_exercises:[{...exercise,state:'attempted'}]},'goal-a');assert.match(attempted,/without a claim/);assert.ok(!attempted.includes(exercise.request_text));
 const skipped=renderPracticeExercises({practice_exercises:[{...exercise,state:'skipped',result:assessment}]},'goal-a');assert.ok(!skipped.includes('Friday'));assert.ok(!skipped.includes(exercise.request_text));
});
test('missing or mismatched model result cannot support an addressed claim',()=>{
 for(const result of [null,{...assessment,assessment:{status:'unavailable',objectives:assessment.assessment.objectives}},{...assessment,assessment:{status:'assessed',objectives:[{...assessment.assessment.objectives[0],id:'other'}]}}]){
  const html=renderPracticeExercises({practice_exercises:[{...exercise,state:'assessed_addressed',result}]},'goal-a');assert.match(html,/AI result unavailable/);assert.ok(!html.includes('AI thinks you covered this point'));assert.ok(!html.includes('Friday'));
 }
 assert.equal(renderPracticeExercises({},'goal-a'),'');
});
test('an exercise ended before any answer reads as skipped, never as a recorded attempt',()=>{
 const html=renderPracticeExercises({practice_exercises:[{...exercise,state:'skipped',persisted_state:'skipped',activation:{round_id:'r'},result:null,latest_attempt:null}]},'goal-a');
 assert.match(html,/Skipped/);assert.ok(!html.includes('An attempt was recorded'));
});
