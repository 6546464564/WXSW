// 万象书屋: 兑换码

let db;
let stmtUpdateRedeemAtomic, stmtRollbackRedeem, stmtSelectRedeemReward, stmtInsertRedeemUse;

function init(database) {
  db = database;
  stmtUpdateRedeemAtomic = db.prepare(
    `UPDATE redeem_codes SET used_count = used_count + 1
     WHERE code = ? AND revoked = 0 AND used_count < max_uses AND (expires_at = 0 OR expires_at > ?)`
  );
  stmtRollbackRedeem = db.prepare('UPDATE redeem_codes SET used_count = used_count - 1 WHERE code = ?');
  stmtSelectRedeemReward = db.prepare('SELECT reward_type, reward_value FROM redeem_codes WHERE code = ?');
  stmtInsertRedeemUse = db.prepare('INSERT INTO redeem_uses(code, device_id, used_at, ip) VALUES (?, ?, ?, ?)');
}

function randomCode(len = 10) {
  const alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  const bytes = require('crypto').randomBytes(len);
  let s = '';
  for (let i = 0; i < len; i++) s += alphabet[bytes[i] % alphabet.length];
  return s;
}

function createRedeemCodes({ count, rewardType, rewardValue, batch, maxUses = 1, expiresAt = 0, creator }) {
  if (!rewardType || !rewardValue) throw new Error('rewardType & rewardValue required');
  const allowedTypes = new Set(['ad_free_minutes', 'vip_days', 'custom']);
  if (!allowedTypes.has(rewardType)) throw new Error('invalid rewardType');
  const n = Math.max(1, Math.min(1000, Number(count) || 1));
  const now = Date.now();
  const codes = [];
  const stmt = db.prepare(
    `INSERT INTO redeem_codes(code, reward_type, reward_value, batch, max_uses, expires_at, created_at, created_by)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)`
  );
  const tx = db.transaction(() => {
    for (let i = 0; i < n; i++) {
      const code = randomCode(10);
      stmt.run(code, rewardType, Number(rewardValue), batch || null, maxUses, expiresAt, now, creator || null);
      codes.push(code);
    }
  });
  tx();
  return codes;
}

function redeemCode(code, deviceId, ip) {
  if (!code || !deviceId) throw new Error('code & deviceId required');
  const now = Date.now();
  const row = stmtSelectRedeemReward.get(code);
  if (!row) return { ok: false, msg: 'code not found' };

  const tx = db.transaction(() => {
    const r = stmtUpdateRedeemAtomic.run(code, now);
    if (r.changes !== 1) {
      return { ok: false, msg: 'code unavailable (used up / revoked / expired)' };
    }
    try {
      stmtInsertRedeemUse.run(code, deviceId, now, ip || '');
    } catch (e) {
      stmtRollbackRedeem.run(code);
      return { ok: false, msg: 'already redeemed by this device' };
    }
    return { ok: true, rewardType: row.reward_type, rewardValue: row.reward_value };
  });
  return tx();
}

function listRedeemCodes({ batch, limit = 500 } = {}) {
  if (batch) {
    return db.prepare('SELECT * FROM redeem_codes WHERE batch=? ORDER BY created_at DESC LIMIT ?').all(batch, limit);
  }
  return db.prepare('SELECT * FROM redeem_codes ORDER BY created_at DESC LIMIT ?').all(limit);
}

function revokeRedeemBatch(batch) {
  return db.prepare('UPDATE redeem_codes SET revoked=1 WHERE batch=?').run(batch).changes;
}

module.exports = {
  init, createRedeemCodes, redeemCode, listRedeemCodes, revokeRedeemBatch,
};
