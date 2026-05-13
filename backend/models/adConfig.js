// 万象书屋: 广告配置 + 灰度 + 熔断检测

let db;

const DEFAULT_AD_CONFIG = {
  disabled: false,
  primary: 'csj',
  sdk: {
    csj: { appId: '', androidAppId: '5822340', iosAppId: '5825810' },
    ylh: { appId: '', androidAppId: '1217143733', iosAppId: '1217620900' }
  },
  placements: {
    splash: {
      enabled: true,
      timeoutMs: 3000,
      soloProvider: '',
      providers: [
        { name: 'csj', weight: 80, posId: '', androidPosId: '980622522', iosPosId: '981264244' },
        { name: 'ylh', weight: 20, posId: '', androidPosId: '7300219291644321', iosPosId: '4300170851839651' }
      ]
    },
    rewardedReadingUnlock: {
      enabled: true,
      unlockMinutes: 30,
      cooldownMinutes: 30,
      cooldownSec: 180,
      maxAccumulatedMinutes: 1440,
      showCountdownBar: true,
      soloProvider: '',
      providers: [
        { name: 'csj', weight: 80, posId: '', androidPosId: '980622521', iosPosId: '981263226' },
        { name: 'ylh', weight: 20, posId: '', androidPosId: '5330818271549483', iosPosId: '3310279811340675' }
      ]
    }
  },
  pollIntervalSec: 21600,
  chapterUnlock: {
    enabled: false,
    freeChapters: 3,
    unlockMinutes: 30,
    blockOnSkip: true
  }
};

function init(database) {
  db = database;
}

function _mergeAdConfigDefaults(saved, defaults) {
  if (saved == null || typeof saved !== 'object') return defaults;
  if (Array.isArray(saved)) return saved;
  const out = { ...saved };
  for (const k of Object.keys(defaults)) {
    if (out[k] === undefined) {
      out[k] = defaults[k];
    } else if (defaults[k] && typeof defaults[k] === 'object' && !Array.isArray(defaults[k])) {
      out[k] = _mergeAdConfigDefaults(out[k], defaults[k]);
    }
  }
  return out;
}

function _applySoloProvider(cfg) {
  if (!cfg || !cfg.placements) return;
  for (const placement of Object.values(cfg.placements)) {
    if (!placement || !Array.isArray(placement.providers)) continue;
    const solo = placement.soloProvider;
    if (!solo) continue;
    for (const slot of placement.providers) {
      if (slot.name !== solo) slot.weight = 0;
    }
  }
}

/**
 * 按平台解析 posId / appId:
 * - providers[].iosPosId / androidPosId → 覆盖 posId
 * - sdk.csj.iosAppId / androidAppId → 覆盖 appId
 * 客户端只读 posId / appId, 无需感知平台差异.
 */
function _resolvePlatformIds(cfg, platform) {
  if (!cfg) return;
  const key = platform === 'ios' ? 'iosPosId' : 'androidPosId';
  const appKey = platform === 'ios' ? 'iosAppId' : 'androidAppId';

  // sdk appId
  if (cfg.sdk) {
    for (const sdkCfg of Object.values(cfg.sdk)) {
      if (sdkCfg && sdkCfg[appKey]) {
        sdkCfg.appId = sdkCfg[appKey];
      }
    }
  }

  // placements posId
  if (cfg.placements) {
    for (const placement of Object.values(cfg.placements)) {
      if (!placement || !Array.isArray(placement.providers)) continue;
      for (const slot of placement.providers) {
        if (slot[key]) {
          slot.posId = slot[key];
        }
      }
    }
  }
}

