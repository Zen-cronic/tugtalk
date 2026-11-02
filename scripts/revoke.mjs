import { readFileSync } from 'node:fs';
import { Store } from '../src/store.mjs';
const store=new Store('.data/connector.sqlite'); store.revoke(readFileSync('.data/owner-token.txt','utf8').trim()); store.close();
console.log('Revoked the synthetic operator credential.');
