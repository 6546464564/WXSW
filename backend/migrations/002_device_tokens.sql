-- 万象书屋: 设备 token 表 — 防 device_id 伪造
-- 注册时后端用 server secret HMAC 一个 token, App 后续接口必须带 token 才认.
-- 这样攻击者就算拿到别人的 device_id, 没 token 也调不了任何接口.
CREATE TABLE IF NOT EXISTS device_tokens (
  device_id    TEXT PRIMARY KEY,
  token_hash   TEXT NOT NULL,        -- HMAC-SHA256(SECRET, device_id || install_ts) 的 hex
  install_ts   INTEGER NOT NULL,     -- 设备首次注册时间戳
  last_seen_at INTEGER NOT NULL,
  ua           TEXT,                 -- 注册时的 UA, 用于风控关联
  ip           TEXT
);

CREATE INDEX IF NOT EXISTS idx_device_tokens_last_seen
  ON device_tokens(last_seen_at);
