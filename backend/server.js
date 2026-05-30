// 万象书屋后端 - Express 入口
//
// 代码结构:
//   middleware/  — 限速、设备认证、admin 认证
//   models/     — 数据库 CRUD (通过 db.js 重导出)
//   jobs/       — 备份、告警、mirror 调度
//   本文件      — 路由注册 + 启动

const express = require('express');
const cookieParser = require('cookie-parser');
const crypto = require('crypto');
const path = require('path');
const db = require('./db');
const validator = require('./sourceValidator');
const logger = require('./logger');

// middleware
const { makeRateLimit, rateLimitSources, rateLimitPing, rateLimitAdConfig,
        rateLimitAdEvent,
        rateLimitFeedback, rateLimitSourceError } = require('./middleware/rateLimit');
const deviceAuth = require('./middleware/deviceAuth');
const adminAuth = require('./middleware/adminAuth');

// jobs
const { scheduleDailyBackup } = require('./jobs/backup');
const { scheduleMirrorJob, getNextRunAt } = require('./jobs/mirrorScheduler');
const qidianMirror = require('./jobs/qidianMirror');

// 初始化有状态中间件
deviceAuth.setup(db);
adminAuth.setup(db);

const { blockBlacklistedDevice, verifyDeviceToken, verifyDeviceTokenStrict } = deviceAuth;
const { loginRateLimit, recordLoginResult, requireAdmin, requireRole } = adminAuth;

const PORT = parseInt(process.env.PORT || '3000', 10);
const app = express();
app.set('trust proxy', 1);
app.set('x-powered-by', false);

// ═══════════════════ 全局中间件 ═══════════════════

// traceId + 请求日志
app.use((req, res, next) => {
  req.traceId = crypto.randomBytes(8).toString('hex');
  res.setHeader('X-Request-Id', req.traceId);
  const start = Date.now();
  res.on('finish', () => {
    const d = Date.now() - start;
    const lvl = d > 500 ? 'warn' : (res.statusCode >= 500 ? 'error' :
                res.statusCode >= 400 ? 'warn' : 'info');
    logger[lvl]('http', {
      t: req.traceId, m: req.method, p: req.path, s: res.statusCode,
      d, ip: req.ip, ua: (req.headers['user-agent'] || '').slice(0, 80),
      pf: req.platform,
    });
  });
  next();
});

// 平台识别
const _ALLOWED_PLATFORMS = new Set(['android', 'ios', 'web']);
app.use((req, res, next) => {
  const raw = (req.get('X-Platform') || '').toLowerCase().trim();
  req.platform = _ALLOWED_PLATFORMS.has(raw) ? raw : 'android';
  next();
});

// 全局 piggyback ETag
app.use('/api/', (req, res, next) => {
  try {
    res.set('X-Sources-Etag', db.getEnabledSourcesEtag(req.platform));
    res.append('Vary', 'X-Platform');
  } catch (_e) {}
  next();
});

// 30 分钟清一次老数据
setInterval(() => db.cleanupOldData(), 30 * 60 * 1000).unref?.();

// 启动定时任务
const backupCtl = scheduleDailyBackup(db);

// 访问日志
app.use(logger.httpAccess());

// 安全 / 性能中间件
const helmet = require('helmet');
const compression = require('compression');
const cors = require('cors');

app.use(helmet({
  contentSecurityPolicy: {
    useDefaults: false,
    directives: {
      defaultSrc: ["'self'"],
      scriptSrc: ["'self'", 'https://cdn.tailwindcss.com', 'https://cdn.jsdelivr.net', "'unsafe-inline'", "'unsafe-eval'"],
      scriptSrcAttr: ["'unsafe-inline'"],
      styleSrc: ["'self'", "'unsafe-inline'", 'https://cdn.jsdelivr.net'],
      imgSrc: ["'self'", 'data:', 'https:'],
      connectSrc: ["'self'", 'https://cdn.jsdelivr.net'],
      fontSrc: ["'self'", 'data:', 'https://cdn.jsdelivr.net'],
      workerSrc: ["'self'", 'blob:'],
      objectSrc: ["'none'"],
      frameAncestors: ["'none'"],
      baseUri: ["'self'"],
      formAction: ["'self'"]
    }
  },
  hsts: { maxAge: 31536000, includeSubDomains: true, preload: false },
  crossOriginEmbedderPolicy: false,
  crossOriginOpenerPolicy: false,
  crossOriginResourcePolicy: false
}));
app.use(compression({ threshold: 1024 }));
app.use('/api/', cors({ origin: false, credentials: false }));

// body parser (路径级分流)
const largeBodyRoutes = new Set([
  'POST /api/admin/sources',
  'POST /api/content-cache',
]);
app.use((req, res, next) => {
  const key = req.method + ' ' + req.path;
  const limit = largeBodyRoutes.has(key) ? '20mb' : '1mb';
  return express.json({ limit })(req, res, next);
});
const largeJson = (req, res, next) => next();
app.use(cookieParser());

// OpenAPI 文档
try {
  const swaggerUi = require('swagger-ui-express');
  const swaggerSpec = require('./swagger');
  app.use('/api/docs', swaggerUi.serve, swaggerUi.setup(swaggerSpec, {
    customSiteTitle: '万象书屋 API',
    swaggerOptions: { docExpansion: 'list' }
  }));
  app.get('/api/docs.json', (req, res) => res.json(swaggerSpec));
} catch (e) {
  console.warn('[swagger] not loaded:', e.message);
}

// TOTP (otplib v13 requires --experimental-require-module on Node 22+)
let _otplib = null;
try { _otplib = require('otplib'); } catch (e) {
  console.error('[TOTP] otplib load failed (likely ESM issue):', e.code || e.message);
  console.error('[TOTP] 2FA will be disabled. Start with: node --experimental-require-module server.js');
}
function totpVerify(token, secret) {
  if (!token || !secret || !_otplib) return false;
  return _otplib.verifySync({ token: String(token), secret, options: { window: 1 } });
}
function totpGenerateSecret() {
  if (!_otplib) throw new Error('otplib not loaded, 2FA unavailable');
  return _otplib.generateSecret();
}
function totpGenerateUri(label, issuer, secret) {
  if (!_otplib) throw new Error('otplib not loaded, 2FA unavailable');
  return _otplib.generateURI({ label, issuer, secret });
}

