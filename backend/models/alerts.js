// 万象书屋: 告警规则

let db;

function init(database) {
  db = database;
}

function listAlertRules() {
  return db.prepare('SELECT * FROM alert_rules ORDER BY id DESC').all();
}

function upsertAlertRule(o) {
  const now = Date.now();
  if (o.id) {
    db.prepare(
      `UPDATE alert_rules SET name=?, kind=?, threshold=?, window_min=?, webhook_url=?, webhook_kind=?, enabled=?, cooldown_min=? WHERE id=?`
    ).run(o.name, o.kind, Number(o.threshold), Number(o.window_min) || 5,
          o.webhook_url, o.webhook_kind || 'wecom', o.enabled ? 1 : 0, Number(o.cooldown_min) || 30, Number(o.id));
    return o.id;
  }
  const r = db.prepare(
    `INSERT INTO alert_rules(name, kind, threshold, window_min, webhook_url, webhook_kind, enabled, cooldown_min, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`
  ).run(o.name, o.kind, Number(o.threshold), Number(o.window_min) || 5,
        o.webhook_url, o.webhook_kind || 'wecom', o.enabled ? 1 : 0, Number(o.cooldown_min) || 30, now);
  return r.lastInsertRowid;
}

function deleteAlertRule(id) {
  db.prepare('DELETE FROM alert_rules WHERE id=?').run(Number(id));
}

function markAlertFired(id) {
  db.prepare('UPDATE alert_rules SET last_fired_at=? WHERE id=?').run(Date.now(), Number(id));
}

module.exports = { init, listAlertRules, upsertAlertRule, deleteAlertRule, markAlertFired };
