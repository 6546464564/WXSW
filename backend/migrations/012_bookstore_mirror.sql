-- 012_bookstore_mirror.sql
-- 万象书屋 D-23 (2026-05-08): 书城 m.qidian.com mirror cache.
--
-- 思路:
--   - 后端定时 (每天 0:00-7:00 随机一次) 抓 m.qidian.com 三个 endpoint
--   - 整理成统一 JSON payload 存到这张表
--   - App 改成请求 /api/bookstore/mirror 拿 payload (走 ETag 304 节流)
--   - App 端原直抓 m.qidian 的代码保留为 fallback (后端挂了 / 没 cache 时降级)
--
-- 字段:
--   version     抓取时间戳 (ms), 用于 App 判断是否拉到新版本
--   payload     完整 JSON (~50KB raw, ~15KB gzip), 含 9 榜 / yuepiao 50 / finish 4 榜
--   etag        md5 hash, 客户端 If-None-Match 用
--   fetched_at  抓取时间 (ms)
--   source      数据来源标识 ("m.qidian.com" / "manual_upload" / "fallback")
--   ok          1 = 抓取成功, 0 = 部分失败但有旧数据可用
--   err_msg     失败时的错误消息 (供 admin 面板显示)
--   overrides_json admin 在面板上添加的覆盖规则 (置顶/屏蔽/改字段), 默认 NULL
--
-- 表只保留最近 24 条 (1 周历史): cron job 每次插入后 DELETE 老的, 防表膨胀.

CREATE TABLE IF NOT EXISTS bookstore_mirror (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    version         INTEGER NOT NULL,
    payload         TEXT NOT NULL,
    etag            TEXT NOT NULL,
    fetched_at      INTEGER NOT NULL,
    source          TEXT NOT NULL DEFAULT 'm.qidian.com',
    ok              INTEGER NOT NULL DEFAULT 1,
    err_msg         TEXT,
    overrides_json  TEXT
);

-- App 客户端读"最新可用 cache"的高频查询: WHERE ok=1 ORDER BY id DESC LIMIT 1
CREATE INDEX IF NOT EXISTS idx_mirror_ok_id ON bookstore_mirror(ok, id DESC);

-- admin 面板显示历史抓取记录的查询: ORDER BY fetched_at DESC LIMIT 24
CREATE INDEX IF NOT EXISTS idx_mirror_fetched_at ON bookstore_mirror(fetched_at DESC);