// 设备 token HMAC
const DEVICE_TOKEN_SECRET = process.env.DEVICE_TOKEN_SECRET ||
  'dev-only-CHANGE-IN-PRODUCTION-please-' + (require('os').hostname());
if (DEVICE_TOKEN_SECRET.startsWith('dev-only-')) {
  console.warn('[security] DEVICE_TOKEN_SECRET not set, using insecure dev fallback');
}
function computeDeviceTokenHash(deviceId, installTs) {
  return crypto.createHmac('sha256', DEVICE_TOKEN_SECRET)
    .update(`${deviceId}|${installTs}`)
    .digest('hex');
}

// ═══════════════════ 公开 API ═══════════════════

// --- 设备注册 ---
app.post('/api/device/register', makeRateLimit({ windowMs: 60_000, max: 3, keyPrefix: 'reg:' }),
  blockBlacklistedDevice, (req, res) => {
  const did = (req.body && (req.body.device_id || req.body.deviceId));
  if (!did || typeof did !== 'string' || did.length < 8 || did.length > 128) {
    return res.status(400).json({ ok: false, msg: 'invalid device_id' });
  }
  const existing = db.getDeviceTokenHash(did);
  const reissue = req.query.reissue === '1';
  if (existing && !reissue) return res.status(409).json({ ok: false, msg: 'already registered' });
  const installTs = Date.now();
  const tokenHash = computeDeviceTokenHash(did, installTs);
  db.upsertDeviceToken({
    deviceId: did, tokenHash, installTs,
    ua: (req.headers['user-agent'] || '').slice(0, 200), ip: req.ip,
    platform: req.platform,
  });
  res.json({ ok: true, token: tokenHash, install_ts: installTs, platform: req.platform });
});

// --- 健康检查 ---
app.get('/api/health', (req, res) => {
  const checks = {};
  let allOk = true;
  const t0 = Date.now();
  try {
    db.__db.prepare('SELECT 1').get();
    checks.db = { ok: true, latency_ms: Date.now() - t0 };
  } catch (e) {
    checks.db = { ok: false, error: e.message };
    allOk = false;
  }
  const mem = process.memoryUsage();
  const rssMb = Math.round(mem.rss / 1024 / 1024);
  checks.mem = { ok: rssMb < 500, rss_mb: rssMb, heap_used_mb: Math.round(mem.heapUsed / 1024 / 1024) };
  if (!checks.mem.ok) allOk = false;
  try {
    const fs = require('fs');
    const dataDir = process.env.DB_PATH ? path.dirname(process.env.DB_PATH) : path.join(__dirname, 'data');
    const stat = fs.statfsSync ? fs.statfsSync(dataDir) : null;
    if (stat) {
      const freeMb = Math.round(stat.bsize * stat.bavail / 1024 / 1024);
      checks.disk = { ok: freeMb > 100, free_mb: freeMb };
      if (!checks.disk.ok) allOk = false;
    }
  } catch (_) {}
  checks.uptime_s = Math.round(process.uptime());
  res.status(allOk ? 200 : 503).json({ ok: allOk, checks, now: Date.now() });
});

// --- Prometheus metrics ---
app.get('/metrics', (req, res) => {
  const lines = [];
  const mem = process.memoryUsage();
  function metric(name, help, type, value, labels = '') {
    lines.push(`# HELP ${name} ${help}`);
    lines.push(`# TYPE ${name} ${type}`);
    lines.push(`${name}${labels} ${value}`);
  }
  metric('wanxiang_uptime_seconds', 'Process uptime seconds', 'counter', Math.round(process.uptime()));
  metric('wanxiang_memory_rss_bytes', 'Resident set size in bytes', 'gauge', mem.rss);
  metric('wanxiang_memory_heap_used_bytes', 'V8 heap used in bytes', 'gauge', mem.heapUsed);
  try {
    metric('wanxiang_active_devices_today', 'Distinct devices visited today (UTC+8)', 'gauge', Number(db.statsToday()) || 0);
    const hb = db.__db.prepare('SELECT COUNT(*) AS n FROM heartbeats WHERE ts > ?').get(Date.now() - 86400_000).n;
    metric('wanxiang_heartbeats_24h', 'Heartbeats received in last 24h', 'gauge', Number(hb) || 0);
    metric('wanxiang_online_5m', 'Distinct devices with heartbeat in last 5 minutes', 'gauge', Number(db.statsOnline()) || 0);
  } catch (_) {}
  try {
    const sourceCount = db.__db.prepare('SELECT COUNT(*) AS n FROM book_sources WHERE enabled = 1').get();
    metric('wanxiang_book_sources_active', 'Active book sources count', 'gauge', sourceCount.n);
  } catch (_) {}
  try {
    const r = db.__db.prepare("SELECT COUNT(*) AS n FROM feedback WHERE status = 'pending'").get();
    metric('wanxiang_feedback_pending', 'Pending feedback count', 'gauge', r.n);
  } catch (_) {}
  res.set('Content-Type', 'text/plain; version=0.0.4');
  res.send(lines.join('\n') + '\n');
});

// --- 版本检查 + 公告 ---
app.get('/api/version-check', (req, res) => {
  const code = parseInt(req.query.code, 10) || 0;
  const v = db.getAppVersion();
  res.json({
    latestCode: v.latest_code, latestName: v.latest_name,
    minRequiredCode: v.min_required_code,
    forceUpgrade: code > 0 && v.min_required_code > 0 && code < v.min_required_code,
    needUpgrade: code > 0 && v.latest_code > 0 && code < v.latest_code,
    changelog: v.changelog || '', apkUrl: v.apk_url || '', marketUrl: v.market_url || ''
  });
});

app.get('/api/announcement', (req, res) => {
  const versionCode = parseInt(req.query.versionCode, 10) || 0;
  const list = db.listActiveAnnouncements(versionCode);
  const etag = '"' + crypto.createHash('md5').update(JSON.stringify(list)).digest('hex').slice(0, 16) + '"';
  res.set('Cache-Control', 'public, max-age=60');
  res.set('ETag', etag);
  if (req.get('If-None-Match') === etag) return res.status(304).end();
  res.json({ ok: true, list });
});

