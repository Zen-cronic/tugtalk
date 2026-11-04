const escape = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const array = value => Array.isArray(value) ? value : [];
const states = {
  open: ['In progress', 'The next answer can continue this request.'],
  addressed: ['AI says addressed', 'The AI assessed the objectives as addressed. This is not proof that the answer is true or that your skills improved.'],
  capped: ['Round finished', 'The four-answer limit was reached without confirming that every objective was addressed.'],
  ended: ['Round ended', 'This round ended without a success claim.'],
  disputed: ['Assessment disputed', 'This assessment is not usable. Review and confirm a revised request in Muse before continuing.'],
  stale: ['Request needs review', 'The goal or source material changed. The old request and assessment are hidden. Review and confirm a revised request in Muse.'],
};
const outcomes = {addressed:'AI: addressed',partial:'AI: partly addressed',not_addressed:'AI: not addressed',unclear:'AI: unclear'};
export function drillBasisStatus(overview, id) {
  return array(overview?.exercise_basis_status).find(item=>item.exercise_id===id)?.status ?? 'unknown';
}
export function renderPracticeRounds(overview, goalId, { fresh = true } = {}) {
  const rounds = array(overview?.practice_rounds).filter(r=>r.goal_id===goalId).sort((a,b)=>{
    const openA=a.persisted_state==='open'||a.state==='open', openB=b.persisted_state==='open'||b.state==='open';
    return Number(openB)-Number(openA)||(b.mutation_order??0)-(a.mutation_order??0);
  });
  if (!rounds.length) return '';
  if (!fresh) return '<section class="card practice-request"><div class="eyebrow">Practice request</div><h3>Check the latest result first.</h3><p class="under">The last request assessment is hidden until a fresh read succeeds. Use Refresh to check the current state.</p></section>';
  return `<section class="practice-requests" aria-label="Confirmed practice requests">${rounds.map((round,index)=>{
    const stale=round.state==='stale'||round.freshness?.status==='stale';
    const unavailable=stale||round.state==='disputed'||round.freshness?.status!=='current'||!Object.hasOwn(states,round.state);
    const key=stale?'stale':round.state==='disputed'?'disputed':round.freshness?.status!=='current'?'unavailable':round.state, [label,explanation]=states[key]??['Status unavailable','Refresh to check this practice request.'];
    const assessment=!unavailable&&!round.pending&&round.assessment?.status==='assessed'?round.assessment:null;
    const contents=`<div class="card-header"><div class="eyebrow">Practice request</div><span class="pill practice-status">${escape(label)}</span></div>${unavailable?`<h3>${escape(label)}</h3><p class="under">${escape(explanation)}</p>`:`<h3>${escape(round.request_text??'No request text available.')}</h3><p class="caption">Request version ${Number.isInteger(round.request_version)?round.request_version:'—'} · ${Number.isInteger(round.answer_count)?round.answer_count:'—'} ${round.answer_count===1?'answer':'answers'} saved</p>${round.pending?'<p class="notice under">An answer is being processed. Refresh to see its result.</p>':''}<div class="objective-list">${array(round.objectives).map(objective=>{
      const matches=array(assessment?.objectives).filter(o=>o.id===objective.id), result=matches.length===1?matches[0]:null;
      const valid=result&&Object.hasOwn(outcomes,result.status), outcome=valid?outcomes[result.status]:'Not assessed';
      return `<article class="objective"><div class="objective-heading"><strong>${escape(objective.text)}</strong><span class="pill outcome-${valid?escape(result.status):'waiting'}">${escape(outcome)}</span></div>${valid?`${array(result.evidence).map(e=>`<blockquote><span>Quoted from the answer</span>“${escape(e.quote)}”</blockquote>`).join('')}${result.missing?`<p class="caption">${escape(result.missing)}</p>`:''}`:''}</article>`;
    }).join('')}</div>${round.assessment?.status==='unavailable'&&!round.pending?'<p class="notice under">The AI could not assess this answer. No objective is treated as addressed.</p>':''}${round.state==='open'&&!round.pending&&round.current_question?`<div class="feedback"><h3>Next question</h3><p>${escape(round.current_question)}</p></div>`:''}<p class="caption">${escape(explanation)}</p><p class="caption"><strong>AI judgment, not a measurement.</strong> Quotes can be checked against the transcript; they do not prove relevance, truth or improvement.</p>`}<details class="record-details"><summary>Request details</summary><p>Record ${escape(round.id)} · version ${Number.isInteger(round.version)?round.version:'—'}<br>Source status: ${escape(round.freshness?.status??'unavailable')}</p></details>`;
    return index===0?`<section class="card practice-request">${contents}</section>`:`<details class="card practice-request previous-request"><summary>Earlier request · ${escape(label)}</summary><div class="under">${contents}</div></details>`;
  }).join('')}</section>`;
}

export function practiceRecords(context) {
  return [...array(context?.sessions), ...array(context?.voice_rounds).map(round=>({
    ...round,
    measurement_status:round.source==='voice_round'?'measured':round.measurement_status,
  }))].filter(record=>!record.deleted);
}
export function readyDrills(exercises, checkins, overview) {
  return array(exercises).filter(exercise=>!array(checkins).some(check=>check.exercise_id===exercise.id)
    && drillBasisStatus(overview,exercise.id)!=='stale');
}
export async function readStablePractice(read) {
  // Context must sit between two matching committed revisions. Otherwise a fresh
  // overview could bless records fetched before a correction on another device.
  for(let attempt=0;attempt<2;attempt++) {
    const before=await read('overview'), context=await read('context'), after=await read('overview');
    if(typeof before.snapshot_revision==='string'&&before.snapshot_revision.length
      &&before.snapshot_revision===after.snapshot_revision)return {overview:after,context};
  }
  throw new Error('Your practice changed while loading. Refresh to check a consistent result.');
}
