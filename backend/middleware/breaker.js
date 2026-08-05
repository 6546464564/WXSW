// 万象书屋: 广告配置熔断 (circuit breaker) 共享状态
//
// 被两处共用:
//   - server.js 公开路由 GET /api/ad-config (应用熔断 + 生成 ETag)
//   - routes/admin.js 管理路由 ad-funnel 读取 / breaker/reset 重置
// 拆出去避免 admin 路由文件持有两份状态.

let db;
let breakerCache = { computedAt: 0, broken: [] };
const BREAKER_SUPPRESS_KV_KEY = 'breaker_suppress_until';
let breakerSuppressUntil = 0;

function setup(database) {
  db = database;
  const v = parseInt(db.kvGet(BREAKER_SUPPRESS_KV_KEY), 10);
  breakerSuppressUntil = Number.isFinite(v) && v > Date.now() ? v : 0;
}

function refreshBreakerIfStale() {
  const now = Date.now();
  if (now < breakerSuppressUntil) {
    breakerCache = { computedAt: now, broken: [] };
    return;
  }
  if (now - breakerCache.computedAt < 5 * 60 * 1000) return;
  try {
    breakerCache = {
      computedAt: now,
      broken: db.adProvidersToBreak({
        windowHours: 6, minSamples: 10, errorThreshold: 0.6,
        perPlacementMinSamples: { rewardedReadingUnlock: 3, chapterUnlock: 3 }
      }),
    };
    if (breakerCache.broken.length) {
      const logger = require('../logger');
      logger.warn('circuit breaker tripped', { broken: breakerCache.broken });
    }
  } catch (e) {
    const logger = require('../logger');
    logger.error('breaker compute failed', { msg: e.message });
  }
}

function applyBreaker(config) {
  refreshBreakerIfStale();
  if (!breakerCache.broken.length) return config;
  const cloned = JSON.parse(JSON.stringify(config));
  for (const b of breakerCache.broken) {
    const p = cloned.placements && cloned.placements[b.placement];
    if (!p || !Array.isArray(p.providers)) continue;
    for (const slot of p.providers) {
      if (slot.name === b.provider) slot.weight = 0;
    }
  }
  if (cloned.placements) {
    for (const [, p] of Object.entries(cloned.placements)) {
      if (!p || !Array.isArray(p.providers) || !p.enabled) continue;
      const totalWeight = p.providers.reduce((s, x) => s + (x.weight || 0), 0);
      if (totalWeight <= 0) p.enabled = false;
    }
  }
  return cloned;
}

function resetBreaker(minutes) {
  const previouslyBroken = breakerCache.broken.slice();
  breakerSuppressUntil = Date.now() + minutes * 60 * 1000;
  db.kvSet(BREAKER_SUPPRESS_KV_KEY, breakerSuppressUntil);
  breakerCache = { computedAt: Date.now(), broken: [] };
  return { suppressUntil: breakerSuppressUntil, suppressMinutes: minutes, previouslyBroken };
}

module.exports = {
  setup,
  refreshBreakerIfStale,
  applyBreaker,
  resetBreaker,
  get broken() { return breakerCache.broken; },
  get cache() { return breakerCache; },
  get suppressUntil() { return breakerSuppressUntil; },
  get BREAKER_SUPPRESS_KV_KEY() { return BREAKER_SUPPRESS_KV_KEY; },
};