// --- 书源 ---
app.get('/api/sources', rateLimitSources, blockBlacklistedDevice, verifyDeviceToken, (req, res) => {
  const healthyOnly = req.query.healthy === '1' || req.query.healthy === 'true' || req.query.hideBroken === '1';
  const etag = db.getEnabledSourcesEtag(req.platform, { healthyOnly });
  res.set('Cache-Control', 'public, max-age=300');
  res.set('ETag', etag);
  res.vary('X-Platform');
  res.vary('X-Source-Health');
  if (req.get('If-None-Match') === etag) return res.status(304).end();
  res.json(db.listEnabledSourcesJson(req.platform, { healthyOnly }));
});

app.post('/api/source-error', rateLimitSourceError, blockBlacklistedDevice, verifyDeviceTokenStrict, (req, res) => {
  try {
    const r = db.recordSourceErrorEvent({
      ...(req.body || {}),
      deviceId: (req.body && req.body.deviceId) || (req.body && req.body.device_id) || req.get('X-Device-Id'),
      platform: (req.body && req.body.platform) || req.platform
    }, req.ip);
    res.json(r);
  } catch (e) {
    res.status(400).json({ ok: false, msg: e.message || 'invalid source error' });
  }
});

// --- 书籍正文内容缓存 ---
app.get('/api/content-cache', rateLimitSources, blockBlacklistedDevice, verifyDeviceToken, (req, res) => {
  const title = (req.query.title || '').trim();
  const author = (req.query.author || '').trim();
  const chapterIndex = parseInt(req.query.chapterIndex, 10);
  if (!title) return res.status(400).json({ ok: false, msg: 'title required' });
  if (!Number.isFinite(chapterIndex) || chapterIndex < 0) return res.status(400).json({ ok: false, msg: 'valid chapterIndex required' });
  const row = db.getContentCache(title, author, chapterIndex);
  if (!row) return res.json({ ok: true, hit: false });
  res.set('Cache-Control', 'public, max-age=3600');
  res.json({ ok: true, hit: true, chapter_title: row.chapter_title, content: row.content });
});
app.post('/api/content-cache', rateLimitSourceError, blockBlacklistedDevice, verifyDeviceToken, (req, res) => {
  const chapters = req.body && req.body.chapters;
  if (!Array.isArray(chapters) || chapters.length === 0) return res.status(400).json({ ok: false, msg: 'chapters array required' });
  const capped = chapters.slice(0, 20);
  const upserted = db.bulkUpsertContentCache(capped);
  // 同步元数据到 book_metadata 表
  const meta = req.body.metadata;
  if (meta && meta.title) {
    try { db.upsertMetadata(meta); } catch {}
  }
  res.json({ ok: true, upserted });
});

// --- 书籍元数据缓存 (Cache-on-Search) ---
app.get('/api/search-cache', rateLimitSources, blockBlacklistedDevice, verifyDeviceToken, (req, res) => {
  const keyword = (req.query.keyword || '').trim();
  if (!keyword || keyword.length < 1) return res.status(400).json({ ok: false, msg: 'keyword required' });
  if (keyword.length > 100) return res.status(400).json({ ok: false, msg: 'keyword too long' });
  const limit = Math.max(1, Math.min(50, parseInt(req.query.limit, 10) || 20));
  const results = db.searchMetadataCache(keyword, limit);
  res.set('Cache-Control', 'public, max-age=300');
  res.json({ ok: true, count: results.length, results });
});
app.post('/api/search-cache', rateLimitSourceError, blockBlacklistedDevice, verifyDeviceToken, (req, res) => {
  const books = req.body && req.body.books;
  if (!Array.isArray(books) || books.length === 0) return res.status(400).json({ ok: false, msg: 'books array required' });
  const capped = books.slice(0, 50);
  const upserted = db.bulkUpsertMetadata(capped);
  res.json({ ok: true, upserted });
});

// --- 书城 mirror ---
app.get('/api/bookstore/mirror', rateLimitSources, blockBlacklistedDevice, verifyDeviceToken, (req, res) => {
  const row = db.getLatestBookstoreMirror();
  if (!row) return res.status(503).json({ ok: false, msg: 'mirror not ready, fallback to direct fetch' });
  res.set('ETag', row.etag);
  res.set('Cache-Control', 'public, max-age=600');
  res.set('Content-Type', 'application/json; charset=utf-8');
  if (req.get('If-None-Match') === row.etag) return res.status(304).end();
  res.send(row.payload);
});

// --- 心跳 ---
app.post('/api/ping', rateLimitPing, blockBlacklistedDevice, verifyDeviceToken, (req, res) => {
  const deviceId = (req.body && typeof req.body.device_id === 'string' && req.body.device_id) ||
    req.get('X-Device-Id') || null;
  if (!deviceId) return res.status(400).json({ ok: false, msg: 'device_id required' });
  if (deviceId.length > 128) return res.status(400).json({ ok: false, msg: 'device_id too long' });
  db.recordPing(deviceId);
  res.json({ ok: true });
});

// --- 广告配置 + 熔断 ---
let breakerCache = { computedAt: 0, broken: [] };
const BREAKER_SUPPRESS_KV_KEY = 'breaker_suppress_until';
let breakerSuppressUntil = (() => {
  const v = parseInt(db.kvGet(BREAKER_SUPPRESS_KV_KEY), 10);
  return Number.isFinite(v) && v > Date.now() ? v : 0;
})();

