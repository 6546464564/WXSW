// 万象书屋: 推广代理码

let db;

function init(database) {
  db = database;
}

function listPromoCodes({ enabledOnly = false } = {}) {
  if (enabledOnly) {
    return db.prepare('SELECT * FROM promo_codes WHERE enabled=1 ORDER BY created_at DESC').all();
  }
  return db.prepare('SELECT * FROM promo_codes ORDER BY created_at DESC').all();
}

function createPromoCode({ code, agentName, maxUses = 0, singleDevice = false, expiresAt = 0, creator }) {
  if (!code) throw new Error('code required');
  const now = Date.now();
  db.prepare(`INSERT INTO promo_codes (code, agent_name, max_uses, single_device, expires_at, created_at, created_by)
              VALUES (?, ?, ?, ?, ?, ?, ?)`)
    .run(code, agentName || '代理', maxUses, singleDevice ? 1 : 0, expiresAt, now, creator || null);
  return { code, agentName: agentName || '代理', maxUses, singleDevice, expiresAt };
}

function updatePromoCode(code, updates) {
  const allowed = ['agent_name', 'max_uses', 'single_device', 'expires_at', 'enabled'];
  const sets = [];
  const vals = [];
  for (const [k, v] of Object.entries(updates)) {
    if (allowed.includes(k)) {
      sets.push(`${k}=?`);
      vals.push(v);
    }
  }
  if (sets.length === 0) return false;
  vals.push(code);
  return db.prepare(`UPDATE promo_codes SET ${sets.join(',')} WHERE code=?`).run(...vals).changes > 0;
}

function deletePromoCode(code) {
  return db.prepare('DELETE FROM promo_codes WHERE code=?').run(code).changes > 0;
}

function recordPromoAttempt({ code, deviceId, deviceModel, success, ip }) {
  db.prepare(`INSERT INTO promo_attempts (code, device_id, device_model, success, ip, ts)
              VALUES (?, ?, ?, ?, ?, ?)`)
    .run(code, deviceId, deviceModel || null, success ? 1 : 0, ip || null, Date.now());
}

function recordPromoUsage({ code, agentName, deviceId, deviceModel, systemVersion, ip }) {
  const now = Date.now();
  try {
    db.prepare(`INSERT INTO promo_usage (code, agent_name, device_id, device_model, system_version, ip, ts)
                VALUES (?, ?, ?, ?, ?, ?, ?)`)
      .run(code, agentName || '', deviceId, deviceModel || null, systemVersion || null, ip || null, now);
    db.prepare('UPDATE promo_codes SET used_count = used_count + 1 WHERE code=?').run(code);
    return true;
  } catch {
    return false;
  }
}

function promoCodeStats(code) {
  const codeRow = db.prepare('SELECT * FROM promo_codes WHERE code=?').get(code);
  const usages = db.prepare('SELECT * FROM promo_usage WHERE code=? ORDER BY ts DESC').all(code);
  const attempts = db.prepare('SELECT COUNT(*) AS total, SUM(CASE WHEN success=1 THEN 1 ELSE 0 END) AS successes FROM promo_attempts WHERE code=?').get(code);
  const uniqueDevices = db.prepare('SELECT COUNT(DISTINCT device_id) AS c FROM promo_usage WHERE code=?').get(code);
  return {
    code: codeRow,
    totalAttempts: attempts?.total || 0,
    successfulAttempts: attempts?.successes || 0,
    totalUses: usages.length,
    uniqueDevices: uniqueDevices?.c || 0,
    usages,
  };
}

function promoOverview() {
  const totalCodes = db.prepare('SELECT COUNT(*) AS c FROM promo_codes WHERE enabled=1').get().c;
  const totalUses = db.prepare('SELECT COUNT(*) AS c FROM promo_usage').get().c;
  const uniqueDevices = db.prepare('SELECT COUNT(DISTINCT device_id) AS c FROM promo_usage').get().c;
  const today = Date.now() - 86400000;
  const todayUses = db.prepare('SELECT COUNT(*) AS c FROM promo_usage WHERE ts>=?').get(today).c;
  const recentAttempts = db.prepare('SELECT COUNT(*) AS c FROM promo_attempts WHERE ts>=?').get(today).c;
  const failedAttempts = db.prepare('SELECT COUNT(*) AS c FROM promo_attempts WHERE ts>=? AND success=0').get(today).c;
  const topCodes = db.prepare(`SELECT code, agent_name, used_count, max_uses, enabled
                               FROM promo_codes ORDER BY used_count DESC LIMIT 10`).all();
  return { totalCodes, totalUses, uniqueDevices, todayUses, recentAttempts, failedAttempts, topCodes };
}

