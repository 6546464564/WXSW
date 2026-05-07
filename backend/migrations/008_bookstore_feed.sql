-- 008_bookstore_feed.sql
-- 万象书屋: iOS 书城 feed 数据 (M2.3.1)
--
-- 思路:
--   - admin 在管理面板逐条录入"书城推荐书"
--   - 按频道 (male/female/publish) + 板块 (banner/recommend/rank) 分类
--   - iOS App 通过 GET /api/bookstore/feed?channel=male&platform=ios 拉
--   - Android 端如果以后切书城代理, 同样能用
--
-- 字段:
--   channel       男生/女生/出版/漫画/有声 (free text, 当前只用 male/female/publish)
--   section       banner/recommend/rank/etc (任意值, 客户端按需展示)
--   name          书名
--   author        作者
--   cover_url     封面 URL
--   intro         简介
--   kind          分类
--   target_url    点击跳转的 URL (用户加书架时这个就是 bookUrl, 必须配合书源能打开)
--   source_origin 配套书源 URL (origin), 让客户端知道用哪个源解析此书 (可空)
--   priority      展示优先级 (越小越靠前)
--   enabled       是否上架
--   updated_at    时间戳
--
-- 用法 (admin):
--   - 添加: POST /api/admin/bookstore-feed
--   - 列表: GET  /api/admin/bookstore-feed
--   - 删除: DELETE /api/admin/bookstore-feed/:id
--   - 切换: PATCH /api/admin/bookstore-feed/:id (改 enabled / priority / section)

CREATE TABLE IF NOT EXISTS bookstore_feed (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    channel         TEXT NOT NULL,                    -- male/female/publish/manga/audio
    section         TEXT NOT NULL DEFAULT 'recommend',-- banner/recommend/rank/today
    name            TEXT NOT NULL,
    author          TEXT NOT NULL DEFAULT '',
    cover_url       TEXT,
    intro           TEXT,
    kind            TEXT,                             -- 分类
    target_url      TEXT NOT NULL,                    -- 点击 = SearchBook.bookUrl
    source_origin   TEXT,                             -- 配套源 (空 = 通用)
    priority        INTEGER NOT NULL DEFAULT 0,
    enabled         INTEGER NOT NULL DEFAULT 1,
    updated_at      INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_bookstore_feed_channel
  ON bookstore_feed(channel, enabled, priority);
CREATE INDEX IF NOT EXISTS idx_bookstore_feed_section
  ON bookstore_feed(channel, section, enabled, priority);
