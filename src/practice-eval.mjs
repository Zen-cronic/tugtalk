// Offline evaluation: prepared prompts or recorded responses only. This module never calls a provider.
import { needMet } from './counterpart.mjs';
import { validateAssessment, semanticSystem } from './practice.mjs';
export const CONDITIONS=['with_brief','without_brief','without_history'];
export function candidatePrompt(item,condition) {
  if(!CONDITIONS.includes(condition))throw new Error('Unknown evaluation condition.');
  const withBrief=condition!=='without_brief',withHistory=condition!=='without_history';
  return {system:semanticSystem('en'),user:JSON.stringify({
    ...(withBrief?{confirmed_request:item.request}:{}),
    objectives:item.objectives.map(o=>withBrief?o:{id:o.id,text:'Respond to the request, if it can be established from the supplied context.'}),
    ...(withHistory?{previous_question:item.previous_question??null,previous_assessment:item.previous_assessment??null,previous_answer:item.previous_answer??null}:{}),answer:item.answer})};
}
// A stronger local comparison than word presence: reject explicit negation and require topic overlap.
// It is intentionally visible and imperfect; no semantic accuracy claim follows from this heuristic.
export function relevanceBaseline(item) {
  const negative=/\b(?:cannot|can't|won't|no one|not yet|still need|don't know|do not know)\b/i.test(item.answer);
  const topic=(item.topic_terms??[]).some(term=>item.answer.toLowerCase().includes(term.toLowerCase()));
  if(!topic)return 'unclear';
  return needMet(item.answer,item.need,'en')&&!negative?'addressed':'not_addressed';
}
export function scoreRecorded(corpus,records) {
  if(corpus.label_status!=='human_reviewed_frozen'||!corpus.reviewed_by||!corpus.frozen_at)throw new Error('Accuracy scoring refused: labels require human review and a frozen version.');
  const rows=[];
  for(const condition of CONDITIONS){
    const tally={condition,denominator:0,expected_addressed:0,expected_not_addressed:0,false_success:0,false_rejection:0,abstention:0,missing:0,ambiguous_labels:0};
    for(const item of corpus.cases.filter(c=>c.split==='holdout')){
      if(item.expected==='unclear'){tally.ambiguous_labels++;continue;}
      const matches=records.filter(r=>r.case_id===item.id&&r.condition===condition);
      if(matches.length>1)throw new Error('Duplicate recorded case/condition.');
      const record=matches[0];if(!record){tally.missing++;continue;}
      if(!record.model||!record.provider_request_id)throw new Error('Recorded inference requires model and provider request provenance.');
      const assessed=validateAssessment(record.assessment,item.objectives,item.answer);
      const addressed=assessed.status==='assessed'&&assessed.objectives.every(o=>o.status==='addressed');
      const abstain=assessed.status==='unavailable'||assessed.objectives.some(o=>o.status==='unclear');
      tally.denominator++;const expected=item.expected==='addressed';tally[expected?'expected_addressed':'expected_not_addressed']++;
      if(abstain)tally.abstention++;else if(addressed&&!expected)tally.false_success++;else if(!addressed&&expected)tally.false_rejection++;
    }
    rows.push(tally);
  }
  return {label_version:corpus.version,rows,question_quality:'Separate human review required; exact quote validation does not establish relevance.',scope:'Recorded cases only; no evidence of learning gain or population reliability.'};
}
