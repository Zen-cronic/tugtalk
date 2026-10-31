// One isolated request. The caller persists the closed database before releasing this response.
import { Readable } from 'node:stream';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { Store } from '../src/store.mjs';
import { createHandler } from '../src/server.mjs';
let input='';
for await (const chunk of process.stdin) {
  input+=chunk;
  if(input.length>65536) throw new Error('Adapter input exceeds 64 KiB');
}
const envelope=JSON.parse(input);
const dbPath=process.env.DB_PATH;
if(!dbPath) throw new Error('DB_PATH is required');
mkdirSync(dirname(dbPath),{recursive:true,mode:0o700});
const store=new Store(dbPath);
try {
  const hash=process.env.CONNECTOR_TOKEN_HASH;
  if(hash) {
    if(!/^[a-f0-9]{64}$/.test(hash)) throw new Error('Invalid bootstrap token hash');
    store.db.prepare('INSERT OR IGNORE INTO tokens(hash,user_id,scopes) VALUES(?,?,?)').run(hash,'synthetic-operator',JSON.stringify(['read','write']));
    store.seed('synthetic-operator');
  }
  const req=Readable.from([Buffer.from(envelope.body_b64??'','base64')]);
  Object.assign(req,{method:envelope.method,url:envelope.path,headers:envelope.headers??{}});
  let output;
  const res={writeHead(status,headers){this.status=status;this.headers=headers;},end(body){output={status:this.status,headers:this.headers,body_b64:Buffer.from(body).toString('base64')};}};
  await createHandler(store,{baseUrl:envelope.base_url})(req,res);
  if(!output) throw new Error('Handler did not produce a response');
  store.db.exec('PRAGMA wal_checkpoint(TRUNCATE)');
  store.close();
  // Emit only the response. Never log request headers or input envelope.
  process.stdout.write(JSON.stringify(output));
} catch(err) {
  try {store.close();} catch {}
  console.error('Adapter failed:',err.name);process.exitCode=1;
}
