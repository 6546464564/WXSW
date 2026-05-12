// 万象书屋: 设备 token / 黑名单 / KV settings / PIPL wipe

let db;
let _stmtUpsertDeviceToken, _stmtGetDeviceTokenHash, _stmtTouchDeviceSeen;
let stmtCheckBlacklist;

function init(database) {
  db = database;

  _stmtUpsertDeviceToken = db.prepare(
    `INSERT INTO device_tokens(device_id, token_hash, install_ts, last_seen_at, ua, ip, platform)
     VALUES (?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(device_id) DO UPDATE SET
       token_hash = excluded.token_hash,
       install_ts = excluded.install_ts,
       last_seen_at = excluded.last_seen_at,
       ua = excluded.ua,
       ip = excluded.ip,
       platform = excluded.platform`
  );
  _stmtGetDeviceTokenHash = db.prepare('SELECT token_hash FROM device_tokens WHERE device_id = ?');
  _stmtTouchDeviceSeen = db.prepare('UPDATE device_tokens SET last_seen_at = ? WHERE device_id = ?');
  stmtCheckBlacklist = db.prepare('SELECT 1 FROM device_blacklist WHERE device_id = ? LIMIT 1');
}

function upsertDeviceToken({ deviceId, tokenHash, installTs, ua, ip, platform }) {
  const now = Date.now();
  const p = (platform === 'ios' || platform === 'web') ? platform : 'android';
  _stmtUpsertDeviceToken.run(
    deviceId, tokenHash, installTs || now, now,
    ua || null, ip || null, p
  );
}

function getDeviceTokenHash(deviceId) {
  const r = _stmtGetDeviceTokenHash.get(deviceId);
  return r ? r.token_hash : null;
}

function touchDeviceSeen(deviceId) {
  _stmtTouchDeviceSeen.run(Date.now(), deviceId);
}

function deleteDeviceToken(deviceId) {
  db.prepare('DELETE FROM device_tokens WHERE device_id = ?').run(deviceId);
}

// --- 黑名单 ---

function isDeviceBlocked(deviceId) {
  if (!deviceId) return false;
  return !!stmtCheckBlacklist.get(deviceId);
}

function blockDevice(deviceId, reason, operator) {
  if (!deviceId) throw new Error('deviceId required');
  db.prepare(
    `INSERT INTO device_blacklist(device_id, reason, blocked_at, operator) VALUES (?, ?, ?, ?)
     ON CONFLICT(device_id) DO UPDATE SET reason=excluded.reason, operator=excluded.operator`
  ).run(String(deviceId).slice(0, 128), String(reason || '').slice(0, 200), Date.now(), String(operator || '').slice(0, 64));
}

function unblockDevice(deviceId) {
  db.prepare('DELETE FROM device_blacklist WHERE device_id=?').run(deviceId);
}

function listBlockedDevices(limit = 200) {
  return db.prepare('SELECT * FROM device_blacklist ORDER BY blocked_at DESC LIMIT ?').all(limit);
}

// --- KV ---

function kvGet(key) {
  const r = db.prepare('SELECT v FROM kv_settings WHERE k = ?').get(key);
  return r ? r.v : null;
}

function kvSet(key, value) {
  db.prepare(
    `INSERT INTO kv_settings(k, v, updated_at) VALUES (?, ?, ?)
     ON CONFLICT(k) DO UPDATE SET v=excluded.v, updated_at=excluded.updated_at`
  ).run(key, String(value), Date.now());
}

// --- PIPL wipe ---

function wipeUserData(deviceId) {
  if (!deviceId || typeof deviceId !== 'string') return { error: 'invalid device_id' };
  const stats = {};
  const tx = db.transaction(() => {
    const tables = [
      'heartbeats', 'visits', 'ad_events', 'crashes', 'feedback',
      'redeem_uses', 'device_tokens', 'events', 'iap_receipts', 'source_error_events',
    ];
    for (const t of tables) {
      try {
        const r = db.prepare(`DELETE FROM ${t} WHERE device_id = ?`).run(deviceId);
        stats[t] = r.changes;
      } catch (e) {
        stats[t] = 0;
      }
    }
  });
  tx();
  return stats;
}

module.exports = {
  init,
  upsertDeviceToken, getDeviceTokenHash, touchDeviceSeen, deleteDeviceToken,
  isDeviceBlocked, blockDevice, unblockDevice, listBlockedDevices,
  kvGet, kvSet,
  wipeUserData,
};
