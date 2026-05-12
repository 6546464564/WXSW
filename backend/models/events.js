// 万象书屋: 自建埋点

let db;
let _insertEventStmt;

function init(database) {
  db = database;
  _insertEventStmt = db.prepare(`
    INSERT INTO events (ts, client_ts, device_id, platform, app_ver,
                        event_type, event_name, params, session_id, ip)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `);
}

function recordEvent(e) {
  const params = e.params != null
    ? (typeof e.params === 'string' ? e.params : JSON.stringify(e.params))
    : null;
  _insertEventStmt.run(
    Date.now(),
    e.clientTs ? Number(e.clientTs) : null,
    String(e.deviceId).slice(0, 80),
    e.platform || null,
    e.appVer || null,
    String(e.type || 'custom').slice(0, 32),
    String(e.name || '').slice(0, 80),
    params ? params.slice(0, 4000) : null,
    e.sessionId ? String(e.sessionId).slice(0, 64) : null,
    e.ip || null,
  );
}

function recordEventsBulk(events, ip) {
  if (!Array.isArray(events) || !events.length) return 0;
  const tx = db.transaction((arr) => {
    for (const e of arr) recordEvent({ ...e, ip: e.ip || ip });
  });
  tx(events);
  return events.length;
}

function listEvents(opts = {}) {
  const limit = Math.min(parseInt(opts.limit, 10) || 200, 1000);
  const conds = [];
  const args = [];
  if (opts.eventName) { conds.push('event_name = ?'); args.push(opts.eventName); }
  if (opts.deviceId)  { conds.push('device_id = ?');  args.push(opts.deviceId); }
  if (opts.type)      { conds.push('event_type = ?'); args.push(opts.type); }
  if (opts.sinceTs)   { conds.push('ts >= ?');         args.push(Number(opts.sinceTs)); }
  const where = conds.length ? 'WHERE ' + conds.join(' AND ') : '';
  return db.prepare(
    `SELECT id, ts, client_ts, device_id, platform, app_ver,
            event_type, event_name, params, session_id, ip
     FROM events ${where}
     ORDER BY ts DESC LIMIT ?`
  ).all(...args, limit);
}

function eventTopList(opts = {}) {
  const sinceTs = Number(opts.sinceTs) || (Date.now() - 7 * 86400 * 1000);
  const limit = Math.min(parseInt(opts.limit, 10) || 20, 100);
  const typeFilter = opts.type ? 'AND event_type = ?' : '';
  const args = opts.type ? [sinceTs, opts.type, limit] : [sinceTs, limit];
  return db.prepare(
    `SELECT event_name, event_type, COUNT(*) AS count,
            COUNT(DISTINCT device_id) AS uv
     FROM events
     WHERE ts >= ? ${typeFilter}
     GROUP BY event_name
     ORDER BY count DESC
     LIMIT ?`
  ).all(...args);
}

function eventDailyDau(days = 7) {
  const since = Date.now() - days * 86400 * 1000;
  const rows = db.prepare(
    `SELECT CAST((ts + 28800000) / 86400000 AS INTEGER) AS day_idx,
            COUNT(DISTINCT device_id) AS dau,
            COUNT(*) AS events
     FROM events WHERE ts >= ?
     GROUP BY day_idx ORDER BY day_idx ASC`
  ).all(since);
  return rows.map(r => {
    const d = new Date(r.day_idx * 86400000 - 28800000);
    return { date: d.toISOString().slice(0, 10), dau: r.dau, events: r.events };
  });
}

function eventFunnel(steps, sinceTs) {
  if (!Array.isArray(steps) || !steps.length) return [];
  const since = sinceTs || (Date.now() - 7 * 86400 * 1000);
  return steps.map((name, idx) => {
    const uv = db.prepare(
      `SELECT COUNT(DISTINCT device_id) AS uv FROM events
       WHERE ts >= ? AND event_name = ?`
    ).get(since, name).uv;
    return { step: idx + 1, name, uv };
  });
}

function eventRetentionMatrix(windowDays = 14) {
  const W = Math.max(2, Math.min(60, parseInt(windowDays, 10) || 14));
  const DAY = 86_400_000;
  const TZ_OFFSET = 8 * 3600_000;
  const now = Date.now();
  const since = now - (2 * W) * DAY;

  const rows = db.prepare(
    'SELECT device_id, ts FROM events WHERE ts >= ? ORDER BY ts ASC'
  ).all(since);

  const firstDay = new Map();
  const activeDays = new Map();
  for (const r of rows) {
    const dayIdx = Math.floor((r.ts + TZ_OFFSET) / DAY);
    if (!firstDay.has(r.device_id)) firstDay.set(r.device_id, dayIdx);
    let s = activeDays.get(r.device_id);
    if (!s) { s = new Set(); activeDays.set(r.device_id, s); }
    s.add(dayIdx);
  }

  const cohortDevices = new Map();
  for (const [dev, day] of firstDay) {
    let arr = cohortDevices.get(day);
    if (!arr) { arr = []; cohortDevices.set(day, arr); }
    arr.push(dev);
  }

  const todayIdx = Math.floor((now + TZ_OFFSET) / DAY);
  const cohorts = [];
  for (let off = W - 1; off >= 0; off--) {
    const cohortDay = todayIdx - off;
    const devices = cohortDevices.get(cohortDay) || [];
    const retention = new Array(W).fill(null);
    const retentionPct = new Array(W).fill(null);
    for (let dN = 0; dN < W; dN++) {
      const dayIdx = cohortDay + dN;
      if (dayIdx > todayIdx) break;
      let count = 0;
      for (const dev of devices) {
        if (activeDays.get(dev)?.has(dayIdx)) count++;
      }
      retention[dN] = count;
      retentionPct[dN] = devices.length ? +(count / devices.length * 100).toFixed(1) : 0;
    }
    cohorts.push({
      date: new Date(cohortDay * DAY - TZ_OFFSET).toISOString().slice(0, 10),
      size: devices.length,
      retention,
      retentionPct,
    });
  }

  return { windowDays: W, cohorts };
}

function eventOverview() {
  const day = 86400 * 1000;
  const now = Date.now();
  const r = (q, ...args) => db.prepare(q).get(...args);
  return {
    today: r('SELECT COUNT(*) AS c FROM events WHERE ts >= ?', now - day).c,
    yesterday: r('SELECT COUNT(*) AS c FROM events WHERE ts >= ? AND ts < ?', now - 2 * day, now - day).c,
    week: r('SELECT COUNT(*) AS c FROM events WHERE ts >= ?', now - 7 * day).c,
    devicesToday: r('SELECT COUNT(DISTINCT device_id) AS c FROM events WHERE ts >= ?', now - day).c,
    totalEvents: r('SELECT COUNT(*) AS c FROM events').c,
    pvToday: r("SELECT COUNT(*) AS c FROM events WHERE ts >= ? AND event_type = 'pv'", now - day).c,
    clickToday: r("SELECT COUNT(*) AS c FROM events WHERE ts >= ? AND event_type = 'click'", now - day).c,
  };
}

module.exports = {
  init, recordEvent, recordEventsBulk, listEvents, eventTopList,
  eventDailyDau, eventFunnel, eventOverview, eventRetentionMatrix,
};
