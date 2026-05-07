-- 006_multi_platform.sql
-- 万象书屋: 让后端服务 Android + iOS 双端
-- 思路: 给现有相关表加 platform 列 (默认 'android' 兼容存量数据), 加索引,
--      新增 iap_receipts 存苹果票据.
-- 全部 ALTER TABLE 都是加列, 老 App 完全不受影响 (默认值兜底).

-- ---- 1. 设备表 ---- 
ALTER TABLE device_tokens ADD COLUMN platform TEXT NOT NULL DEFAULT 'android';

-- ---- 2. 广告事件 ----
ALTER TABLE ad_events ADD COLUMN platform TEXT NOT NULL DEFAULT 'android';
CREATE INDEX IF NOT EXISTS idx_ad_events_platform_ts
  ON ad_events(platform, ts);

-- ---- 3. 崩溃 ----
ALTER TABLE crashes ADD COLUMN platform TEXT NOT NULL DEFAULT 'android';
CREATE INDEX IF NOT EXISTS idx_crashes_platform_ts
  ON crashes(platform, ts);

-- ---- 4. 反馈 ----
ALTER TABLE feedback ADD COLUMN platform TEXT NOT NULL DEFAULT 'android';
CREATE INDEX IF NOT EXISTS idx_feedback_platform_ts
  ON feedback(platform, ts);

-- ---- 5. 苹果 IAP 票据 ----
-- 用户内购验票后存这, 防止重放; 续订订阅时续期 expires_at; admin 可查每个用户的 entitlement 状态.
CREATE TABLE IF NOT EXISTS iap_receipts (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  device_id       TEXT NOT NULL,
  product_id      TEXT NOT NULL,            -- 苹果后台配的 SKU 比如 com.wanxiang.adfree.lifetime
  transaction_id  TEXT NOT NULL,            -- 苹果 transaction id, 唯一
  original_tx_id  TEXT,                     -- 原始 tx (订阅续订时和首次相同)
  receipt_data    TEXT NOT NULL,            -- 苹果原始 receipt-data (base64)
  expires_at      INTEGER,                  -- 订阅过期时间戳 (一次性购买为 NULL)
  verified_at     INTEGER NOT NULL,
  sandbox         INTEGER NOT NULL DEFAULT 0,
  status          TEXT NOT NULL DEFAULT 'active',  -- active / expired / refunded / revoked
  raw_response    TEXT,                     -- 苹果完整响应 json, 排查用
  UNIQUE(transaction_id)
);
CREATE INDEX IF NOT EXISTS idx_iap_receipts_device
  ON iap_receipts(device_id, expires_at);
CREATE INDEX IF NOT EXISTS idx_iap_receipts_product_status
  ON iap_receipts(product_id, status);

-- ---- 6. 广告配置: 复用现有 ad_config + ad_config_history, 不分表
-- 万象书屋: 思考过加 platform 列, 但带来 staging/rollout 状态机的复杂性.
-- 当前设计: 一份 ad_config 通用; 客户端按 placement 内的 providers 过滤即可
-- (ios 端不放 csj_ios 而放 csj 等同名 key, AdRepository 在客户端按平台 SDK 可用性决定使用哪个).
-- 真要 iOS 完全独立, 后续加 ad_config_ios 表; 此次不引入.
