/**
 * 万象书屋 (2026-05-11): 把桌面那份 404 条 pruned-final 全量灌进 backend.
 *
 * 行为:
 *   1. 备份当前 book_sources 表到 book_sources_backup_<ts>
 *   2. 清空 book_sources
 *   3. bulkUpsert(404) — platforms 取 schema 默认 'android,ios', enabled=1
 *   4. invalidateSourcesCache() 让 /api/sources 立刻看到新数据
 *
 * 用法:
 *   node scripts/reseed-from-pruned.js [/path/to/pruned.json]
 *   默认读 /Users/stark/Desktop/bookSources-pruned-final.json
 */
const fs = require('fs');
const path = require('path');
const db = require('../db');
const rawDb = require('better-sqlite3');

const DEFAULT_JSON = '/Users/stark/Desktop/bookSources-pruned-final.json';
const jsonPath = process.argv[2] || DEFAULT_JSON;

if (!fs.existsSync(jsonPath)) {
  console.error('❌ pruned JSON 不存在:', jsonPath);
  process.exit(1);
}

const arr = JSON.parse(fs.readFileSync(jsonPath, 'utf8'));
if (!Array.isArray(arr) || arr.length === 0) {
  console.error('❌ JSON 不是非空数组');
  process.exit(1);
}

console.log(`[reseed] 读到 ${arr.length} 条源 from ${jsonPath}`);

// 直接拿 db 模块下的 better-sqlite3 实例
const DB_PATH = path.join(__dirname, '..', 'data', 'wanxiang.db');
const sqlite = rawDb(DB_PATH);

const before = sqlite.prepare('SELECT COUNT(*) AS n FROM book_sources').get().n;
console.log(`[reseed] 灌入前: ${before} 条源`);

// 备份
const ts = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
const backupTable = `book_sources_backup_${ts.replace(/[-T]/g, '')}`;
sqlite.exec(`CREATE TABLE ${backupTable} AS SELECT * FROM book_sources`);
console.log(`[reseed] 备份到表: ${backupTable}`);

// 清空
sqlite.exec('DELETE FROM book_sources');
console.log(`[reseed] 已清空 book_sources`);

// 灌入 (走 db 模块的 bulkUpsert, 自动处理 invalidate cache)
const r = db.bulkUpsert(arr);
const after = sqlite.prepare('SELECT COUNT(*) AS n FROM book_sources').get().n;
console.log(`[reseed] 灌入完成: created=${r.created} updated=${r.updated} total=${after}`);

// 校验 platforms — 应该全部 android,ios 默认
const platformStats = sqlite.prepare(`
  SELECT platforms, COUNT(*) AS n FROM book_sources GROUP BY platforms
`).all();
console.log(`[reseed] platforms 分布:`);
for (const row of platformStats) {
  console.log(`  ${row.platforms || '(NULL)'} → ${row.n}`);
}

sqlite.close();
console.log('[reseed] ✓ done');
