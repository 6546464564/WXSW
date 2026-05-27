// 万象书屋: 广告事件 + 审计 + 反馈

let db;
let stmtInsertAdEvent, stmtInsertFeedback;

function init(database) {
  db = database;

  stmtInsertAdEvent = db.prepare(
    `INSERT INTO ad_events(ts, placement, provider, type, err_code, err_msg, device_id, app_ver, platform)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`
  );
  stmtInsertFeedback = db.prepare(
    `INSERT INTO feedback(ts, type, content, contact, device_id, app_ver, ip, platform)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)`
  );
}

function recordAdEvent({ placement, provider, type, errCode, errMsg, deviceId, appVer, platform }) {
  if (!placement || !provider || !type) {
    throw new Error('placement / provider / type required');
  }
  const p = (platform === 'ios' || platform === 'web') ? platform : 'android';
  stmtInsertAdEvent.run(
    Date.now(), String(placement).slice(0, 64), String(provider).slice(0, 32),
    String(type).slice(0, 16),
    errCode != null ? Number(errCode) : null,
    errMsg ? String(errMsg).slice(0, 200) : null,
    deviceId ? String(deviceId).slice(0, 128) : null,
    appVer ? String(appVer).slice(0, 32) : null,
    p,
  );
}

function adEventFunnel({ hours = 24 } = {}) {
  const since = Date.now() - hours * 3600_000;
  const rows = db.prepare(`
    SELECT placement, provider, type, COUNT(*) AS c
    FROM ad_events WHERE ts >= ?
    GROUP BY placement, provider, type
  `).all(since);
  const funnel = {};
  for (const r of rows) {
    const k = `${r.placement}|${r.provider}`;
    if (!funnel[k]) funnel[k] = { placement: r.placement, provider: r.provider };
    funnel[k][r.type] = r.c;
  }
  for (const v of Object.values(funnel)) {
    const load = v.load || 0;
    const error = v.error || 0;
    v.errorRate = load > 0 ? Math.min(1, error / load) : 0;
  }
  return Object.values(funnel);
}

function adProvidersToBreak({ windowHours = 1, minSamples = 20, errorThreshold = 0.6, perPlacementMinSamples = null } = {}) {
  const since = Date.now() - windowHours * 3600_000;
  const rows = db.prepare(`
    SELECT placement, provider,
           SUM(CASE WHEN type='error' THEN 1 ELSE 0 END) AS errs,
           SUM(CASE WHEN type='load'  THEN 1 ELSE 0 END) AS loads
    FROM ad_events WHERE ts >= ?
    GROUP BY placement, provider
  `).all(since);
  return rows
    .filter(r => {
      const m = (perPlacementMinSamples && perPlacementMinSamples[r.placement]) || minSamples;
      return r.loads >= m && (r.errs / r.loads) >= errorThreshold;
    })
    .map(r => {
      const top = db.prepare(`
        SELECT err_code AS errCode, err_msg AS errMsg, COUNT(*) AS n
        FROM ad_events
        WHERE ts >= ? AND placement = ? AND provider = ? AND type = 'error'
        GROUP BY err_code, err_msg
        ORDER BY n DESC LIMIT 1
      `).get(since, r.placement, r.provider);
      return {
        placement: r.placement,
        provider: r.provider,
        errs: r.errs,
        total: r.loads,
        errorRate: Number((r.errs / r.loads).toFixed(3)),
        topErrCode: top ? top.errCode : null,
        topErrMsg: top ? top.errMsg : null
      };
    });
}

// --- Feedback ---

function recordFeedback(f) {
  const { type, content, contact, deviceId, appVer, ip, platform } = f;
  if (!type || !content) throw new Error('type & content required');
  const allowedTypes = new Set(['bug', 'content', 'suggest', 'other']);
  const t = allowedTypes.has(type) ? type : 'other';
  if (String(content).length < 5) throw new Error('content too short');
  if (String(content).length > 2000) throw new Error('content too long');
  const p = (platform === 'ios' || platform === 'web') ? platform : 'android';
  const r = stmtInsertFeedback.run(
    Date.now(), t,
    String(content).slice(0, 2000),
    contact ? String(contact).slice(0, 100) : null,
    deviceId ? String(deviceId).slice(0, 128) : null,
    appVer ? String(appVer).slice(0, 32) : null,
    ip ? String(ip).slice(0, 64) : null,
    p,
  );
  return { id: r.lastInsertRowid };
}

function listFeedback({ status = null, limit = 200 } = {}) {
  if (status) {
    return db.prepare(`
      SELECT id, ts, type, content, contact, device_id, app_ver, ip, status, reply, reply_ts
      FROM feedback WHERE status = ?
      ORDER BY ts DESC LIMIT ?
    `).all(status, limit);
  }
  return db.prepare(`
    SELECT id, ts, type, content, contact, device_id, app_ver, ip, status, reply, reply_ts
    FROM feedback ORDER BY ts DESC LIMIT ?
  `).all(limit);
}

function updateFeedbackStatus(id, status, reply) {
  const allowed = new Set(['open', 'processing', 'done', 'spam']);
  if (!allowed.has(status)) throw new Error('invalid status');
  if (reply != null) {
    db.prepare('UPDATE feedback SET status=?, reply=?, reply_ts=? WHERE id=?')
      .run(status, String(reply).slice(0, 2000), Date.now(), id);
  } else {
    db.prepare('UPDATE feedback SET status=? WHERE id=?').run(status, id);
  }
}

function feedbackStats() {
  return db.prepare('SELECT status, COUNT(*) AS c FROM feedback GROUP BY status').all();
}

module.exports = {
  init,
  recordAdEvent, adEventFunnel, adProvidersToBreak,
  recordFeedback, listFeedback, updateFeedbackStatus, feedbackStats,
};
