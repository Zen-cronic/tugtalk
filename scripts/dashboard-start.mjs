import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { createDashboard } from '../src/dashboard-gateway.mjs';
const env=process.env;
// Secrets are supplied to this server process, never to the browser or its bundle.
const password=env.DASHBOARD_PASSWORD_FILE?(await readFile(env.DASHBOARD_PASSWORD_FILE,'utf8')).trim():env.DASHBOARD_PASSWORD;
const server=createDashboard({webRoot:resolve('build/dashboard'),landingRoot:resolve('build/landing'),origin:env.DASHBOARD_ORIGIN,upstream:env.DASHBOARD_UPSTREAM,token:env.DASHBOARD_CONNECTOR_TOKEN,password,secure:env.DASHBOARD_LOCAL_HTTP!=='1',allowRecordingChanges:env.DASHBOARD_ALLOW_RECORDING_CHANGES==='1'});
const port=Number(env.DASHBOARD_PORT??4321);
server.listen(port,env.DASHBOARD_BIND??'127.0.0.1',()=>process.stdout.write(`Private dashboard listening on port ${port}.\n`));
for(const signal of ['SIGINT','SIGTERM'])process.on(signal,()=>server.close());