function getAdConfig(deviceId, platform) {
  const row = db.prepare(
    'SELECT version, json, etag, staging_json, rollout_pct FROM ad_config WHERE id = 1'
  ).get();
  if (!row) {
    const cfg = JSON.parse(JSON.stringify(DEFAULT_AD_CONFIG));
    _resolvePlatformIds(cfg, platform || 'android');
    return { version: 0, json: JSON.stringify(cfg), etag: 'v0', isStaging: false };
  }

  let chosenJson = row.json;
  let chosenEtag = row.etag;
  let isStaging = false;

  const pct = row.rollout_pct || 0;
  if (pct > 0 && row.staging_json) {
    let inRollout = pct >= 100;
    if (!inRollout && deviceId) {
      const h = require('crypto').createHash('md5').update(deviceId).digest();
      const bucket = h.readUInt32LE(0) % 100;
      inRollout = bucket < pct;
    }
    if (inRollout) {
      chosenJson = row.staging_json;
      chosenEtag = row.etag + '-s' + pct;
      isStaging = true;
    }
  }

  try {
    const saved = JSON.parse(chosenJson);
    const merged = _mergeAdConfigDefaults(saved, DEFAULT_AD_CONFIG);
    _applySoloProvider(merged);
    _resolvePlatformIds(merged, platform || 'android');
    return { version: row.version, json: JSON.stringify(merged), etag: chosenEtag, isStaging };
  } catch (e) {
    console.error('[db.getAdConfig] JSON parse failed, falling back to DEFAULT_AD_CONFIG:', e.message);
    const cfg = JSON.parse(JSON.stringify(DEFAULT_AD_CONFIG));
    _resolvePlatformIds(cfg, platform || 'android');
    return {
      version: row.version,
      json: JSON.stringify(cfg),
      etag: 'fallback-' + (row.etag || ''),
      isStaging: false
    };
  }
}

function getAdConfigRaw() {
  const row = db.prepare('SELECT version, json, etag FROM ad_config WHERE id = 1').get();
  if (!row) {
    return { version: 0, json: JSON.stringify(DEFAULT_AD_CONFIG), etag: 'v0' };
  }
  try {
    const saved = JSON.parse(row.json);
    const merged = _mergeAdConfigDefaults(saved, DEFAULT_AD_CONFIG);
    return { version: row.version, json: JSON.stringify(merged), etag: row.etag };
  } catch (_) {
    return row;
  }
}

function saveAdConfig(jsonObj) {
  if (!jsonObj || typeof jsonObj !== 'object' || !jsonObj.placements) {
    throw new Error('ad config must contain placements');
  }
  const now = Date.now();
  const json = JSON.stringify(jsonObj);
  const cur = db.prepare('SELECT version FROM ad_config WHERE id = 1').get();
  const nextVer = (cur ? cur.version : 0) + 1;
  const etag = `v${nextVer}-${require('crypto').createHash('md5').update(json).digest('hex').slice(0, 8)}`;
  const tx = db.transaction(() => {
    db.prepare(
      `INSERT INTO ad_config(id, version, json, etag, updated_at) VALUES (1, ?, ?, ?, ?)
       ON CONFLICT(id) DO UPDATE SET version=excluded.version, json=excluded.json, etag=excluded.etag, updated_at=excluded.updated_at`
    ).run(nextVer, json, etag, now);
    db.prepare(
      'INSERT OR REPLACE INTO ad_config_history(version, json, created_at) VALUES (?, ?, ?)'
    ).run(nextVer, json, now);
    db.prepare(
      'DELETE FROM ad_config_history WHERE version <= (SELECT MAX(version) FROM ad_config_history) - 30'
    ).run();
  });
  tx();
  return { version: nextVer, etag };
}

function listAdConfigHistory(limit = 30) {
  return db.prepare('SELECT version, created_at FROM ad_config_history ORDER BY version DESC LIMIT ?').all(limit);
}

function getAdConfigByVersion(version) {
  return db.prepare('SELECT version, json, created_at FROM ad_config_history WHERE version = ?').get(version);
}

function setAdConfigStaging(jsonObj, rolloutPct) {
  if (!jsonObj || typeof jsonObj !== 'object' || !jsonObj.placements) {
    throw new Error('staging config must contain placements');
  }
  const pct = Math.max(0, Math.min(100, parseInt(rolloutPct, 10) || 0));
  db.prepare('UPDATE ad_config SET staging_json=?, rollout_pct=? WHERE id=1')
    .run(JSON.stringify(jsonObj), pct);
}

function commitAdConfigStaging() {
  const row = db.prepare('SELECT staging_json, rollout_pct FROM ad_config WHERE id = 1').get();
  if (!row || !row.staging_json) throw new Error('no staging config to commit');
  const obj = JSON.parse(row.staging_json);
  saveAdConfig(obj);
  db.prepare('UPDATE ad_config SET staging_json=NULL, rollout_pct=0 WHERE id=1').run();
}

function abortAdConfigStaging() {
  db.prepare('UPDATE ad_config SET staging_json=NULL, rollout_pct=0 WHERE id=1').run();
}

module.exports = {
  init, DEFAULT_AD_CONFIG,
  getAdConfig, getAdConfigRaw, saveAdConfig,
  listAdConfigHistory, getAdConfigByVersion,
  setAdConfigStaging, commitAdConfigStaging, abortAdConfigStaging,
};
