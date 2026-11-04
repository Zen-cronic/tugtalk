import { createServer } from 'node:http';
export function fixtureServer(token) {
  const at='2026-11-03T18:20:00.000Z';
  const goals=[{id:'goal-clear',title:'Say the main point first',target:'Give a clear update in one sentence, then add the detail.',version:1},{id:'goal-french',title:'Find my words in French',target:'Ask a question without switching back to English.',version:1},{id:'goal-listen',title:'Leave room to listen',target:'Pause before responding in a difficult conversation.',version:1}];
  const sessions=[{id:'session-watch',version:1,goal_id:goals[0].id,occurred_at:at,capture_device:'watch',language:'en',source:'capture',measurement_status:'measured',transcript:'Um, I think we should launch the smaller version first. The sign-in flow is ready, and the team can test it on Friday.',metrics:{word_count:25,words_per_minute:116,filler_count:1,hedge_count:1,restart_count:0},analysis:{status:'model_observation',observation:'Your recommendation is clear. Try saying it before “I think” so the listener hears the decision straight away.'}},{id:'session-mac',version:1,goal_id:goals[0].id,occurred_at:'2026-11-03T16:10:00.000Z',capture_device:'mac',language:'en',source:'capture',measurement_status:'measured',transcript:'Um, maybe we can start with the sign-in flow. I think the smaller release will help us learn.',metrics:{word_count:19,words_per_minute:108,filler_count:1,hedge_count:2,restart_count:0},analysis:{status:'model_observation',observation:'Try leading with the release you recommend.'}},{id:'session-french',version:1,goal_id:goals[1].id,occurred_at:'2026-11-02T22:00:00.000Z',capture_device:'mac',language:'fr',source:'capture',measurement_status:'measured',transcript:'Est-ce que vous pouvez répéter la dernière question, s’il vous plaît ?',metrics:{word_count:12,words_per_minute:80,filler_count:0,hedge_count:0,restart_count:0}}];
  const exercises=[{id:'drill-one',version:1,goal_id:goals[0].id,title:'Lead with your decision',instructions:'Say your recommendation in one sentence. Pause. Then give one reason it matters.',set_via:'connector',basis:{habit:'hedge',source_ids:['session-watch'],claimed_count:1,checked:'recounted by the server from stored metrics',checked_at:at}}];
  let settings={keep_recordings:true,version:1};let media=[{id:'session-watch',record_kind:'sessions',kind:'audio',bytes:16044,content_type:'audio/wav',kept_at:at,occurred_at:at,record_hidden:false}];
  const wav=Buffer.alloc(16044);wav.write('RIFF');wav.writeUInt32LE(16036,4);wav.write('WAVEfmt ',8);wav.writeUInt32LE(16,16);wav.writeUInt16LE(1,20);wav.writeUInt16LE(1,22);wav.writeUInt32LE(8000,24);wav.writeUInt32LE(16000,28);wav.writeUInt16LE(2,32);wav.writeUInt16LE(16,34);wav.write('data',36);wav.writeUInt32LE(16000,40);
  const seen=new Map();
  return createServer(async(req,res)=>{
    const send=(status,data)=>{res.writeHead(status,{'Content-Type':'application/json'});res.end(JSON.stringify(data));};
    if(req.headers.authorization!==`Bearer ${token}`)return send(401,{error:'Unauthorized'});
    const context={as_of:new Date().toISOString(),goals,sessions,exercises,check_ins:[],voice_rounds:[],screen_contexts:[]};
    if(req.method==='GET'&&req.url==='/v1/context')return send(200,context);
    if(req.method==='GET'&&req.url==='/v1/overview')return send(200,{as_of:context.as_of,snapshot_revision:`fixture-${settings.version}-${media.length}`,goals,settings});
    if(req.method==='GET'&&req.url==='/v1/settings')return send(200,{settings});
    if(req.method==='GET'&&req.url==='/v1/media')return send(200,{media,recordings:media.length,bytes:media.reduce((s,m)=>s+m.bytes,0),cap_bytes:200*1024*1024});
    if(req.method==='PATCH'&&req.url==='/v1/settings'){
      const key=req.headers['idempotency-key'];if(seen.has(key))return send(200,seen.get(key));
      let raw='';for await(const part of req)raw+=part;const body=JSON.parse(raw);
      if(body.expected_version!==settings.version)return send(409,{error:'Conflict'});
      settings={keep_recordings:body.keep_recordings,version:settings.version+1};const result={settings};seen.set(key,result);return send(200,result);
    }
    if(req.url==='/v1/media/session-watch'&&media.length){if(req.method==='GET'){res.writeHead(200,{'Content-Type':'audio/wav'});res.end(wav);return;}if(req.method==='DELETE'){media=[];return send(200,{deleted:true});}}
    return send(404,{error:'Not found'});
  });
}
