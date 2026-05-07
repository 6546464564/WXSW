-- 万象书屋 schema baseline
-- 记录 v1 schema 已就绪. 实际表创建在 db.js init() 内的 IF NOT EXISTS,
-- 这个文件只是为了在已上线的库里建立 migrations 索引起点.
-- 新增表/字段从 002 开始用单独的迁移文件.

CREATE TABLE IF NOT EXISTS schema_migrations (
  filename   TEXT PRIMARY KEY,
  applied_at INTEGER NOT NULL,
  duration_ms INTEGER
);
