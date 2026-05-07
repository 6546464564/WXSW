// 一键 disable 已知劣质书源 (bing.com 搜索引擎 wrap + 规则不完整)
const db = require('../db');

// disable 的 url 清单 (从 analyze + find-zhihu-source 综合)
const TO_DISABLE = [
  // bing.com 搜索引擎 wrap, 搜冷门词会返回 zhihu/baidu 等乱码结果
  { url: 'https://min-yuan.com/', reason: 'bing.com 搜索引擎 wrap, 易污染搜索结果' },
  { url: 'https://www.min-yuan.com', reason: 'bing.com 搜索引擎 wrap + search 规则全空' },
  { url: 'https://www.min-yuan.com/', reason: 'bing.com 搜索引擎 wrap (重复源)' },
  { url: 'https://dingdianzww.org', reason: 'bing.com 搜索引擎 wrap' },
];

let okCount = 0, missCount = 0;
const stmtDisable = db.__db.prepare('UPDATE book_sources SET enabled = 0, updated_at = ? WHERE url = ?');
for (const item of TO_DISABLE) {
  const r = stmtDisable.run(Date.now(), item.url);
  if (r.changes > 0) {
    console.log(`  ✅ disabled: ${item.url}`);
    console.log(`     原因: ${item.reason}`);
    okCount++;
  } else {
    console.log(`  ⚠️  not found: ${item.url}`);
    missCount++;
  }
}

console.log(`\n汇总: 成功 disable ${okCount} 个, ${missCount} 个未找到`);

// 看现状
const enabled = db.__db.prepare('SELECT COUNT(*) AS n FROM book_sources WHERE enabled = 1').get().n;
const disabled = db.__db.prepare('SELECT COUNT(*) AS n FROM book_sources WHERE enabled = 0').get().n;
console.log(`当前: 启用 ${enabled}, 禁用 ${disabled}`);

// 让 sources 缓存失效, App 下次拉会拿到新的
console.log('\n书源已 disable, /api/sources 下次返回会少这些. App 端也会自动同步 (etag 变化)');
