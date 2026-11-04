import {renderPracticeExercises,renderPracticeRounds,drillBasisStatus,practiceRecords,readyDrills,readStablePractice} from '/app/practice-view.js';
const root = document.querySelector('#app');
const state = { csrf: '', demo: false, canWrite: false, tab: 'goals', goal: null, session: null, data: null, error: '', stale: false, loading: false, sequence: 0 };
const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;' }[c]));
const date = value => { const d = new Date(value); return value && !Number.isNaN(+d) ? d.toLocaleString(undefined, { month:'short', day:'numeric', hour:'numeric', minute:'2-digit' }) : 'Time not recorded'; };
const plural = (n, singular, many=singular+'s') => n===1?singular:many;
const count = n => Number.isFinite(n) ? String(n) : '—';
const device = s => ({ watch:'Apple Watch', apple_watch:'Apple Watch', mac:'Mac', macos:'Mac', browser:'Browser' }[s] ?? (s ? String(s) : 'Unknown device'));
const practices = context => practiceRecords(context,state.data?.overview,{fresh:!state.stale&&!state.loading});
const allGoals = c => [...(c.goals??[]),...(practices(c).some(s=>!s.goal_id)?[{id:'__unlinked',title:'Not linked to a goal',target:'Saved without a goal, so they don’t show progress on any goal.'}]:[])];
const forGoal = (s,id) => id==='__unlinked'?!s.goal_id:s.goal_id===id;
const brand = '<a class="brand" href="/" aria-label="TugTalk home page"><img src="/app/icon.svg" alt="">TugTalk</a>';
async function api(path, { method = 'GET', body } = {}) {
  const response = await fetch(`/app-api/${path}`, { method, credentials:'same-origin', cache:'no-store', headers:{ ...(body ? {'Content-Type':'application/json'} : {}), ...(method !== 'GET' ? {'X-CSRF-Token':state.csrf, 'Idempotency-Key':crypto.randomUUID()} : {}) }, ...(body ? {body:JSON.stringify(body)} : {}) });
  const data = await response.json();
  if (!response.ok) { const e = new Error(data.error ?? 'Your practice could not be loaded.'); e.status=response.status; throw e; }
  return data;
}
function signIn(error = '') {
  state.csrf=''; state.data=null; state.sequence++;
  root.innerHTML=`<div class="login-wrap">${brand}<main class="login-card"><h1>Sign in to your practice</h1><p>Your goals, recordings and feedback from TugTalk.</p><form id="login"><label for="access">Access code</label><input id="access" name="access" type="password" autocomplete="current-password" required minlength="20" aria-describedby="login-note"><div id="login-error" role="alert">${error?`<p class="notice error">${esc(error)}</p>`:''}</div><button class="primary" type="submit">Sign in</button></form><small id="login-note">Not your Muse password. This dashboard has its own code.</small></main></div>`;
  document.querySelector('#login').onsubmit=async event=>{event.preventDefault();const button=event.currentTarget.querySelector('button');button.disabled=true;try{const data=await api('login',{method:'POST',body:{password:document.querySelector('#access').value}});state.csrf=data.csrf;state.demo=data.demo===true;state.canWrite=data.can_change_recordings===true;await refresh();}catch(e){signIn(e.message);}};
}
async function refresh() {
  const seq=++state.sequence; state.loading=true; state.error=''; render();
  try {const [snapshot,media,settings,conversations]=await Promise.all([readStablePractice(api),...['media','settings','conversations'].map(p=>api(p))]);const {overview,context}=snapshot;
    if(seq!==state.sequence)return;
    state.data={overview,context,media,settings:settings.settings,conversations};state.stale=false;
    if(!allGoals(context).some(g=>g.id===state.goal)){state.goal=allGoals(context)[0]?.id??null;state.session=null;}
  }catch(e){if(seq!==state.sequence)return;if(e.status===401){signIn('Your session ended. Sign in again to continue.');return;}state.error=e.message;state.stale=Boolean(state.data);}
  if(seq!==state.sequence)return;state.loading=false;render();
}
function selectSession(sessions) { return sessions.find(s=>s.id===state.session) ?? [...sessions].sort((a,b)=>String(b.occurred_at).localeCompare(String(a.occurred_at)))[0]; }
function sessionCard(s) {
  if(!s)return '<section class="card session empty-session"><div class="eyebrow">Practice</div><h2>No practice yet.</h2><p class="under">Record on your watch or Mac, then refresh.</p></section>';
  const m=s.metrics??{}, measured=s.measurement_status==='measured', lang={en:'English',fr:'French'}[s.language]??s.language;
  const chip=(n,cls,one,many,example)=>`<div class="metric ${cls}"><strong>${count(n)}</strong><span>${plural(n,one,many)}</span><small>${example}</small></div>`;
  const observation=s.analysis?.observation, question=s.reply?.question, ai=observation||question;
  const aiTitle=observation&&!question&&s.analysis.status!=='model_observation'?'Saved feedback':'AI feedback';
  return `<section class="card session"><div class="card-header"><h2>${esc(date(s.occurred_at))}</h2><span class="pill">${esc(device(s.capture_device))}${lang&&lang!=='English'?` · ${esc(lang)}`:''}</span></div><p class="transcript">“${esc(s.transcript||'No transcript available.')}”</p><div class="session-split${ai?'':' single'}"><div class="counted"><div class="eyebrow">${measured?'Counted by code':'Sample counts'}</div><div class="metrics">${chip(m.filler_count,'filler','Filler','Fillers','“um”, “uh”')}${chip(m.hedge_count,'unsure','Unsure word','Unsure words','“I think”, “maybe”')}${chip(m.restart_count,'restart','Restart','Restarts','starting over')}</div><p class="caption">${count(m.word_count)} words · ${count(m.words_per_minute)} words a minute · Counts, not a progress score</p></div>${ai?`<div class="feedback"><div class="eyebrow">${aiTitle}</div>${observation?`<p>${esc(observation)}</p>`:''}${question?`<p class="ai-question"><span>Follow-up question</span>${esc(question)}</p>`:''}<p class="caption">Written by AI. A suggestion, not a count.</p></div>`:''}</div></section>`;
}
function drillCard(exercise, sessions, basisStatus, fresh=true) {
  const muse='<a class="button-link" href="https://muse.ai" target="_blank" rel="noreferrer">Open Muse</a>';
  if(!fresh)return '<aside class="card next"><div class="eyebrow">Next drill</div><h3>Refresh to see your next drill.</h3></aside>';
  if(exercise&&(basisStatus==='stale'||(exercise.basis&&basisStatus!=='current')))return `<aside class="card next"><div class="eyebrow">Saved drill</div><h3>This drill needs a review.</h3><p>Its source changed, so the old steps are hidden. Review it in Muse first.</p>${muse}</aside>`;
  if(!exercise)return `<aside class="card next"><div class="eyebrow">Next drill</div><h3>No saved drill yet.</h3><p>Ask Muse for one and save it to TugTalk.</p>${muse}</aside>`;
  const basis=exercise.basis, habit={filler:plural(basis?.claimed_count,'filler'),hedge:plural(basis?.claimed_count,'unsure word'),restart:plural(basis?.claimed_count,'restart')}[basis?.habit]??'speech patterns';
  const linked=(basis?.source_ids??[]).map(id=>sessions.find(s=>s.id===id)).filter(Boolean);
  return `<aside class="card next"><div class="eyebrow">Next drill</div><h3>${esc(exercise.title)}</h3><p>${esc(exercise.instructions)}</p><p class="basis">${basis?`<strong>Why:</strong> ${count(basis.claimed_count)} ${esc(habit)} in ${count(basis.source_ids?.length)} ${basis.source_ids?.length===1?'practice':'practices'}${linked.length?` (${esc(linked.map(s=>date(s.occurred_at)).join(', '))})`:''}${basis.checked?', checked by the server':''}.`:'No reason was saved with this drill.'}${exercise.due_at?` Due ${esc(date(exercise.due_at))}.`:''}</p>${muse}</aside>`;
}
function goalsView() {
  const c=state.data.context, goals=allGoals(c), goal=goals.find(g=>g.id===state.goal);
  if(!goal)return '<section class="card empty"><h2>No goals yet.</h2><p>Create one in TugTalk or Muse, then refresh.</p></section>';
  const sessions=practices(c).filter(s=>forGoal(s,goal.id)), exercises=(c.exercises??[]).filter(e=>e.goal_id===goal.id), checkins=c.check_ins??[];
  const fresh=!state.stale&&!state.loading, pending=readyDrills(exercises,checkins,state.data.overview,{fresh}), staleDrills=exercises.filter(e=>!checkins.some(x=>x.exercise_id===e.id)&&(drillBasisStatus(state.data.overview,e.id)==='stale'||(e.basis&&drillBasisStatus(state.data.overview,e.id)!=='current')));
  const s=selectSession(sessions);const unlinked=practices(c).filter(x=>!x.goal_id).length;
  const shown=pending[0]??staleDrills[0], otherDrills=exercises.filter(e=>e!==shown||!fresh), rounds=renderPracticeRounds(state.data.overview,goal.id,{fresh:!state.stale&&!state.loading});
  const n=g=>practices(c).filter(x=>forGoal(x,g.id)).length;
  return `<div class="layout"><aside><div class="sidebar-title"><h2>Your goals</h2><span class="pill">${goals.length}</span></div><div class="goals">${goals.map(g=>`<button class="goal ${g.id===goal.id?'active':''}" data-goal="${esc(g.id)}" aria-pressed="${g.id===goal.id}"><strong>${esc(g.title)}</strong><span>${n(g)} ${plural(n(g),'practice')}</span></button>`).join('')}</div>${unlinked?`<p class="aside-note">${unlinked} ${plural(unlinked,'practice')} not linked to a goal.</p>`:''}</aside><main><div class="detail-head"><h2>${esc(goal.title)}</h2><p>${esc(goal.target)}</p></div>${sessionCard(s)}<div class="practice-grid${rounds?'':' single'}">${rounds}${drillCard(shown,sessions,drillBasisStatus(state.data.overview,shown?.id),fresh)}</div><section class="under"><div class="sidebar-title"><h2>Practice history</h2><span class="subtle">${sessions.length}</span></div><div class="rows">${sessions.length?sessions.map(x=>`<div class="row"><div><strong>${esc(date(x.occurred_at))}</strong><small>${esc(device(x.capture_device))}${x.measurement_status==='measured'?'':' · Sample'}</small></div><button data-session="${esc(x.id)}" ${x.id===s?.id?'disabled':''}>${x.id===s?.id?'Showing':'View'}</button></div>`).join(''):'<p class="subtle">Your first practice will show here.</p>'}</div></section>${otherDrills.length?`<section class="under"><div class="sidebar-title"><h2>Saved drills</h2></div><div class="rows">${otherDrills.map(e=>{const check=checkins.find(x=>x.exercise_id===e.id),basisStale=!fresh||drillBasisStatus(state.data.overview,e.id)==='stale'||(e.basis&&drillBasisStatus(state.data.overview,e.id)!=='current');return `<div class="row"><div><strong>${esc(e.title)}</strong><small>${basisStale?'Needs a fresh check before use.':check?check.status==='skipped'?'Skipped.':check.evidence_type==='measured'?'Done, with a linked recording.':'Marked done by you. Not measured.':esc(e.instructions)}</small></div><span class="pill">${basisStale?'Needs review':check?esc(check.status??'Checked in'):'Ready'}</span></div>`;}).join('')}</div></section>`:''}${renderPracticeExercises(state.data.overview,goal.id,{fresh})}</main></div>`;
}
function conversationsView() {
  const row=(label,status,on)=>`<div class="row"><strong>${label}</strong><span class="pill${on?' on':''}">${status}</span></div>`;
  return `<main><section class="card empty"><div class="eyebrow">Muse chats</div><h2>Your chats stay in Muse.</h2><p>TugTalk shows goals and drills saved from Muse. It can’t read your chat history.</p><div class="rows">${row('Saved goals and drills','Shown in Goals',true)}${row('Chat summaries','Not connected')}${row('Full chats','Not connected')}</div><a class="button-link" href="https://muse.ai" target="_blank" rel="noreferrer">Open Muse</a></section></main>`;
}
function recordingsView() {
  const settings=state.data.settings??{}, list=state.data.media.media??[];
  return `<main><section class="card settings"><div><div class="eyebrow">Recording setting</div><h2>Keep recordings: ${settings.keep_recordings?'on':'off'}</h2><p>${settings.keep_recordings?'New audio is kept so you can replay it.':'New audio is deleted after transcription. Transcripts and counts stay.'} Turning this off doesn’t delete kept audio.</p></div><button id="retention" ${!state.canWrite?'disabled':''}>Turn ${settings.keep_recordings?'off':'on'}</button></section>${!state.canWrite?'<p class="notice">Changes are off for this connection. You can still play and download.</p>':''}<section class="card"><div class="card-header"><h2>Kept recordings</h2><span class="pill">${list.length} ${plural(list.length,'file')}</span></div><p class="caption">Deleting audio keeps its transcript and counts.</p>${list.length?list.map(item=>`<article class="recording"><div><h3>${esc(date(item.occurred_at??item.kept_at))}</h3><p class="caption">${esc(['voice_rounds','voice-rounds'].includes(item.record_kind)?'Conversation practice':'Recorded practice')} · ${Math.ceil((item.bytes??0)/1024)} KB${item.record_hidden?' · Practice hidden':''}</p><audio controls preload="none" src="/app-api/media/${encodeURIComponent(item.id)}" aria-label="Recording from ${esc(date(item.occurred_at??item.kept_at))}"></audio></div><div class="actions"><a class="button-outline" href="/app-api/media/${encodeURIComponent(item.id)}" download="practice-recording.wav">Download</a><button class="danger" data-delete="${esc(item.id)}" ${!state.canWrite?'disabled':''}>Delete audio</button></div></article>`).join(''):'<p class="under subtle">No kept recordings.</p>'}</section></main>`;
}
function render() {
  if(!state.csrf)return;
  const o=state.data?.overview;
  root.innerHTML=`<header class="topbar">${brand}<div class="account"><button id="logout" class="quiet">Sign out</button></div></header><div class="shell"><div class="intro"><h1>Your practice</h1><div class="refresh"><span class="freshness">${state.loading?'Checking…':o?`Updated ${esc(date(o.as_of))}`:'Not connected yet'}</span><button id="refresh" ${state.loading?'disabled':''}>${state.loading?'Refreshing…':'Refresh'}</button></div></div>${state.demo?'<div class="notice">Sample data. Your account is not changed.</div>':''}<nav class="tabs" aria-label="Practice sections">${[['goals','Goals'],['conversations','Conversations'],['recordings','Recordings']].map(([key,label])=>`<button class="tab" data-tab="${key}" ${state.tab===key?'aria-current="page"':''}>${label}</button>`).join('')}</nav><div id="message" role="alert">${state.error?`<p class="notice error">${esc(state.error)}${state.stale?' Showing older results.':''}</p>`:''}</div>${state.data?(state.tab==='goals'?goalsView():state.tab==='conversations'?conversationsView():recordingsView()):`<main class="card loading"><h2>${state.loading?'Loading your practice…':'Your practice is unavailable.'}</h2>${state.loading?'':'<p class="under">Use Refresh to try again.</p>'}</main>`}<footer><a href="/">TugTalk home</a><span>Private to this account.</span></footer></div>`;
  document.querySelector('#refresh').onclick=refresh;
  document.querySelector('#logout').onclick=async()=>{try{await api('logout',{method:'POST'});signIn();}catch(e){state.error=e.message;render();}};
  document.querySelectorAll('[data-tab]').forEach(b=>b.onclick=()=>{state.tab=b.dataset.tab;render();});
  document.querySelectorAll('[data-goal]').forEach(b=>b.onclick=()=>{state.goal=b.dataset.goal;state.session=null;render();});
  document.querySelectorAll('[data-session]').forEach(b=>b.onclick=()=>{state.session=b.dataset.session;render();});
  document.querySelector('#retention')?.addEventListener('click',async event=>{const button=event.currentTarget;button.disabled=true;try{await api('settings',{method:'PATCH',body:{expected_version:state.data.settings.version,keep_recordings:!state.data.settings.keep_recordings}});await refresh();}catch(e){if(e.status===401){signIn();return;}if(e.status===409){await refresh();state.error='This setting changed on another device. The latest is loaded; check it, then try again.';}else{state.error=e.message;}render();}});
  document.querySelectorAll('[data-delete]').forEach(b=>b.onclick=async()=>{if(!confirm('Delete this audio for good? Its transcript and counts stay.'))return;b.disabled=true;try{await api(`media/${encodeURIComponent(b.dataset.delete)}`,{method:'DELETE'});await refresh();}catch(e){if(e.status===401){signIn();return;}state.error=e.message;render();}});
}
window.addEventListener('focus',()=>{if(state.csrf&&!state.loading)refresh();});
try{const data=await api('session');state.csrf=data.csrf;state.demo=data.demo===true;state.canWrite=data.can_change_recordings===true;await refresh();}catch{signIn();}