function refreshBreakerIfStale() {
  const now = Date.now();
  if (now < breakerSuppressUntil) {
    breakerCache = { computedAt: now, broken: [] };
    return;
  }
  if (now - breakerCache.computedAt < 5 * 60_000) return;
  try {
    breakerCache = {
      computedAt: now,
      broken: db.adProvidersToBreak({
        windowHours: 6, minSamples: 10, errorThreshold: 0.6,
        perPlacementMinSamples: { rewardedReadingUnlock: 3, chapterUnlock: 3 }
      }),
    };
    if (breakerCache.broken.length) logger.warn('circuit breaker tripped', { broken: breakerCache.broken });
  } catch (e) {
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

app.get('/api/ad-config', rateLimitAdConfig, (req, res) => {
  const deviceId = req.get('X-Device-Id') || req.query.device_id;
  const row = db.getAdConfig(deviceId, req.platform);
  res.set('Cache-Control', 'public, max-age=300');
  if (row.isStaging) res.set('X-Rollout-Bucket', 'staging');
  refreshBreakerIfStale();
  const breakerKey = breakerCache.broken.length
    ? '-b' + crypto.createHash('md5').update(JSON.stringify(breakerCache.broken)).digest('hex').slice(0, 6)
    : '';
  const effectiveEtag = row.etag + breakerKey;
  res.set('ETag', effectiveEtag);
  if (req.get('If-None-Match') === effectiveEtag) return res.status(304).end();
  if (breakerCache.broken.length) {
    const cfg = applyBreaker(JSON.parse(row.json));
    res.set('Content-Type', 'application/json; charset=utf-8');
    res.send(JSON.stringify({ version: row.version, etag: effectiveEtag, config: cfg }));
  } else {
    res.set('Content-Type', 'application/json; charset=utf-8');
    res.send(`{"version":${row.version},"etag":${JSON.stringify(effectiveEtag)},"config":${row.json}}`);
  }
});

// --- 广告事件上报 ---
app.post('/api/ad-event', rateLimitAdEvent, blockBlacklistedDevice, verifyDeviceToken, (req, res) => {
  const b = req.body || {};
  try {
    db.recordAdEvent({
      placement: b.placement, provider: b.provider, type: b.type,
      errCode: b.errCode, errMsg: b.errMsg, deviceId: b.deviceId,
      appVer: b.appVer, platform: req.platform,
    });
    res.json({ ok: true });
  } catch (e) {
    res.status(400).json({ ok: false, msg: e.message });
  }
});

app.post('/api/ad-events', rateLimitAdEvent, blockBlacklistedDevice, verifyDeviceToken, (req, res) => {
  const arr = Array.isArray(req.body) ? req.body : req.body?.events;
  if (!Array.isArray(arr)) return res.status(400).json({ ok: false, msg: 'array expected' });
  if (arr.length > 50) return res.status(400).json({ ok: false, msg: 'too many events' });
  let ok = 0, bad = 0, firstError = null, firstBadEvent = null;
  for (const e of arr) {
    try {
      db.recordAdEvent({ ...e, platform: req.platform });
      ok++;
    } catch (err) {
      bad++;
      if (!firstError) { firstError = err.message; firstBadEvent = e; }
    }
  }
  if (bad > 0) {
    logger.warn('ad-events batch had rejected items', {
      t: req.traceId, accepted: ok, rejected: bad, total: arr.length,
      firstError, sampleEvent: firstBadEvent ? JSON.stringify(firstBadEvent).slice(0, 200) : null
    });
  }
  res.json({ ok: true, accepted: ok, rejected: bad, total: arr.length });
});


// --- 反馈 ---
app.post('/api/feedback', rateLimitFeedback, blockBlacklistedDevice, verifyDeviceTokenStrict, (req, res) => {
  const b = req.body || {};
  try {
    const r = db.recordFeedback({
      type: b.type, content: b.content, contact: b.contact,
      deviceId: b.deviceId, appVer: b.appVer, ip: req.ip, platform: req.platform,
    });
    res.json({ ok: true, id: r.id });
  } catch (e) {
    res.status(400).json({ ok: false, msg: e.message });
  }
});

// --- IAP ---
const _IAP_PROD_URL = 'https://buy.itunes.apple.com/verifyReceipt';
const _IAP_SANDBOX_URL = 'https://sandbox.itunes.apple.com/verifyReceipt';
const _IAP_RATE = makeRateLimit({ windowMs: 60_000, max: 10, keyPrefix: 'iap:' });

function _mapProductIdToEntitlement(productId) {
  if (!productId) return null;
  if (productId.endsWith('.lifetime') || productId === 'com.wanxiang.adfree.lifetime') return 'lifetime';
  if (productId.includes('adfree') || productId.includes('vip')) return 'vip';
  return null;
}

async function _verifyAppleReceipt(receiptData, sandboxFirst = false) {
  const body = JSON.stringify({
    'receipt-data': receiptData,
    'password': process.env.APPLE_SHARED_SECRET || '',
    'exclude-old-transactions': true,
  });
  const tryUrl = async (url) => {
    const r = await fetch(url, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body, signal: AbortSignal.timeout(10_000),
    });
    return r.json();
  };
  let firstUrl = sandboxFirst ? _IAP_SANDBOX_URL : _IAP_PROD_URL;
  let resp = await tryUrl(firstUrl);
  if (resp.status === 21007 && firstUrl === _IAP_PROD_URL) {
    resp = await tryUrl(_IAP_SANDBOX_URL); resp.__sandbox = true;
  } else if (resp.status === 21008 && firstUrl === _IAP_SANDBOX_URL) {
    resp = await tryUrl(_IAP_PROD_URL);
  } else if (firstUrl === _IAP_SANDBOX_URL) {
    resp.__sandbox = true;
  }
  return resp;
}

// IAP verify 暂未上线, 保留路由占位避免 404 噪音
app.post('/api/iap/verify', _IAP_RATE, blockBlacklistedDevice, verifyDeviceToken, async (req, res) => {
  return res.status(503).json({ ok: false, msg: 'IAP verification not yet enabled' });
});

app.get('/api/iap/entitlements', blockBlacklistedDevice, verifyDeviceToken, (req, res) => {
  const did = req.get('X-Device-Id') || req.query.device_id;
  if (!did) return res.status(400).json({ ok: false, msg: 'device_id required' });
  const list = db.listActiveIapForDevice(String(did));
  const entitlements = Array.from(new Set(
    list.map(r => _mapProductIdToEntitlement(r.product_id)).filter(Boolean)
  ));
  res.json({
    ok: true, entitlements,
    receipts: list.map(r => ({
      product_id: r.product_id, expires_at: r.expires_at,
      verified_at: r.verified_at, sandbox: !!r.sandbox,
    }))
  });
});

// --- 推广代理码 (客户端) ---
app.get('/api/promo/codes', blockBlacklistedDevice, (req, res) => {
  const codes = db.listPromoCodes({ enabledOnly: true }).map(c => ({
    code: c.code, agent_name: c.agent_name, max_uses: c.max_uses,
    single_device: c.single_device === 1,
    expires_at: c.expires_at ? new Date(c.expires_at).toISOString() : null,
  }));
  res.json({ ok: true, codes });
});

app.get('/api/promo/agent-stats', (req, res) => {
  const code = (req.query.code || '').trim();
  if (!code) return res.status(400).json({ ok: false, msg: '请输入推广码' });
  const codeRow = db.listPromoCodes().find(c => c.code.toLowerCase() === code.toLowerCase());
  if (!codeRow) return res.json({ ok: false, msg: '推广码不存在' });
  if (!codeRow.enabled) return res.json({ ok: false, msg: '该推广码已停用' });
  const stats = db.promoCodeStats(code);
  const usages = (stats.usages || []).map(u => ({
    device_model: u.device_model || '未知设备', system_version: u.system_version || '', ts: u.ts,
  }));
  res.json({
    ok: true, code: codeRow.code, agentName: codeRow.agent_name,
    totalUses: stats.totalUses, uniqueDevices: stats.uniqueDevices,
    totalAttempts: stats.totalAttempts, usages,
  });
});

app.post('/api/promo/attempt', blockBlacklistedDevice, (req, res) => {
  const { code, success, device_id, device_model } = req.body || {};
  if (!code || !device_id) return res.status(400).json({ ok: false, msg: 'code & device_id required' });
  db.recordPromoAttempt({ code, deviceId: device_id, deviceModel: device_model, success: !!success, ip: req.ip });
  res.json({ ok: true });
});

app.post('/api/promo/usage', blockBlacklistedDevice, (req, res) => {
  const { code, agent_name, device_id, device_model, system_version } = req.body || {};
  if (!code || !device_id) return res.status(400).json({ ok: false, msg: 'code & device_id required' });
  const ok = db.recordPromoUsage({ code, agentName: agent_name, deviceId: device_id, deviceModel: device_model, systemVersion: system_version, ip: req.ip });
  res.json({ ok });
});

// ═══════════════════ 管理 API ═══════════════════

// --- 登录/登出 ---
app.post('/api/admin/login', loginRateLimit, async (req, res) => {
  const { username, password, totp } = req.body || {};
  const pwd = password;
  if (username) {
    const lock = db.isAccountLocked(username, { windowMin: 5, threshold: 5, lockMin: 30 });
    if (lock.locked) {
      const left = Math.ceil((lock.unlock_at - Date.now()) / 60_000);
      logger.warn('admin login locked', { t: req.traceId, username, ip: req.ip, unlock_in_min: left });
      return res.status(423).json({ ok: false, msg: `account locked due to too many failures, try again in ${left} minutes`, unlock_at: lock.unlock_at });
    }
    const user = await db.verifyAdminUser(username, pwd);
    if (!user) {
      recordLoginResult(res, false);
      db.recordLoginFailure(username, req.ip);
      return res.status(401).json({ ok: false, msg: 'wrong username or password' });
    }
    if (user.totp_enabled) {
      if (!totp) return res.status(401).json({ ok: false, msg: 'totp required', need_totp: true });
      if (!totpVerify(totp, user.totp_secret)) {
        recordLoginResult(res, false);
        db.recordLoginFailure(username, req.ip);
        return res.status(401).json({ ok: false, msg: 'wrong totp code' });
      }
    }
    recordLoginResult(res, true);
    db.clearLoginFailures(username);
    db.recordAdminLogin(username, req.ip);
    const token = db.createSession(req.ip || '', req.get('User-Agent') || '', { username, role: user.role });
    res.cookie('adm', token, { httpOnly: true, sameSite: 'strict', maxAge: 7 * 86400 * 1000, secure: !!process.env.SECURE_COOKIE });
    return res.json({ ok: true, role: user.role });
  }
  const ok = await db.verifyAdminPassword(pwd);
  if (!ok) { recordLoginResult(res, false); return res.status(401).json({ ok: false, msg: 'wrong password' }); }
  recordLoginResult(res, true);
  const token = db.createSession(req.ip || '', req.get('User-Agent') || '');
  res.cookie('adm', token, { httpOnly: true, sameSite: 'strict', maxAge: 7 * 86400 * 1000, secure: !!process.env.SECURE_COOKIE });
  res.json({ ok: true, role: 'super' });
});

app.post('/api/admin/logout', requireAdmin, (req, res) => {
  db.destroySession(req.cookies.adm);
  res.clearCookie('adm');
  res.json({ ok: true });
});

app.post('/api/admin/password', loginRateLimit, requireAdmin, async (req, res) => {
  const { oldPassword, newPassword } = req.body || {};
  const ok = await db.verifyAdminPassword(oldPassword);
  if (!ok) { recordLoginResult(res, false); return res.status(401).json({ ok: false, msg: 'wrong old password' }); }
  recordLoginResult(res, true);
  if (!newPassword || newPassword.length < 8) return res.status(400).json({ ok: false, msg: 'new password must be >= 8 chars' });
  if (newPassword === oldPassword) return res.status(400).json({ ok: false, msg: 'new password must differ from old' });
  await db.setAdminPassword(newPassword);
  db.destroyAllSessions();
  res.clearCookie('adm');
  res.json({ ok: true });
});

app.get('/api/admin/me', (req, res) => {
  const tok = req.cookies && req.cookies.adm;
  res.json({ ok: db.isValidSession(tok, req.get('User-Agent') || '') });
});

// --- admin 书源管理 ---
app.get('/api/admin/sources', requireAdmin, (req, res) => res.json(db.listAllSources()));
app.get('/api/admin/sources/raw', requireAdmin, (req, res) => {
  const row = db.getSource(req.query.url);
  if (!row) return res.status(404).json({ ok: false });
  res.set('Content-Type', 'application/json'); res.send(row.json);
});
app.post('/api/admin/sources', largeJson, requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  try {
    if (Array.isArray(req.body)) {
      const r = db.bulkUpsert(req.body);
      return res.json({ ok: true, ...r });
    }
    if (req.body && typeof req.body === 'object') {
      const r = db.upsertSource(req.body);
      return res.json({ ok: true, ...r });
    }
    return res.status(400).json({ ok: false, msg: 'JSON object or array expected' });
  } catch (err) {
    return res.status(400).json({ ok: false, msg: err.message || 'invalid book source' });
  }
});
app.delete('/api/admin/sources', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  const url = req.query.url;
  if (!url) return res.status(400).json({ ok: false });
  const n = db.deleteSource(url);
  res.json({ ok: true, deleted: n });
});
app.post('/api/admin/sources/check', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  try {
    const r = db.runSourceStaticCheck({ platform: req.body?.platform || req.query.platform || 'ios', sampleKeyword: req.body?.sampleKeyword || req.query.sampleKeyword || '斗破苍穹', url: req.body?.url || req.query.url || null });
    const { ok: okCount, error: errorCount, ...rest } = r;
    res.json({ ok: true, okCount, errorCount, ...rest });
  } catch (e) { res.status(400).json({ ok: false, msg: e.message || 'check failed' }); }
});
app.patch('/api/admin/sources/enabled', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  const { url, enabled } = req.body || {};
  if (!url) return res.status(400).json({ ok: false });
  db.setEnabled(url, !!enabled);
  res.json({ ok: true });
});
app.patch('/api/admin/sources/platforms', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  const { url, platforms } = req.body || {};
  if (!url) return res.status(400).json({ ok: false, msg: 'url required' });
  if (!Array.isArray(platforms)) return res.status(400).json({ ok: false, msg: 'platforms must be an array' });
  try {
    const n = db.setSourcePlatforms(url, platforms);
    if (n === 0) return res.status(404).json({ ok: false, msg: 'source not found' });
    res.json({ ok: true, changed: n });
  } catch (err) { res.status(400).json({ ok: false, msg: err.message || 'invalid' }); }
});
app.patch('/api/admin/sources/platforms/bulk', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  const { urls, platform, op } = req.body || {};
  if (!Array.isArray(urls) || urls.length === 0) return res.status(400).json({ ok: false, msg: 'urls required' });
  if (!['android', 'ios', 'web'].includes(platform)) return res.status(400).json({ ok: false, msg: 'platform invalid' });
  if (!['add', 'remove'].includes(op)) return res.status(400).json({ ok: false, msg: 'op must be add|remove' });
  let changed = 0;
  for (const url of urls) {
    const row = db.getSource(url);
    if (!row) continue;
    const cur = String(row.platforms || '').split(',').map(s => s.trim()).filter(Boolean);
    let next;
    if (op === 'add') { if (cur.includes(platform)) continue; next = [...cur, platform]; }
    else { if (!cur.includes(platform)) continue; next = cur.filter(p => p !== platform); }
    db.setSourcePlatforms(url, next);
    changed++;
  }
  res.json({ ok: true, changed });
});
app.patch('/api/admin/sources/group-enabled', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  const { group, enabled } = req.body || {};
  if (typeof group !== 'string') return res.status(400).json({ ok: false, msg: 'group required' });
  const rows = db.__db.prepare('SELECT url, json FROM book_sources').all();
  let affected = 0;
  const tx = db.__db.transaction(() => {
    for (const r of rows) {
      try {
        const src = JSON.parse(r.json);
        const tokens = String(src.bookSourceGroup || '').split(/[,;，；]/).map(s => s.trim());
        if (!tokens.includes(group)) continue;
        db.__db.prepare('UPDATE book_sources SET enabled=?, updated_at=? WHERE url=?').run(enabled ? 1 : 0, Date.now(), r.url);
        affected++;
      } catch {}
    }
  });
  tx();
  db.invalidateSourcesCache();
  res.json({ ok: true, affected });
});
app.get('/api/admin/sources/groups', requireAdmin, (req, res) => {
  const rows = db.__db.prepare('SELECT json FROM book_sources').all();
  const set = new Set();
  for (const r of rows) {
    try { for (const g of String(JSON.parse(r.json).bookSourceGroup || '').split(/[,;，；]/)) { const t = g.trim(); if (t) set.add(t); } } catch {}
  }
  res.json({ ok: true, groups: [...set].sort() });
});
app.get('/api/admin/sources/export', requireAdmin, (req, res) => {
  const rows = db.__db.prepare('SELECT json FROM book_sources ORDER BY updated_at DESC').all();
  const body = '[' + rows.map(r => r.json).join(',') + ']';
  const fname = `wanxiang-sources-${new Date().toISOString().slice(0,10)}.json`;
  res.set('Content-Type', 'application/json; charset=utf-8');
  res.set('Content-Disposition', `attachment; filename="${fname}"`);
  res.send(body);
});
app.get('/api/admin/sources/validate', requireAdmin, async (req, res) => {
  const url = req.query.url;
  if (!url) return res.status(400).json({ ok: false, msg: 'url required' });
  const row = db.getSource(url);
  if (!row) return res.status(404).json({ ok: false, msg: 'source not found' });
  try {
    const src = JSON.parse(row.json);
    const result = await validator.validateOne(src, { checkReach: true, checkSearch: String(req.query.search || '') === '1', timeoutMs: 6000 });
    res.json({ ok: true, result });
  } catch (e) { res.status(500).json({ ok: false, msg: e.message }); }
});
app.get('/api/admin/sources/validate-all', requireAdmin, async (req, res) => {
  const checkSearch = String(req.query.search || '') === '1';
  const list = db.listAllSources();
  const sources = list.map(meta => { const row = db.getSource(meta.url); try { return JSON.parse(row.json); } catch { return { bookSourceUrl: meta.url, bookSourceName: meta.name }; } });
  try {
    const summary = await validator.validateAll(sources, { concurrency: 8, checkReach: true, checkSearch, timeoutMs: 6000 });
    res.json({ ok: true, ...summary });
  } catch (e) { res.status(500).json({ ok: false, msg: e.message }); }
});

