#!/usr/bin/env node
/**
 * 万象书屋: 重置管理员密码 (忘密/紧急情况用).
 *
 * 用法:
 *   node backend/scripts/reset-admin-password.js <new_password>
 *   或设置环境变量:
 *   ADMIN_RESET_PASSWORD=xxxxxx node backend/scripts/reset-admin-password.js
 *
 * 安全: 只能在后端机器本地运行. 需要 SQLite 文件的写权限.
 */

const path = require('path');
const Database = require('better-sqlite3');
const bcrypt = require('bcryptjs');

const DB_PATH = process.env.DB_PATH || path.join(__dirname, '..', 'data', 'wanxiang.db');

const pwd = process.argv[2] || process.env.ADMIN_RESET_PASSWORD;
if (!pwd) {
  console.error('usage: node reset-admin-password.js <new_password>');
  console.error('   or: ADMIN_RESET_PASSWORD=xxx node reset-admin-password.js');
  process.exit(1);
}

if (pwd.length < 8) {
  console.error('password must be >= 8 chars');
  process.exit(1);
}

// 万象书屋: 与 db.js 保持一致, 允许通过 BCRYPT_COST 覆盖
const cost = (() => {
  const v = parseInt(process.env.BCRYPT_COST, 10);
  if (!Number.isFinite(v)) return 10;
  return Math.max(4, Math.min(14, v));
})();

const db = new Database(DB_PATH);
try {
  const hash = bcrypt.hashSync(pwd, cost);
  const now = Date.now();
  // 可能 admin 行不存在 (全新 db), 先 upsert
  db.prepare(
    `INSERT INTO admin(id, pwd_hash, updated_at) VALUES (1, ?, ?)
     ON CONFLICT(id) DO UPDATE SET pwd_hash=excluded.pwd_hash, updated_at=excluded.updated_at`
  ).run(hash, now);
  // 清掉所有已登录的 session, 强制重登
  db.prepare('DELETE FROM admin_session').run();
  console.log('[ok] admin password updated, all sessions cleared');
} catch (e) {
  console.error('[err]', e.message);
  process.exit(1);
} finally {
  db.close();
}
