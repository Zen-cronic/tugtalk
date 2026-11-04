const escape = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const array = value => Array.isArray(value) ? value : [];
const states = {
  open: ['In progress', 'Your next answer continues this round.'],
  addressed: ['AI says addressed', 'The AI thinks every point was covered. This is not proof that you improved.'],
  capped: ['Round finished', 'Stopped at four answers without confirming every point.'],
  ended: ['Round ended', 'Ended without a success claim.'],
  disputed: ['Assessment disputed', 'Hidden because the result was disputed. Review the round in Muse.'],
  stale: ['Round needs review', 'The goal or its source changed, so this round is hidden. Review it in Muse.'],
};
const outcomes = {addressed:'AI: addressed',partial:'AI: partly addressed',not_addressed:'AI: not addressed',unclear:'AI: unclear'};
export function drillBasisStatus(overview, id) {
  return array(overview?.exercise_basis_status).find(item=>item.exercise_id===id)?.status ?? 'unknown';
}
export function renderPracticeRounds(overview, goalId, { fresh = true, shownQuestion = null } = {}) {
  const rounds = array(overview?.practice_rounds).filter(r=>r.goal_id===goalId).sort((a,b)=>{
    const openA=a.persisted_state==='open'||a.state==='open', openB=b.persisted_state==='open'||b.state==='open';
    return Number(openB)-Number(openA)||(b.mutation_order??0)-(a.mutation_order??0);
  });
  if (!rounds.length) return '';
  if (!fresh) return '<section class="card practice-request"><div class="eyebrow">Practice round</div><h3>Refresh to see this round.</h3><p class="under">The last result is hidden until a fresh read succeeds.</p></section>';
  return `<section class="practice-requests" aria-label="Confirmed practice requests">${rounds.map((round,index)=>{
    const stale=round.state==='stale'||round.freshness?.status==='stale';
    const unavailable=stale||round.state==='disputed'||round.freshness?.status!=='current'||!Object.hasOwn(states,round.state);
    const key=stale?'stale':round.state==='disputed'?'disputed':round.freshness?.status!=='current'?'unavailable':round.state, [label,explanation]=states[key]??['Status unavailable','Refresh to check this round.'];
    const assessment=!unavailable&&!round.pending&&round.assessment?.status==='assessed'?round.assessment:null;
    const contents=`<div class="card-header"><div class="eyebrow">${unavailable?'Practice round':'Practice round · AI feedback'}</div>${unavailable?'':`<span class="pill practice-status">${escape(label)}</span>`}</div>${unavailable?`<h3>${escape(label)}</h3><p class="under">${escape(explanation)}</p>`:`<h3>${escape(round.request_text??'No request text available.')}</h3><p class="caption">${Number.isInteger(round.answer_count)?round.answer_count:'—'} ${round.answer_count===1?'answer':'answers'} so far</p>${round.pending?'<p class="notice under">An answer is still being checked. Refresh soon.</p>':''}<div class="objective-list">${array(round.objectives).map(objective=>{
      const matches=array(assessment?.objectives).filter(o=>o.id===objective.id), result=matches.length===1?matches[0]:null;
      const valid=result&&Object.hasOwn(outcomes,result.status), outcome=valid?outcomes[result.status]:'Not assessed';
      return `<article class="objective"><div class="objective-heading"><strong>${escape(objective.text)}</strong><span class="pill outcome-${valid?escape(result.status):'waiting'}">${escape(outcome)}</span></div>${valid?`${array(result.evidence).map(e=>`<blockquote><span>Your words</span>“${escape(e.quote)}”</blockquote>`).join('')}${result.missing?`<p class="caption">${escape(result.missing)}</p>`:''}`:''}</article>`;
    }).join('')}</div>${round.assessment?.status==='unavailable'&&!round.pending?'<p class="notice under">The AI could not check this answer, so no point counts as covered.</p>':''}${round.state==='open'&&!round.pending&&round.current_question&&round.current_question!==shownQuestion?`<div class="feedback"><h3>AI’s next question</h3><p>${escape(round.current_question)}</p></div>`:''}${round.state==='open'?'':`<p class="caption">${escape(explanation)}</p>`}<p class="ai-note">AI judgment, not a measurement.</p>`}<details class="record-details"><summary>Record details</summary><p>Record ${escape(round.id)} · version ${Number.isInteger(round.version)?round.version:'—'}<br>Source status: ${escape(round.freshness?.status??'unavailable')}</p></details>`;
    return index===0?`<section class="card practice-request">${contents}</section>`:`<details class="card practice-request previous-request"><summary>Earlier round · ${escape(label)}</summary><div class="under">${contents}</div></details>`;
  }).join('')}</section>`;
}

