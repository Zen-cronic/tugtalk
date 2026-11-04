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
  proposed:['Proposed','This exercise has not been started.'],
  active:['In progress','This exercise is active; it is not a completed result.'],
  assessed_addressed:['AI thinks you covered this point','The AI assessed this answer against the practice objective.'],
  attempted:['Attempted','An attempt was recorded without a claim that the objective was addressed.'],
  skipped:['Skipped','This exercise was skipped; no successful outcome is implied.'],
  disputed:['Result disputed','The result was disputed. Its scenario and assessment are hidden.'],
};
export function renderPracticeExercises(overview, goalId, {fresh=true}={}) {
  const exercises=array(overview?.practice_exercises).filter(e=>e.goal_id===goalId)
    .sort((a,b)=>Number(b.state==='active')-Number(a.state==='active')||String(b.updated_at??'').localeCompare(String(a.updated_at??'')));
  if(!exercises.length)return '';
  const heading='<div class="sidebar-title"><h2>Conversation exercises</h2></div><p class="caption">Fictional scenarios to practise a part of a conversation. Separate from drills that count fillers or restarts.</p>';
  if(!fresh)return `<section class="conversation-exercises under">${heading}<section class="card under"><h3>Refresh to check these exercises.</h3><p class="under">Refresh to see the latest practice. The scenario and result will appear once the update finishes.</p></section></section>`;
  return `<section class="conversation-exercises under" aria-label="Conversation exercises">${heading}${exercises.map(exercise=>{
    const stale=exercise.state==='stale'||exercise.freshness?.status==='stale'||exercise.superseded===true;
    const known=Object.hasOwn(exerciseStates,exercise.state), current=exercise.freshness?.status==='current';
    const usable=!stale&&current&&known&&exercise.state!=='disputed'&&exercise.scenario_type==='fictional_practice';
    const [stateLabel,explanation]=['disputed','skipped'].includes(exercise.state)?exerciseStates[exercise.state]:stale?['Exercise needs review','The goal, an earlier answer or the request changed. This exercise needs a review before it can be used.']:!current||!known||exercise.scenario_type!=='fictional_practice'?['Practice unavailable','Refresh to check this exercise before using it.']:exerciseStates[exercise.state];
    const showScenario=usable&&['proposed','active'].includes(exercise.state);
    const result=usable&&['active','assessed_addressed','attempted'].includes(exercise.state)&&exercise.result?.evidence_type==='model_assessment'&&exercise.result?.assessment?.status==='assessed'?exercise.result.assessment:null;
    const matches=array(result?.objectives).filter(o=>o.id===exercise.objective?.id), outcome=matches.length===1&&Object.hasOwn(outcomes,matches[0]?.status)?matches[0]:null;
    const addressed=exercise.state==='assessed_addressed', resultMismatch=usable&&addressed&&(!outcome||outcome.status!=='addressed');
    const badge=exercise.state==='assessed_addressed'&&usable&&!resultMismatch?'AI assessment':null;
    const label=resultMismatch?'AI result unavailable':stateLabel;
    return `<article class="card conversation-exercise under"><div class="card-header"><div class="eyebrow">${showScenario?'Fictional practice scenario':'Exercise status'}</div><span class="pill">${escape(badge??label)}</span></div>${showScenario?`<h3>${escape(exercise.title??'Saved conversation exercise')}</h3><p class="exercise-scenario">${escape(exercise.request_text??'No scenario text available.')}</p><p class="caption">${exercise.purpose==='transfer'?'Try the objective in a different situation.':exercise.purpose==='address_gap'?'Practise an objective left unanswered earlier.':''}</p>`:`<h3>${escape(label)}</h3>`}${usable&&exercise.objective?.text?`<div class="feedback"><h3>Practice objective</h3><p>${escape(exercise.objective.text)}</p></div>`:''}${outcome&&!resultMismatch?`<div class="feedback"><div class="objective-heading"><h3>Saved AI assessment</h3><span class="pill outcome-${escape(outcome.status)}">${escape({addressed:'AI: answered',partial:'AI: partly answered',not_addressed:'AI: not answered',unclear:'AI: unclear'}[outcome.status])}</span></div>${array(outcome.evidence).map(e=>`<blockquote><span>Words cited by the AI</span>“${escape(e.quote)}”</blockquote>`).join('')}${outcome.missing?`<p class="caption">${escape(outcome.missing)}</p>`:''}</div>`:''}<p class="caption">${escape(resultMismatch?'The current assessment could not be confirmed. Refresh to check it.':explanation)}</p><p class="caption">${exercise.created_via==='connector'?'Saved through your connected assistant or app.':'Creation source not recorded.'}</p><details class="record-details"><summary>Exercise details</summary><p>Record ${escape(exercise.id)} · version ${Number.isInteger(exercise.version)?exercise.version:'—'}<br>Source status: ${escape(exercise.freshness?.status??'unavailable')}<br>Saved by: ${exercise.created_via==='connector'?'a connected assistant or app; creator not identified':'not recorded'}</p></details></article>`;
  }).join('')}<p class="caption">AI assessments describe individual answers. They are not measured learning or proof of lasting improvement.</p></section>`;
}
