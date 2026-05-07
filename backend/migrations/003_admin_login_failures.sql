-- 万象书屋: admin 登录失败记录, 用于按 username 锁定 (区别于 IP 限流)
-- IP 限流防机器, username 锁定防慢速密码爆破 (即使换 IP 也限).
CREATE TABLE IF NOT EXISTS admin_login_failures (
  id        INTEGER PRIMARY KEY AUTOINCREMENT,
  username  TEXT NOT NULL,
  ip        TEXT,
  ts        INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_login_fail_user_ts
  ON admin_login_failures(username, ts);
