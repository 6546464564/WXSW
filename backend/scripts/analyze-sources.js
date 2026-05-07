const db = require('../db');

console.log('=== 所有书源 (含 enabled 状态) ===\n');
const all = db.__db.prepare(`
  SELECT url, name, enabled, json_extract(json, '$.bookSourceGroup') AS groupRaw, updated_at
  FROM book_sources
  ORDER BY enabled DESC, name
`).all();

let enabledCount = 0, disabledCount = 0;
for (const s of all) {
  if (s.enabled) enabledCount++; else disabledCount++;
}
console.log(`总数: ${all.length}, 已启用: ${enabledCount}, 已禁用: ${disabledCount}\n`);

// 按"明显劣质特征"标记建议 disable
function isSuspicious(s) {
  const url = (s.url || '').toLowerCase();
  const name = (s.name || '').toLowerCase();
  const reasons = [];
  if (url.includes('zhihu.com')) reasons.push('zhihu 不是小说源');
  if (url.includes('baidu.com')) reasons.push('baidu 是搜索引擎不是小说源');
  if (url.includes('google.com')) reasons.push('google 不是小说源');
  if (url.includes('bing.com')) reasons.push('bing 是搜索引擎');
  if (url.includes('weibo.com')) reasons.push('weibo 不是小说源');
  if (url.includes('jianshu.com')) reasons.push('jianshu 不是小说源');
  if (url.includes('csdn.net')) reasons.push('csdn 不是小说源');
  if (url.includes('blog')) reasons.push('blog 不是结构化小说源');
  if (url.includes('wikipedia') || url.includes('wikiwand')) reasons.push('wiki 不是小说源');
  if (name === url || name.length < 2) reasons.push('名字异常 (可能解析失败)');
  return reasons;
}

console.log('=== 启用中的疑似劣质源 (建议 disable) ===\n');
const suspicious = [];
for (const s of all) {
  if (!s.enabled) continue;
  const reasons = isSuspicious(s);
  if (reasons.length) {
    suspicious.push(s);
    console.log(`  [启用] ${s.name?.padEnd(30) || '(无名)'} ${(s.url || '').substring(0, 60)}`);
    console.log(`         理由: ${reasons.join('; ')}\n`);
  }
}
if (suspicious.length === 0) console.log('  (无)');
console.log('');

console.log('=== 启用中的所有书源 (人工筛检参考) ===\n');
for (const s of all) {
  if (!s.enabled) continue;
  const flag = isSuspicious(s).length ? '⚠️' : '  ';
  console.log(`  ${flag} ${(s.name || '').padEnd(30)} ${(s.url || '').substring(0, 60)} [${s.groupRaw || '-'}]`);
}

console.log('');
console.log(`=== 建议 disable ${suspicious.length} 个 ===`);
for (const s of suspicious) console.log(`  ${s.url}`);
