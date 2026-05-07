const db = require('../db');

console.log('=== 当前所有 ad_events (最近 20 条) ===');
const r = db.__db.prepare(`
  SELECT placement, provider, type, err_code, err_msg, ts
  FROM ad_events ORDER BY ts DESC LIMIT 20
`).all();
for (const x of r) {
  const t = new Date(x.ts).toLocaleTimeString('zh-CN');
  const msg = (x.err_msg || '').replace(/\s+/g, ' ').substring(0, 60);
  console.log(`  ${t} ${x.placement.padEnd(22)} ${x.provider.padEnd(5)} ${x.type.padEnd(7)} ${x.err_code || '-'} ${msg}`);
}

console.log('');
console.log('=== 时间窗口分布 ===');
for (const h of [1, 6, 24]) {
  const since = Date.now() - h * 3600000;
  const c = db.__db.prepare(`
    SELECT placement, provider, type, COUNT(*) AS n
    FROM ad_events WHERE ts > ?
    GROUP BY placement, provider, type
    ORDER BY placement, provider
  `).all(since);
  console.log(`过去 ${h} 小时 (${c.reduce((s, x) => s + x.n, 0)} 条):`);
  for (const x of c) {
    console.log(`  ${x.placement}/${x.provider}/${x.type}: ${x.n}`);
  }
  console.log('');
}
