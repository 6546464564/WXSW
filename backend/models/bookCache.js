// 万象书屋: 书籍内容缓存 model
// 管理 cached_books + cached_chapters 两张表的 CRUD

let db;
let stmts = {};

function init(database) {
  db = database;

  stmts.insertBook = db.prepare(`
    INSERT OR IGNORE INTO cached_books
      (qidian_id, title, author, category, cover_url, priority, status, created_at, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?)
  `);

  stmts.getBookById = db.prepare('SELECT * FROM cached_books WHERE id = ?');
  stmts.getBookByQidianId = db.prepare('SELECT * FROM cached_books WHERE qidian_id = ?');
  stmts.getBookByTitle = db.prepare('SELECT * FROM cached_books WHERE title = ? LIMIT 1');

  stmts.listBooks = db.prepare(`
    SELECT id, qidian_id, title, author, category, cover_url, source_url,
           total_chapters, cached_chapters, status, error_msg, priority, created_at, updated_at
    FROM cached_books ORDER BY cached_chapters DESC, id ASC
  `);

  stmts.listBooksByStatus = db.prepare(`
    SELECT id, qidian_id, title, author, category, cover_url, source_url,
           total_chapters, cached_chapters, status, error_msg, priority, created_at, updated_at
    FROM cached_books WHERE status = ? ORDER BY cached_chapters DESC, id ASC
  `);

  stmts.nextPendingBook = db.prepare(`
    SELECT * FROM cached_books WHERE status = 'pending'
    ORDER BY priority DESC, id ASC LIMIT 1
  `);

  stmts.updateBookSource = db.prepare(`
    UPDATE cached_books SET source_url = ?, source_book_url = ?, cover_url = COALESCE(?, cover_url),
           intro = COALESCE(?, intro), updated_at = ? WHERE id = ?
  `);

  stmts.updateBookStatus = db.prepare(`
    UPDATE cached_books SET status = ?, error_msg = ?, updated_at = ? WHERE id = ?
  `);

  stmts.updateBookChapterCount = db.prepare(`
    UPDATE cached_books SET total_chapters = ?, updated_at = ? WHERE id = ?
  `);

  stmts.updateBookCachedCount = db.prepare(`
    UPDATE cached_books SET cached_chapters = (
      SELECT COUNT(*) FROM cached_chapters WHERE book_id = ? AND status = 'done'
    ), updated_at = ? WHERE id = ?
  `);

  stmts.insertChapter = db.prepare(`
    INSERT OR IGNORE INTO cached_chapters
      (book_id, chapter_idx, title, source_url, status, created_at)
    VALUES (?, ?, ?, ?, 'pending', ?)
  `);

  stmts.updateChapterContent = db.prepare(`
    UPDATE cached_chapters SET content = ?, word_count = ?, status = 'done' WHERE book_id = ? AND chapter_idx = ?
  `);

  stmts.updateChapterError = db.prepare(`
    UPDATE cached_chapters SET status = 'error' WHERE book_id = ? AND chapter_idx = ?
  `);

  stmts.getChapter = db.prepare(`
    SELECT * FROM cached_chapters WHERE book_id = ? AND chapter_idx = ?
  `);

  stmts.listChapters = db.prepare(`
    SELECT id, book_id, chapter_idx, title, word_count, source_url, status
    FROM cached_chapters WHERE book_id = ? ORDER BY chapter_idx ASC
  `);

  stmts.getChapterContent = db.prepare(`
    SELECT content FROM cached_chapters WHERE book_id = ? AND chapter_idx = ?
  `);

  stmts.pendingChapters = db.prepare(`
    SELECT * FROM cached_chapters WHERE book_id = ? AND status = 'pending'
    ORDER BY chapter_idx ASC LIMIT ?
  `);

  stmts.bookStats = db.prepare(`
    SELECT status, COUNT(*) as count FROM cached_books GROUP BY status
  `);

  stmts.totalStats = db.prepare(`
    SELECT
      (SELECT COUNT(*) FROM cached_books) as total_books,
      (SELECT COUNT(*) FROM cached_books WHERE status = 'done') as done_books,
      (SELECT COUNT(*) FROM cached_books WHERE status = 'downloading') as downloading_books,
      (SELECT COUNT(*) FROM cached_books WHERE status = 'pending') as pending_books,
      (SELECT COUNT(*) FROM cached_books WHERE status = 'error') as error_books,
      (SELECT COUNT(*) FROM cached_chapters WHERE status = 'done') as total_cached_chapters,
      (SELECT SUM(word_count) FROM cached_chapters WHERE status = 'done') as total_words
  `);
}