// --- admin 统计 ---
app.get('/api/admin/stats', requireAdmin, (req, res) => {
  const days = parseInt(req.query.days, 10) || 7;
  res.json({ online: db.statsOnline(), today: db.statsToday(), week: db.statsWeek(), month: db.statsMonth(), daily: db.statsDailyCurve(days) });
});

// --- admin 书城 mirror ---
app.get('/api/admin/bookstore-mirror/status', requireAdmin, (req, res) => {
  const latest = db.getLatestBookstoreMirror();
  const recent = db.listRecentBookstoreMirror(3);
  res.json({
    latest: latest ? { version: latest.version, fetched_at: latest.fetched_at, etag: latest.etag, source: latest.source, payload_size: latest.payload?.length || 0 } : null,
    nextScheduledAt: getNextRunAt() || null,
    recent: recent.map(r => ({ id: r.id, version: r.version, fetched_at: r.fetched_at, ok: r.ok === 1, err_msg: r.err_msg, payload_size: r.payload_size, source: r.source })),
  });
});
app.post('/api/admin/bookstore-mirror/refresh', requireAdmin, requireRole(['super', 'operator']), async (req, res) => {
  try { const result = await qidianMirror.fetchAndCache(db); logger.info('mirror manual refresh ok', result); res.json({ ok: true, ...result }); }
  catch (e) { qidianMirror.recordFailure(db, e); logger.warn('mirror manual refresh failed', { msg: e.message }); res.status(500).json({ ok: false, msg: e.message }); }
});
/** 万象书屋: 从可信 admin 客户端上传完整 mirror JSON (含 ranksFemale). SSH 不可达时的备用发布路径. */
app.post('/api/admin/bookstore-mirror/publish', requireAdmin, requireRole(['super', 'operator']), largeJson, (req, res) => {
  const payload = req.body;
  if (!payload || typeof payload !== 'object' || !payload.ranks) {
    return res.status(400).json({ ok: false, msg: 'body must be mirror payload with ranks' });
  }
  const validation = qidianMirror.validateMirrorPayload(payload);
  if (!validation.ok) {
    return res.status(400).json({ ok: false, msg: 'mirror validation failed', errors: validation.errors });
  }
  const payloadStr = JSON.stringify(payload);
  const etag = crypto.createHash('md5').update(payloadStr).digest('hex');
  const totalBooks = Object.values(payload.ranks).reduce((s, l) => s + (l?.length || 0), 0)
    + (payload.yuepiaoTop50?.length || 0)
    + Object.values(payload.finish || {}).reduce((s, l) => s + (l?.length || 0), 0)
    + (payload.ranksFemale
      ? Object.values(payload.ranksFemale).reduce((s, l) => s + (l?.length || 0), 0)
      : 0)
    + (payload.yuepiaoTop50Female?.length || 0)
    + (payload.ranksPublish
      ? Object.values(payload.ranksPublish).reduce((s, l) => s + (l?.length || 0), 0)
      : 0)
    + (payload.yuepiaoTop50Publish?.length || 0);
  db.insertBookstoreMirror({
    version: payload.version || Date.now(),
    payload: payloadStr,
    etag,
    fetched_at: Date.now(),
    source: payload.source || 'admin-publish',
    ok: 1,
    err_msg: null,
  });
  db.cleanupOldBookstoreMirror(3);
  logger.info('mirror admin publish ok', { totalBooks, etag, hasFemale: !!payload.ranksFemale });
  res.json({ ok: true, totalBooks, etag, version: payload.version || Date.now(), hasFemale: !!payload.ranksFemale });
});
app.get('/api/admin/bookstore-mirror/preview', requireAdmin, (req, res) => {
  const row = db.getLatestBookstoreMirror();
  res.set('Content-Type', 'application/json; charset=utf-8'); res.send(row?.payload || '{}');
});

