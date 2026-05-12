// 万象书屋: 广告事件 + 崩溃 + 审计 + 反馈

let db;
let stmtInsertAdEvent, stmtInsertCrash, stmtInsertAudit, stmtInsertFeedback;

function init(database) {
  db = database;

  stmtInsertAdEvent = db.prepare(
    `INSERT INTO ad_events(ts, placement, provider, type, err_code, err_msg, device_id, app_ver, platform)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`
  );
  stmtInsertCrash = db.prepare(
    `INSERT INTO crashes(ts, device_id, app_ver, brand, model, sdk_int, fingerprint, exception, stack, platform)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
  );
  stmtInsertAudit = db.prepare(
    `INSERT INTO audit_log(ts, ip, action, target, detail) VALUES (?, ?, ?, ?, ?)`
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

// --- Crashes ---

function recordCrash(c) {
  const { deviceId, appVer, brand, model, sdkInt, fingerprint, exception, stack, platform } = c;
  if (!exception || !stack) return;
  const p = (platform === 'ios' || platform === 'web') ? platform : 'android';
  stmtInsertCrash.run(
    Date.now(),
    deviceId ? String(deviceId).slice(0, 128) : null,
    appVer ? String(appVer).slice(0, 32) : null,
    brand ? String(brand).slice(0, 32) : null,
    model ? String(model).slice(0, 64) : null,
    sdkInt != null ? Number(sdkInt) : null,
    fingerprint ? String(fingerprint).slice(0, 64) : null,
    String(exception).slice(0, 200),
    String(stack).slice(0, 20_000),
    p,
  );
}

function listCrashSummary({ hours = 168 } = {}) {
  const since = Date.now() - hours * 3600_000;
  return db.prepare(`
    SELECT fingerprint, exception, COUNT(*) AS count,
           MAX(ts) AS last_ts, MIN(ts) AS first_ts,
           COUNT(DISTINCT device_id) AS devices
    FROM crashes WHERE ts >= ?
    GROUP BY fingerprint, exception
    ORDER BY count DESC LIMIT 100
  `).all(since);
}

function listCrashesByFingerprint(fingerprint, limit = 20) {
  return db.prepare(`
    SELECT ts, device_id, app_ver, brand, model, sdk_int, exception, stack
    FROM crashes WHERE fingerprint = ? ORDER BY ts DESC LIMIT ?
  `).all(fingerprint, limit);
}

// --- Audit log ---

function recordAudit({ ip, action, target, detail }) {
  if (!action) return;
  stmtInsertAudit.run(
    Date.now(),
    ip ? String(ip).slice(0, 64) : null,
    String(action).slice(0, 64),
    target ? String(target).slice(0, 256) : null,
    detail ? (typeof detail === 'string' ? detail.slice(0, 2000) : JSON.stringify(detail).slice(0, 2000)) : null,
  );
}

function listAuditLog({ limit = 200 } = {}) {
  return db.prepare(`
    SELECT ts, ip, action, target, detail FROM audit_log
    ORDER BY ts DESC LIMIT ?
  `).all(limit);
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
  recordCrash, listCrashSummary, listCrashesByFingerprint,
  recordAudit, listAuditLog,
  recordFeedback, listFeedback, updateFeedbackStatus, feedbackStats,
};
