// 万象书屋: 书籍元数据缓存 (Cache-on-Search)

let db;
let stmtSearch, stmtUpsert, stmtBumpCount, stmtTopHot, stmtCount;

function init(database) {
  db = database;

  stmtSearch = db.prepare(
    `SELECT id, title, author, cover_url, intro, category, word_count, last_chapter, search_count
     FROM book_metadata
     WHERE title LIKE ?
     ORDER BY search_count DESC
     LIMIT ?`
  );

  stmtUpsert = db.prepare(
    `INSERT INTO book_metadata (title, author, cover_url, intro, category, word_count, last_chapter, search_count, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
     ON CONFLICT(title, author) DO UPDATE SET
       cover_url   = CASE WHEN excluded.cover_url   IS NOT NULL AND excluded.cover_url   != '' THEN excluded.cover_url   ELSE book_metadata.cover_url   END,
       intro       = CASE WHEN excluded.intro       IS NOT NULL AND length(excluded.intro) > length(COALESCE(book_metadata.intro, '')) THEN excluded.intro ELSE book_metadata.intro END,
       category    = CASE WHEN excluded.category    IS NOT NULL AND excluded.category    != '' THEN excluded.category    ELSE book_metadata.category    END,
       word_count  = CASE WHEN excluded.word_count  IS NOT NULL AND excluded.word_count  != '' THEN excluded.word_count  ELSE book_metadata.word_count  END,
       last_chapter= CASE WHEN excluded.last_chapter IS NOT NULL AND excluded.last_chapter != '' THEN excluded.last_chapter ELSE book_metadata.last_chapter END,
       search_count= book_metadata.search_count + 1,
       updated_at  = excluded.updated_at`
  );

  stmtBumpCount = db.prepare(
    `UPDATE book_metadata SET search_count = search_count + 1, updated_at = ? WHERE title = ? AND author = ?`
  );

  stmtTopHot = db.prepare(
    `SELECT id, title, author, cover_url, intro, category, word_count, last_chapter, search_count
     FROM book_metadata
     ORDER BY search_count DESC
     LIMIT ?`
  );

  stmtCount = db.prepare('SELECT COUNT(*) AS cnt FROM book_metadata');
}

function searchCache(keyword, limit = 20) {
  return stmtSearch.all(`%${keyword}%`, Math.min(limit, 100));
}

function upsertMetadata(book) {
  const title = (book.title || '').trim();
  if (!title) return;
  const author = (book.author || '').trim();
  const now = Date.now();
  stmtUpsert.run(
    title, author,
    book.cover_url || book.coverUrl || null,
    book.intro || null,
    book.category || book.cat || null,
    book.word_count || book.wordCount || null,
    book.last_chapter || book.lastChapter || null,
    now, now
  );
}

function bulkUpsertMetadata(books) {
  const tx = db.transaction((items) => {
    let upserted = 0;
    for (const b of items) {
      try { upsertMetadata(b); upserted++; } catch {}
    }
    return upserted;
  });
  return tx(books);
}

function topHot(limit = 50) {
  return stmtTopHot.all(Math.min(limit, 200));
}

function totalCount() {
  return stmtCount.get().cnt;
}

module.exports = {
  init, searchCache, upsertMetadata, bulkUpsertMetadata, topHot, totalCount,
};