// --- admin 广告配置 ---
app.get('/api/admin/ad-config', requireAdmin, (req, res) => {
  const row = db.getAdConfigRaw();
  res.json({ version: row.version, etag: row.etag, config: JSON.parse(row.json) });
});
app.post('/api/admin/ad-config', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  try {
    if (!req.body || typeof req.body !== 'object') return res.status(400).json({ ok: false, msg: 'JSON object expected' });
    const r = db.saveAdConfig(req.body);
    res.json({ ok: true, ...r });
  } catch (err) { res.status(400).json({ ok: false, msg: err.message || 'invalid ad config' }); }
});
app.get('/api/admin/ad-config/history', requireAdmin, (req, res) => res.json(db.listAdConfigHistory(30)));
app.get('/api/admin/ad-config/version/:v', requireAdmin, (req, res) => {
  const v = parseInt(req.params.v, 10);
  if (!Number.isFinite(v)) return res.status(400).json({ ok: false });
  const row = db.getAdConfigByVersion(v);
  if (!row) return res.status(404).json({ ok: false });
  res.json({ version: row.version, createdAt: row.created_at, config: JSON.parse(row.json) });
});
app.put('/api/admin/ad-config/staging', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  try { const { config, rolloutPct } = req.body || {}; db.setAdConfigStaging(config, rolloutPct); res.json({ ok: true }); }
  catch (e) { res.status(400).json({ ok: false, error: e.message }); }
});
app.post('/api/admin/ad-config/staging/commit', requireAdmin, requireRole(['super']), (req, res) => {
  try { db.commitAdConfigStaging(); res.json({ ok: true }); }
  catch (e) { res.status(400).json({ ok: false, error: e.message }); }
});
app.post('/api/admin/ad-config/staging/abort', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  db.abortAdConfigStaging(); res.json({ ok: true });
});
app.get('/api/admin/ad-funnel', requireAdmin, (req, res) => {
  const hours = Math.max(1, Math.min(24 * 30, parseInt(req.query.hours, 10) || 24));
  res.json({ ok: true, hours, funnel: db.adEventFunnel({ hours }), breaker: breakerCache });
});
app.post('/api/admin/breaker/reset', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  const minutes = Math.max(1, Math.min(360, parseInt(req.query.minutes, 10) || 30));
  const before = breakerCache.broken.slice();
  breakerSuppressUntil = Date.now() + minutes * 60_000;
  db.kvSet(BREAKER_SUPPRESS_KV_KEY, breakerSuppressUntil);
  breakerCache = { computedAt: Date.now(), broken: [] };
  res.json({ ok: true, previouslyBroken: before, suppressMinutes: minutes, suppressUntil: breakerSuppressUntil, msg: `breaker suppressed for ${minutes} minutes` });
});
app.post('/api/admin/backup/now', requireAdmin, requireRole(['super']), async (req, res) => {
  try { await backupCtl.runBackupOnce(); res.json({ ok: true, msg: 'backup triggered' }); }
  catch (e) { res.status(500).json({ ok: false, error: e.message }); }
});


