-- 016_drop_bookstore_feed.sql
-- 移除书城 Feed 手工推荐功能，书城统一走 Mirror.

DROP TABLE IF EXISTS bookstore_feed;
