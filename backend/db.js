// 万象书屋 - SQLite 数据访问层
const path = require('path');
const Database = require('better-sqlite3');
const bcrypt = require('bcryptjs');

const DB_PATH = process.env.DB_PATH || path.join(__dirname, 'data', 'wanxiang.db');
const db = new Database(DB_PATH);
db.pragma('journal_mode = WAL');

function init() {
  db.exec(`
    CREATE TABLE IF NOT EXISTS book_sources (
      url        TEXT PRIMARY KEY,
      name       TEXT,
      json       TEXT NOT NULL,
      enabled    INTEGER NOT NULL DEFAULT 1,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS heartbeats (
      device_id TEXT NOT NULL,
      ts        INTEGER NOT NULL,
      PRIMARY KEY (device_id, ts)
    );
    CREATE INDEX IF NOT EXISTS idx_heartbeats_ts ON heartbeats(ts);

    CREATE TABLE IF NOT EXISTS visits (
      device_id TEXT NOT NULL,
      day       TEXT NOT NULL,           -- YYYY-MM-DD UTC+8
      first_ts  INTEGER NOT NULL,
      PRIMARY KEY (device_id, day)
    );
    CREATE INDEX IF NOT EXISTS idx_visits_day ON visits(day);

    CREATE TABLE IF NOT EXISTS admin (
      id         INTEGER PRIMARY KEY CHECK (id = 1),
      pwd_hash   TEXT NOT NULL,
      updated_at INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS admin_session (
      token      TEXT PRIMARY KEY,
      created_at INTEGER NOT NULL
    );
  `);

  // 默认管理员密码 (首次启动)
  const row = db.prepare('SELECT 1 FROM admin WHERE id = 1').get();
  if (!row) {
    const defaultPwd = process.env.ADMIN_INITIAL_PASSWORD || 'wanxiang2026';
    const hash = bcrypt.hashSync(defaultPwd, 10);
    db.prepare('INSERT INTO admin(id, pwd_hash, updated_at) VALUES (1, ?, ?)')
      .run(hash, Date.now());
    console.log(`[init] admin password = ${defaultPwd} (set ADMIN_INITIAL_PASSWORD env to override)`);
  }
}

init();

// === Book sources ===
function listEnabledSourcesJson() {
  // 给 App 拉的 endpoint，返回纯 JSON 数组（每条 source 的 json 字段）
  const rows = db.prepare('SELECT json FROM book_sources WHERE enabled = 1').all();
  return rows.map(r => JSON.parse(r.json));
}

function listAllSources() {
  return db.prepare(
    'SELECT url, name, enabled, updated_at FROM book_sources ORDER BY updated_at DESC'
  ).all();
}

function getSource(url) {
  return db.prepare('SELECT * FROM book_sources WHERE url = ?').get(url);
}

function upsertSource(srcJson) {
  const url = srcJson.bookSourceUrl;
  if (!url) throw new Error('bookSourceUrl required');
  const name = srcJson.bookSourceName || url;
  const now = Date.now();
  const existing = db.prepare('SELECT created_at FROM book_sources WHERE url = ?').get(url);
  if (existing) {
    db.prepare('UPDATE book_sources SET name=?, json=?, updated_at=? WHERE url=?')
      .run(name, JSON.stringify(srcJson), now, url);
    return { url, action: 'updated' };
  }
  db.prepare('INSERT INTO book_sources(url,name,json,enabled,created_at,updated_at) VALUES (?,?,?,1,?,?)')
    .run(url, name, JSON.stringify(srcJson), now, now);
  return { url, action: 'created' };
}

function bulkUpsert(arr) {
  const insert = db.transaction((items) => {
    let created = 0, updated = 0;
    for (const it of items) {
      const r = upsertSource(it);
      if (r.action === 'created') created++; else updated++;
    }
    return { created, updated };
  });
  return insert(arr);
}

function deleteSource(url) {
  const info = db.prepare('DELETE FROM book_sources WHERE url = ?').run(url);
  return info.changes;
}

function setEnabled(url, enabled) {
  const info = db.prepare('UPDATE book_sources SET enabled=?, updated_at=? WHERE url=?')
    .run(enabled ? 1 : 0, Date.now(), url);
  return info.changes;
}

