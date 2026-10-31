import { readFileSync, existsSync } from 'node:fs';
import { Store } from '../src/store.mjs';
const s=new Store(process.env.DB_PATH??'.data/connector.sqlite');
const c=s.context('synthetic-operator');
const receipts=s.receipts('synthetic-operator');
const localProbeFile='.artifacts/local-probe-request-ids.json';
const localProbeIds=new Set(existsSync(localProbeFile)?JSON.parse(readFileSync(localProbeFile,'utf8')):[]);
const requests=s.db.prepare("SELECT id,method,path,status,created_at FROM requests WHERE user_id='synthetic-operator' ORDER BY created_at").all().filter(r=>!localProbeIds.has(r.id));
const checks={
  authenticated_read:requests.some(r=>r.method==='GET'&&r.path==='/v1/context'&&r.status===200),
  goal_saved:c.goals.length>0&&receipts.some(r=>c.goals.some(g=>g.id===r.record.id)),
  exercise_saved:c.exercises.length>0,
  completion_saved:c.check_ins.some(x=>x.status==='completed'&&x.evidence_type==='self_reported'),
  corrected_session:c.sessions.some(x=>x.version>=2&&x.correction_reason),
  revised_goal:c.goals.some(x=>x.version>=2),
  no_fabricated_measurement:c.progress.measured_improvement===null,
  text_file_read:requests.some(r=>r.path==='/v1/files/evidence.txt'&&r.status===200)
};
console.log(JSON.stringify({checks,receipts:receipts.map(r=>({receipt_id:r.receipt_id,record_id:r.record.id,version:r.record_version,saved_at:r.saved_at})),requests,limitations:'Known local diagnostic requests are excluded. Remaining server-side checks still require correlation with Muse activity; they do not prove the displayed answer, fresh-chat continuity, or device notifications. Inspect the corresponding chat too.'},null,2));
s.close();
if(Object.values(checks).some(x=>!x)) process.exitCode=1;
