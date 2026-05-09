/**
 * 将 App 工程内置 defaultData/bookSources.json 批量写入后端 SQLite，
 * 便于管理后台立刻能看到与客户端一致的默认书源。
 *
 * 用法（在 backend 目录）:
 *   npm run seed
 * 或指定文件:
 *   set BOOK_SOURCES_JSON=C:\path\to\bookSources.json && npm run seed
 */
const fs = require('fs');
const path = require('path');
const db = require('../db');

// 万象书屋: 默认按优先级查找 bookSources.json, 都允许 BOOK_SOURCES_JSON 覆盖.
//   1) backend/seed/bookSources.json  ← 后端独立维护的种子 (推荐生产)
//   2) android/app/src/main/assets/defaultData/bookSources.json  ← App 内置 (此前路径少了 android/ 一层)
//   3) app/src/main/assets/...        ← 老布局兼容
// 优先选**存在且非空数组**的, 避开历史上的空 [] 占位文件.
const candidates = [
  path.join(__dirname, '..', 'seed', 'bookSources.json'),
  path.join(__dirname, '..', '..', 'android', 'app', 'src', 'main', 'assets', 'defaultData', 'bookSources.json'),
  path.join(__dirname, '..', '..', 'app', 'src', 'main', 'assets', 'defaultData', 'bookSources.json'),
];
function isUsable(p) {
  if (!fs.existsSync(p)) return false;
  try {
    const a = JSON.parse(fs.readFileSync(p, 'utf8'));
    return Array.isArray(a) && a.length > 0;
  } catch { return false; }
}
const defaultJson = candidates.find(isUsable) || candidates[0];
const jsonPath = process.env.BOOK_SOURCES_JSON || defaultJson;

if (!fs.existsSync(jsonPath)) {
  console.error('[seed] file not found:', jsonPath);
  process.exit(1);
}

const raw = fs.readFileSync(jsonPath, 'utf8');
const arr = JSON.parse(raw);
if (!Array.isArray(arr)) {
  console.error('[seed] JSON root must be an array');
  process.exit(1);
}

const r = db.bulkUpsert(arr);
console.log('[seed] ok:', jsonPath);
console.log('[seed] inserted:', r.created, 'updated:', r.updated, 'total:', arr.length);
