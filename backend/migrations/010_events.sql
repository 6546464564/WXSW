-- 万象书屋: 自建埋点 events 表
-- 设计目标: 替代友盟/神策, 用最少表结构存所有"用户行为日志".
--
-- 一条事件的语义:
--   "[device_id] 在 [platform] 上, 客户端时间 [client_ts] 触发了 [event_name] 事件"
--
-- event_type 大类约定:
--   pv         = 页面浏览 (page view), event_name 是页面 ID, params 含 stay_ms 离开时段
--   click      = 用户点击, event_name 是控件标识, 比如 btn_search / item_book
--   custom     = 业务自定义事件, 比如 read_chapter_done / source_change
--
-- 索引设计:
--   - (ts) 时间倒序查最近事件 / 删除老数据
--   - (device_id, ts) 单设备行为路径
--   - (event_name, ts) 单事件聚合 (比如统计某按钮一天点了多少次)
--
-- 数据保留策略: 后端定时清理超过 90 天的, 防止表无限膨胀.
CREATE TABLE IF NOT EXISTS events (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  ts          INTEGER NOT NULL,        -- 服务端接收时间 (ms since epoch)
  client_ts   INTEGER,                 -- 客户端事件发生时间 (ms),用于跨设备时序对齐
  device_id   TEXT NOT NULL,
  platform    TEXT,                    -- android / ios / web
  app_ver     TEXT,
  event_type  TEXT NOT NULL,           -- pv / click / custom
  event_name  TEXT NOT NULL,           -- 例: page_main / btn_search / read_chapter_done
  params      TEXT,                    -- JSON 字符串, 自定义参数 (可空)
  session_id  TEXT,                    -- 客户端生成的会话 ID, 同一会话内复用
  ip          TEXT
);
CREATE INDEX IF NOT EXISTS idx_events_ts          ON events(ts);
CREATE INDEX IF NOT EXISTS idx_events_device_ts   ON events(device_id, ts);
CREATE INDEX IF NOT EXISTS idx_events_name_ts     ON events(event_name, ts);
