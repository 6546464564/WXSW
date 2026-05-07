const db = require('../db');

console.log('=== 1. 所有 placement/type 计数 ===');
const all = db.__db.prepare(`
  SELECT placement, type, provider, COUNT(*) AS n
  FROM ad_events
  GROUP BY placement, type, provider
  ORDER BY placement, type
`).all();
for (const r of all) {
  console.log('  ' + r.placement + '/' + r.provider + '/' + r.type + ': ' + r.n);
}

console.log('');
console.log('=== 2. 最近 20 条 rewardedReadingUnlock 事件 ===');
const recent = db.__db.prepare(`
  SELECT ts, provider, type, err_code, err_msg
  FROM ad_events
  WHERE placement = 'rewardedReadingUnlock'
  ORDER BY ts DESC LIMIT 20
`).all();
if (recent.length === 0) {
  console.log('  (无任何记录, 一条都没回传过)');
} else {
  for (const r of recent) {
    const t = new Date(r.ts).toLocaleTimeString('zh-CN');
    const err = r.err_code ? ' code=' + r.err_code : '';
    console.log('  ' + t + ' ' + r.provider + ' ' + r.type + err);
  }
}

console.log('');
console.log('=== 3. 总条数 ===');
const c = (sql) => db.__db.prepare(sql).get().n;
console.log('  ad_events 总:                ' + c('SELECT COUNT(*) AS n FROM ad_events'));
console.log('  splash:                      ' + c("SELECT COUNT(*) AS n FROM ad_events WHERE placement='splash'"));
console.log('  rewardedReadingUnlock:       ' + c("SELECT COUNT(*) AS n FROM ad_events WHERE placement='rewardedReadingUnlock'"));

console.log('');
console.log('=== 4. 历史所有时段 (含被清空前) ===');
console.log('  注: 重置 (10:37) 之前的数据已删');
const span = db.__db.prepare(`
  SELECT MIN(ts) AS first, MAX(ts) AS last FROM ad_events
`).get();
if (span.first) {
  console.log('  现存数据时间窗: ' + new Date(span.first).toLocaleTimeString('zh-CN') + ' - ' + new Date(span.last).toLocaleTimeString('zh-CN'));
}
