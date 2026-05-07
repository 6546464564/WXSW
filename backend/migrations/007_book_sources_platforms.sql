-- 007_book_sources_platforms.sql
-- 万象书屋: 让 /api/sources 支持按平台过滤,使 iOS 端能拉到精选审核过的子集
--
-- 思路:
--   - 给 book_sources 加 platforms TEXT 列, 默认 'android,ios' 让历史源对所有平台可见
--   - 服务端 listEnabledSourcesJson(platform) 用 LIKE '%<platform>%' 过滤
--   - admin 面板可批量勾选每个源的可见平台
--
-- 为什么不用 join 表:
--   - 当前平台只有 android/ios/web 三个枚举, CSV 字符串够用且查询简单
--   - 上规模 (>10 平台) 时再迁 join 表
--
-- 兼容性:
--   - 老 Android 客户端不发 X-Platform → 服务端默认 android, 会匹配 'android,ios' → 命中
--   - 新 iOS 客户端发 X-Platform: ios → 匹配 'android,ios' → 命中
--   - admin 显式取消某源的 ios → 该源 platforms='android', iOS 不再拉到

ALTER TABLE book_sources ADD COLUMN platforms TEXT NOT NULL DEFAULT 'android,ios';

-- 加索引让 platform 过滤更快 (虽然 LIKE 不走索引, 但 platforms 列上的统计排序会用)
CREATE INDEX IF NOT EXISTS idx_book_sources_platforms ON book_sources(platforms);
