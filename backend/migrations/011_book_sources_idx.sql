-- 011_book_sources_idx.sql
-- 万象书屋 D-16 (BACKEND-2): book_sources 表 admin 列表查询走全表扫 + ORDER BY updated_at DESC.
-- 当前数据量 (<1000 条) 全表扫 < 5ms 不可见, 但运营拉到 1 万条以上时会显著慢.
-- 提前加索引, 防止后期出现"admin 面板第一屏卡顿"型隐患.

CREATE INDEX IF NOT EXISTS idx_book_sources_updated_at
  ON book_sources(updated_at DESC);

-- 万象书屋: 同时给 enabled 列加索引, /api/sources 公开接口高频查 enabled=1.
-- SQLite 对 LIKE 不走索引但对 WHERE enabled=1 会走.
CREATE INDEX IF NOT EXISTS idx_book_sources_enabled
  ON book_sources(enabled);
