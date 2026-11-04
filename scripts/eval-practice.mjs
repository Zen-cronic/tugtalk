import { readFileSync } from 'node:fs';
import { candidatePrompt, relevanceBaseline, scoreRecorded, CONDITIONS } from '../src/practice-eval.mjs';
import { needMet } from '../src/counterpart.mjs';
const corpus=JSON.parse(readFileSync(new URL('../test/fixtures/practice-candidates.json',import.meta.url),'utf8'));
const args=process.argv.slice(2);
if(args[0]==='--prepare') {
 const condition=args[1]??'with_brief';
 console.log(JSON.stringify({label_status:corpus.label_status,condition,requests:corpus.cases.filter(c=>c.split!=='calibration').map(c=>({case_id:c.id,...candidatePrompt(c,condition)}))},null,2));
} else if(args[0]==='--score') {
 const reviewed=JSON.parse(readFileSync(args[1],'utf8')),records=JSON.parse(readFileSync(args[2],'utf8'));
 console.log(JSON.stringify(scoreRecorded(reviewed,records),null,2));
} else {
 console.log(JSON.stringify({label_status:corpus.label_status,accuracy_claim:'Blocked until human-reviewed labels are frozen and real recorded responses exist.',paid_calls:0,conditions:CONDITIONS,
  candidate_count:corpus.cases.filter(c=>c.split!=='calibration').length,calibration_count:corpus.cases.filter(c=>c.split==='calibration').length,
  predictions:corpus.cases.map(c=>({id:c.id,split:c.split,lexical:needMet(c.answer,c.need,'en')?'addressed':'not_addressed',relevance_heuristic:relevanceBaseline(c)}))},null,2));
}