function promoFraudDetection() {
  const alerts = [];

  const multiCodeDevices = db.prepare(`
    SELECT device_id, COUNT(DISTINCT code) AS code_count, GROUP_CONCAT(DISTINCT code) AS codes
    FROM promo_usage GROUP BY device_id HAVING code_count > 1
  `).all();
  for (const d of multiCodeDevices) {
    alerts.push({
      type: 'multi_code_device', severity: 'high',
      desc: `同一设备使用了 ${d.code_count} 个不同推广码`,
      detail: { deviceId: d.device_id, codes: d.codes },
    });
  }

  const ipBurst = db.prepare(`
    SELECT ip, COUNT(*) AS cnt, COUNT(DISTINCT device_id) AS devices, GROUP_CONCAT(DISTINCT code) AS codes
    FROM promo_usage WHERE ts >= ? GROUP BY ip HAVING cnt >= 3
  `).all(Date.now() - 86400000);
  for (const r of ipBurst) {
    if (r.cnt >= 5) {
      alerts.push({
        type: 'ip_burst', severity: r.cnt >= 10 ? 'high' : 'medium',
        desc: `同一IP(${r.ip}) 24h内激活 ${r.cnt} 次 (${r.devices} 台设备)`,
        detail: { ip: r.ip, count: r.cnt, devices: r.devices, codes: r.codes },
      });
    }
  }

  const codeBurst = db.prepare(`
    SELECT code, COUNT(*) AS cnt, MIN(ts) AS first_ts, MAX(ts) AS last_ts
    FROM promo_usage WHERE ts >= ? GROUP BY code HAVING cnt >= 5
  `).all(Date.now() - 3600000);
  for (const r of codeBurst) {
    const spanMin = (r.last_ts - r.first_ts) / 60000;
    if (spanMin < 30 && r.cnt >= 5) {
      alerts.push({
        type: 'code_burst', severity: 'medium',
        desc: `推广码 "${r.code}" 在 ${Math.round(spanMin)} 分钟内被使用 ${r.cnt} 次`,
        detail: { code: r.code, count: r.cnt, spanMinutes: Math.round(spanMin) },
      });
    }
  }

  const codeDeviceModels = db.prepare(`
    SELECT code, device_model, COUNT(*) AS cnt
    FROM promo_usage GROUP BY code, device_model HAVING cnt >= 3
    ORDER BY cnt DESC
  `).all();
  const codeTotal = {};
  for (const r of codeDeviceModels) {
    if (!codeTotal[r.code]) {
      codeTotal[r.code] = db.prepare('SELECT COUNT(*) AS c FROM promo_usage WHERE code=?').get(r.code).c;
    }
    const ratio = r.cnt / codeTotal[r.code];
    if (ratio > 0.8 && codeTotal[r.code] >= 5) {
      alerts.push({
        type: 'same_model', severity: 'medium',
        desc: `推广码 "${r.code}" 下 ${Math.round(ratio * 100)}% 设备为同一型号 "${r.device_model}"`,
        detail: { code: r.code, model: r.device_model, count: r.cnt, total: codeTotal[r.code] },
      });
    }
  }

  const bruteForce = db.prepare(`
    SELECT device_id, COUNT(*) AS fails
    FROM promo_attempts WHERE success=0 AND ts >= ?
    GROUP BY device_id HAVING fails >= 10
  `).all(Date.now() - 86400000);
  for (const r of bruteForce) {
    alerts.push({
      type: 'brute_force', severity: 'low',
      desc: `设备 24h 内尝试 ${r.fails} 次均失败（可能在猜码）`,
      detail: { deviceId: r.device_id, fails: r.fails },
    });
  }

  return alerts.sort((a, b) => {
    const sev = { high: 0, medium: 1, low: 2 };
    return (sev[a.severity] || 9) - (sev[b.severity] || 9);
  });
}

module.exports = {
  init,
  listPromoCodes, createPromoCode, updatePromoCode, deletePromoCode,
  recordPromoAttempt, recordPromoUsage, promoCodeStats, promoOverview, promoFraudDetection,
};
