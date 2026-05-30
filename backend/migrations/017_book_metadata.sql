-- 万象书屋: 书籍元数据缓存 (Cache-on-Search)
-- 用户搜索时自动积累; 种子脚本可批量灌入热门书

CREATE TABLE IF NOT EXISTS book_metadata (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    title TEXT NOT NULL,
    author TEXT NOT NULL DEFAULT '',
    cover_url TEXT,
    intro TEXT,
    category TEXT,
    word_count TEXT,
    last_chapter TEXT,
    search_count INTEGER NOT NULL DEFAULT 1,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_book_metadata_title_author
    ON book_metadata(title, author);
CREATE INDEX IF NOT EXISTS idx_book_metadata_title
    ON book_metadata(title);
CREATE INDEX IF NOT EXISTS idx_book_metadata_search_count
    ON book_metadata(search_count DESC);
