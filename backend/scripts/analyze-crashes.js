const db = require('../db');

console.log('=== 所有 crash 记录 ===');
const crashes = db.__db.prepare(`
  SELECT fingerprint, exception, stack, app_ver, brand, model, sdk_int, ts
  FROM crashes
  ORDER BY ts DESC
  LIMIT 20
`).all();

for (const c of crashes) {
  console.log('\n----------');
  console.log(`时间: ${new Date(c.ts).toLocaleString('zh-CN')}`);
  console.log(`fingerprint: ${c.fingerprint}`);
  console.log(`exception: ${c.exception}`);
  console.log(`device: ${c.brand} ${c.model} (sdk ${c.sdk_int}) appVer ${c.app_ver}`);
  console.log(`stack:`);
  const stackLines = (c.stack || '').split('\n').slice(0, 15);
  for (const line of stackLines) console.log(`  ${line}`);
  if ((c.stack || '').split('\n').length > 15) console.log(`  ... (truncated)`);
}

console.log('\n\n=== 按 fingerprint 聚合 ===');
const grouped = db.__db.prepare(`
  SELECT fingerprint, exception, COUNT(*) AS n, MIN(ts) AS first_ts, MAX(ts) AS last_ts
  FROM crashes
  GROUP BY fingerprint
  ORDER BY n DESC
`).all();
for (const g of grouped) {
  const first = new Date(g.first_ts).toLocaleString('zh-CN');
  const last = new Date(g.last_ts).toLocaleString('zh-CN');
  console.log(`  [${g.n}x] ${g.exception.substring(0, 60)}`);
  console.log(`         fp=${g.fingerprint.substring(0, 16)}... 首次=${first} 最近=${last}`);
}
