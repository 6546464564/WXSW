-- 018_cleanup_sources.sql
-- 只保留万象书屋和速读谷书源，删除其他所有书源

DELETE FROM book_sources WHERE name NOT IN ('万象书屋', '速读谷');
DELETE FROM book_sources WHERE url = 'https://www.sudugu.org/';
