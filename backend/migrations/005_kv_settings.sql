-- 万象书屋: 通用 KV settings 表, 给跨进程持久化用 (breakerSuppressUntil 等运维状态)
-- 比新建多个专用表更轻
CREATE TABLE IF NOT EXISTS kv_settings (
  k          TEXT PRIMARY KEY,
  v          TEXT,
  updated_at INTEGER NOT NULL
);
