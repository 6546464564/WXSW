// 万象书屋: 从现有 bookstore_mirror 提取热门书元数据灌入 book_metadata 缓存表
//
// 用法:
//   node jobs/seedMetadata.js            # 从 DB 中最新 mirror 提取
//   node jobs/seedMetadata.js --fetch    # 先抓一次起点再提取
//
// 设计: 不引入新依赖, 复用 qidianMirror.parseBook 的 schema

const path = require('path');

const DB_PATH = process.env.DB_PATH || path.join(__dirname, '..', 'data', 'wanxiang.db');
const Database = require('better-sqlite3');
const db = new Database(DB_PATH);
db.pragma('journal_mode = WAL');
db.pragma('busy_timeout = 5000');

const bookMetadataModel = require('../models/bookMetadata');
bookMetadataModel.init(db);

// 确保 migration 已跑 (book_metadata 表存在)
const fs = require('fs');
const migFile = path.join(__dirname, '..', 'migrations', '017_book_metadata.sql');
if (fs.existsSync(migFile)) {
  db.exec(`CREATE TABLE IF NOT EXISTS schema_migrations (
    filename TEXT PRIMARY KEY, applied_at INTEGER NOT NULL, duration_ms INTEGER
  )`);
  const exists = db.prepare('SELECT 1 FROM schema_migrations WHERE filename = ?').get('017_book_metadata.sql');
  if (!exists) {
    const sql = fs.readFileSync(migFile, 'utf8');
    db.exec(sql);
    db.prepare('INSERT INTO schema_migrations (filename, applied_at, duration_ms) VALUES (?, ?, ?)').run('017_book_metadata.sql', Date.now(), 0);
    console.log('[seed] applied migration 017_book_metadata.sql');
  }
}

function extractFromMirror() {
  const row = db.prepare(
    'SELECT payload FROM bookstore_mirror WHERE ok = 1 ORDER BY id DESC LIMIT 1'
  ).get();
  if (!row) {
    console.log('[seed] no mirror data found, skip');
    return [];
  }
  const payload = JSON.parse(row.payload);
  const books = [];
  const seen = new Set();

  function push(b) {
    if (!b || !b.name) return;
    const key = `${b.name}::${b.author || ''}`;
    if (seen.has(key)) return;
    seen.add(key);
    books.push({
      title: b.name,
      author: b.author || '',
      cover_url: b.coverUrl || '',
      intro: b.intro || '',
      category: b.cat || b.subCat || '',
      word_count: b.wordCount || '',
    });
  }

  // 男频 9 榜
  if (payload.ranks) {
    for (const arr of Object.values(payload.ranks)) {
      if (Array.isArray(arr)) arr.forEach(push);
    }
  }
  // 女频 9 榜
  if (payload.ranksFemale) {
    for (const arr of Object.values(payload.ranksFemale)) {
      if (Array.isArray(arr)) arr.forEach(push);
    }
  }
  // 月票 TOP50
  if (Array.isArray(payload.yuepiaoTop50)) payload.yuepiaoTop50.forEach(push);
  if (Array.isArray(payload.yuepiaoTop50Female)) payload.yuepiaoTop50Female.forEach(push);
  // 完结
  if (payload.finish) {
    for (const arr of Object.values(payload.finish)) {
      if (Array.isArray(arr)) arr.forEach(push);
    }
  }
  // 出版
  if (payload.ranksPublish) {
    for (const arr of Object.values(payload.ranksPublish)) {
      if (Array.isArray(arr)) arr.forEach(push);
    }
  }
  if (Array.isArray(payload.yuepiaoTop50Publish)) payload.yuepiaoTop50Publish.forEach(push);

  return books;
}

async function main() {
  const doFetch = process.argv.includes('--fetch');
  if (doFetch) {
    console.log('[seed] fetching fresh mirror from m.qidian.com...');
    const bookstoreFeedModel = require('../models/bookstoreFeed');
    bookstoreFeedModel.init(db);
    const qidianMirror = require('./qidianMirror');
    try {
      const result = await qidianMirror.fetchAndCache({
        insertBookstoreMirror: bookstoreFeedModel.insertBookstoreMirror,
        cleanupOldBookstoreMirror: bookstoreFeedModel.cleanupOldBookstoreMirror,
      });
      console.log(`[seed] mirror fetched: ${result.totalBooks} books, etag=${result.etag}`);
    } catch (e) {
      console.error('[seed] mirror fetch failed:', e.message);
      console.log('[seed] falling back to existing mirror data');
    }
  }

  const books = extractFromMirror();
  if (books.length === 0) {
    console.log('[seed] no books to seed');
    process.exit(0);
  }

  console.log(`[seed] extracted ${books.length} unique books from mirror`);
  const upserted = bookMetadataModel.bulkUpsertMetadata(books);
  console.log(`[seed] upserted ${upserted} rows into book_metadata`);
  const total = bookMetadataModel.totalCount();
  console.log(`[seed] total book_metadata rows: ${total}`);
}

main().catch(e => { console.error(e); process.exit(1); });
