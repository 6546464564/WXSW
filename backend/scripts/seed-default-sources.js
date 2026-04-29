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

const defaultJson = path.join(
  __dirname,
  '..',
  '..',
  'app',
  'src',
  'main',
  'assets',
  'defaultData',
  'bookSources.json'
);
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
