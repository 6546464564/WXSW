-- 万象书屋: 书籍正文内容缓存
-- 用户阅读时上报; 其他用户读同书时命中缓存

CREATE TABLE IF NOT EXISTS book_content_cache (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    book_title TEXT NOT NULL,
    book_author TEXT NOT NULL DEFAULT '',
    chapter_index INTEGER NOT NULL,
    chapter_title TEXT NOT NULL DEFAULT '',
    content TEXT NOT NULL,
    content_length INTEGER NOT NULL DEFAULT 0,
    hit_count INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_content_cache_book_chapter
    ON book_content_cache(book_title, book_author, chapter_index);
CREATE INDEX IF NOT EXISTS idx_content_cache_book
    ON book_content_cache(book_title, book_author);
