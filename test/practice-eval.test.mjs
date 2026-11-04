import{test}from'node:test';import assert from'node:assert/strict';import{readFileSync}from'node:fs';
import{candidatePrompt,scoreRecorded,CONDITIONS,relevanceBaseline}from'../src/practice-eval.mjs';
const corpus=JSON.parse(readFileSync(new URL('./fixtures/practice-candidates.json',import.meta.url),'utf8'));
test('candidate labels cannot be scored as verified accuracy; conditions remove only their named context',()=>{
 assert.equal(corpus.cases.filter(c=>c.split==='candidate_holdout').length,24);
 assert.throws(()=>scoreRecorded(corpus,[]),/human review/);
 const item=corpus.cases[0];const withBrief=JSON.parse(candidatePrompt(item,'with_brief').user),without=JSON.parse(candidatePrompt(item,'without_brief').user),noHistory=JSON.parse(candidatePrompt(item,'without_history').user);
 assert.equal(without.confirmed_request,undefined);assert.deepEqual(without.answer,withBrief.answer);assert.equal(noHistory.previous_question,undefined);assert.equal(noHistory.confirmed_request,withBrief.confirmed_request);
 const candidateKeys=new Set(corpus.cases.filter(c=>c.split!=='calibration').map(c=>JSON.stringify([c.request,c.answer])));
 assert.ok(corpus.cases.filter(c=>c.split==='calibration').every(c=>!candidateKeys.has(JSON.stringify([c.request,c.answer]))));
 const multi=corpus.cases.find(c=>c.previous_answer);assert.ok(multi.previous_assessment);assert.equal(JSON.parse(candidatePrompt(multi,'with_brief').user).previous_answer,multi.previous_answer);assert.equal(JSON.parse(candidatePrompt(multi,'without_history').user).previous_answer,undefined);
 assert.equal(relevanceBaseline(corpus.cases[1]),'unclear');
});
test('recorded score reports denominators, abstention and false success separately with missing responses',()=>{
 const c={...corpus,label_status:'human_reviewed_frozen',reviewed_by:'test reviewer',frozen_at:'test',cases:[{...corpus.cases[1],split:'holdout'}]};const item=c.cases[0];
 const record={case_id:item.id,condition:'with_brief',model:'test',provider_request_id:'fixture',assessment:{objectives:[{id:'objective',status:'addressed',evidence:[{start:0,end:item.answer.length,quote:item.answer}],missing:''}],next_question:'What is the budget?'}};
 const score=scoreRecorded(c,[record]);assert.equal(score.rows[0].false_success,1);assert.equal(score.rows[0].denominator,1);assert.equal(score.rows[1].missing,1);assert.throws(()=>scoreRecorded(c,[record,record]),/Duplicate/);
});
