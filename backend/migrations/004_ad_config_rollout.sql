-- 万象书屋: ad_config 灰度发布字段
-- staging_json: 灰度中的下一个版本 JSON
-- rollout_pct: 0-100, 多少比例的设备命中 staging (按 hash(device_id) % 100)
ALTER TABLE ad_config ADD COLUMN staging_json TEXT;
ALTER TABLE ad_config ADD COLUMN rollout_pct INTEGER NOT NULL DEFAULT 0;
