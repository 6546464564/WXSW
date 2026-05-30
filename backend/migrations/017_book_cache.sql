-- 017_book_cache.sql
-- 书籍内容缓存系统: 存储通过书源下载的章节内容, 供 App 离线阅读.
--
-- cached_books:  书籍元数据 + 下载状态
-- cached_chapters: 各章节正文内容

CREATE TABLE IF NOT EXISTS cached_books (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    qidian_id       TEXT,
    title           TEXT NOT NULL,
    author          TEXT NOT NULL DEFAULT '',
    category        TEXT NOT NULL DEFAULT '',
    cover_url       TEXT,
    intro           TEXT,
    source_url      TEXT,
    source_book_url TEXT,
    total_chapters  INTEGER NOT NULL DEFAULT 0,
    cached_chapters INTEGER NOT NULL DEFAULT 0,
    status          TEXT NOT NULL DEFAULT 'pending',
    error_msg       TEXT,
    priority        INTEGER NOT NULL DEFAULT 0,
    created_at      INTEGER NOT NULL,
    updated_at      INTEGER NOT NULL,
    UNIQUE(qidian_id)
);

CREATE INDEX IF NOT EXISTS idx_cached_books_status ON cached_books(status);
CREATE INDEX IF NOT EXISTS idx_cached_books_title ON cached_books(title);

CREATE TABLE IF NOT EXISTS cached_chapters (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    book_id         INTEGER NOT NULL REFERENCES cached_books(id) ON DELETE CASCADE,
    chapter_idx     INTEGER NOT NULL,
    title           TEXT NOT NULL DEFAULT '',
    content         TEXT,
    word_count      INTEGER NOT NULL DEFAULT 0,
    source_url      TEXT,
    status          TEXT NOT NULL DEFAULT 'pending',
    created_at      INTEGER NOT NULL,
    UNIQUE(book_id, chapter_idx)
);

CREATE INDEX IF NOT EXISTS idx_cached_chapters_book ON cached_chapters(book_id, chapter_idx);
CREATE INDEX IF NOT EXISTS idx_cached_chapters_status ON cached_chapters(status);