function insertBook({ qidianId, title, author, category, coverUrl, priority = 0 }) {
  const now = Date.now();
  const cover = coverUrl || `https://bookcover.yuewen.com/qdbimg/349573/${qidianId}/180`;
  return stmts.insertBook.run(qidianId, title, author, category, cover, priority, now, now);
}

const bulkInsertBooks = (books) => {
  const tx = db.transaction((list) => {
    let inserted = 0;
    for (const b of list) {
      const r = insertBook(b);
      if (r.changes > 0) inserted++;
    }
    return inserted;
  });
  return tx(books);
};

function searchBooks(keyword, limit = 20) {
  const like = `%${keyword}%`;
  return db.prepare(`
    SELECT id, qidian_id, title, author, category, cover_url, intro,
           total_chapters, cached_chapters, status
    FROM cached_books WHERE status = 'done' AND (title LIKE ? OR author LIKE ?)
    ORDER BY
      CASE WHEN title = ? THEN 0 WHEN title LIKE ? THEN 1 ELSE 2 END,
      priority DESC, cached_chapters DESC
    LIMIT ?
  `).all(like, like, keyword, keyword + '%', limit);
}

function getBook(id) { return stmts.getBookById.get(id); }
function getBookByQidianId(qid) { return stmts.getBookByQidianId.get(qid); }
function getBookByTitle(title) { return stmts.getBookByTitle.get(title); }
function listBooks(status) {
  return status ? stmts.listBooksByStatus.all(status) : stmts.listBooks.all();
}
function nextPendingBook() { return stmts.nextPendingBook.get() || null; }

function updateBookSource(id, { sourceUrl, sourceBookUrl, coverUrl, intro }) {
  stmts.updateBookSource.run(sourceUrl, sourceBookUrl, coverUrl || null, intro || null, Date.now(), id);
}

function updateBookStatus(id, status, errorMsg = null) {
  stmts.updateBookStatus.run(status, errorMsg, Date.now(), id);
}

function updateBookChapterCount(id, total) {
  stmts.updateBookChapterCount.run(total, Date.now(), id);
}

function refreshBookCachedCount(id) {
  stmts.updateBookCachedCount.run(id, Date.now(), id);
}

function insertChapters(bookId, chapters) {
  const now = Date.now();
  const tx = db.transaction((list) => {
    let inserted = 0;
    for (const ch of list) {
      const r = stmts.insertChapter.run(bookId, ch.idx, ch.title, ch.url || null, now);
      if (r.changes > 0) inserted++;
    }
    return inserted;
  });
  return tx(chapters);
}

function saveChapterContent(bookId, chapterIdx, content) {
  const wordCount = content ? content.replace(/\s/g, '').length : 0;
  stmts.updateChapterContent.run(content, wordCount, bookId, chapterIdx);
}

function markChapterError(bookId, chapterIdx) {
  stmts.updateChapterError.run(bookId, chapterIdx);
}

function getChapter(bookId, chapterIdx) { return stmts.getChapter.get(bookId, chapterIdx); }
function getChapterContent(bookId, chapterIdx) { return stmts.getChapterContent.get(bookId, chapterIdx); }
function listChapters(bookId) { return stmts.listChapters.all(bookId); }
function pendingChapters(bookId, limit = 10) { return stmts.pendingChapters.all(bookId, limit); }
function getCacheStats() { return stmts.totalStats.get(); }

module.exports = {
  init,
  insertBook, bulkInsertBooks,
  searchBooks, getBook, getBookByQidianId, getBookByTitle,
  listBooks, nextPendingBook,
  updateBookSource, updateBookStatus,
  updateBookChapterCount, refreshBookCachedCount,
  insertChapters, saveChapterContent, markChapterError,
  getChapter, getChapterContent, listChapters, pendingChapters,
  getCacheStats,
};
