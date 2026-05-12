// 万象书屋: 强制升级 + 公告

let db;
let stmtListEnabledAnnouncements;

function init(database) {
  db = database;
  stmtListEnabledAnnouncements = db.prepare(
    `SELECT id, title, content, style, dismissable, version_min, version_max, end_at
     FROM announcements
     WHERE enabled = 1
       AND (start_at = 0 OR start_at <= ?)
       AND (end_at   = 0 OR end_at   >= ?)
     ORDER BY id DESC`
  );
}

function getAppVersion() {
  const row = db.prepare('SELECT * FROM app_versions WHERE id = 1').get();
  if (!row) return { latest_code: 0, latest_name: '', min_required_code: 0, changelog: '', apk_url: '', market_url: '', updated_at: 0 };
  return row;
}

function saveAppVersion(o) {
  const now = Date.now();
  db.prepare(
    `INSERT INTO app_versions(id, latest_code, latest_name, min_required_code, changelog, apk_url, market_url, updated_at)
     VALUES (1, ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(id) DO UPDATE SET
       latest_code=excluded.latest_code,
       latest_name=excluded.latest_name,
       min_required_code=excluded.min_required_code,
       changelog=excluded.changelog,
       apk_url=excluded.apk_url,
       market_url=excluded.market_url,
       updated_at=excluded.updated_at`
  ).run(
    Number(o.latest_code) || 0,
    String(o.latest_name || '').slice(0, 32),
    Number(o.min_required_code) || 0,
    String(o.changelog || '').slice(0, 4000),
    String(o.apk_url || '').slice(0, 500),
    String(o.market_url || '').slice(0, 200),
    now
  );
}

function listActiveAnnouncements(versionCode) {
  const now = Date.now();
  const rows = stmtListEnabledAnnouncements.all(now, now);
  return rows.filter(r =>
    (r.version_min === 0 || versionCode >= r.version_min) &&
    (r.version_max === 0 || versionCode <= r.version_max)
  );
}

function listAllAnnouncements() {
  return db.prepare('SELECT * FROM announcements ORDER BY id DESC LIMIT 200').all();
}

function upsertAnnouncement(o) {
  const now = Date.now();
  if (o.id) {
    db.prepare(
      `UPDATE announcements SET title=?, content=?, style=?, dismissable=?, enabled=?,
       start_at=?, end_at=?, version_min=?, version_max=?, updated_at=? WHERE id=?`
    ).run(
      String(o.title || '').slice(0, 100), String(o.content || '').slice(0, 4000),
      String(o.style || 'info'), o.dismissable ? 1 : 0, o.enabled ? 1 : 0,
      Number(o.start_at) || 0, Number(o.end_at) || 0,
      Number(o.version_min) || 0, Number(o.version_max) || 0,
      now, Number(o.id)
    );
    return o.id;
  }
  const r = db.prepare(
    `INSERT INTO announcements(title, content, style, dismissable, enabled, start_at, end_at, version_min, version_max, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
  ).run(
    String(o.title || '').slice(0, 100), String(o.content || '').slice(0, 4000),
    String(o.style || 'info'), o.dismissable ? 1 : 0, o.enabled ? 1 : 0,
    Number(o.start_at) || 0, Number(o.end_at) || 0,
    Number(o.version_min) || 0, Number(o.version_max) || 0,
    now, now
  );
  return r.lastInsertRowid;
}

function deleteAnnouncement(id) {
  db.prepare('DELETE FROM announcements WHERE id=?').run(Number(id));
}

module.exports = {
  init,
  getAppVersion, saveAppVersion,
  listActiveAnnouncements, listAllAnnouncements, upsertAnnouncement, deleteAnnouncement,
};
