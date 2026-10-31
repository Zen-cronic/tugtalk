import { Store } from '../src/store.mjs';
const store=new Store(process.env.DB_PATH??'.data/connector.sqlite');
console.log(JSON.stringify({requests:store.db.prepare('SELECT * FROM requests ORDER BY created_at').all(),receipts:store.receipts('synthetic-operator'),context:store.context('synthetic-operator')},null,2));
store.close();
