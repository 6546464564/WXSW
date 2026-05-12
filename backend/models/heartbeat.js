// 万象书屋: 心跳 / 访问 / 统计

let db;
let heartbeatStmt, visitStmt;
let stmtStatsOnline, stmtStatsToday, stmtStatsDay, stmtStatsMonth, stmtStatsWeek;

function init(database) {
  db = database;
  heartbeatStmt = db.prepare('INSERT OR REPLACE INTO heartbeats(device_id, ts) VALUES (?, ?)');
  visitStmt = db.prepare('INSERT OR IGNORE INTO visits(device_id, day, first_ts) VALUES (?, ?, ?)');
  stmtStatsOnline = db.prepare('SELECT COUNT(DISTINCT device_id) AS c FROM heartbeats WHERE ts >= ?');
  stmtStatsToday = db.prepare('SELECT COUNT(*) AS c FROM visits WHERE day = ?');
  stmtStatsDay = db.prepare('SELECT COUNT(*) AS c FROM visits WHERE day = ?');
  stmtStatsMonth = db.prepare('SELECT COUNT(DISTINCT device_id) AS c FROM visits WHERE day > ? AND day < ?');
  stmtStatsWeek = db.prepare('SELECT COUNT(DISTINCT device_id) AS c FROM visits WHERE day >= ? AND day <= ?');
}

function recordPing(deviceId) {
  if (!deviceId) return;
  const now = Date.now();
  heartbeatStmt.run(deviceId, now);
  const day = new Date(now + 8 * 3600 * 1000).toISOString().slice(0, 10);
  visitStmt.run(deviceId, day, now);
}

function statsOnline(windowMs = 5 * 60 * 1000) {
  return stmtStatsOnline.get(Date.now() - windowMs).c;
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

function monthKey() { return todayKey().slice(0, 7); }

function statsToday() { return stmtStatsToday.get(todayKey()).c; }

function statsWeek() {
  const days = weekDays();
  return stmtStatsWeek.get(days[0], days[days.length - 1]).c;
}

function statsMonth() {
  const m = monthKey();
  const [yyyy, mm] = m.split('-').map(Number);
  const nextMonth = mm === 12
    ? `${yyyy + 1}-01-01`
    : `${yyyy}-${String(mm + 1).padStart(2, '0')}-01`;
  const loBoundary = `${m}-00`;
  return stmtStatsMonth.get(loBoundary, nextMonth).c;
}

function statsDailyCurve(days = 7) {
  const n = Math.max(1, Math.min(60, Number(days) || 7));
  const list = [];
  for (let i = n - 1; i >= 0; i--) {
    const d = new Date(Date.now() + 8 * 3600 * 1000 - i * 86400 * 1000);
    list.push(d.toISOString().slice(0, 10));
  }
  return list.map(day => ({ day, count: stmtStatsDay.get(day).c }));
}

module.exports = {
  init, recordPing, statsOnline, statsToday, statsWeek, statsMonth, statsDailyCurve,
};