export function practiceRecords(context, overview, {fresh=true}={}) {
  return [...array(context?.sessions), ...array(context?.voice_rounds).map(round=>({
    ...round,
    ...(round.practice&&(!fresh||round.practice.current===false||!array(overview?.practice_rounds).some(current=>current.id===round.practice.round_id&&current.request_version===round.practice.request_version&&current.freshness?.status==='current'&&!['stale','disputed'].includes(current.state)))?{reply:null}:{}),
    measurement_status:round.source==='voice_round'?'measured':round.measurement_status,
  }))].filter(record=>!record.deleted);
}
export function readyDrills(exercises, checkins, overview, {fresh=true}={}) {
  if(!fresh)return [];
  return array(exercises).filter(exercise=>!array(checkins).some(check=>check.exercise_id===exercise.id)
    && drillBasisStatus(overview,exercise.id)!=='stale'
    &&(!exercise.basis||drillBasisStatus(overview,exercise.id)==='current'));
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

const exerciseStates = {
  proposed:['Not started','This exercise has not been started.'],
  active:['In progress','In progress, not a completed result.'],
  assessed_addressed:['AI thinks you covered this point','The AI checked this answer against the objective.'],
  attempted:['Attempted','Attempted, without a claim that the point was covered.'],
  skipped:['Skipped','Skipped. No result is implied.'],
  disputed:['Result disputed','Disputed, so the scenario and result are hidden.'],
};
export function renderPracticeExercises(overview, goalId, {fresh=true}={}) {
  const exercises=array(overview?.practice_exercises).filter(e=>e.goal_id===goalId)
    .sort((a,b)=>Number(b.state==='active')-Number(a.state==='active')||String(b.updated_at??'').localeCompare(String(a.updated_at??'')));
  if(!exercises.length)return '';
  const heading='<div class="sidebar-title"><h2>Conversation exercises</h2></div><p class="caption">Separate from drills that count fillers or restarts.</p>';
  if(!fresh)return `<section class="conversation-exercises under">${heading}<section class="card under"><h3>Refresh to see the latest practice.</h3></section></section>`;
  let anyResult=false;
  const items=exercises.map(exercise=>{
    const stale=exercise.state==='stale'||exercise.freshness?.status==='stale'||exercise.superseded===true;
    const known=Object.hasOwn(exerciseStates,exercise.state), current=exercise.freshness?.status==='current';
    const usable=!stale&&current&&known&&exercise.state!=='disputed'&&exercise.scenario_type==='fictional_practice';
    const [stateLabel,explanation]=['disputed','skipped'].includes(exercise.state)?exerciseStates[exercise.state]:stale?['Exercise needs review','Something it was based on changed. Review it before use.']:!current||!known||exercise.scenario_type!=='fictional_practice'?['Practice unavailable','Refresh to check this exercise.']:exerciseStates[exercise.state];
    const showScenario=usable&&['proposed','active'].includes(exercise.state);
    const result=usable&&['active','assessed_addressed','attempted'].includes(exercise.state)&&exercise.result?.evidence_type==='model_assessment'&&exercise.result?.assessment?.status==='assessed'?exercise.result.assessment:null;
    const matches=array(result?.objectives).filter(o=>o.id===exercise.objective?.id), outcome=matches.length===1&&Object.hasOwn(outcomes,matches[0]?.status)?matches[0]:null;
    const addressed=exercise.state==='assessed_addressed', resultMismatch=usable&&addressed&&(!outcome||outcome.status!=='addressed');
    const badge=exercise.state==='assessed_addressed'&&usable&&!resultMismatch?'AI assessment':null;
    const label=resultMismatch?'AI result unavailable':stateLabel;
    if(outcome&&!resultMismatch)anyResult=true;
    return `<article class="card conversation-exercise under"><div class="card-header"><div class="eyebrow">${showScenario?'Fictional practice scenario':'Exercise status'}</div>${showScenario||badge?`<span class="pill">${escape(badge??label)}</span>`:''}</div>${showScenario?`<h3>${escape(exercise.title??'Saved conversation exercise')}</h3><p class="exercise-scenario">${escape(exercise.request_text??'No scenario text available.')}</p><p class="caption">${exercise.purpose==='transfer'?'Try the point in a new situation.':exercise.purpose==='address_gap'?'Practise a point you missed earlier.':''}</p>`:`<h3>${escape(label)}</h3>`}${usable&&exercise.objective?.text?`<div class="feedback"><h3>Objective</h3><p>${escape(exercise.objective.text)}</p></div>`:''}${outcome&&!resultMismatch?`<div class="feedback"><div class="objective-heading"><h3>AI assessment</h3><span class="pill outcome-${escape(outcome.status)}">${escape(outcomes[outcome.status])}</span></div>${array(outcome.evidence).map(e=>`<blockquote><span>Words cited by the AI</span>“${escape(e.quote)}”</blockquote>`).join('')}${outcome.missing?`<p class="caption">${escape(outcome.missing)}</p>`:''}</div>`:''}<p class="caption">${escape(resultMismatch?'The current assessment could not be confirmed. Refresh to check it.':explanation)}</p><details class="record-details"><summary>Exercise details</summary><p>Record ${escape(exercise.id)} · version ${Number.isInteger(exercise.version)?exercise.version:'—'}<br>Source status: ${escape(exercise.freshness?.status??'unavailable')}<br>Saved by: ${exercise.created_via==='connector'?'a connected assistant or app; creator not identified':'not recorded'}</p></details></article>`;
  }).join('');
  return `<section class="conversation-exercises under" aria-label="Conversation exercises">${heading}${items}${anyResult?'<p class="ai-note">AI assessments look at single answers. They are not measured learning.</p>':''}</section>`;
}