// === Heartbeat / Visit ===
const heartbeatStmt = db.prepare(
  'INSERT OR REPLACE INTO heartbeats(device_id, ts) VALUES (?, ?)'
);
const visitStmt = db.prepare(
  'INSERT OR IGNORE INTO visits(device_id, day, first_ts) VALUES (?, ?, ?)'
);

function recordPing(deviceId) {
  if (!deviceId) return;
  const now = Date.now();
  heartbeatStmt.run(deviceId, now);
  // 按 UTC+8 计算 day
  const day = new Date(now + 8 * 3600 * 1000).toISOString().slice(0, 10);
  visitStmt.run(deviceId, day, now);
}

function statsOnline(windowMs = 5 * 60 * 1000) {
  const since = Date.now() - windowMs;
  const r = db.prepare('SELECT COUNT(DISTINCT device_id) AS c FROM heartbeats WHERE ts >= ?').get(since);
  return r.c;
}

function todayKey() {
  return new Date(Date.now() + 8 * 3600 * 1000).toISOString().slice(0, 10);
}
function weekDays() {
  const days = [];
  for (let i = 6; i >= 0; i--) {
    const d = new Date(Date.now() + 8 * 3600 * 1000 - i * 86400 * 1000);
    days.push(d.toISOString().slice(0, 10));
  }
  return days;
}
function monthKey() {
  return todayKey().slice(0, 7);
}

function statsToday() {
  return db.prepare('SELECT COUNT(*) AS c FROM visits WHERE day = ?').get(todayKey()).c;
}
function statsWeek() {
  const days = weekDays();
  return db.prepare(
    `SELECT COUNT(DISTINCT device_id) AS c FROM visits WHERE day IN (${days.map(() => '?').join(',')})`
  ).get(...days).c;
}
function statsMonth() {
  return db.prepare(
    `SELECT COUNT(DISTINCT device_id) AS c FROM visits WHERE day LIKE ?`
  ).get(monthKey() + '%').c;
}
function statsDailyCurve(days = 7) {
  const list = weekDays();
  const counts = list.map(day => {
    const r = db.prepare('SELECT COUNT(*) AS c FROM visits WHERE day = ?').get(day);
    return { day, count: r.c };
  });
  return counts;
}

// === Admin ===
function verifyAdminPassword(plain) {
  const row = db.prepare('SELECT pwd_hash FROM admin WHERE id = 1').get();
  if (!row) return false;
  return bcrypt.compareSync(plain, row.pwd_hash);
}

function setAdminPassword(plain) {
  const hash = bcrypt.hashSync(plain, 10);
  db.prepare('UPDATE admin SET pwd_hash=?, updated_at=? WHERE id=1').run(hash, Date.now());
}

function createSession() {
  const token = require('crypto').randomBytes(24).toString('hex');
  db.prepare('INSERT INTO admin_session(token, created_at) VALUES (?, ?)').run(token, Date.now());
  return token;
}

function isValidSession(token) {
  if (!token) return false;
  const row = db.prepare('SELECT created_at FROM admin_session WHERE token = ?').get(token);
  if (!row) return false;
  // 7 天有效
  return Date.now() - row.created_at < 7 * 86400 * 1000;
}

function destroySession(token) {
  db.prepare('DELETE FROM admin_session WHERE token = ?').run(token);
}

// 定时清理 30 天前的心跳数据
function cleanupOldData() {
  const cutoff = Date.now() - 30 * 86400 * 1000;
  db.prepare('DELETE FROM heartbeats WHERE ts < ?').run(cutoff);
  const cutoffDay = new Date(Date.now() + 8 * 3600 * 1000 - 90 * 86400 * 1000)
    .toISOString().slice(0, 10);
  db.prepare('DELETE FROM visits WHERE day < ?').run(cutoffDay);
}

module.exports = {
  init,
  // book sources
  listEnabledSourcesJson, listAllSources, getSource, upsertSource, bulkUpsert,
  deleteSource, setEnabled,
  // ping / stats
  recordPing, statsOnline, statsToday, statsWeek, statsMonth, statsDailyCurve,
  // admin
  verifyAdminPassword, setAdminPassword,
  createSession, isValidSession, destroySession,
  cleanupOldData,
};
