// 分析 1h 测试结果, 输出 funnel + error 明细
const db = require('../db');

console.log('=== load -> show -> close 转化漏斗 ===');
const conv = db.__db.prepare(`
  SELECT placement, provider,
    SUM(CASE WHEN type='load' THEN 1 ELSE 0 END) AS L,
    SUM(CASE WHEN type='show' THEN 1 ELSE 0 END) AS S,
    SUM(CASE WHEN type='reward' THEN 1 ELSE 0 END) AS R,
    SUM(CASE WHEN type='close' THEN 1 ELSE 0 END) AS C,
    SUM(CASE WHEN type='error' THEN 1 ELSE 0 END) AS E
  FROM ad_events GROUP BY placement, provider
  ORDER BY placement, provider
`).all();

for (const x of conv) {
  const sr = x.L > 0 ? ((x.S * 100) / x.L).toFixed(0) + '%' : 'n/a';
  const cr = x.S > 0 ? ((x.C * 100) / x.S).toFixed(0) + '%' : 'n/a';
  const er = x.L > 0 ? ((x.E * 100) / x.L).toFixed(0) + '%' : 'n/a';
  console.log(`  ${x.placement.padEnd(24)} ${x.provider.padEnd(5)} L=${String(x.L).padStart(3)} S=${String(x.S).padStart(3)}(${sr}) R=${String(x.R).padStart(3)} C=${String(x.C).padStart(3)}(${cr}) E=${String(x.E).padStart(3)}(${er})`);
}

console.log('');
console.log('=== 错误明细 (按 errCode 分组) ===');
const errs = db.__db.prepare(`
  SELECT placement, provider, err_code AS errCode, err_msg AS errMsg, COUNT(*) AS n
  FROM ad_events
  WHERE type = 'error'
  GROUP BY placement, provider, err_code, err_msg
  ORDER BY n DESC
  LIMIT 30
`).all();

for (const x of errs) {
  const msg = (x.errMsg || '').replace(/\s+/g, ' ').substring(0, 80);
  console.log(`  [${x.n}x] ${x.placement}/${x.provider} code=${x.errCode}: ${msg}`);
}

console.log('');
console.log('=== 时间分布 (按 5 分钟分桶) ===');
const ts = db.__db.prepare(`
  SELECT MIN(ts) AS first, MAX(ts) AS last, COUNT(*) AS total FROM ad_events
`).get();
const startMs = ts.first;
const endMs = ts.last;
const durationMin = ((endMs - startMs) / 60000).toFixed(0);
console.log(`  首事件: ${new Date(ts.first).toLocaleTimeString('zh-CN')}`);
console.log(`  末事件: ${new Date(ts.last).toLocaleTimeString('zh-CN')}`);
console.log(`  总时长: ${durationMin} 分钟`);
console.log(`  总事件数: ${ts.total}`);
console.log(`  平均: ${(ts.total / durationMin).toFixed(1)} 事件/分钟`);

console.log('');
console.log('=== 关键比率 ===');
const total = conv.reduce((a, x) => ({
  L: a.L + x.L, S: a.S + x.S, R: a.R + x.R, C: a.C + x.C, E: a.E + x.E
}), { L: 0, S: 0, R: 0, C: 0, E: 0 });
console.log(`  总 load:  ${total.L}`);
console.log(`  总 show:  ${total.S}  (${((total.S * 100) / Math.max(1, total.L)).toFixed(0)}% load 转化为 show)`);
console.log(`  总 close: ${total.C}  (${((total.C * 100) / Math.max(1, total.S)).toFixed(0)}% show 完整 close)`);
console.log(`  总 reward:${total.R}  (${((total.R * 100) / Math.max(1, total.S)).toFixed(0)}% show 拿奖励)`);
console.log(`  总 error: ${total.E}  (${((total.E * 100) / Math.max(1, total.L)).toFixed(0)}% load 出错)`);