// --- admin 缓存统计 ---
app.get('/api/admin/metadata/stats', requireAdmin, (req, res) => {
  const total = db.metadataCount();
  const hot = db.topHotMetadata(10);
  res.json({ ok: true, total, topHot: hot });
});
app.get('/api/admin/content-cache/stats', requireAdmin, (req, res) => {
  const s = db.contentCacheStats();
  res.json({ ok: true, ...s });
});
app.get('/api/admin/content-cache/books', requireAdmin, (req, res) => {
  const limit = Math.max(10, Math.min(500, parseInt(req.query.limit, 10) || 100));
  const books = db.contentCacheListBooks(limit);
  const enriched = books.map(b => {
    const metas = db.searchMetadataCache(b.book_title, 1);
    const meta = metas.find(m => m.author === (b.book_author || ''));
    return {
      ...b,
      cover_url: meta?.cover_url || null,
      intro: meta?.intro || null,
      category: meta?.category || null,
      word_count: meta?.word_count || null,
    };
  });
  res.json({ ok: true, books: enriched });
});
app.get('/api/admin/content-cache/chapters', requireAdmin, (req, res) => {
  const title = (req.query.title || '').trim();
  const author = (req.query.author || '').trim();
  if (!title) return res.status(400).json({ ok: false, msg: 'title required' });
  const limit = Math.max(1, Math.min(200, parseInt(req.query.limit, 10) || 50));
  const offset = Math.max(0, parseInt(req.query.offset, 10) || 0);
  const chapters = db.contentCacheGetChapterContent(title, author, limit, offset);
  res.json({ ok: true, chapters });
});

