// 万象书屋: 书籍正文内容缓存

let db;
let stmtGet, stmtGetBatch, stmtUpsert, stmtBumpHit, stmtCount, stmtSize, stmtCleanup,
    stmtListBooks, stmtGetChapterContent;

function init(database) {
  db = database;

  stmtGet = db.prepare(
    `SELECT content, chapter_title FROM book_content_cache
     WHERE book_title = ? AND book_author = ? AND chapter_index = ?`
  );

  stmtGetBatch = db.prepare(
    `SELECT chapter_index, chapter_title, content FROM book_content_cache
     WHERE book_title = ? AND book_author = ?
     ORDER BY chapter_index`
  );

  stmtUpsert = db.prepare(
    `INSERT INTO book_content_cache
       (book_title, book_author, chapter_index, chapter_title, content, content_length, hit_count, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?)
     ON CONFLICT(book_title, book_author, chapter_index) DO UPDATE SET
       content = CASE WHEN length(excluded.content) > length(book_content_cache.content) THEN excluded.content ELSE book_content_cache.content END,
       content_length = CASE WHEN length(excluded.content) > length(book_content_cache.content) THEN excluded.content_length ELSE book_content_cache.content_length END,
       chapter_title = CASE WHEN excluded.chapter_title != '' THEN excluded.chapter_title ELSE book_content_cache.chapter_title END,
       updated_at = excluded.updated_at`
  );

  stmtBumpHit = db.prepare(
    `UPDATE book_content_cache SET hit_count = hit_count + 1
     WHERE book_title = ? AND book_author = ? AND chapter_index = ?`
  );

  stmtCount = db.prepare('SELECT COUNT(*) AS cnt FROM book_content_cache');

  stmtSize = db.prepare(
    `SELECT COUNT(*) AS chapters, SUM(content_length) AS total_bytes,
            COUNT(DISTINCT book_title || '::' || book_author) AS books
     FROM book_content_cache`
  );

  stmtCleanup = db.prepare(
    `DELETE FROM book_content_cache WHERE id NOT IN (
       SELECT id FROM book_content_cache ORDER BY updated_at DESC LIMIT ?
     )`
  );

  stmtListBooks = db.prepare(
    `SELECT book_title, book_author,
            COUNT(*) AS chapter_count,
            SUM(content_length) AS total_bytes,
            SUM(hit_count) AS total_hits,
            MAX(updated_at) AS last_updated
     FROM book_content_cache
     GROUP BY book_title, book_author
     ORDER BY last_updated DESC
     LIMIT ?`
  );

  stmtGetChapterContent = db.prepare(
    `SELECT chapter_index, chapter_title, content, content_length, hit_count
     FROM book_content_cache
     WHERE book_title = ? AND book_author = ?
     ORDER BY chapter_index
     LIMIT ? OFFSET ?`
  );
}

function getContent(bookTitle, bookAuthor, chapterIndex) {
  const row = stmtGet.get(bookTitle, bookAuthor || '', chapterIndex);
  if (row) {
    stmtBumpHit.run(bookTitle, bookAuthor || '', chapterIndex);
  }
  return row || null;
}

function getBookChapters(bookTitle, bookAuthor) {
  return stmtGetBatch.all(bookTitle, bookAuthor || '');
}

function upsertContent(bookTitle, bookAuthor, chapterIndex, chapterTitle, content) {
  const title = (bookTitle || '').trim();
  if (!title || !content) return;
  const now = Date.now();
  stmtUpsert.run(
    title,
    (bookAuthor || '').trim(),
    chapterIndex,
    (chapterTitle || '').trim(),
    content,
    content.length,
    now, now
  );
}

function bulkUpsertContent(chapters) {
  const tx = db.transaction((items) => {
    let upserted = 0;
    for (const c of items) {
      try {
        upsertContent(c.book_title || c.bookTitle, c.book_author || c.bookAuthor,
                       c.chapter_index ?? c.chapterIndex, c.chapter_title || c.chapterTitle,
                       c.content);
        upserted++;
      } catch {}
    }
    return upserted;
  });
  return tx(chapters);
}

function stats() {
  return stmtSize.get();
}

function cleanup(keepCount = 500000) {
  return stmtCleanup.run(keepCount);
}

function listBooks(limit = 100) {
  return stmtListBooks.all(Math.min(limit, 500));
}

function getChapterContent(bookTitle, bookAuthor, limit = 50, offset = 0) {
  return stmtGetChapterContent.all(bookTitle, bookAuthor || '', limit, offset);
}

module.exports = {
  init, getContent, getBookChapters, upsertContent, bulkUpsertContent,
  stats, cleanup, listBooks, getChapterContent,
};
