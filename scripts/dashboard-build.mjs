import { dirname } from 'node:path';
import landingAssets from '../src/landing-assets.json' with { type: 'json' };
import { mkdir, copyFile, readFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
const checked=spawnSync(process.execPath,['--check','web/app.js'],{stdio:'inherit'});if(checked.status!==0)process.exit(checked.status??1);
// The one dashboard asset list, also read by the gateway (src/dashboard-gateway.mjs) and the hosting app (deploy/dashboard_app.py).
const assets=JSON.parse(await readFile('web/dashboard-assets.json','utf8'));
await mkdir('build/dashboard',{recursive:true});
for(const name of assets){await readFile(`web/${name}`);await copyFile(`web/${name}`,`build/dashboard/${name}`);}
console.log(`Dashboard built: ${assets.length} static assets in build/dashboard.`);

for(const name of landingAssets){await mkdir(dirname(`build/landing/${name}`),{recursive:true});await copyFile(`site/${name}`,`build/landing/${name}`);}
console.log(`Landing built: ${landingAssets.length} public assets in build/landing.`);
