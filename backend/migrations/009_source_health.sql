-- 万象书屋: 书源健康度 / iOS 解析器反馈
-- 目标:
--   1. iOS/Android 各自统计 search/info/toc/content 阶段是否可用
--   2. App 端可上报真实用户解析失败
--   3. 后台可一键静态检查规则完整性

CREATE TABLE IF NOT EXISTS source_health (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  source_url      TEXT NOT NULL,
  platform        TEXT NOT NULL DEFAULT 'ios',
  stage           TEXT NOT NULL,             -- search / info / toc / content / static
  sample_keyword  TEXT NOT NULL DEFAULT '',
  status          TEXT NOT NULL,             -- ok / zero / error / timeout / skip
  error_message   TEXT,
  success_count   INTEGER NOT NULL DEFAULT 0,
  fail_count      INTEGER NOT NULL DEFAULT 0,
  last_checked_at INTEGER NOT NULL,
  last_ok_at      INTEGER,
  last_error_at   INTEGER,
  app_ver         TEXT,
  UNIQUE(source_url, platform, stage, sample_keyword)
);

CREATE INDEX IF NOT EXISTS idx_source_health_platform_stage
  ON source_health(platform, stage, status, last_checked_at);

CREATE INDEX IF NOT EXISTS idx_source_health_source
  ON source_health(source_url, platform);

CREATE TABLE IF NOT EXISTS source_error_events (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  ts             INTEGER NOT NULL,
  source_url     TEXT NOT NULL,
  source_name    TEXT,
  platform       TEXT NOT NULL DEFAULT 'ios',
  stage          TEXT NOT NULL,
  status         TEXT NOT NULL DEFAULT 'error',
  error_message  TEXT,
  sample_keyword TEXT,
  sample_url     TEXT,
  app_ver        TEXT,
  device_id      TEXT,
  ip             TEXT
);

CREATE INDEX IF NOT EXISTS idx_source_error_events_ts
  ON source_error_events(ts);

CREATE INDEX IF NOT EXISTS idx_source_error_events_source
  ON source_error_events(source_url, platform, stage, ts);
