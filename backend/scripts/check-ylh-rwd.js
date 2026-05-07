const db = require('../db');
const r = db.__db.prepare(`
  SELECT placement, provider, type, err_code, err_msg, ts
  FROM ad_events
  WHERE placement = 'rewardedReadingUnlock' AND provider = 'ylh'
  ORDER BY ts DESC LIMIT 10
`).all();
console.log('=== ylh 激励视频事件 ===');
for (const x of r) {
  const t = new Date(x.ts).toLocaleTimeString('zh-CN');
  console.log(t, x.type, 'code=' + (x.err_code || '-'), '| msg:', (x.err_msg || '').substring(0, 100));
}