// --- admin 反馈 ---
app.get('/api/admin/feedback', requireAdmin, (req, res) => {
  const status = req.query.status || null;
  const limit = Math.max(10, Math.min(500, parseInt(req.query.limit, 10) || 200));
  res.json({ ok: true, list: db.listFeedback({ status, limit }), stats: db.feedbackStats() });
});
app.patch('/api/admin/feedback/:id', requireAdmin, (req, res) => {
  const id = parseInt(req.params.id, 10);
  const { status, reply } = req.body || {};
  if (!id) return res.status(400).json({ ok: false, msg: 'invalid id' });
  try { db.updateFeedbackStatus(id, status, reply); res.json({ ok: true }); }
  catch (e) { res.status(400).json({ ok: false, msg: e.message }); }
});

// --- admin 公告 ---
app.get('/api/admin/announcements', requireAdmin, (req, res) => res.json({ ok: true, list: db.listAllAnnouncements() }));
app.post('/api/admin/announcement', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  try { const id = db.upsertAnnouncement(req.body || {}); res.json({ ok: true, id }); }
  catch (e) { res.status(400).json({ ok: false, msg: e.message }); }
});
app.delete('/api/admin/announcement/:id', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  db.deleteAnnouncement(req.params.id); res.json({ ok: true });
});

// --- admin 推广代理码 ---
app.get('/api/admin/promo/codes', requireAdmin, (req, res) => res.json({ ok: true, list: db.listPromoCodes() }));
app.post('/api/admin/promo/codes', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  try {
    const { code, agentName, maxUses, singleDevice, expiresAt } = req.body || {};
    const result = db.createPromoCode({ code, agentName, maxUses, singleDevice, expiresAt, creator: req.admin.username });
    res.json({ ok: true, ...result });
  } catch (e) { res.status(400).json({ ok: false, msg: e.message }); }
});
app.put('/api/admin/promo/codes/:code', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  const ok = db.updatePromoCode(req.params.code, req.body || {});
  if (ok)
  res.json({ ok });
});
app.delete('/api/admin/promo/codes/:code', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  const ok = db.deletePromoCode(req.params.code);
  if (ok)
  res.json({ ok });
});
app.get('/api/admin/promo/stats', requireAdmin, (req, res) => res.json({ ok: true, ...db.promoOverview() }));
app.get('/api/admin/promo/stats/:code', requireAdmin, (req, res) => res.json({ ok: true, ...db.promoCodeStats(req.params.code) }));
app.get('/api/admin/promo/fraud', requireAdmin, (req, res) => res.json({ ok: true, alerts: db.promoFraudDetection() }));

// ═══════════════════ 静态文件 + 兜底 ═══════════════════

app.use(express.static(path.join(__dirname, 'public')));
app.get(['/admin', '/admin/*'], (req, res) => res.sendFile(path.join(__dirname, 'public', 'admin.html')));
app.get('/', (req, res) => res.redirect('/admin'));

// 全局错误处理
// eslint-disable-next-line no-unused-vars
app.use((err, req, res, next) => {
  const status = err.status || (err.type === 'entity.parse.failed' ? 400 : 500);
  logger.error('request error', { method: req.method, url: req.url, status, msg: err.message });
  res.status(status).json({ ok: false, msg: err.message || 'server error' });
});

// ═══════════════════ 启动 ═══════════════════

let server = null;
function start() {
  server = app.listen(PORT, () => {
    logger.info('backend listening', { port: PORT, admin: `http://0.0.0.0:${PORT}/admin` });
  });
  scheduleMirrorJob(db);
  process.on('SIGTERM', () => gracefulShutdown('SIGTERM'));
  process.on('SIGINT', () => gracefulShutdown('SIGINT'));
  return server;
}

function gracefulShutdown(signal) {
  logger.info('shutting down', { signal });
  const forceExitTimer = setTimeout(() => { logger.error('force exit after 10s'); process.exit(1); }, 10_000);
  forceExitTimer.unref();
  if (!server) { try { db.__db.close(); } catch {} return process.exit(0); }
  server.close(err => {
    if (err) { logger.error('http close error', { msg: err.message }); process.exit(1); }
    try { db.__db.close(); } catch (e) { logger.error('db close error', { msg: e.message }); }
    logger.info('shutdown complete');
    process.exit(0);
  });
}

if (require.main === module) { start(); }

module.exports = { app, start, gracefulShutdown };
