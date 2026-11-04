// Compile unchanged native packages in temporary storage and feed actual backend response fixtures.
// No installed app is launched, no provider is called, and no native source directory is written.
import { cpSync, mkdtempSync, readFileSync, writeFileSync, readdirSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { Readable } from 'node:stream';
import { Store } from '../src/store.mjs';
import { createPractice } from '../src/practice.mjs';
import { voiceParams, handleVoiceRound } from '../src/voice.mjs';
import { createLiveRound, wavFromPcm } from '../src/live-voice.mjs';
import { createHandler } from '../src/server.mjs';
const root=resolve(fileURLToPath(new URL('..',import.meta.url)));
const workspace=mkdtempSync(join(tmpdir(),'practice-native-'));
const sha=x=>createHash('sha256').update(x).digest('hex');
function manifest(dir) {
 const files=[];const visit=p=>{for(const entry of readdirSync(p)){const f=join(p,entry);if(statSync(f).isDirectory())visit(f);else files.push({path:relative(root,f),sha256:sha(readFileSync(f))});}};
 visit(dir);return files.sort((a,b)=>a.path.localeCompare(b.path));
}
const packages=[{name:'mac',source:'apps/mac',target:'ScreenContextCoreTests'},{name:'watch',source:'apps/watch/SparringCore',target:'SparringCoreTests'}];
const before=packages.flatMap(p=>['Sources','Tests'].flatMap(d=>manifest(join(root,p.source,d))).concat([{path:`${p.source}/Package.swift`,sha256:sha(readFileSync(join(root,p.source,'Package.swift')))}]));
const fixtures=await backendFixtures();
const fixturePath=join(workspace,'responses.json');writeFileSync(fixturePath,JSON.stringify(fixtures,null,2));
const results=[];
for(const p of packages){
 const destination=join(workspace,p.name);
 for(const item of ['Package.swift','Sources','Tests'])cpSync(join(root,p.source,item),join(destination,item),{recursive:true});
 cpSync(join(root,'test/native-practice',`${p.name}.swift`),join(destination,'Tests',p.target,'SemanticNativeCompatibility.swift'));
 const args=['test','--package-path',destination,'--scratch-path',join(workspace,`${p.name}-build`),'--filter','SemanticNativeCompatibility'];
 const run=spawnSync('swift',args,{env:{...process.env,SEMANTIC_FIXTURES:fixturePath},encoding:'utf8',maxBuffer:32*1024*1024});
 const log=join(workspace,`${p.name}.log`);writeFileSync(log,(run.stdout??'')+(run.stderr??''));
 results.push({package:p.name,exit:run.status,log,command:['swift',...args]});
 console.log(`${p.name}: ${run.status===0?'PASS':'FAIL'}; ${log}`);
 if(run.status!==0){const lines=((run.stdout??'')+(run.stderr??'')).split('\n');console.error(lines.filter(line=>/error:|failed|fatal|Error/.test(line)).concat(lines.slice(-15)).join('\n'));}
}
const unchanged=before.every(f=>sha(readFileSync(join(root,f.path)))===f.sha256);
const report={backend_ref:spawnSync('git',['rev-parse','HEAD'],{cwd:root,encoding:'utf8'}).stdout.trim(),source_files:before,native_sources_unchanged:unchanged,results,fixturePath,
 scope:'Actual unchanged native package decoding and state helpers with mocked-inference backend responses; no physical device or installed app exercised.',
 limitations:['Existing watch must start a fresh local round before joining semantic practice; a mid-legacy join can hit its local cap before the server cap.','Existing native displays do not show full semantic assessment or authoritative round totals; use current Muse/API/dashboard state.']};
writeFileSync(join(workspace,'report.json'),JSON.stringify(report,null,2));
console.log(`Report: ${join(workspace,'report.json')}`);
if(!unchanged||results.some(r=>r.exit!==0))process.exitCode=1;

async function backendFixtures(){
 const store=new Store(join(workspace,'fixtures.sqlite'));store.addToken('native-fixture-token','test');
 for(const id of ['goal-semantic','goal-legacy','goal-live'])store.put('test','goals',{id,version:1,title:'Delivery',target:'Answer the delivery request',updated_at:new Date().toISOString()});
 const answer='We can deliver by Friday if security approves Thursday.';
 let outcome='unclear';const models={async transcribe(){return {transcript:answer,turns:[],model:'fixture-asr',provider_session_id:'fixture-asr'};},async voiceReply({allowed}){return {status:'model_reply',model:'fixture-spark',attempts:1,reply:{move:allowed[0],question:'What will security need to approve?',quote:answer,assessment:{objectives:[{id:'delivery',status:outcome,evidence:outcome==='unclear'?[]:[{start:0,end:answer.length,quote:answer}],missing:outcome==='addressed'?'':'Clarify the dependency.'}],next_question:'What will security need to approve?'}}};}};
 const audio=wavFromPcm(Buffer.alloc(48000)),phases={async release(){},async acquire(){}};
 const params=voiceParams({'x-goal-id':'goal-semantic'});
 let number=0;const create=goal=>createPractice(store,'test',{goal_id:goal,expected_goal_version:1,request_text:'When can you deliver, and what does it depend on?',objectives:[{id:'delivery',text:'Explain delivery timing and dependency.'}],confirmed:true},`create-${++number}`);
 const send=(key,p=params)=>handleVoiceRound(store,models,'test',{params:p,audio},key,'fixture',phases);
 try{
  const legacyParams=voiceParams({'x-goal-id':'goal-legacy','x-counterpart-need':'date'});
  const legacy=await send('legacy-001',legacyParams);
  create('goal-semantic');const unclear=await send('semantic-001');outcome='partial';const partial=await send('semantic-002');outcome='addressed';const addressed=await send('semantic-003');const replay=await send('semantic-003');
  const req=Object.assign(Readable.from([audio]),{method:'POST',url:'/v1/voice-rounds',headers:{authorization:'Bearer native-fixture-token','content-type':'audio/wav','x-goal-id':'goal-semantic','idempotency-key':'closed-001'}});
  let closed409;const res={writeHead(status){this.status=status;},end(data){closed409={status:this.status,body:JSON.parse(data)};}};await createHandler(store,{models})(req,res);
  create('goal-semantic');outcome='unclear';let capped;for(let i=1;i<=4;i++)capped=await send(`cap-${i}`);
  create('goal-live');const events=[];const live=createLiveRound({store,models,token:'native-fixture-token',start:{type:'start',idempotency_key:'live-fixture',goal_id:'goal-live',speech:false},phases,emit:event=>events.push(event)});live.audio(Buffer.alloc(48000));live.end();const saved=await live.done;
  return {legacy,unclear,partial,addressed,replay,capped,closed409,liveReply:events.find(e=>e.type==='reply'),liveSaved:{type:'saved',...saved.body}};
 }finally{store.close();}
}
